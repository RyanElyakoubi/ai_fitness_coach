// lib/services/first_run_service.dart
import 'package:shared_preferences/shared_preferences.dart';

class FirstRunService {
  static const _kSeenInstructionsKey = 'seen_instructions_v1';

  static Future<bool> shouldShowInstructions() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_kSeenInstructionsKey) ?? false);
  }

  static Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSeenInstructionsKey, true);
  }

  static Future<void> resetForDebug() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSeenInstructionsKey);
  }
}

