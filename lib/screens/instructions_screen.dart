import 'package:flutter/material.dart';
import '../services/first_run_service.dart';
import '../widgets/recording_guidance_illustration.dart';
import '../widgets/brand_checkbox.dart';
import '../widgets/gradient_cta_button.dart';

class InstructionsScreen extends StatefulWidget {
  const InstructionsScreen({super.key});
  @override
  State<InstructionsScreen> createState() => _InstructionsScreenState();
}

class _InstructionsScreenState extends State<InstructionsScreen> {
  bool _mvpAccepted = false;

  void _continue() async {
    if (_mvpAccepted) {
      await FirstRunService.markSeen();
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please confirm this MVP only supports bench press.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF111318), // app dark
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title
                    _FormAILogo(),

                    const SizedBox(height: 8),

                    // Headline
                    Text(
                      'Record in portrait with full body & bar in frame.',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Bullets
                    _Bullet('Place phone ~45° off the bench, hip height'),
                    _Bullet('Keep lifter and bar fully visible'),
                    _Bullet('Good lighting • Stable phone'),

                    const SizedBox(height: 12),

                    // Illustration card
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: Colors.white.withOpacity(0.1)),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withOpacity(0.08),
                              Colors.white.withOpacity(0.04),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                        child: const RecordingGuidanceIllustration(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            // Bottom section with checkbox and CTA
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: BrandCheckbox(
                value: _mvpAccepted,
                onChanged: (v) => setState(() => _mvpAccepted = v),
                label: 'Bench press only (MVP). Other lifts are not graded yet.',
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, (bottom > 10 ? bottom : 10)),
              child: GradientCtaButton(
                label: 'Confirm & Continue',
                onPressed: _continue,
                enabled: _mvpAccepted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8, height: 8,
            margin: const EdgeInsets.only(top: 9, right: 10),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF7A3EF8), Color(0xFF4F6FF3), Color(0xFF2DB7C4)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.white.withOpacity(0.9),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FormAILogo extends StatelessWidget {
  const _FormAILogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // "Form" in white
        const Text(
          'Form',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 1.2,
          ),
        ),
        // "AI" with gradient
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFF7A3EF8), Color(0xFF4F6FF3), Color(0xFF2DB7C4)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ).createShader(bounds),
          child: const Text(
            'AI',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: Colors.white, // This will be masked by the gradient
              letterSpacing: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}
