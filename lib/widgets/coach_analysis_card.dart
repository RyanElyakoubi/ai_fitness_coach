import 'package:flutter/material.dart';

class CoachAnalysisCard extends StatelessWidget {
  final String? text;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  const CoachAnalysisCard({
    super.key,
    required this.text,
    this.loading = false,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    Widget child;

    if (loading) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          const CircularProgressIndicator(strokeWidth: 3, color: Colors.white70),
          const SizedBox(height: 16),
          Text("Generating coach's analysis...", style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
        ],
      );
    } else if (error != null) {
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text("Couldn't generate analysis.", style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry, 
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: const Text("Try again"),
            ),
        ],
      );
    } else {
      child = Text(
        text ?? "",
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          height: 1.4,
          fontWeight: FontWeight.w400,
        ),
        textAlign: TextAlign.left,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0x141A2236),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: child,
    );
  }
}
