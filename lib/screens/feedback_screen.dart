import 'package:flutter/material.dart';
import '../ui/style.dart';
import '../ui/gradient_ring.dart';
import '../models/score_response.dart';
import '../models/score_labels.dart';
import '../models/coach_insights.dart';
import '../services/gemini_service.dart';
import '../widgets/coach_analysis_card.dart';
import '../widgets/key_improvements_card.dart';

class FeedbackScreen extends StatefulWidget {
  static const routeName = '/feedback';
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _pageCtrl = PageController();
  int _page = 0;

  CoachInsights? _insights;
  String? _coachText;
  bool _coachLoading = false;
  String? _coachError;
  bool _requestedOnce = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onPageChanged(int p) {
    setState(() => _page = p);
    if (p == 1) {
      _ensureCoachInsights();
    }
  }

  Future<void> _ensureCoachInsights() async {
    if (_requestedOnce) return;
    final score = ModalRoute.of(context)!.settings.arguments as ScoreResponse;
    if (score.insufficient) return; // Don't generate analysis for insufficient scores
    
    _requestedOnce = true;
    setState(() {
      _coachLoading = true;
      _coachError = null;
    });

    try {
      final formCats = score.formBreakdownMap;
      final intCats = score.intensityBreakdownMap;

      final ci = await GeminiService.generateCoachInsights(
        holistic: score.holistic,
        form: score.form,
        intensity: score.intensity,
        formBreakdown: formCats,
        intensityBreakdown: intCats,
      );

      setState(() {
        _insights = ci;
        _coachText = ci.analysis; // reuse existing text field for CoachAnalysisCard
        _coachLoading = false;
      });
    } catch (e) {
      setState(() {
        _coachError = e.toString();
        _coachLoading = false;
      });
    }
  }

  void _retryCoachAnalysis() {
    _requestedOnce = false;
    _ensureCoachInsights();
  }

  @override
  Widget build(BuildContext context) {
    final ScoreResponse score =
        ModalRoute.of(context)!.settings.arguments as ScoreResponse;

    return Container(
      decoration: const BoxDecoration(gradient: AppStyle.pageBg),
      child: SafeArea(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Scorecard', style: TextStyle(color: Colors.white)),
                // Page dots
                if (!score.insufficient && score.failure?.status != AnalysisStatus.no_grade_not_bench) Row(
                  children: List.generate(2, (i) {
                    final active = i == _page;
                    return Container(
                      width: active ? 8 : 6,
                      height: active ? 8 : 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: active
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.3),
                        shape: BoxShape.circle,
                      ),
                    );
                  }),
                ),
              ],
            ),
            centerTitle: false,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: (score.insufficient || score.failure?.status == AnalysisStatus.no_grade_not_bench)
            ? _ScorecardPage(score: score) // Single page for insufficient scores or no-grade
            : PageView(
                controller: _pageCtrl,
                onPageChanged: _onPageChanged,
                children: [
                  // PAGE 1: EXISTING SCORECARD
                  _ScorecardPage(score: score),
                  
                  // PAGE 2: COACH ANALYSIS
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Coach's Analysis", 
                          style: TextStyle(
                            color: Colors.white, 
                            fontSize: 24, 
                            fontWeight: FontWeight.bold
                          )
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "Why you got this score and the #1 fix to focus on next set.",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14,
                          )
                        ),
                        const SizedBox(height: 16),
                        CoachAnalysisCard(
                          text: _coachText,
                          loading: _coachLoading,
                          error: _coachError,
                          onRetry: _retryCoachAnalysis,
                        ),
                        const SizedBox(height: 16),
                        if (_insights != null && _insights!.improvements.isNotEmpty)
                          KeyImprovementsCard(items: _insights!.improvements),
                        const SizedBox(height: 16),
                        Text(
                          "Tip: Swipe right to return to your score breakdown.",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 12,
                          )
                        ),
                        const SizedBox(height: 20),
                        // Actions (same as page 1)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: const BorderSide(color: Colors.white30),
                              ),
                              child: const Text("Done"),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF7C3AED),
                                foregroundColor: Colors.white,
                              ),
                              child: const Text("Rescan"),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        ),
      ),
    );
  }
}

// Extracted scorecard page to reuse existing UI exactly
class _ScorecardPage extends StatelessWidget {
  final ScoreResponse score;
  const _ScorecardPage({required this.score});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        children: [
          if (score.failure?.status == AnalysisStatus.no_grade_not_bench) ...[
            // Show no-grade message for unsupported movements
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0x141A2236),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.fitness_center, color: Colors.blue, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'No Grade – Unsupported Movement',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'This prototype only supports bench press/chest-press movements. Please upload a bench press video recorded in portrait with the full body and bar visible.',
                    style: TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  if (score.failure?.rationale.isNotEmpty == true) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0x0AFFFFFF),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          const Text('Detected:', style: TextStyle(color: Colors.white60, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(
                            score.failure!.rationale.values.first,
                            style: const TextStyle(color: Colors.white70, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white30),
                        ),
                        child: const Text("Tips"),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text("Rescan"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else if (score.insufficient) ...[
            // Show insufficient analysis message
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: const Color(0x141A2236),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x1FFFFFFF)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'Insufficient video for full analysis',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  const Text('Tips for better analysis:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text('• Good lighting', style: TextStyle(color: Colors.white70)),
                  const Text('• Full body and bar in frame', style: TextStyle(color: Colors.white70)),
                  const Text('• Stable phone position', style: TextStyle(color: Colors.white70)),
                  const Text('• Clear view of form', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ] else ...[
            // --- Holistic at top ---
            GradientRing(
              size: 180,
              stroke: 12,
              percent: score.holisticPercent,
              center: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("${score.holistic}", style: const TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  const Text("Holistic", style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _MainScoreBreakdownCard(resp: score),
            const SizedBox(height: 16),
            // Show swipe hint only on page 1
            Text(
              "Swipe left for coach's analysis →",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: 20),
          // Actions
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  side: const BorderSide(color: Colors.white30),
                ),
                child: const Text("Done"),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7C3AED),
                  foregroundColor: Colors.white,
                ),
                child: const Text("Rescan"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MainScoreBreakdownCard extends StatelessWidget {
  final ScoreResponse resp;
  const _MainScoreBreakdownCard({required this.resp});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            color: const Color(0x141A2236),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeaderRow(title: "Form", score: resp.form),
              const SizedBox(height: 10),
              _SubSectionBarsForm(items: resp.formSubs, overallFallback: resp.form),
            ],
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: const Color(0x141A2236),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x1FFFFFFF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionHeaderRow(title: "Intensity", score: resp.intensity),
              const SizedBox(height: 10),
              _SubSectionBarsIntensity(items: resp.intensitySubs, overallFallback: resp.intensity),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  final String title;
  final int score;
  const _SectionHeaderRow({required this.title, required this.score});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
        const Spacer(),
        _GradientScoreChip(value: score),
      ],
    );
  }
}

class _GradientScoreChip extends StatelessWidget {
  final int value;
  const _GradientScoreChip({required this.value});

  @override
  Widget build(BuildContext context) {
    const double size = 44;
    const double ring = 4;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppStyle.scoreGradient, // same as Holistic
        boxShadow: AppStyle.softGlow,
      ),
      child: Center(
        child: Container(
          width: size - ring*2,
          height: size - ring*2,
          decoration: BoxDecoration(
            color: const Color(0xFF0E1220), // inner fill matches page bg for contrast
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            "$value",
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 14,
              height: 1.0,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _SubSectionBarsForm extends StatelessWidget {
  final List<CategoryScore<SubFormKey>> items;
  final int overallFallback;
  const _SubSectionBarsForm({required this.items, required this.overallFallback});

  @override
  Widget build(BuildContext context) {
    final list = items.isEmpty
        ? SubFormKey.values.map((k) => CategoryScore(key: k, score: overallFallback)).toList()
        : items;

    return Column(
      children: list.map((e) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _MetricBar(label: kFormLabels[e.key]!, value: e.score / 100.0),
      )).toList(),
    );
  }
}

class _SubSectionBarsIntensity extends StatelessWidget {
  final List<CategoryScore<SubIntensityKey>> items;
  final int overallFallback;
  const _SubSectionBarsIntensity({required this.items, required this.overallFallback});

  @override
  Widget build(BuildContext context) {
    final list = items.isEmpty
        ? SubIntensityKey.values.map((k) => CategoryScore(key: k, score: overallFallback)).toList()
        : items;

    return Column(
      children: list.map((e) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _MetricBar(label: kIntensityLabels[e.key]!, value: e.score / 100.0),
      )).toList(),
    );
  }
}

class _MetricBar extends StatelessWidget {
  final String label;
  final double value; // 0..1
  const _MetricBar({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, overflow: TextOverflow.ellipsis, maxLines: 1,
          style: const TextStyle(color: Color(0xFFB7C2D0), fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return Stack(
              children: [
                // Track
                Container(
                  height: 10,
                  width: w,
                  decoration: BoxDecoration(
                    color: const Color(0x1FFFFFFF),
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
                // Fill with score gradient
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  height: 10,
                  width: w * v,
                  decoration: BoxDecoration(
                    gradient: AppStyle.scoreGradient, // use shared gradient
                    borderRadius: BorderRadius.circular(100),
                    boxShadow: const [
                      BoxShadow(color: Color(0x405EEAD4), blurRadius: 10, spreadRadius: 0), // teal-ish
                      BoxShadow(color: Color(0x407C3AED), blurRadius: 12, spreadRadius: 0), // purple-ish
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}