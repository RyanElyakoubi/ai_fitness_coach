import 'package:flutter/material.dart';
import '../theme/app_gradients.dart';

class BrandCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String label;

  const BrandCheckbox({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final box = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 22, height: 22,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: value ? AppGradients.brandLinear : null,
        border: value ? null : Border.all(color: Colors.white.withOpacity(.28), width: 1.5),
        color: value ? null : Colors.white.withOpacity(.06),
      ),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: value ? 1 : 0,
        child: const Icon(Icons.check, size: 16, color: Colors.white),
      ),
    );

    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          box,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                height: 1.35,
                color: Colors.white.withOpacity(.92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
