import 'package:flutter/material.dart';

class KeyImprovementsCard extends StatelessWidget {
  final List<String> items;
  const KeyImprovementsCard({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0x141A2236),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x1FFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Key Improvements", 
            style: TextStyle(
              color: Colors.white, 
              fontSize: 18, 
              fontWeight: FontWeight.bold
            )
          ),
          const SizedBox(height: 16),
          ...List.generate(items.length, (i) {
            final label = items[i];
            return Padding(
              padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Large green numbered circle
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: const Color(0xFF10B981),
                        width: 2,
                      ),
                    ),
                    child: Text(
                      "${i + 1}",
                      style: const TextStyle(
                        color: Color(0xFF10B981),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
