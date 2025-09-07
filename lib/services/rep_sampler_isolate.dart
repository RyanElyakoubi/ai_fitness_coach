import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bench_mvp/services/isolate_runner.dart';
import 'package:bench_mvp/services/motion_gate.dart';
import 'package:bench_mvp/services/video_utils_channel.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
// import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart'; // keep as fallback

class SamplingResult {
  final List<Uint8List> anchors;
  final List<Uint8List> frames;
  final List<SamplingClip> clips;
  final String gateRationale;
  final bool gateConfident;
  final int trimmedStartMs;
  final int trimmedEndMs;
  final Map<String, dynamic> meta;
  
  SamplingResult({
    required this.anchors,
    required this.frames,
    required this.clips,
    required this.gateRationale,
    required this.gateConfident,
    required this.trimmedStartMs,
    required this.trimmedEndMs,
    required this.meta,
  });
}

class SamplingClip {
  final Uint8List bytes;
  final int startMs;
  final int endMs;
  
  SamplingClip({required this.bytes, required this.startMs, required this.endMs});
}

class _IsoInput {
  final String path;
  final int durationMs;
  final int maxImages; // <= 60
  final int maxClips;  // <= 2
  _IsoInput(this.path, this.durationMs, this.maxImages, this.maxClips);
}

class _IsoOutput {
  final List<Uint8List> anchors;
  final List<Uint8List> frames;
  final List<_Clip> clips;
  final MotionGateResult gate;
  _IsoOutput(this.anchors, this.frames, this.clips, this.gate);
}

class _Clip {
  final Uint8List bytes; // mp4
  final int startMs;
  final int endMs;
  _Clip(this.bytes, this.startMs, this.endMs);
}

class RepAwareSampler {
  Future<SamplingResult> sample(String pickedPath) async {
    final sw = Stopwatch()..start();
    
    // 1) Ensure local + precise duration (fast, native)
    final ensured = await VideoUtilsChannel.ensureLocalAndDuration(pickedPath);
    final localPath = ensured['path'] as String;
    final durMs = ensured['durationMs'] as int;

    // 2) Pre-probe thumbnails on the UI isolate BUT trivially light work (every 400ms, quality=20)
    //    This is cheap (byte-size only), won't block animation.
    final headBudget = math.min(durMs, MotionGate.kScanBudgetHeadMs);
    final times = <int>[];
    final sizes = <int>[];
    for (int t = 0; t <= headBudget; t += MotionGate.kStepMs) {
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: localPath,
          imageFormat: ImageFormat.JPEG,
          timeMs: t,
          quality: 20,
        );
        if (data != null) { times.add(t); sizes.add(data.length); }
      } catch (_) {/* ignore */}
    }

    // 3) Gate the window (trim dead time)
    final gate = MotionGate.detect(probeTimesMs: times, jpegSizes: sizes, durationMs: durMs);
    final start = math.max(0, gate.startMs);
    final end = math.min(durMs, gate.endMs);
    final windowMs = math.max(2000, end - start);

    print("Trimmed window: start=${start}ms end=${end}ms len=${windowMs}ms confident=${gate.confident} reason=${gate.rationale}");

    // 4) Offload the actual sampling + clip cutting to a background isolate
    final isoOut = await IsolateRunner.run<_IsoInput, _IsoOutput>(_isoWork, _IsoInput(localPath, windowMs, 60, 2));

    print("Payload: anchors=${isoOut.anchors.length} images=${isoOut.frames.length} clips=${isoOut.clips.length}");

    // 5) Map to your existing SamplingResult type
    return SamplingResult(
      anchors: isoOut.anchors,
      frames: isoOut.frames,
      clips: isoOut.clips.map((c) => SamplingClip(bytes: c.bytes, startMs: c.startMs, endMs: c.endMs)).toList(),
      gateRationale: gate.rationale,
      gateConfident: gate.confident,
      trimmedStartMs: start,
      trimmedEndMs: end,
      meta: {
        'strategy': 'isolate_motion_gate',
        'duration_ms': durMs,
        'elapsed_ms': sw.elapsedMilliseconds,
        'window_ms': windowMs,
        'gate_confident': gate.confident,
      },
    );
  }
}

// Isolate worker function
Future<_IsoOutput> _isoWork(_IsoInput inp) async {
  final anchors = <Uint8List>[];
  final frames = <Uint8List>[];
  final clips = <_Clip>[];

  final windowStart = 0; // isolate receives a windowed asset; treat 0 as start
  final windowEnd = inp.durationMs;
  final stepDenseMs = 35; // ~28 fps equivalent but we sub-sample later
  final anchorCount = 5;

  // Anchor positions spread across the window
  for (int i = 0; i < anchorCount; i++) {
    final t = (windowStart + ((i + 1) * (windowEnd - windowStart) / (anchorCount + 1))).toInt();
    final data = await _thumbIso(inp.path, t, q: 40);
    if (data != null) anchors.add(data);
  }

  // Dense pass: collect every 35ms, then **stratified subsample** to cap images<=60
  final dense = <Uint8List>[];
  for (int t = windowStart; t <= windowEnd; t += stepDenseMs) {
    final data = await _thumbIso(inp.path, t, q: 38);
    if (data != null) dense.add(data);
  }
  // Subsample to budget
  final want = math.max(0, inp.maxImages - anchors.length);
  final keep = _stratifiedPick(dense, want);
  frames.addAll(keep);

  // Quick 2 short clips ~0.9s around max-motion zones (find by JPEG-size deltas)
  if (inp.maxClips > 0 && dense.length >= 12) {
    final deltas = <int>[];
    for (int i = 1; i < dense.length; i++) {
      deltas.add((dense[i].length - dense[i - 1].length).abs());
    }
    final tops = _topKIndices(deltas, k: inp.maxClips, minSpacing: 40);
    for (final idx in tops) {
      final midMs = windowStart + (idx * stepDenseMs);
      final startMs = math.max(windowStart, midMs - 450);
      final endMs = math.min(windowEnd, midMs + 450);
      final bytes = await _cutClipIso(inp.path, startMs, endMs);
      if (bytes != null) clips.add(_Clip(bytes, startMs, endMs));
    }
  }

  return _IsoOutput(anchors, frames, clips, MotionGateResult(startMs: 0, endMs: inp.durationMs, confident: true, rationale: 'iso_window'));
}

Future<Uint8List?> _thumbIso(String path, int tMs, {int q = 40}) async {
  // Use VideoThumbnail; retry light. If fails, ffmpeg fallback.
  try {
    final data = await VideoThumbnail.thumbnailData(video: path, imageFormat: ImageFormat.JPEG, timeMs: tMs, quality: q);
    if (data != null) return data;
  } catch (_) {}
  
  // FFmpeg fallback commented out since dependency might not be available
  /*
  try {
    final tmp = '/tmp/iso_ff_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final ss = (tMs / 1000).toStringAsFixed(3);
    await FFmpegKit.execute('-y -ss $ss -i "$path" -frames:v 1 -q:v 3 "$tmp"');
    final f = File(tmp);
    if (await f.exists()) {
      final b = await f.readAsBytes();
      unawaited(f.delete());
      return b;
    }
  } catch (_) {}
  */
  return null;
}

Future<Uint8List?> _cutClipIso(String path, int startMs, int endMs) async {
  // FFmpeg clip cutting commented out since dependency might not be available
  /*
  try {
    final tmp = '/tmp/iso_cut_${DateTime.now().microsecondsSinceEpoch}.mp4';
    final ss = (startMs / 1000).toStringAsFixed(3);
    final to = ((endMs - startMs) / 1000).toStringAsFixed(3);
    await FFmpegKit.execute('-y -ss $ss -t $to -i "$path" -c:v libx264 -preset ultrafast -crf 28 -an "$tmp"');
    final f = File(tmp);
    if (await f.exists()) {
      final b = await f.readAsBytes();
      unawaited(f.delete());
      return b;
    }
  } catch (_) {}
  */
  return null;
}

List<T> _stratifiedPick<T>(List<T> xs, int k) {
  if (xs.length <= k) return xs;
  final out = <T>[];
  final step = xs.length / k;
  double i = 0;
  while (out.length < k) {
    out.add(xs[i.floor()]);
    i += step;
  }
  return out;
}

List<int> _topKIndices(List<int> vals, {int k = 2, int minSpacing = 30}) {
  final idx = List<int>.generate(vals.length, (i) => i);
  idx.sort((a, b) => vals[b].compareTo(vals[a]));
  final picked = <int>[];
  for (final i in idx) {
    if (picked.length >= k) break;
    if (picked.every((p) => (p - i).abs() >= minSpacing)) picked.add(i);
  }
  picked.sort();
  return picked;
}
