import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/app_colors.dart';

/// Lightweight global state to track the active screen's dominant and foreground colors.
/// Useful for persistent bottom navigation and mini player to adapt their contrast.
///
/// Also imperatively sets system status bar icons via SystemChrome so that the
/// status bar contrast always matches the current screen — even when
/// AnnotatedRegion does not re-evaluate fast enough.
class ThemeState extends ChangeNotifier {
  Color _backgroundColor = AppColors.background;
  Color _foregroundColor = Colors.white;
  bool _notifyScheduled = false;

  Color get backgroundColor => _backgroundColor;
  Color get foregroundColor => _foregroundColor;

  void updateColors(Color bg, Color fg) {
    if (_backgroundColor == bg && _foregroundColor == fg) return;
    _backgroundColor = bg;
    _foregroundColor = fg;

    // Imperatively set status bar icons NOW — this is the most reliable
    // way to ensure status bar contrast updates on Android.
    _applyStatusBarStyle();

    // Coalesce multiple updates in the same frame into a single notification.
    if (!_notifyScheduled) {
      _notifyScheduled = true;
      scheduleMicrotask(() {
        _notifyScheduled = false;
        notifyListeners();
      });
    }
  }

  /// Reset to default dark theme
  void reset() {
    updateColors(AppColors.background, Colors.white);
  }

  /// Set system status bar icon brightness based on foreground color.
  void _applyStatusBarStyle() {
    final style = _foregroundColor == Colors.white
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    SystemChrome.setSystemUIOverlayStyle(style.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ));
  }
}
