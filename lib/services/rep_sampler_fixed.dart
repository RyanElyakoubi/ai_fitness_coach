import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
// import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart'; // Keep commented for now

import 'motion_gate.dart';
import 'video_utils_channel.dart';

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

class RepAwareSampler {
  static const int kMaxImages = 60;
  static const int kMaxClips  = 2;

  /// Main entry: returns anchors, frames, short clips, and gate info.
  Future<SamplingResult> sample(String pickedPath) async {
    final sw = Stopwatch()..start();
    
    // 1) Ensure local path & precise duration
    final ensured = await VideoUtilsChannel.ensureLocalAndDuration(pickedPath);
    final localPath = ensured['path'] as String;
    final durMs     = ensured['durationMs'] as int;

    print("video_utils: localized=$localPath durMs=$durMs");

    // 2) Cheap probe (main isolate, small quality, every 400ms)
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
      if (t % 2000 == 0) { await Future.delayed(Duration.zero); } // yield
    }

    // 3) Gate the window (trim dead time)
    final gate = MotionGate.detect(
      probeTimesMs: times,
      jpegSizes: sizes,
      durationMs: durMs,
    );

    final startMs = math.max(0, gate.startMs);
    final endMs   = math.min(durMs, gate.endMs);
    final window  = math.max(2000, endMs - startMs);

    print("Trimmed window: start=${startMs}ms end=${endMs}ms len=${window}ms confident=${gate.confident} reason=${gate.rationale}");

    // 4) Build anchor timestamps: 5 evenly within [startMs, endMs]
    final anchorsTs = <int>[];
    const anchorCount = 5;
    for (int i = 0; i < anchorCount; i++) {
      final t = (startMs + ((i + 1) * window / (anchorCount + 1))).toInt();
      anchorsTs.add(t);
    }

    // 5) Dense timestamps in the window at ~35ms (≈28 fps), then stratify down to budget
    final denseTs = <int>[];
    for (int t = startMs; t <= endMs; t += 35) { denseTs.add(t); }

    // Subsample dense to fit budget (after anchors)
    final wantFrames = math.max(0, kMaxImages - anchorsTs.length);
    final densePickedTs = _stratifiedPick(denseTs, wantFrames);

    // 6) Extract thumbnails in small batches to avoid jank
    final anchors = <Uint8List>[];
    final frames  = <Uint8List>[];

    Future<void> _extract(List<int> stamps, List<Uint8List> out, {int quality = 40}) async {
      const batch = 6;
      for (int i = 0; i < stamps.length; i++) {
        final t = stamps[i];
        try {
          final data = await VideoThumbnail.thumbnailData(
            video: localPath,
            imageFormat: ImageFormat.JPEG,
            timeMs: t,
            quality: quality,
          );
          if (data != null) out.add(data);
        } catch (_) {/* ignore */}
        if (i % batch == 0) { await Future.delayed(Duration.zero); } // yield
      }
    }

    await _extract(anchorsTs, anchors, quality: 42);
    await _extract(densePickedTs, frames, quality: 38);

    // 7) If for any reason frames are still empty, do a strong fallback (quartiles)
    if (anchors.isEmpty && frames.isEmpty) {
      final fallbackTs = <int>[
        startMs,
        startMs + (window * 0.25).toInt(),
        startMs + (window * 0.50).toInt(),
        startMs + (window * 0.75).toInt(),
        endMs,
      ];
      await _extract(fallbackTs, frames, quality: 45);
    }

    // 8) Short clips: pick up to 2 ~0.9s clips around high-motion zones using JPEG size deltas
    final clips = <SamplingClip>[];
    if (frames.isNotEmpty && kMaxClips > 0) {
      // Recreate small motion profile by sampling coarse 70ms JPEG sizes
      final probeTs = <int>[];
      final probeSizes = <int>[];
      for (int t = startMs; t <= endMs; t += 70) {
        try {
          final d = await VideoThumbnail.thumbnailData(video: localPath, imageFormat: ImageFormat.JPEG, timeMs: t, quality: 18);
          if (d != null) { probeTs.add(t); probeSizes.add(d.length); }
        } catch (_) {}
        if (t % 700 == 0) { await Future.delayed(Duration.zero); }
      }
      final deltas = <int>[];
      for (int i = 1; i < probeSizes.length; i++) {
        deltas.add((probeSizes[i] - probeSizes[i - 1]).abs());
      }
      final peaks = _topKIndices(deltas, k: kMaxClips, minSpacing: 14);
      for (final idx in peaks) {
        final midMs = probeTs[math.min(idx + 1, probeTs.length - 1)];
        final s = math.max(startMs, midMs - 450);
        final e = math.min(endMs,   midMs + 450);
        final bytes = await _cutClip(localPath, s, e);
        if (bytes != null) {
          clips.add(SamplingClip(bytes: bytes, startMs: s, endMs: e));
        }
      }
    }

    // 9) Final guard — never return empty payload
    if (anchors.isEmpty && frames.isEmpty && clips.isEmpty) {
      // Last-chance thumbnails at 5 points across the full video
      final ts = <int>[];
      for (int i = 1; i <= 5; i++) {
        ts.add((durMs * (i / 6)).toInt());
      }
      await _extract(ts, frames, quality: 42);
    }

    print("Payload: anchors=${anchors.length} images=${frames.length} clips=${clips.length}");

    return SamplingResult(
      anchors: anchors,
      frames:  frames,
      clips:   clips,
      gateRationale: gate.rationale,
      gateConfident: gate.confident,
      trimmedStartMs: startMs,
      trimmedEndMs:   endMs,
      meta: {
        'strategy': 'main_isolate_batched',
        'duration_ms': durMs,
        'elapsed_ms': sw.elapsedMilliseconds,
        'window_ms': window,
        'gate_confident': gate.confident,
      },
    );
  }

  // Helpers

  List<int> _stratifiedPick(List<int> xs, int k) {
    if (k <= 0) return <int>[];
    if (xs.length <= k) return xs;
    final out = <int>[];
    final step = xs.length / k;
    double i = 0;
    while (out.length < k) { out.add(xs[i.floor()]); i += step; }
    return out;
  }

  List<int> _topKIndices(List<int> vals, {int k = 2, int minSpacing = 12}) {
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

  Future<Uint8List?> _cutClip(String path, int startMs, int endMs) async {
    // FFmpeg clip cutting commented out since dependency might not be available
    // For now, return null to skip clips
    /*
    try {
      final tmp = '/tmp/cut_${DateTime.now().microsecondsSinceEpoch}.mp4';
      final ss  = (startMs / 1000).toStringAsFixed(3);
      final dur = ((endMs - startMs) / 1000).toStringAsFixed(3);
      final cmd = '-y -ss $ss -t $dur -i "$path" -c:v libx264 -preset ultrafast -crf 28 -an "$tmp"';
      await FFmpegKit.execute(cmd);
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
}
