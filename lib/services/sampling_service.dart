import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class SamplingOptions {
  final int maxFrames; // default 24
  final int targetWidth; // default 480
  final double jpegQuality; // 0.0..1.0 => map to ffmpeg qscale (2..31)
  final int snippetCount; // default 1
  final double snippetDurationSec; // default 0.6
  const SamplingOptions({
    this.maxFrames = 24,
    this.targetWidth = 480,
    this.jpegQuality = 0.72,
    this.snippetCount = 1,
    this.snippetDurationSec = 0.6,
  });
}

class SamplingResult {
  final List<String> framesBase64Jpeg;
  final List<String> snippetsBase64Mp4;
  final int approxTotalBase64Bytes;
  final String diagnostics; // short human-readable summary
  const SamplingResult({
    required this.framesBase64Jpeg,
    required this.snippetsBase64Mp4,
    required this.approxTotalBase64Bytes,
    required this.diagnostics,
  });
}

class SamplingService {
  Future<SamplingResult> sample(String videoPath, {SamplingOptions opts = const SamplingOptions()}) async {
    // 0) Normalize path and verify readable file
    final inFile = File(videoPath.replaceFirst('file://', ''));
    if (!await inFile.exists()) {
      throw Exception("Video file not found at $videoPath");
    }
    final inSize = await inFile.length();

    final tmpDir = await getTemporaryDirectory();
    final work = Directory(p.join(tmpDir.path, 'bench_mvp_work'));
    if (!await work.exists()) await work.create(recursive: true);

    var frames = <String>[];
    var clips = <String>[];
    var logs = StringBuffer();

    // Extract video thumbnail frames using video_thumbnail package
    debugPrint('Extracting video frames using video_thumbnail...');
    logs.writeln('Starting frame extraction from video: ${inFile.path}');
    
    try {
      // Extract frames at strategic time points for bench press analysis
      final framesToExtract = math.min(opts.maxFrames, 15); // Optimized for Gemini payload
      
      for (int i = 0; i < framesToExtract; i++) {
        try {
          // Strategic time distribution: early, middle, late in video
          int timeMs;
          if (i == 0) {
            timeMs = 500; // Start position setup
          } else if (i == 1) {
            timeMs = 2000; // Descent phase
          } else if (i == 2) {
            timeMs = 4000; // Bottom position
          } else if (i == 3) {
            timeMs = 6000; // Press phase
          } else if (i == 4) {
            timeMs = 8000; // Lockout
          } else {
            // Additional frames distributed throughout
            timeMs = 1000 + (i * 2000);
          }
          
          debugPrint('Extracting frame ${i + 1} at ${timeMs}ms...');
          
          final thumbnailData = await VideoThumbnail.thumbnailData(
            video: inFile.path,
            imageFormat: ImageFormat.JPEG,
            maxWidth: opts.targetWidth, // 480px width for good detail
            maxHeight: 640, // Maintain aspect ratio
            timeMs: timeMs,
            quality: (opts.jpegQuality * 100).round().clamp(50, 90), // High quality for analysis
          );
          
          if (thumbnailData != null && thumbnailData.isNotEmpty) {
            final base64Frame = base64Encode(thumbnailData);
            frames.add(base64Frame);
            debugPrint('✓ Frame ${i + 1} extracted: ${thumbnailData.length} bytes (${base64Frame.length} base64)');
            logs.writeln('Frame ${i + 1} at ${timeMs}ms: ${thumbnailData.length} bytes');
          } else {
            debugPrint('✗ Frame ${i + 1} extraction returned null/empty');
            logs.writeln('Frame ${i + 1} at ${timeMs}ms: failed (null/empty)');
          }
        } catch (e) {
          debugPrint('✗ Frame ${i + 1} extraction error: $e');
          logs.writeln('Frame ${i + 1} extraction failed: $e');
        }
      }
    } catch (e) {
      debugPrint('Video thumbnail extraction setup failed: $e');
      logs.writeln('Video thumbnail extraction setup failed: $e');
    }

    // Fallback: if no frames extracted, try to use original video (if reasonably sized)
    if (frames.isEmpty && clips.isEmpty) {
      debugPrint('No frames extracted, attempting video fallback...');
      try {
        final b = await inFile.readAsBytes();
        // Use more aggressive size limits for Gemini API (max ~10MB for reliable processing)
        if (b.length < 10 * 1024 * 1024) {
          clips.add(base64Encode(b));
          debugPrint('✓ Using original video as fallback: ${b.length} bytes');
          logs.writeln('Fallback: original video (${b.length} bytes)');
        } else {
          debugPrint('✗ Original video too large for Gemini: ${b.length} bytes (max 10MB)');
          logs.writeln('Video too large: ${b.length} bytes > 10MB limit');
        }
      } catch (e) {
        debugPrint('✗ Fallback video read failed: $e');
        logs.writeln('Fallback video read failed: $e');
      }
    }

    final totalBytes = frames.fold<int>(0, (s, e) => s + e.length) + clips.fold<int>(0, (s, e) => s + e.length);
    final diag = 'in=${inSize}B frames=${frames.length} clips=${clips.length} totalB64=$totalBytes (video_thumbnail)';
    debugPrint('sampling: $diag');
    
    if (frames.isEmpty && clips.isEmpty) {
      // Include logs in thrown error for Processing screen
      final short = logs.toString().split('\n').take(20).join('\n');
      throw Exception('Video processing produced no media.\n$diag\n$short');
    }

    return SamplingResult(
      framesBase64Jpeg: frames,
      snippetsBase64Mp4: clips,
      approxTotalBase64Bytes: totalBytes,
      diagnostics: diag,
    );
  }

  /// Returns up to 8 evenly spaced, small JPEG scout frames from the currently
  /// chosen trimmed window if present; otherwise across the whole video.
  /// Size ~320px width; quality ~60.
  Future<List<Uint8List>> getScoutFramesForPrecheck({
    required String videoPath,
    required int desiredCount,
    required Duration? windowStart,
    required Duration? windowEnd,
  }) async {
    final count = desiredCount.clamp(4, 8);
    final frames = <Uint8List>[];

    try {
      // Get video duration
      final durMs = await _getDurationMs(videoPath);
      if (durMs <= 0) return frames;

      final startMs = (windowStart?.inMilliseconds ?? 0);
      final endMs = (windowEnd?.inMilliseconds ?? durMs);
      final span = math.max(1, endMs - startMs);

      // Generate evenly spaced timestamps
      for (int i = 0; i < count; i++) {
        final ts = startMs + ((i + 1) * (span ~/ (count + 1)));
        final jpg = await _makeThumbnailAt(
          videoPath: videoPath,
          millis: ts,
          width: 320,
          quality: 60,
        );
        if (jpg != null) frames.add(jpg);
      }
    } catch (e) {
      debugPrint("Error generating scout frames: $e");
    }
    
    return frames;
  }

  /// Helper to get video duration in milliseconds
  Future<int> _getDurationMs(String videoPath) async {
    try {
      final data = await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        quality: 20,
        timeMs: 0,
      );
      if (data == null) return 0;

      // Binary search for duration
      int guessMs = 60 * 1000; // fallback to 60s guess then tighten
      int hi = 15 * 60 * 1000;
      int lo = 0;
      for (int i = 0; i < 22; i++) {
        final ms = guessMs;
        final data = await VideoThumbnail.thumbnailData(
          video: videoPath,
          imageFormat: ImageFormat.JPEG,
          quality: 20,
          timeMs: ms,
        );
        if (data == null) {
          hi = ms;
        } else {
          lo = ms;
        }
        guessMs = (lo + hi) ~/ 2;
      }
      return lo;
    } catch (e) {
      debugPrint("Error getting duration: $e");
      return 0;
    }
  }

  /// Helper to make thumbnail at specific timestamp
  Future<Uint8List?> _makeThumbnailAt({
    required String videoPath,
    required int millis,
    required int width,
    required int quality,
  }) async {
    try {
      return await VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: ImageFormat.JPEG,
        timeMs: millis,
        quality: quality,
        maxWidth: width,
      );
    } catch (e) {
      debugPrint("Error making thumbnail at ${millis}ms: $e");
      return null;
    }
  }
}