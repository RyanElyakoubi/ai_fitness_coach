import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
// import 'package:ffmpeg_kit_flutter_min_gpl/ffmpeg_kit.dart'; // Commented out due to dependency issues
import 'logging.dart';

class VideoUtilsChannel {
  static const MethodChannel _meta = MethodChannel('video_meta');
  static const MethodChannel _utils = MethodChannel('video_utils');

  /// Copy pickedPath into sandbox cache and return local path + durationMs (robust).
  static Future<Map<String, dynamic>> ensureLocalAndDuration(String pickedPath) async {
    final cache = await getTemporaryDirectory();
    final localPath = '${cache.path}/vid_${DateTime.now().microsecondsSinceEpoch}.mp4';
    await File(pickedPath).copy(localPath);

    int durationMs = await _getDurationNative(localPath);
    if (durationMs <= 0) {
      durationMs = await _getDurationByFfprobe(localPath);
    }
    Log.i('video_utils: localized=$localPath durMs=$durationMs');

    return {'path': localPath, 'durationMs': durationMs};
  }

  static Future<int> _getDurationNative(String path) async {
    try {
      final res = await _meta.invokeMethod<Map>('getMeta', {'path': path});
      if (res == null) return 0;
      final ms = (res['durationMs'] as num?)?.toInt() ?? 0;
      return ms;
    } catch (e) {
      Log.w('video_utils: native meta failed: $e');
      return 0;
    }
  }

  static Future<int> _getDurationByFfprobe(String path) async {
    // FFmpeg dependency unavailable, skip ffprobe fallback
    Log.w('video_utils: ffprobe unavailable, skipping fallback');
    return 0;
  }

  // Legacy support for existing duration method
  static Future<int> durationMs(String path) async {
    final dur = await _getDurationNative(path);
    return dur > 0 ? dur : await _getDurationByFfprobe(path);
  }
}
