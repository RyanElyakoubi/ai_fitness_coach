import 'dart:io';
import 'package:path_provider/path_provider.dart';

class CacheCleaner {
  static Future<void> purgeOldFiles({Duration olderThan = const Duration(hours: 8)}) async {
    try {
      final cache = await getTemporaryDirectory();
      final now = DateTime.now();
      final dir = Directory(cache.path);
      if (!await dir.exists()) return;
      await for (final fse in dir.list()) {
        if (fse is File) {
          final stat = await fse.stat();
          if (now.difference(stat.modified) > olderThan) {
            await fse.delete().catchError((_) {});
          }
        }
      }
    } catch (_) {}
  }
}
