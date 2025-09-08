import 'package:flutter/material.dart';

class RecordingGuidanceIllustration extends StatelessWidget {
  const RecordingGuidanceIllustration({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        // Reserve a max height that works on small phones too.
        final maxH = constraints.maxHeight.clamp(280.0, 420.0);
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxH, maxWidth: maxH * 9 / 16 + 56),
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: CustomPaint(
                painter: _GuidePainter(Theme.of(context)),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GuidePainter extends CustomPainter {
  final ThemeData theme;
  _GuidePainter(this.theme);

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;

    // Phone outline - subtle stroke
    final phoneStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.025
      ..color = cs.outline.withValues(alpha: 0.3);

    final phoneRadius = Radius.circular(size.shortestSide * 0.12);
    final phoneRect = RRect.fromRectAndRadius(Offset.zero & size, phoneRadius);
    canvas.drawRRect(phoneRect, phoneStroke);

    // Screen area
    final screenInset = size.shortestSide * 0.05;
    
    // Dynamic Island
    final notchWidth = size.width * 0.38;
    final notchHeight = size.height * 0.04;
    final notchRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, screenInset + notchHeight * 0.8),
        width: notchWidth,
        height: notchHeight,
      ),
      Radius.circular(notchHeight * 0.5),
    );
    final notchPaint = Paint()..color = cs.onSurface.withValues(alpha: 0.08);
    canvas.drawRRect(notchRect, notchPaint);

    // Bench silhouette - clean geometric lines
    final benchStroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.shortestSide * 0.018
      ..strokeCap = StrokeCap.round
      ..color = cs.outline.withValues(alpha: 0.3);
    
    final benchY = size.height * 0.76;
    final benchWidth = size.width * 0.6;
    final benchStartX = (size.width - benchWidth) * 0.5;
    
    // Bench top
    canvas.drawLine(
      Offset(benchStartX, benchY),
      Offset(benchStartX + benchWidth, benchY),
      benchStroke,
    );
    
    // Bench legs
    final legHeight = size.height * 0.05;
    canvas.drawLine(
      Offset(benchStartX + benchWidth * 0.25, benchY),
      Offset(benchStartX + benchWidth * 0.25, benchY + legHeight),
      benchStroke,
    );
    canvas.drawLine(
      Offset(benchStartX + benchWidth * 0.75, benchY),
      Offset(benchStartX + benchWidth * 0.75, benchY + legHeight),
      benchStroke,
    );

    // No lifter, arrow, or barbell - just the clean bench
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
