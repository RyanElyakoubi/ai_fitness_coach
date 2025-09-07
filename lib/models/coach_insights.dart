class CoachInsights {
  final String analysis;
  final List<String> improvements;

  CoachInsights({required this.analysis, required this.improvements});

  factory CoachInsights.fromJson(Map<String, dynamic> j) {
    final a = (j['analysis'] ?? '').toString().trim();
    final list = ((j['improvements'] ?? []) as List).map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
    return CoachInsights(analysis: a, improvements: list.take(3).toList());
  }
}
