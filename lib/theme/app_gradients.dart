import 'package:flutter/material.dart';

class AppGradients {
  static const colors = [
    Color(0xFF7A3EF8), // iris
    Color(0xFF4F6FF3), // blurple
    Color(0xFF2DB7C4), // teal
  ];

  static const brandLinear = LinearGradient(
    colors: colors,
    begin: Alignment(-1, 0),
    end: Alignment(1, 0),
  );

  static SweepGradient brandSweep() => const SweepGradient(
        colors: colors,
        stops: [0.0, 0.55, 1.0],
        startAngle: -1.5708, // 12 o'clock
        endAngle: 4.71239,
      );

  static List<BoxShadow> glow = [
    BoxShadow(color: Color(0xFF7A3EF8).withOpacity(.35), blurRadius: 30, spreadRadius: 4, offset: Offset(0, 8)),
    BoxShadow(color: Color(0xFF2DB7C4).withOpacity(.22), blurRadius: 36, spreadRadius: 6, offset: Offset(0, 14)),
  ];
}
