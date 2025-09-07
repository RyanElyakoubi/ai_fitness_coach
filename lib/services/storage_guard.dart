import 'dart:io';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart';

class StorageGuard {
  /// Estimate bytes needed and attempt a small probe write in cache.
  /// Returns true if we can write; false if ENOSPC or other IO errors.
  static Future<bool> canWriteTemp({required int estimatedBytes}) async {
    try {
      final cacheDir = await getTemporaryDirectory();
      // Heuristic: require room for estimate + 3MB headroom.
      final need = math.max(estimatedBytes, 0) + 3 * 1024 * 1024;
      // Probe by writing a ~256KB file; if this fails, we're almost certainly out of space.
      final probe = File('${cacheDir.path}/__probe_${DateTime.now().microsecondsSinceEpoch}.bin');
      final data = List<int>.filled(256 * 1024, 0);
      await probe.writeAsBytes(data, flush: true);
      await probe.delete().catchError((_) {});
      // We can't read true free space in pure Dart; rely on try/catch during real writes as well.
      return true;
    } catch (_) {
      return false;
    }
  }
}
