import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.primaryStart, // Just a fallback
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primaryStart,
        secondary: AppColors.primaryEnd,
        surface: AppColors.surface,
        background: AppColors.background,
      ),
      textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        displayMedium: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        displaySmall: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        headlineLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        headlineMedium: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
        titleLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600),
        bodyLarge: const TextStyle(color: AppColors.textPrimary),
        bodyMedium: const TextStyle(color: AppColors.textSecondary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent, // We will use Container decorations usually
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(56),
          ),
          minimumSize: const Size(double.infinity, 56),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardTheme(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      useMaterial3: true,
    );
  }
}
