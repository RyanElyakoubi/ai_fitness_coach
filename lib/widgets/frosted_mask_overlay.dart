import 'dart:ui';
import 'package:flutter/material.dart';

/// Draws a frosted/blurred overlay everywhere EXCEPT a rounded-rect "window".
/// The outside region is blurred + darkened to ~75% opacity.
class FrostedMaskOverlay extends StatelessWidget {
  final Rect clearRect;
  final double radius;
  final double blurSigma;
  final Color tint;

  const FrostedMaskOverlay({
    super.key,
    required this.clearRect,
    this.radius = 20,
    this.blurSigma = 20,
    this.tint = const Color(0xCC0B0E17), // ~80% dark tint, matches app scheme
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ClipPath(
        clipper: _OutsideHoleClipper(clearRect: clearRect, radius: radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: Container(color: tint),
        ),
      ),
    );
  }
}

class _OutsideHoleClipper extends CustomClipper<Path> {
  final Rect clearRect;
  final double radius;
  _OutsideHoleClipper({required this.clearRect, required this.radius});

  @override
  Path getClip(Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    final rrect = RRect.fromRectAndRadius(clearRect, Radius.circular(radius));
    final inner = Path()..addRRect(rrect);
    // Subtract inner from outer to leave a "hole"
    return Path.combine(PathOperation.difference, outer, inner);
  }

  @override
  bool shouldReclip(covariant _OutsideHoleClipper oldClipper) {
    return oldClipper.clearRect != clearRect || oldClipper.radius != radius;
  }
}
