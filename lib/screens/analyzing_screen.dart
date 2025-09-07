import 'dart:math' as math;
import 'package:flutter/material.dart';

class AnalyzingScreen extends StatefulWidget {
  const AnalyzingScreen({super.key});

  @override
  State<AnalyzingScreen> createState() => _AnalyzingScreenState();
}

class _AnalyzingScreenState extends State<AnalyzingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _rotation;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Smooth continuous spin + gentle pulse
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _rotation = Tween<double>(begin: 0, end: 2 * math.pi).animate(_ctrl);
    // Pulse between 0.94x and 1.06x every 1.6s (two pulses per rotation)
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.94, end: 1.06).chain(CurveTween(curve: Curves.easeInOut)), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.06, end: 0.94).chain(CurveTween(curve: Curves.easeInOut)), weight: 50),
    ]).animate(
      CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.8)), // subtle pause at the end of cycle
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.of(context).size;

    // Choose a square size that looks good on phones and scales on tablets
    final double squareSize = math.min(size.width, size.height) * 0.54;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1420), // app dark bg
      body: SafeArea(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // SUNBURST GLOW — positioned to match the square
            Positioned(
              top: size.height * 0.35 - (squareSize * 1.35 / 2), // Center with the square
              child: IgnorePointer(
                ignoring: true,
                child: Container(
                  width: squareSize * 1.35,
                  height: squareSize * 1.35,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    // Subtle radial glow that matches brand gradient hues
                    gradient: RadialGradient(
                      colors: [
                        Color(0x3300FFC6), // soft mint glow (transparent)
                        Color(0x0000FFC6), // fade to transparent
                      ],
                      stops: [0.0, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // ROTATION + PULSE - moved up slightly for better centering
            Positioned(
              top: size.height * 0.35, // Move up from center
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  return Transform.rotate(
                    angle: _rotation.value,
                    child: Transform.scale(
                      scale: _scale.value,
                      child: CustomPaint(
                        size: Size.square(squareSize),
                        painter: _GradientStrokeSquarePainter(
                          strokeWidth: 6,
                          cornerRadius: 22,
                          // Gradient colors matching existing app ring
                          colors: const [
                            Color(0xFF38E0B9), // mint
                            Color(0xFF6DB7FF), // sky
                            Color(0xFF8B5CFF), // purple
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

            // STATUS TEXT — stays centered below square
            Positioned(
              bottom: size.height * 0.16,
              child: Text(
                'Analyzing with AI…',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GradientStrokeSquarePainter extends CustomPainter {
  _GradientStrokeSquarePainter({
    required this.strokeWidth,
    required this.cornerRadius,
    required this.colors,
  });

  final double strokeWidth;
  final double cornerRadius;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // Create a sweep gradient for a continuous neon edge
    final gradient = SweepGradient(
      colors: colors,
      stops: const [0.0, 0.5, 1.0],
      transform: const GradientRotation(-math.pi / 2), // start at 12 o'clock
    );

    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);

    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(cornerRadius),
    );

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _GradientStrokeSquarePainter oldDelegate) {
    return oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.cornerRadius != cornerRadius ||
        oldDelegate.colors != colors;
  }
}
