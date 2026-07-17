import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  /// Roboto — locked globally so OEM system overrides cannot change it.
  static String? _fontFamily;
  static String get appFontFamily {
    _fontFamily ??= GoogleFonts.roboto().fontFamily!;
    return _fontFamily!;
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      // Lock Manrope globally — prevents OEM system fonts
      fontFamily: appFontFamily,
      scaffoldBackgroundColor: AppColors.background,
      primaryColor: AppColors.primaryStart,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primaryStart,
        secondary: AppColors.primaryEnd,
        surface: AppColors.surface,
        background: AppColors.background,
      ),
      textTheme: GoogleFonts.robotoTextTheme(ThemeData.dark().textTheme).copyWith(
        displayLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w900),
        displayMedium: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        displaySmall: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        headlineLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w800),
        headlineMedium: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        titleLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700),
        bodyLarge: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w500),
        bodyMedium: const TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(56),
          ),
          minimumSize: const Size(double.infinity, 56),
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        elevation: 0,
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FastPageTransitionBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
      ),
      useMaterial3: true,
    );
  }
}

/// Instant page transitions — no fade, no slide animation.
/// Screen appears immediately when navigated to.
class _FastPageTransitionBuilder extends PageTransitionsBuilder {
  const _FastPageTransitionBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}
