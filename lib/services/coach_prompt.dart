/// lib/services/coach_prompt.dart
class CoachPrompt {
  static String build({
    required int holistic,
    required int form,
    required int intensity,
    Map<String, num>? formCats,
    Map<String, num>? intensityCats,
  }) {
    // Normalize category names to the UI's canonical labels.
    String kv(Map<String, num>? m) {
      if (m == null || m.isEmpty) return "none";
      final entries = m.entries
        .map((e) => "${e.key.trim()}:${e.value.toStringAsFixed(0)}")
        .join(", ");
      return entries;
    }

    final formStr = kv(formCats);
    final intStr  = kv(intensityCats);

    // === Coach Analysis Prompt ===
    // Keep to 5–8 sentences; practical, concise, supportive tone.
    return '''
You are an experienced powerlifting coach writing a short, constructive analysis for an intermediate lifter.

The lifter's scores:
- Holistic: $holistic
- Form: $form
- Intensity: $intensity

Category breakdowns:
- Form categories (Bar Path, Range of Motion, Stability, Wrists & Elbow Flare, Leg Drive): $formStr
- Intensity categories (Power, Uniformity, Proximity to Failure, Cadence, Bar-speed Consistency): $intStr

Write 5–8 sentences that:
1) Explain why these scores make sense given the breakdowns (what went well vs. what cost points).
2) Identify the single biggest flaw holding back the lift.
3) Give one highly actionable coaching cue the lifter can apply next session to fix that flaw.

Tone: supportive but direct; practical and specific; avoid generic platitudes; no emojis; no markdown; no bullet lists; plain sentences only.
''';
  }

  static String buildInsightsJson({
    required int holistic,
    required int form,
    required int intensity,
    Map<String, num>? formCats,
    Map<String, num>? intensityCats,
  }) {
    String kv(Map<String, num>? m) {
      if (m == null || m.isEmpty) return "none";
      return m.entries.map((e) => "${e.key}:${e.value.toStringAsFixed(0)}").join(", ");
    }

    final formStr = kv(formCats);
    final intStr = kv(intensityCats);

    return '''
You are an experienced powerlifting coach giving friendly, encouraging feedback to an intermediate lifter after watching their bench press.

Scores:
- Holistic: $holistic
- Form: $form
- Intensity: $intensity

Breakdowns:
- Form (Bar Path, Range of Motion, Stability, Wrists & Elbow Flare, Leg Drive): $formStr
- Intensity (Power, Uniformity, Proximity to Failure, Cadence, Bar-speed Consistency): $intStr

Return ONLY valid JSON in this exact schema, no extra text:

{
  "analysis": "Write 5–8 friendly sentences using 'You' to address the lifter directly. Start with 2-3 sentences highlighting what they did well (strengths, good technique, effort). Then give 2-3 sentences on specific, concrete form fixes they can easily implement. Focus on actionable coaching cues, not numerical scores. Be encouraging and supportive.",
  "improvements": [
    "One specific form fix #1 (<= 12 words)",
    "One specific form fix #2 (<= 12 words)",
    "One specific form fix #3 (<= 12 words)"
  ]
}

Keep the three "improvements" as concrete, actionable form cues that directly relate to the written analysis. Do NOT include any fields other than analysis and improvements. Do NOT prefix with code fences.
''';
  }
}
