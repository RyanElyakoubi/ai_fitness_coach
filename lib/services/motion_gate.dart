import 'dart:math' as math;
import 'dart:typed_data';

/// Simple motion detector based on JPEG byte deltas (very fast).
/// We request low-quality thumbnails every 400ms and measure absolute
/// deltas. When sustained motion exceeds a threshold, we mark start.
/// We also find end via a cooldown window after motion falls below threshold.
class MotionGateResult {
  final int startMs;
  final int endMs;
  final bool confident;
  final String rationale;
  MotionGateResult({required this.startMs, required this.endMs, required this.confident, required this.rationale});
}

class MotionGate {
  /// Inspect at most this many milliseconds from the beginning and end
  /// to detect working reps (keeps it fast on long uploads).
  static const int kScanBudgetHeadMs = 30000; // 30s
  static const int kScanBudgetTailMs = 20000; // 20s
  static const int kStepMs = 400;

  /// Returns [startMs, endMs] for the "working set" trimmed window.
  /// If we're unsure, returns a centered 70% cut of the video.
  static MotionGateResult detect({
    required List<int> probeTimesMs,
    required List<int> jpegSizes,
    required int durationMs,
  }) {
    if (probeTimesMs.isEmpty || jpegSizes.length != probeTimesMs.length) {
      final start = (durationMs * 0.15).toInt();
      final end = (durationMs * 0.85).toInt();
      return MotionGateResult(startMs: start, endMs: end, confident: false, rationale: 'fallback_no_probe');
    }

    // Compute deltas
    final deltas = <double>[];
    for (int i = 1; i < jpegSizes.length; i++) {
      deltas.add((jpegSizes[i] - jpegSizes[i - 1]).abs().toDouble());
    }
    final median = _median(deltas);
    final thr = math.max(80.0, median * 1.2); // Even more sensitive threshold

    // Find first sustained motion (>= 3 consecutive frames above thr)
    int? sIdx;
    int streak = 0;
    for (int i = 0; i < deltas.length; i++) {
      if (deltas[i] >= thr) {
        streak++;
        if (streak >= 3) { sIdx = i - streak + 1; break; }
      } else { streak = 0; }
    }

    // If not found, fallback to 15%-85%
    if (sIdx == null) {
      final start = (durationMs * 0.15).toInt();
      final end = (durationMs * 0.85).toInt();
      return MotionGateResult(startMs: start, endMs: end, confident: false, rationale: 'no_sustained_motion');
    }

    // Back off 1s to include setup posture
    final startMs = math.max(0, probeTimesMs[math.max(0, sIdx)] - 1000);

    // Find end: last sustained motion ± cooldown of 2.5s
    int? eIdx;
    streak = 0;
    for (int i = deltas.length - 1; i >= 0; i--) {
      if (deltas[i] >= thr) {
        streak++;
        if (streak >= 3) { eIdx = i + 1; break; }
      } else { streak = 0; }
    }
    int endMs = (eIdx != null ? probeTimesMs[math.min(eIdx, probeTimesMs.length - 1)] + 2500 : (durationMs * 0.9).toInt());
    endMs = math.min(durationMs, endMs);

    // If the window too short (< 10s for bench press), inflate significantly
    final windowDur = endMs - startMs;
    if (windowDur < 10000) {
      final targetDur = 12000; // 12 seconds target
      final expansion = (targetDur - windowDur) ~/ 2;
      final newStart = math.max(0, startMs - expansion);
      final newEnd = math.min(durationMs, endMs + expansion);
      
      return MotionGateResult(
        startMs: newStart,
        endMs: newEnd,
        confident: false,
        rationale: 'expanded_for_bench_press_analysis',
      );
    }

    return MotionGateResult(startMs: startMs, endMs: endMs, confident: true, rationale: 'sustained_motion_detected');
  }

  static double _median(List<double> xs) {
    if (xs.isEmpty) return 0;
    final s = List<double>.from(xs)..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
    }
}
