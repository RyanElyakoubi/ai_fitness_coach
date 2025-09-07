import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../models/score_response.dart';
import '../models/score_labels.dart';
import '../models/coach_insights.dart';
import 'coach_prompt.dart';

class PayloadTooLarge implements Exception {
  final String msg;
  PayloadTooLarge(this.msg);
  @override
  String toString() => msg;
}

const bool kFakeAnalysis = false;
const _endpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';
const _timeout = Duration(seconds: 120);

// Precheck constants
const _precheckSystemPreamble = '''
You are a strict movement classifier for fitness videos.

Decide if the video depicts ANY variety of CHEST PRESS:
- Bench press (barbell)
- Dumbbell bench press (flat/incline/decline)
- Smith/machine chest press

Exclude: squats, deadlifts, OHP/shoulder press, rows, curls, cardio, random content, talking heads.

Return STRICT JSON only:
{"is_chest_press": true|false, "reason": "<short phrase 3-10 words>"}
No extra words. No markdown. No trailing commas.
''';

String _precheckUserPrompt({required bool portraitHint}) => '''
Determine if this video is a chest-press movement.
Camera orientation hint: ${portraitHint ? "portrait" : "landscape"}.
Return only the JSON object as specified.
''';

Future<String> _loadRubric() async {
  final s = await rootBundle.loadString('assets/bench_rubric.md');
  return s.length > 12000 ? s.substring(0, 12000) : s;
}

Future<String> _loadSchema() async {
  return await rootBundle.loadString('assets/bench_schema.json');
}

FailureInfo _parseFailure(Map<String, dynamic> m) {
  final statusStr = (m['status'] as String).trim();
  final status = statusStr == 'no_set'
      ? AnalysisStatus.no_set
      : AnalysisStatus.insufficient;

  final reasons = <FailReason>[];
  final rationale = <FailReason, String>{};

  if (status == AnalysisStatus.insufficient) {
    final List<dynamic> arr = (m['fail_reasons'] ?? []) as List<dynamic>;
    for (final r in arr) {
      switch ((r as String).trim()) {
        case 'poor_lighting': reasons.add(FailReason.poor_lighting); break;
        case 'subject_out_of_frame': reasons.add(FailReason.subject_out_of_frame); break;
        case 'camera_motion': reasons.add(FailReason.camera_motion); break;
        case 'too_short_clip': reasons.add(FailReason.too_short_clip); break;
        case 'blurry_frames': reasons.add(FailReason.blurry_frames); break;
        case 'wrong_orientation': reasons.add(FailReason.wrong_orientation); break;
        case 'occlusions': reasons.add(FailReason.occlusions); break;
        case 'bar_not_visible': reasons.add(FailReason.bar_not_visible); break;
        case 'multiple_people': reasons.add(FailReason.multiple_people); break;
        case 'file_corrupt': reasons.add(FailReason.file_corrupt); break;
      }
    }
    final Map<String, dynamic> rat = (m['rationale'] ?? {}) as Map<String, dynamic>;
    for (final e in rat.entries) {
      final key = e.key.trim();
      final val = e.value.toString();
      final fr = {
        'poor_lighting': FailReason.poor_lighting,
        'subject_out_of_frame': FailReason.subject_out_of_frame,
        'camera_motion': FailReason.camera_motion,
        'too_short_clip': FailReason.too_short_clip,
        'blurry_frames': FailReason.blurry_frames,
        'wrong_orientation': FailReason.wrong_orientation,
        'occlusions': FailReason.occlusions,
        'bar_not_visible': FailReason.bar_not_visible,
        'multiple_people': FailReason.multiple_people,
        'file_corrupt': FailReason.file_corrupt,
      }[key];
      if (fr != null) rationale[fr] = val;
    }
  }

  return FailureInfo(status: status, reasons: reasons, rationale: rationale);
}

ScoreResponse parseScoreOk(Map<String, dynamic> m) {
  final scores = (m['scores'] ?? {}) as Map<String, dynamic>;
  int holistic = (scores['holistic'] ?? 0).round();
  int form = (scores['form'] ?? 0).round();
  int intensity = (scores['intensity'] ?? 0).round();

  // Form subs
  final fs = <CategoryScore<SubFormKey>>[];
  final fm = (m['form_subscores'] ?? {}) as Map<String, dynamic>;
  if (fm.isNotEmpty) {
    fs.add(CategoryScore(key: SubFormKey.bar_path, score: (fm['bar_path'] ?? 0).round()));
    fs.add(CategoryScore(key: SubFormKey.range_of_motion, score: (fm['range_of_motion'] ?? 0).round()));
    fs.add(CategoryScore(key: SubFormKey.stability, score: (fm['stability'] ?? 0).round()));
    fs.add(CategoryScore(key: SubFormKey.elbow_wrist, score: (fm['elbow_wrist'] ?? 0).round()));
    fs.add(CategoryScore(key: SubFormKey.leg_drive, score: (fm['leg_drive'] ?? 0).round()));
    form = weightedForm(fs);
  }

  // Intensity subs
  final isubs = <CategoryScore<SubIntensityKey>>[];
  final im = (m['intensity_subscores'] ?? {}) as Map<String, dynamic>;
  if (im.isNotEmpty) {
    isubs.add(CategoryScore(key: SubIntensityKey.power, score: (im['power'] ?? 0).round()));
    isubs.add(CategoryScore(key: SubIntensityKey.uniformity, score: (im['uniformity'] ?? 0).round()));
    isubs.add(CategoryScore(key: SubIntensityKey.proximity_failure, score: (im['proximity_failure'] ?? 0).round()));
    isubs.add(CategoryScore(key: SubIntensityKey.cadence, score: (im['cadence'] ?? 0).round()));
    isubs.add(CategoryScore(key: SubIntensityKey.bar_speed_consistency, score: (im['bar_speed_consistency'] ?? 0).round()));
    intensity = weightedIntensity(isubs);
  }

  // Extract details
  final details = (m['details'] ?? {}) as Map<String, dynamic>;
  final issues = ((details['issues'] as List?) ?? const [])
      .whereType<Map<String, dynamic>>()
      .map((issue) => IssueItem.fromJson(issue))
      .toList();
  final cues = ((details['cues'] as List?) ?? const [])
      .map((e) => e.toString())
      .toList();

  // If holistic missing, compute default 0.5/0.5
  if (holistic == 0 && (form > 0 || intensity > 0)) {
    holistic = ((form + intensity) / 2).round();
  }

  return ScoreResponse.success(
    holistic: holistic.clamp(0, 100),
    form: form.clamp(0, 100),
    intensity: intensity.clamp(0, 100),
    issues: issues,
    cues: cues,
    formSubs: fs,
    intensitySubs: isubs,
  );
}

class GeminiService {

  static Future<ScoreResponse> analyze({
    required List<String> framesBase64Jpeg,
    required List<String> snippetsBase64Mp4,
    Map<String, dynamic>? requestHints,
  }) async {
    debugPrint("GeminiService.analyze called with kFakeAnalysis=$kFakeAnalysis");
    
    if (kFakeAnalysis) {
      debugPrint("Using fake analysis - returning dummy score");
      await Future.delayed(const Duration(milliseconds: 800));
      return ScoreResponse.success(
        holistic: 78, form: 74, intensity: 82, issues: [], cues: []
      ).recomputeHolistic();
    }

    final key = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'AIzaSyA9EsZLwlAv2c1m9N70ehO1jzhqA9jMdbs');
    debugPrint("API Key length: ${key.length}, starts with: ${key.isNotEmpty ? key.substring(0, 10) : 'empty'}");
    
    if (key.isEmpty) {
      debugPrint("API key is empty - throwing exception");
      throw Exception('GEMINI_API_KEY missing. Run with --dart-define=GEMINI_API_KEY=YOUR_KEY');
    }

    // Load rubric and schema for accurate scoring (available for future use)
    // final rubric = await _loadRubric();
    // final schema = await _loadSchema();
    
    bool retriedOnce = false;

    Future<ScoreResponse> _call(List<String> imgs, List<String> clips, {bool strict = false, Map<String, dynamic>? hints}) async {
      debugPrint("Using consistent rubric-based scoring for maximum accuracy");
      
      final hintsText = hints != null ? '''

Input hints:
- Pipeline: ${hints['pipeline'] ?? 'unknown'}
- Video duration: ${((hints['trimmed_window_ms'] ?? 0) / 1000).toStringAsFixed(1)}s
- Window: ${hints['gate_confident'] == true ? 'confident motion detection' : 'fallback window'}
- Frame count: ${imgs.length} images extracted from workout window
- Analysis scope: Full bench press set with setup, execution, and completion
''' : '';
      
      final parts = <Map<String, dynamic>>[
        {
          "text": '''You are an expert powerlifting judge analyzing bench press technique.$hintsText

CRITICAL: Always attempt to score the lift unless the video is completely unusable. Be very lenient and focus on providing helpful feedback rather than rejecting videos.

IMPORTANT: These frames represent a complete bench press training set extracted from a longer video. If the frames show any bench press sequence (even partial), attempt to score it. Poor lighting, slight blur, or minor visibility issues should NOT prevent scoring - just score lower and note the limitations.

Return ONLY valid JSON that conforms to this schema:
{
  "status": "ok" | "no_set" | "insufficient",
  "fail_reasons": string[] (only when status="insufficient"),
  "rationale": { string: string } (map from reason code to the exact scripted sentence),
  "scores": { "holistic": number, "form": number, "intensity": number } (when status="ok"),
  "details": { ... } (optional extra)
}

REJECTION GUIDELINES - Only use "insufficient" status in these extreme cases:
- Video is completely dark/blurry (unable to see anything)
- No person visible at all in any frame
- Clearly not a bench press or any lifting movement
- Video file is corrupted and cannot be analyzed

DO NOT reject for:
- Poor lighting (score lower instead)
- Slight blur (score lower instead) 
- Bar not perfectly visible (score lower instead)
- Multiple people in frame (score the main lifter)
- Camera movement (score lower instead)
- Short duration (score what you can see)
- Wrong orientation (score anyway)

If no training set is detected (e.g., completely random content, not a lift), respond with:
{ "status": "no_set" }

If conditions are truly insufficient (completely unusable video), respond with:
{
  "status": "insufficient",
  "fail_reasons": ["<one or more enums>"],
  "rationale": {
     "<reason>": "<exact canonical sentence below>"
  }
}

Reason codes (enums) - use sparingly:
- "poor_lighting" (only if completely dark)
- "subject_out_of_frame" (only if no person visible at all)
- "camera_motion" (only if completely unusable)
- "too_short_clip" (only if no movement visible)
- "blurry_frames" (only if completely blurred)
- "wrong_orientation" (only if cannot analyze at all)
- "occlusions" (only if completely blocked)
- "bar_not_visible" (only if no bar visible at all)
- "multiple_people" (only if cannot identify main lifter)
- "file_corrupt" (only if file cannot be decoded)

Canonical rationale strings (use verbatim):
- poor_lighting: "Video failed due to poor lighting."
- subject_out_of_frame: "Lifter and/or barbell not fully visible in frame."
- camera_motion: "Camera moved too much during the set."
- too_short_clip: "Clip is too short to analyze a set."
- blurry_frames: "Video is too blurry for reliable analysis."
- wrong_orientation: "Video orientation is not portrait."
- occlusions: "Lifter or barbell is blocked from view."
- bar_not_visible: "Barbell is not visible enough to analyze bar path."
- multiple_people: "Multiple people in frame caused ambiguity."
- file_corrupt: "Video file couldn't be decoded."

When status="ok", include scores and continue with the normal scoring output:
{
  "status": "ok",
  "scores": {
    "form": score_0_to_100,
    "intensity": score_0_to_100,
    "holistic": score_0_to_100
  },
  "form_subscores": {
    "bar_path": number,
    "range_of_motion": number,
    "stability": number,
    "elbow_wrist": number,
    "leg_drive": number
  },
  "intensity_subscores": {
    "power": number,
    "uniformity": number,
    "proximity_failure": number,
    "cadence": number,
    "bar_speed_consistency": number
  },
  "details": {
    "issues": ["specific_technical_issues"],
    "cues": ["actionable_coaching_advice"]
  }
}

Overall "form" should be the evenly weighted mean (0.20 each) of the 5 form_subscores.
Overall "intensity" should be the evenly weighted mean (0.20 each) of the 5 intensity_subscores.

Return JSON only, no explanation.'''
        },
      ];
      for (final b64 in imgs) {
        parts.add({"inlineData": {"mimeType": "image/jpeg", "data": b64}});
      }
      for (final b64 in clips) {
        parts.add({"inlineData": {"mimeType": "video/mp4", "data": b64}});
      }

      final body = {
        "contents": [
          {"parts": parts}
        ],
        "generationConfig": {
          "temperature": 0.7, // Higher temperature for more varied, realistic scoring
          "maxOutputTokens": 512,
          "responseMimeType": "application/json"
        },
        "safetySettings": []
      };

      final uri = Uri.parse("$_endpoint?key=$key");
      final resp = await http
          .post(uri, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(_timeout);

      debugPrint(
          "Gemini status=${resp.statusCode} bytes=${resp.bodyBytes.length} imgs=${imgs.length} clips=${clips.length}");

      if (resp.statusCode == 413 || resp.statusCode == 400) {
        throw PayloadTooLarge("status ${resp.statusCode}");
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw Exception("Gemini auth error ${resp.statusCode}. Check API key / project.");
      }
      if (resp.statusCode != 200) {
        final bodySnippet = resp.body.substring(0, math.min(400, resp.body.length));
        throw Exception("Gemini error ${resp.statusCode}: $bodySnippet");
      }

      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final pf = map["promptFeedback"];
      if (pf != null && pf is Map && pf["safetyRatings"] != null) {
        final failure = FailureInfo(
          status: AnalysisStatus.insufficient,
          reasons: [FailReason.poor_lighting, FailReason.subject_out_of_frame],
          rationale: {
            FailReason.poor_lighting: "Video failed due to poor lighting.",
            FailReason.subject_out_of_frame: "Lifter and/or barbell not fully visible in frame.",
          },
        );
        return ScoreResponse.failure(failure);
      }

      final candidates = (map["candidates"] as List?) ?? const [];
      if (candidates.isEmpty) {
        throw Exception("No candidates in response");
      }
      final partsOut = (candidates.first["content"]?["parts"] as List?) ?? const [];
      final buf = StringBuffer();
      for (final p in partsOut) {
        final t = p["text"];
        if (t is String) buf.write(t);
      }
      var text = buf.toString().trim();
      if (text.startsWith("```")) {
        text = text.replaceAll(RegExp(r"^```[a-zA-Z]*\n|\n```\s*$"), "");
      }

      Map<String, dynamic> payload;
      try {
        payload = jsonDecode(text) as Map<String, dynamic>;
      } catch (e) {
        throw Exception("JSON parse failed: ${e.toString().split('\n').first}");
      }
      
      // Check status to determine if this is success or failure
      final status = payload['status']?.toString().trim() ?? 'ok';
      
      if (status == 'no_set') {
        // Only reject if it's clearly not a lifting video at all
        final failure = _parseFailure(payload);
        debugPrint("Gemini returned no_set: ${failure.reasons}");
        return ScoreResponse.failure(failure);
      } else if (status == 'insufficient') {
        // Parse failure reasons but be very lenient
        final failure = _parseFailure(payload);
        debugPrint("Gemini returned insufficient: status=$status, reasons=${failure.reasons}");
        
        // Only reject if it's truly unusable (completely dark, not a lift, or no subject visible)
        final criticalReasons = [
          FailReason.file_corrupt,
          FailReason.subject_out_of_frame, // Only if truly no subject visible
        ];
        
        // Check if ALL failure reasons are critical (meaning truly unusable)
        final hasOnlyCriticalReasons = failure.reasons.isNotEmpty && 
            failure.reasons.every((reason) => criticalReasons.contains(reason));
        
        // Also check if we have multiple severe issues that make analysis impossible
        final hasMultipleSevereIssues = failure.reasons.length >= 3 && 
            failure.reasons.any((reason) => [
              FailReason.blurry_frames,
              FailReason.poor_lighting,
              FailReason.bar_not_visible,
              FailReason.subject_out_of_frame,
            ].contains(reason));
        
        if (hasOnlyCriticalReasons || hasMultipleSevereIssues) {
          debugPrint("Video is truly unusable, rejecting");
          return ScoreResponse.failure(failure);
        } else {
          // Video has issues but is still analyzable - return low scores instead of rejecting
          debugPrint("Video has issues but is analyzable, returning low scores");
          return ScoreResponse(
            success: true,
            holistic: 0,
            form: 0,
            intensity: 0,
            issues: const [],
            cues: const [],
            insufficient: true,
            insufficientReasons: failure.reasons.map((r) => r.toString()).toList(),
            formSubs: const [],
            intensitySubs: const [],
          );
        }
      } else {
        // Parse success using new sub-score aware parser
        final result = parseScoreOk(payload);
        debugPrint("Gemini returned: form=${result.form}, intensity=${result.intensity}, holistic=${result.holistic}");
        return result;
      }
    }

    // Require actual media for analysis
    // Only fail if we truly have no media at all
    if (framesBase64Jpeg.isEmpty && snippetsBase64Mp4.isEmpty) {
      debugPrint("No frames or snippets available - cannot perform analysis");
      final failureInfo = FailureInfo(
        status: AnalysisStatus.insufficient,
        reasons: [FailReason.file_corrupt],
        rationale: {FailReason.file_corrupt: "No video frames could be extracted"},
      );
      return ScoreResponse.failure(failureInfo);
    }

    try {
      debugPrint("Attempting Gemini API call with ${framesBase64Jpeg.length} frames and ${snippetsBase64Mp4.length} snippets");
      
      // Strategy 1: Try maximum detail first - more frames for better analysis
      if (framesBase64Jpeg.isNotEmpty) {
        final maxFrames = math.min(framesBase64Jpeg.length, 12); // Send up to 12 frames for detailed analysis
        final result = await _call(
          framesBase64Jpeg.take(maxFrames).toList(),
          snippetsBase64Mp4.take(1).toList(), // Include 1 video clip if available
          hints: requestHints,
        );
        
        // Guardrail: If status=insufficient but we sent >=20 images, retry once with images-only
        final imagesCount = framesBase64Jpeg.length;
        
        if (result.success == false && result.holistic == 0 && 
            imagesCount >= 20 && !retriedOnce) {
          retriedOnce = true;
          debugPrint("Gemini returned insufficient but we have ${imagesCount} images. Retrying with images-only...");
          
          // Retry with images only (no clips) and re-subsampled frames
          final imageOnlyFrames = math.min(40, framesBase64Jpeg.length);
          final result2 = await _call(
            framesBase64Jpeg.take(imageOnlyFrames).toList(),
            const [], // No clips
            hints: {...?requestHints, 'retry_reason': 'insufficient_with_good_payload'},
          );
          debugPrint("Gemini retry result: holistic=${result2.holistic}, form=${result2.form}, intensity=${result2.intensity}");
          return result2;
        }
        
        debugPrint("Gemini API call successful: holistic=${result.holistic}, form=${result.form}, intensity=${result.intensity}");
        return result;
      } else {
        // If no frames, use video clips only
        final result = await _call(
          const [],
          snippetsBase64Mp4.take(1).toList(),
          hints: requestHints,
        );
        debugPrint("Gemini API call successful (video only): holistic=${result.holistic}, form=${result.form}, intensity=${result.intensity}");
        return result;
      }
    } on PayloadTooLarge catch (e) {
      debugPrint("Payload too large, retrying with reduced payload: $e");
      
      try {
        // Strategy 2: Reduce to 6 key frames
        if (framesBase64Jpeg.length >= 6) {
          final keyFrames = [
            framesBase64Jpeg[0], // Setup
            framesBase64Jpeg[1], // Descent
            framesBase64Jpeg[2], // Bottom
            framesBase64Jpeg[3], // Press
            framesBase64Jpeg[math.min(4, framesBase64Jpeg.length - 1)], // Lockout
            framesBase64Jpeg[framesBase64Jpeg.length - 1], // Final
          ];
          final result = await _call(keyFrames, const [], hints: requestHints);
          debugPrint("Gemini API retry successful (6 frames): holistic=${result.holistic}, form=${result.form}, intensity=${result.intensity}");
          return result;
        } else {
          // Strategy 3: Minimal payload - 3 best frames
          final minFrames = framesBase64Jpeg.take(3).toList();
          final result = await _call(minFrames, const [], hints: requestHints);
          debugPrint("Gemini API retry successful (3 frames): holistic=${result.holistic}, form=${result.form}, intensity=${result.intensity}");
          return result;
        }
      } catch (e2) {
        debugPrint("Second retry failed: $e2");
        rethrow;
      }
    } catch (e) {
      debugPrint("Gemini API call failed: $e");
      rethrow;
    }
  }

  static Future<String> generateCoachAnalysis({
    required int holistic,
    required int form,
    required int intensity,
    Map<String, num>? formBreakdown,
    Map<String, num>? intensityBreakdown,
    String model = 'gemini-1.5-flash',
    Duration timeout = const Duration(seconds: 18),
  }) async {
    final prompt = CoachPrompt.build(
      holistic: holistic,
      form: form,
      intensity: intensity,
      formCats: formBreakdown,
      intensityCats: intensityBreakdown,
    );

    Future<String> _once() async {
      final key = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'AIzaSyA9EsZLwlAv2c1m9N70ehO1jzhqA9jMdbs');
      final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key');
      final body = {
        "contents": [
          {
            "parts": [
              {"text": prompt}
            ]
          }
        ],
        "generationConfig": {
          "temperature": 0.8,
          "topK": 40,
          "topP": 0.9,
          "maxOutputTokens": 220
        }
      };

      final res = await http
          .post(uri, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(timeout);

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final j = jsonDecode(res.body);
        final candidates = (j["candidates"] as List?) ?? const [];
        if (candidates.isNotEmpty) {
          final text = (candidates.first["content"]["parts"] as List).map((p) => p["text"]).join("\n");
          // Safety: trim and enforce 5–8 sentences if model returns more
          final sents = text
              .replaceAll('\n', ' ')
              .split(RegExp(r'(?<=[.!?])\s+'))
              .where((s) => s.trim().isNotEmpty)
              .toList();
          final clamped = sents.take(8).join(' ');
          return clamped;
        }
        throw Exception("Empty Gemini response");
      } else {
        throw Exception("Gemini ${res.statusCode}: ${res.body}");
      }
    }

    try {
      return await _once();
    } catch (e) {
      // Simple retry for 429/5xx or network glitches
      return await _once();
    }
  }

  static Future<CoachInsights> generateCoachInsights({
    required int holistic,
    required int form,
    required int intensity,
    Map<String, num>? formBreakdown,
    Map<String, num>? intensityBreakdown,
    String model = 'gemini-1.5-flash',
    Duration timeout = const Duration(seconds: 18),
  }) async {
    final prompt = CoachPrompt.buildInsightsJson(
      holistic: holistic,
      form: form,
      intensity: intensity,
      formCats: formBreakdown,
      intensityCats: intensityBreakdown,
    );

    Future<CoachInsights> _once() async {
      final key = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'AIzaSyA9EsZLwlAv2c1m9N70ehO1jzhqA9jMdbs');
      final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$key');
      final body = {
        "contents": [
          {
            "parts": [
              {"text": prompt}
            ]
          }
        ],
        "generationConfig": {
          "temperature": 0.7,
          "topK": 40,
          "topP": 0.9,
          "maxOutputTokens": 320,
        }
      };

      final res = await http
          .post(uri, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(timeout);

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception("Gemini ${res.statusCode}: ${res.body}");
      }

      final j = jsonDecode(res.body);
      final candidates = (j["candidates"] as List?) ?? const [];
      if (candidates.isEmpty) throw Exception("Empty Gemini response");

      final text = (candidates.first["content"]["parts"] as List).map((p) => p["text"]).join("\n").toString().trim();

      // Extract JSON (strip stray chars if any)
      final start = text.indexOf('{');
      final end = text.lastIndexOf('}');
      if (start < 0 || end < 0 || end <= start) throw Exception("Invalid JSON from model");
      final jsonSlice = text.substring(start, end + 1);

      final Map<String, dynamic> parsed = json.decode(jsonSlice);
      return CoachInsights.fromJson(parsed);
    }

    try {
      return await _once();
    } catch (_) {
      // brief retry for transient errors
      return await _once();
    }
  }

  /// Fast pre-check to classify if video is a chest press movement
  static Future<PrecheckResult> classifyIsChestPress({
    required List<Uint8List> scoutFramesJpeg,
    required bool portraitHint,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    // If we somehow have no frames, allow analysis (fail-open)
    if (scoutFramesJpeg.isEmpty) {
      return PrecheckResult(isChestPress: true, reason: "no frames; fail-open");
    }

    final key = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: 'AIzaSyA9EsZLwlAv2c1m9N70ehO1jzhqA9jMdbs');
    if (key.isEmpty) {
      return PrecheckResult(isChestPress: true, reason: "no API key; fail-open");
    }

    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$key');

    // Build parts: system preamble + user instruction + up to 8 images
    final inputs = <Map<String, dynamic>>[
      {"text": _precheckSystemPreamble},
      {"text": _precheckUserPrompt(portraitHint: portraitHint)},
    ];

    // Attach images (base64) as inline data; cap at 8
    final capped = scoutFramesJpeg.take(8).toList();
    for (final bytes in capped) {
      inputs.add({
        "inline_data": {
          "mime_type": "image/jpeg",
          "data": base64Encode(bytes),
        }
      });
    }

    final body = {
      "contents": [
        {
          "role": "user",
          "parts": inputs,
        }
      ],
      "generationConfig": {
        "temperature": 0.1,
        "topP": 0.2,
        "topK": 20,
        "maxOutputTokens": 64,
        "responseMimeType": "application/json"
      }
    };

    try {
      final resp = await http
          .post(uri, headers: {"Content-Type": "application/json"}, body: jsonEncode(body))
          .timeout(timeout);

      if (resp.statusCode != 200) {
        debugPrint("Precheck API error ${resp.statusCode}: ${resp.body}");
        return PrecheckResult(isChestPress: true, reason: "API error; fail-open");
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final candidates = (data["candidates"] as List?) ?? const [];
      if (candidates.isEmpty) {
        return PrecheckResult(isChestPress: true, reason: "no response; fail-open");
      }

      final partsOut = (candidates.first["content"]?["parts"] as List?) ?? const [];
      final buf = StringBuffer();
      for (final p in partsOut) {
        final t = p["text"];
        if (t is String) buf.write(t);
      }
      var text = buf.toString().trim();
      
      // Clean up any markdown formatting
      if (text.startsWith("```")) {
        text = text.replaceAll(RegExp(r"^```[a-zA-Z]*\n|\n```\s*$"), "");
      }

      // Strict JSON parse, fallback to pass-through if invalid
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      final isChest = (parsed["is_chest_press"] == true);
      final reason = (parsed["reason"] ?? "").toString();
      
      debugPrint("Precheck result: isChestPress=$isChest, reason=$reason");
      return PrecheckResult(isChestPress: isChest, reason: reason);
    } catch (e) {
      debugPrint("Precheck failed: $e");
      // Do not block; allow analysis if precheck failed
      return PrecheckResult(isChestPress: true, reason: "precheck error; fail-open");
    }
  }

}
