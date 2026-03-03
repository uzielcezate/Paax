import 'package:flutter/material.dart';
import 'dart:math' as math;

class Responsive {
  static const double mobileBreakpoint = 600;
  static const double tabletBreakpoint = 1200;

  static bool isMobile(BuildContext context) =>
      MediaQuery.of(context).size.width < mobileBreakpoint;

  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.width >= mobileBreakpoint &&
      MediaQuery.of(context).size.width < tabletBreakpoint;

  static bool isDesktop(BuildContext context) =>
      MediaQuery.of(context).size.width >= tabletBreakpoint;

  /// Returns a value based on the current screen size.
  static T value<T>(BuildContext context, {required T mobile, T? tablet, T? desktop}) {
    final width = MediaQuery.of(context).size.width;
    if (width >= tabletBreakpoint) return desktop ?? tablet ?? mobile;
    if (width >= mobileBreakpoint) return tablet ?? mobile;
    return mobile;
  }

  /// Calculates a responsive grid cross-axis count based on item width.
  static int gridCount(BuildContext context, {double minItemWidth = 160, int maxColumns = 6}) {
    final width = MediaQuery.of(context).size.width;
    // Ensure at least 2 columns on mobile if possible, or 1 if very small
    int count = (width / minItemWidth).floor();
    return count.clamp(2, maxColumns); 
  }

  /// Responsive spacing based on screen width.
  /// mobile: 8-16, tablet: 16-24, desktop: 24+
  static double spacing(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return (width * 0.02).clamp(8.0, 24.0);
  }

  /// Horizontal padding: 6% of screen width, clamped 16-24
  static double horizontalPadding(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return (width * 0.06).clamp(16.0, 24.0);
  }

  /// Vertical spacing: 1.2% of screen height, clamped 8-14
  static double verticalSpacing(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    return (height * 0.012).clamp(8.0, 14.0);
  }

  /// Artwork size for player: 68% of width, clamped 220-320
  static double artworkSize(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return (width * 0.68).clamp(220.0, 320.0);
  }

  /// Responsive padding (horizontal) for screens.
  static EdgeInsets screenPadding(BuildContext context) {
    final s = spacing(context);
    return EdgeInsets.symmetric(horizontal: s, vertical: s);
  }

  /// Responsive Font Size
  /// Scales base font size with screen width, clamped within a range.
  static double fontSize(BuildContext context, double base, {double min = 12, double max = 30}) {
    final width = MediaQuery.of(context).size.width;
    // Scale factor: 1.0 at 400px width
    double scale = width / 400; 
    // Dampen the scale so it doesn't get too huge on desktop
    scale = math.min(scale, 1.5); 
    
    return (base * scale).clamp(min, max);
  }
  
  /// Responsive Icon Size
  static double iconSize(BuildContext context, {double base = 24, double min = 20, double max = 32}) {
     final width = MediaQuery.of(context).size.width;
     double scale = width / 400;
     scale = math.min(scale, 1.5);
     return (base * scale).clamp(min, max);
  }
  
  /// Returns the height of the bottom navigation bar + mini player
  /// allowing screens to add correct bottom padding.
  static double bottomPadding(BuildContext context) {
     final hasMiniPlayer = true; // Assuming always true if we have a robust check later
     // Nav: 80, MiniPlayer: 80 (approx with margin)
     return 160.0 + MediaQuery.of(context).padding.bottom;
  }
}
