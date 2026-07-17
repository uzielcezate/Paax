import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Cross-device safe insets helper.
///
/// Some Android OEMs (Oppo/ColorOS, Realme, Xiaomi MIUI) report incorrect
/// or zero bottom padding via `MediaQuery.padding.bottom`, especially with
/// gesture navigation. This utility normalizes bottom insets across devices.
class SafeInsets {
  SafeInsets._();

  /// The minimum bottom spacing to apply even when the OS reports zero.
  /// Prevents controls from sitting directly on the screen edge on
  /// gesture-nav devices where the OS bar is translucent.
  static const double _minBottomSpacing = 8.0;

  /// Returns a reliable bottom inset that works across all OEMs.
  ///
  /// Uses `viewPadding.bottom` (includes system nav even when keyboard is up)
  /// as primary source, with a defensive minimum fallback.
  static double bottomInset(BuildContext context) {
    final mq = MediaQuery.of(context);
    // viewPadding is more reliable than padding on OEM Android skins
    final viewPad = mq.viewPadding.bottom;
    final safePad = mq.padding.bottom;
    // Take the larger of the two, with a minimum floor
    return [viewPad, safePad, _minBottomSpacing].reduce((a, b) => a > b ? a : b);
  }

  /// Returns the top safe area inset.
  static double topInset(BuildContext context) {
    final mq = MediaQuery.of(context);
    return [mq.viewPadding.top, mq.padding.top].reduce((a, b) => a > b ? a : b);
  }

  /// Whether the device likely has gesture navigation (small bottom inset).
  static bool hasGestureNav(BuildContext context) {
    final mq = MediaQuery.of(context);
    return mq.viewPadding.bottom > 0 && mq.viewPadding.bottom < 40;
  }
}
