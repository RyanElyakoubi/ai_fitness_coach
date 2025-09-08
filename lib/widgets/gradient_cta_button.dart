import 'package:flutter/material.dart';
import '../theme/app_gradients.dart';

class GradientCtaButton extends StatefulWidget {
  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  const GradientCtaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  @override
  State<GradientCtaButton> createState() => _GradientCtaButtonState();
}

class _GradientCtaButtonState extends State<GradientCtaButton> with SingleTickerProviderStateMixin {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = 22.0;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: widget.enabled ? 1 : .6,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          transform: Matrix4.identity()..scale(_pressed ? .98 : 1.0),
          decoration: BoxDecoration(
            gradient: AppGradients.brandLinear,
            borderRadius: BorderRadius.circular(radius),
            boxShadow: AppGradients.glow,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: .2,
            ),
          ),
        ),
      ),
    );
  }
}
