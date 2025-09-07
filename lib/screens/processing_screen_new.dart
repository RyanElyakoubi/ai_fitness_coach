import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/sampling_service.dart';
import '../services/rep_sampler.dart';
import '../services/gemini_service.dart';
import '../services/gating_service.dart';
import '../ui/style.dart';
import '../widgets/animated_gradient_square.dart';

class ProcessingScreen extends StatefulWidget {
  static const routeName = '/processing';
  const ProcessingScreen({super.key});

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

enum ProcState { running, success, failure }

class _ProcessingScreenState extends State<ProcessingScreen> with SingleTickerProviderStateMixin {
  final RepAwareSampler _repSampler = RepAwareSampler();
  final GatingService _gating = GatingService();
  String _currentStep = 'Checking limits...';
  ProcState _state = ProcState.running;
  String? _errorMsg;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      duration: const Duration(seconds: 6),
      vsync: this,
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
    final videoPath = args['videoPath'] as String;
    
    setState(() => _state = ProcState.running);
    
    try {
      // Step 1: Gate check
      setState(() => _currentStep = 'Checking daily limits...');
      
      final canFree = await _gating.canAnalyzeFreeUser();
      if (!canFree) {
        _showFail(['Daily limit reached'], fallback: 'daily_limit');
        return;
      }

      // Step 2: Sampling (now uses isolate + motion gate)
      setState(() => _currentStep = 'Analyzing video...');
      
      final sampling = await _repSampler.sample(videoPath);
      
      // Step 3: Convert to base64 for Gemini
      setState(() => _currentStep = 'Preparing for AI analysis...');
      
      final framesBase64 = <String>[];
      final clipsBase64 = <String>[];
      
      // Add anchors and frames
      for (final anchor in sampling.anchors) {
        framesBase64.add(base64Encode(anchor));
      }
      for (final frame in sampling.frames) {
        framesBase64.add(base64Encode(frame));
      }
      for (final clip in sampling.clips) {
        clipsBase64.add(base64Encode(clip.bytes));
      }
      
      setState(() => _currentStep = 'Analyzing with AI...');
      
      final result = await GeminiService.analyze(
        framesBase64Jpeg: framesBase64,
        snippetsBase64Mp4: clipsBase64,
        requestHints: {
          'pipeline': 'isolate_motion_gate',
          'gate_confident': sampling.gateConfident,
          'gate_rationale': sampling.gateRationale,
          'trimmed_window_ms': sampling.trimmedEndMs - sampling.trimmedStartMs,
        },
      );
      
      await _gating.recordAnalysisUsed();
      
      if (result.holistic > 0 || result.form > 0 || result.intensity > 0) {
        if (!mounted) return;
        Navigator.pushReplacementNamed(
          context,
          '/feedback',
          arguments: result,
        );
      } else {
        _showFail(['insufficient'], fallback: sampling.gateRationale);
      }
    } catch (e) {
      _showFail(['pipeline_error'], fallback: 'pipeline_error');
    }
  }

  void _showFail(List<String> reasons, {required String fallback}) {
    if (!mounted) return;
    Navigator.pushReplacementNamed(
      context,
      '/scorecard_failed', 
      arguments: {
        'reasons': reasons,
        'rationale': fallback,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final loading = _state == ProcState.running;
    return Container(
      decoration: const BoxDecoration(gradient: AppStyle.pageBg),
      child: SafeArea(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            alignment: Alignment.center,
            children: [
              if (loading) ...[
                // Soft glow behind the square
                Positioned(
                  bottom: MediaQuery.of(context).size.height * 0.30,
                  child: Container(
                    width: 320, height: 320,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: const Color(0x335EEAD4), blurRadius: 90, spreadRadius: 12),
                        BoxShadow(color: const Color(0x337C3AED), blurRadius: 60, spreadRadius: 8),
                      ],
                    ),
                  ),
                ),
                // Rotating gradient square with independent animation controller
                Positioned(
                  bottom: MediaQuery.of(context).size.height * 0.28,
                  child: SizedBox(
                    width: 220, height: 220,
                    child: AnimatedBuilder(
                      animation: _animController,
                      builder: (_, __) {
                        return Transform.rotate(
                          angle: _animController.value * 2 * 3.14159,
                          child: const AnimatedGradientSquare(size: 220, strokeWidth: 2.5),
                        );
                      },
                    ),
                  ),
                ),
                // Label text
                Positioned(
                  bottom: MediaQuery.of(context).size.height * 0.20,
                  child: Text(
                    _currentStep,
                    style: const TextStyle(
                      color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: 0.2),
                  ),
                ),
              ],

              // Error state
              if (_state == ProcState.failure) ...[
                Positioned(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 64),
                      const SizedBox(height: 16),
                      Text(
                        _errorMsg ?? 'Processing failed',
                        style: const TextStyle(color: Colors.white, fontSize: 18),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Go Back'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
