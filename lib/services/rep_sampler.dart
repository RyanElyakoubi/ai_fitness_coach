import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:video_thumbnail/video_thumbnail.dart';
// import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart'; // Commented out due to dependency issues
import 'package:path_provider/path_provider.dart';

import 'motion_gate.dart';
import 'video_utils_channel.dart';
import 'logging.dart';

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

class _RepWindow {
  final int startMs;
  final int endMs;
  final double energy;
  
  _RepWindow(this.startMs, this.endMs, this.energy);
}

class RepAwareSampler {
  static const int kMaxImages = 60;
  static const int kMaxClips = 4;
  static const int kMinGuaranteedImages = 30;

  /// Main entry: rep-driven sampling with guaranteed payload
  Future<SamplingResult> sample(String pickedPath) async {
    final sw = Stopwatch()..start();

    // 1) Ensure local path & robust duration detection
    final ensured = await VideoUtilsChannel.ensureLocalAndDuration(pickedPath);
    final localPath = ensured['path'] as String;
    final rawDurMs = ensured['durationMs'] as int;
    
    // Never give up! If duration unknown, assume conservative cap
    final durMs = rawDurMs > 0 ? rawDurMs : 30000; // 30s fallback
    
    Log.i('rep_sampler: path=$localPath rawDur=${rawDurMs}ms useDur=${durMs}ms');

    try {
      return await _sampleForBench(localPath, durMs, sw);
    } catch (e) {
      Log.w('rep_sampler: main sampling failed ($e), using emergency fallback');
      return await _emergencyFallback(localPath, durMs, sw);
    }
  }

  Future<SamplingResult> _sampleForBench(String localPath, int durMs, Stopwatch sw) async {
    // 1) Coarse motion sweep: 2 fps across duration, max 200 thumbs for speed
    final coarseThumbs = await _coarseThumbs(localPath, durMs, fps: 2.0, maxFrames: 200);
    Log.i('rep_sampler: coarse scan produced ${coarseThumbs.length} thumbnails');

    // 2) Analyze motion energy to find rep windows
    final repWindows = _findRepWindows(coarseThumbs, durMs);
    Log.i('rep_sampler: found ${repWindows.length} rep windows: ${repWindows.map((w) => '${w.startMs}-${w.endMs}ms').join(', ')}');

    // 3) Extract dense bursts from each rep window
    final images = <Uint8List>[];
    final clips = <SamplingClip>[];

    for (final window in repWindows) {
      final windowImages = await _denseBurst(
        localPath, 
        centerMs: (window.startMs + window.endMs) ~/ 2,
        count: 14, 
        stepMs: 30, 
        quality: 40
      );
      images.addAll(windowImages);

      // Extract clip around peak motion in this window
      final clipBytes = await _cutClip(
        localPath, 
        startMs: math.max(0, window.startMs),
        endMs: math.min(durMs, window.endMs)
      );
      if (clipBytes != null) {
        clips.add(SamplingClip(
          bytes: clipBytes, 
          startMs: window.startMs, 
          endMs: window.endMs
        ));
      }
    }

    // 4) Guarantee minimum payload: if < 30 images, fill with anchors
    if (images.length < kMinGuaranteedImages) {
      final needed = kMinGuaranteedImages - images.length;
      final anchors = await _anchorFill(localPath, durMs, target: needed);
      images.addAll(anchors);
      Log.i('rep_sampler: added ${anchors.length} anchor frames to reach minimum');
    }

    // 5) Cap to budget
    if (images.length > kMaxImages) {
      images.removeRange(kMaxImages, images.length);
    }
    if (clips.length > kMaxClips) {
      clips.removeRange(kMaxClips, clips.length);
    }

    Log.i('rep_sampler: final payload - images=${images.length} clips=${clips.length} (${sw.elapsedMilliseconds}ms)');

    return SamplingResult(
      anchors: images.take(5).toList(), // First 5 as "anchors"
      frames: images.skip(5).toList(),  // Rest as "frames"
      clips: clips,
      gateRationale: 'rep_driven_v2',
      gateConfident: repWindows.isNotEmpty,
      trimmedStartMs: repWindows.isNotEmpty ? repWindows.first.startMs : 0,
      trimmedEndMs: repWindows.isNotEmpty ? repWindows.last.endMs : durMs,
      meta: {
        'strategy': 'rep_driven_v2',
        'duration_ms': durMs,
        'windows_found': repWindows.length,
        'elapsed_ms': sw.elapsedMilliseconds,
      },
    );
  }

  Future<SamplingResult> _emergencyFallback(String localPath, int durMs, Stopwatch sw) async {
    Log.w('rep_sampler: emergency fallback - extracting 30 evenly spaced frames');
    
    final images = <Uint8List>[];
    final stepMs = durMs ~/ 35; // 35 frames across duration
    
    for (int i = 0; i < 35; i++) {
      final t = (i * stepMs).clamp(0, durMs - 100);
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: localPath,
          imageFormat: ImageFormat.JPEG,
          timeMs: t,
          quality: 42,
        );
        if (data != null) images.add(data);
      } catch (_) {
        // Skip failed frames
      }
      if (i % 6 == 0) await Future.delayed(Duration.zero); // yield
    }

    return SamplingResult(
      anchors: images.take(5).toList(),
      frames: images.skip(5).toList(),
      clips: const [],
      gateRationale: 'emergency_fallback',
      gateConfident: false,
      trimmedStartMs: 0,
      trimmedEndMs: durMs,
      meta: {
        'strategy': 'emergency_fallback',
        'duration_ms': durMs,
        'elapsed_ms': sw.elapsedMilliseconds,
      },
    );
  }

  /// Extract coarse thumbnails at specified FPS for motion analysis
  Future<List<MapEntry<int, Uint8List>>> _coarseThumbs(String path, int durMs, {double fps = 2.0, int maxFrames = 200}) async {
    final thumbs = <MapEntry<int, Uint8List>>[];
    final stepMs = (1000 / fps).round();
    final maxTimeMs = math.min(durMs, maxFrames * stepMs);
    
    for (int t = 0; t <= maxTimeMs; t += stepMs) {
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          timeMs: t,
          quality: 20, // Low quality for speed
        );
        if (data != null) {
          thumbs.add(MapEntry(t, data));
        }
      } catch (_) {
        // Skip failed frames
      }
      if (t % (stepMs * 10) == 0) await Future.delayed(Duration.zero); // yield
    }
    
    return thumbs;
  }

  /// Find rep windows based on motion energy patterns
  List<_RepWindow> _findRepWindows(List<MapEntry<int, Uint8List>> thumbs, int durMs) {
    if (thumbs.length < 10) {
      // Not enough data, return full duration as single window
      return [_RepWindow(0, durMs, 1.0)];
    }

    // Calculate motion energy (JPEG size deltas)
    final energies = <double>[];
    for (int i = 1; i < thumbs.length; i++) {
      final delta = (thumbs[i].value.length - thumbs[i-1].value.length).abs();
      energies.add(delta.toDouble());
    }

    // Find threshold for activity
    final sorted = List<double>.from(energies)..sort();
    final threshold = sorted[(sorted.length * 0.6).round()]; // 60th percentile

    // Find continuous active regions
    final windows = <_RepWindow>[];
    int? windowStart;
    double windowEnergy = 0;
    int windowFrames = 0;

    for (int i = 0; i < energies.length; i++) {
      if (energies[i] > threshold) {
        if (windowStart == null) {
          windowStart = thumbs[i].key;
          windowEnergy = 0;
          windowFrames = 0;
        }
        windowEnergy += energies[i];
        windowFrames++;
      } else {
        if (windowStart != null && windowFrames >= 3) {
          // End of active window
          final windowEnd = thumbs[i].key;
          final avgEnergy = windowEnergy / windowFrames;
          if (windowEnd - windowStart >= 1200) { // At least 1.2s window
            windows.add(_RepWindow(windowStart, windowEnd, avgEnergy));
          }
        }
        windowStart = null;
      }
    }

    // Handle final window
    if (windowStart != null && windowFrames >= 3) {
      final windowEnd = thumbs.last.key;
      final avgEnergy = windowEnergy / windowFrames;
      if (windowEnd - windowStart >= 1200) {
        windows.add(_RepWindow(windowStart, windowEnd, avgEnergy));
      }
    }

    // Sort by energy and take top 3
    windows.sort((a, b) => b.energy.compareTo(a.energy));
    return windows.take(3).toList();
  }

  /// Extract dense burst of frames around center point
  Future<List<Uint8List>> _denseBurst(String path, {required int centerMs, int count = 14, int stepMs = 30, int quality = 40}) async {
    final images = <Uint8List>[];
    final halfCount = count ~/ 2;
    
    for (int i = -halfCount; i <= halfCount; i++) {
      final t = math.max(0, centerMs + (i * stepMs));
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          timeMs: t,
          quality: quality,
        );
        if (data != null) images.add(data);
      } catch (_) {
        // Skip failed frames
      }
      if (i % 3 == 0) await Future.delayed(Duration.zero); // yield
    }
    
    return images;
  }

  /// Fill with anchor frames across duration to guarantee minimum count
  Future<List<Uint8List>> _anchorFill(String path, int durMs, {required int target}) async {
    final images = <Uint8List>[];
    final stepMs = durMs ~/ (target + 1);
    
    for (int i = 1; i <= target; i++) {
      final t = (i * stepMs).clamp(0, durMs - 100);
      try {
        final data = await VideoThumbnail.thumbnailData(
          video: path,
          imageFormat: ImageFormat.JPEG,
          timeMs: t,
          quality: 42,
        );
        if (data != null) images.add(data);
      } catch (_) {
        // Skip failed frames
      }
      if (i % 5 == 0) await Future.delayed(Duration.zero); // yield
    }
    
    return images;
  }

  /// Extract video clip using FFmpeg (currently disabled due to dependency issues)
  Future<Uint8List?> _cutClip(String path, {required int startMs, required int endMs}) async {
    // Skip clip extraction due to FFmpeg dependency issues
    Log.i('clip extraction skipped - FFmpeg unavailable');
    return null;
  }
}