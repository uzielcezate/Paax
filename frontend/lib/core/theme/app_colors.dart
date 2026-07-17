import 'package:flutter/material.dart';

class AppColors {
  // ── Core surfaces ──
  static const Color background = Color(0xFF080808);
  static const Color surface = Color(0xFF111111);
  static const Color elevatedSurface = Color(0xFF111111);
  static const Color surfaceLight = Color(0xFF111111); // alias for elevatedSurface

  // ── Brand gradient (kept) ──
  static const Color primaryStart = Color(0xFFFFFFFF);
  static const Color primaryEnd = Color(0xFFFF0055);
  static const Color secondary = Color(0xFF9D4EDD);

  // ── Text hierarchy ──
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Colors.white70;
  static const Color mutedText = Color(0xFF8A8A8A);       // white54-ish

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryStart, primaryEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
