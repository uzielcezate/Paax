import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Lightweight global state to track the active screen's dominant and foreground colors.
/// Useful for persistent bottom navigation and mini player to adapt their contrast.
class ThemeState extends ChangeNotifier {
  Color _backgroundColor = AppColors.background;
  Color _foregroundColor = Colors.white;

  Color get backgroundColor => _backgroundColor;
  Color get foregroundColor => _foregroundColor;

  void updateColors(Color bg, Color fg) {
    if (_backgroundColor != bg || _foregroundColor != fg) {
      _backgroundColor = bg;
      _foregroundColor = fg;
      // Delay notification to avoid "setState() or markNeedsBuild() called during build"
      Future.microtask(() {
        notifyListeners();
      });
    }
  }

  /// Reset to default dark theme
  void reset() {
    updateColors(AppColors.background, Colors.white);
  }
}
