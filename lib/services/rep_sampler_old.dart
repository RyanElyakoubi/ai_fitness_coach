import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:bench_mvp/services/video_utils_channel.dart';

/// Simple struct we already use elsewhere; if your project has a different SamplingResult
/// type, keep fields identical (framesJpegs, clipMp4s, meta, bytesB64 etc.) so callers don't change.
class SamplingResult {
  final List<Uint8List> frameJpegs;   // JPEG bytes for stills
  final List<Uint8List> clipMp4s;     // MP4 bytes for micro-clips
  final Map<String, dynamic> meta;    // timings, reps, budgets, etc.
  SamplingResult({required this.frameJpegs, required this.clipMp4s, required this.meta});
}

class RepAwareConfig {
  // Budget/latency knobs
  final int maxImages;           // hard cap for stills sent to Gemini
  final int maxClips;            // hard cap for micro-clips
  final int scoutFps;            // FPS for low-cost downtime detection
  final int denseFps;            // FPS used to detect cycles within active windows
  final Duration maxClipDur;     // per-clip duration
  final Duration minActive;      // drop tiny bursts below this
  final Duration mergeGap;       // merge nearby bursts within this gap
  final int maxActiveWindows;    // if user records multiple sets in one file
  final double jpegQuality;      // 0–100
  final int thumbSize;           // grayscale size for diffs (pixels)

  const RepAwareConfig({
    this.maxImages = 24,           // Reduce significantly for speed
    this.maxClips = 1,             // Minimal clips for speed
    this.scoutFps = 1,             // Ultra-fast scout phase
    this.denseFps = 3,             // Much faster dense sampling
    this.maxClipDur = const Duration(milliseconds: 500),
    this.minActive = const Duration(milliseconds: 2000), // Longer minimum to filter noise
    this.mergeGap = const Duration(milliseconds: 1500),  // Wider merge gap
    this.maxActiveWindows = 1,     // Only 1 window for speed
    this.jpegQuality = 80,         // High quality for better Gemini results
    this.thumbSize = 120,          // Smaller for speed
  });
}

class RepAwareSampler {
  final RepAwareConfig cfg;
  String _currentVideoPath = '';
  int? _cachedDurMs;
  
  RepAwareSampler({RepAwareConfig? cfg}) : cfg = cfg ?? const RepAwareConfig();

  Future<double> _durationMs(String path) async {
    try {
      final info = await VideoUtilsChannel.ensureLocalAndDuration(path);
      // Update the path if iOS gave us a localized copy:
      _currentVideoPath = info['path'] as String;
      _cachedDurMs = info['durationMs'] as int;
      return (info['durationMs'] as int).toDouble();
    } catch (_) {
      // Fallback to old guess (should rarely run)
      _cachedDurMs = 60 * 1000;
      return 60 * 1000.0;
    }
  }

  Future<Uint8List?> _safeThumb(String path, int tMs, {int quality = 68}) async {
    // Clamp to [0, dur-50ms]
    final dur = _cachedDurMs ?? 0;
    final capped = dur > 0 ? tMs.clamp(0, math.max(0, dur - 50)) : tMs;

    // Try AVFoundation via video_thumbnail (fewer attempts for speed)
    for (final jitter in [0, -40, 40]) {
      final when = (capped + jitter).clamp(0, math.max(0, dur - 30)).round();
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          timeMs: when,
          quality: quality,
        );
        if (data != null) return data;
      } catch (_) {/* keep trying */}
    }

    return null;
  }

  Future<img.Image?> _decodeGray(Uint8List bytes) async {
    final base = img.decodeJpg(bytes);
    if (base == null) return null;
    final g = img.grayscale(base);
    final s = img.copyResize(g, width: cfg.thumbSize);
    return s;
  }

  double _meanAbsDiff(img.Image a, img.Image b) {
    final w = math.min(a.width, b.width);
    final h = math.min(a.height, b.height);
    int acc = 0, n = 0;
    for (int y = 0; y < h; y += 3) {  // Sample every 3rd pixel for speed
      for (int x = 0; x < w; x += 3) {
        final pa = a.getPixel(x, y);
        final pb = b.getPixel(x, y);
        final va = img.getLuminance(pa).round();
        final vb = img.getLuminance(pb).round();
        acc += (va - vb).abs();
        n++;
      }
    }
    return n == 0 ? 0 : acc / n;
  }

  List<_Segment> _segmentsFromEnergy(List<_Sample> samples) {
    if (samples.length < 3) return [];
    
    // Smooth energy
    final e = samples.map((s) => s.energy).toList();
    final k = math.max(1, (cfg.scoutFps * 0.5).round());
    final sm = List<double>.filled(e.length, 0);
    for (int i = 0; i < e.length; i++) {
      double acc = 0;
      int n = 0;
      for (int j = i - k; j <= i + k; j++) {
        if (j < 0 || j >= e.length) continue;
        acc += e[j];
        n++;
      }
      sm[i] = n == 0 ? e[i] : acc / n;
    }

    // Adaptive threshold
    final mean = sm.reduce((a,b)=>a+b) / sm.length;
    final varAcc = sm.fold<double>(0, (p, v) => p + (v - mean) * (v - mean));
    final sd = math.sqrt(varAcc / sm.length);
    final thr = mean + (sd * 0.4); // Slightly higher threshold

    // Build segments
    final segs = <_Segment>[];
    bool on = false;
    int start = 0;
    for (int i = 0; i < sm.length; i++) {
      final active = sm[i] > thr;
      if (active && !on) {
        on = true;
        start = i;
      }
      if (!active && on) {
        on = false;
        segs.add(_Segment(start, i));
      }
    }
    if (on) segs.add(_Segment(start, sm.length - 1));

    // Times, merge, min length
    final fps = cfg.scoutFps.toDouble();
    List<_Segment> merged = [];
    for (final s in segs) {
      if (merged.isEmpty) {
        merged.add(s);
        continue;
      }
      final prev = merged.last;
      final gapMs = ((s.start - prev.end) / fps) * 1000;
      if (gapMs <= cfg.mergeGap.inMilliseconds) {
        merged[merged.length - 1] = _Segment(prev.start, s.end);
      } else {
        merged.add(s);
      }
    }

    final minFrames = (cfg.minActive.inMilliseconds / (1000 / fps)).ceil();
    final pruned = merged.where((s) => (s.end - s.start + 1) >= minFrames).toList();

    // Cap and sort
    pruned.sort((a, b) => (a.start).compareTo(b.start));
    return pruned.take(cfg.maxActiveWindows).toList();
  }

  Future<List<_Sample>> _scout(String path, double durMs) async {
    final localPath = _currentVideoPath.isEmpty ? path : _currentVideoPath;
    final dur = (_cachedDurMs ?? durMs).toInt();
    final endGuard = math.max(0, dur - 40);
    
    final fps = cfg.scoutFps;
    final stepMs = (1000 / fps).round();
    final frames = <_Sample>[];
    img.Image? prev;
    
    // Limit scout to first 60 seconds for speed
    final maxScanMs = math.min(endGuard, 60000);
    
    for (int t = 0; t <= maxScanMs; t += stepMs) {
      final data = await _safeThumb(localPath, t, quality: 50); // Lower quality for scout
      if (data == null) continue;
      final g = await _decodeGray(data);
      if (g == null) continue;
      double energy = 0;
      if (prev != null) {
        energy = _meanAbsDiff(prev, g);
      }
      frames.add(_Sample(t.toDouble(), energy, data));
      prev = g;
    }
    return frames;
  }

  Future<List<_Sample>> _dense(String path, double startMs, double endMs) async {
    final localPath = _currentVideoPath.isEmpty ? path : _currentVideoPath;
    final dur = (_cachedDurMs ?? endMs).toInt();
    final endGuard = math.max(0, dur - 40);
    final clampedEnd = math.min(endMs, endGuard.toDouble());
    
    final fps = cfg.denseFps;
    final stepMs = (1000 / fps).round();
    final out = <_Sample>[];
    img.Image? prev;
    for (int t = startMs.round(); t <= clampedEnd; t += stepMs) {
      final data = await _safeThumb(localPath, t, quality: 60);
      if (data == null) continue;
      final g = await _decodeGray(data);
      if (g == null) continue;
      double energy = 0;
      if (prev != null) {
        energy = _meanAbsDiff(prev, g);
      }
      out.add(_Sample(t.toDouble(), energy, data));
      prev = g;
    }
    return out;
  }

  List<double> _repKeyTimes(List<_Sample> dense, double fps) {
    if (dense.length < 6) return dense.map((s) => s.tMs).toList();
    
    // Simplified: just take evenly spaced samples
    final count = math.min(12, dense.length); // Max 12 per segment
    final step = dense.length / count;
    final times = <double>[];
    for (int i = 0; i < count; i++) {
      final idx = (i * step).round().clamp(0, dense.length - 1);
      times.add(dense[idx].tMs);
    }
    return times;
  }

  Future<Uint8List?> _grabJpeg(String path, int tMs, {int quality = 70}) async {
    final localPath = _currentVideoPath.isEmpty ? path : _currentVideoPath;
    return await _safeThumb(localPath, tMs, quality: quality);
  }

  Future<SamplingResult> run(String videoPath, {Function(String)? onProgress}) async {
    final sw = Stopwatch()..start();
    const maxProcessingTime = 20000; // 20 seconds max
    
    try {
        onProgress?.call("Getting video info...");
        final durMs = await _durationMs(videoPath);
        
        // Check timeout
        if (sw.elapsedMilliseconds > maxProcessingTime) {
          throw TimeoutException("Processing timeout", Duration(milliseconds: maxProcessingTime));
        }
        
        print("video_utils: localized=${_currentVideoPath.isEmpty ? videoPath : _currentVideoPath} durMs=${durMs.round()}");
        
        if (durMs < 3000) {
          throw Exception("Video too short (${durMs.round()}ms)");
        }
        
        onProgress?.call("Scanning for activity...");
        
        final scout = await _scout(videoPath, durMs);
        final segIdx = _segmentsFromEnergy(scout);

        if (segIdx.isEmpty) {
          onProgress?.call("No activity found, using fallback...");
          // Take 3 evenly spaced frames
          final frames = <Uint8List>[];
          for (int i = 0; i < 3; i++) {
            final t = (durMs * (i + 1) / 4).round();
            final f = await _grabJpeg(videoPath, t, quality: 85);
            if (f != null) frames.add(f);
          }
          return SamplingResult(
            frameJpegs: frames,
            clipMp4s: const <Uint8List>[],
            meta: {
              'strategy': 'rep_aware_fallback',
              'duration_ms': durMs,
              'elapsed_ms': sw.elapsedMilliseconds,
              'active_segments': [],
              'reps_detected': 0,
            },
          );
        }

        onProgress?.call("Analyzing ${segIdx.length} active segments...");

        final frames = <Uint8List>[];
        final keyTimes = <double>[];
        final segmentsMeta = <Map<String, dynamic>>[];

        for (final seg in segIdx) {
          final startMs = scout[seg.start].tMs;
          final endMs = scout[seg.end].tMs;
          final dense = await _dense(videoPath, startMs, endMs);
          if (dense.length < 3) continue;
          final keys = _repKeyTimes(dense, cfg.denseFps.toDouble());
          keyTimes.addAll(keys);
          segmentsMeta.add({'start_ms': startMs, 'end_ms': endMs, 'keys': keys});
        }

        // Cap to maxImages
        if (keyTimes.length > cfg.maxImages) {
          final step = keyTimes.length / cfg.maxImages;
          final selected = <double>[];
          for (int i = 0; i < cfg.maxImages; i++) {
            final idx = (i * step).round().clamp(0, keyTimes.length - 1);
            selected.add(keyTimes[idx]);
          }
          keyTimes
            ..clear()
            ..addAll(selected);
        }

        onProgress?.call("Extracting ${keyTimes.length} key frames...");

        for (final t in keyTimes) {
          final data = await _grabJpeg(videoPath, t.round(), quality: cfg.jpegQuality.round());
          if (data != null) frames.add(data);
        }

        return SamplingResult(
          frameJpegs: frames,
          clipMp4s: const <Uint8List>[],
          meta: {
            'strategy': 'rep_aware_v2_fast',
            'duration_ms': durMs,
            'elapsed_ms': sw.elapsedMilliseconds,
            'active_segments': segmentsMeta,
            'images': frames.length,
            'clips': 0,
            'scout_fps': cfg.scoutFps,
            'dense_fps': cfg.denseFps,
          },
        );
    } catch (e) {
      print("rep_aware timeout/error: $e");
      rethrow;
    }
  }
}

class _Sample {
  final double tMs;
  final double energy;
  final Uint8List jpeg;
  _Sample(this.tMs, this.energy, this.jpeg);
}

class _Segment {
  final int start;
  final int end;
  _Segment(this.start, this.end);
  int get length => end - start + 1;
}
