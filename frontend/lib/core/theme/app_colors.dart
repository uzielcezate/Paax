import 'package:flutter/material.dart';

class AppColors {
  static const Color background = Color(0xFF0B0B10);
  static const Color surface = Color(0xFF12121A);
  static const Color surfaceLight = Color(0xFF1E1E28); // Slightly lighter for cards
  
  static const Color primaryStart = Color(0xFFFF9A00); // Amber/Orange
  static const Color primaryEnd = Color(0xFFFF0055); // Warm Pink/Magenta
  
  static const Color secondary = Color(0xFF9D4EDD); // Muted Purple
  
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFAAAAAA);
  
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryStart, primaryEnd],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient glassGradient = LinearGradient(
    colors: [
      Color(0x22FFFFFF),
      Color(0x05FFFFFF),
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
