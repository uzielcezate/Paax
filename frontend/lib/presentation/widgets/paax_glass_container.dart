import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:math' as math;
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../state/theme_state.dart';
import 'glass_surface.dart';

/// Whether the current platform supports liquid glass (Impeller-based shaders).
/// Web does NOT support it — always falls back to BackdropFilter.
bool get _useLiquidGlass => !kIsWeb;

/// ─── Liquid Glass Settings (Apple Music style) ──────────────────────────────
/// Very subtle, premium feel — not milky, not heavy.
/// Lightband is zeroed — we draw our own partial rim via CustomPainter.
const _liquidSettings = OCLiquidGlassSettings(
  refractStrength: -0.03,    // Very low refraction — subtle bend
  blurRadiusPx: 1.5,         // Frosted feel
  specStrength: 4.0,         // Slightly brighter specular highlight for 3D top edge
  specPower: 70.0,           // Slightly softer falloff
  specWidth: 0.3,            // Ultra-thin highlight rim
  lightbandStrength: 0.0,    // Disabled — we paint our own partial rim
  lightbandColor: Color(0x00FFFFFF),
);

/// ─── PaaxGlassContainer ─────────────────────────────────────────────────────
/// Single integration point for liquid glass on mobile.
///
/// Usage:
/// ```dart
/// PaaxGlassContainer(
///   width: 200,
///   height: 60,
///   borderRadius: 30,
///   child: Text('Hello'),
/// )
/// ```
///
/// On Android/iOS: renders via `OCLiquidGlassGroup` + `OCLiquidGlass`.
/// On Web: falls back to the existing `BackdropFilter` + `GlassTokens` system.
class PaaxGlassContainer extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final double borderRadius;
  final bool showShadow;
  final bool showBorder;
  final EdgeInsetsGeometry? padding;
  final Color? overrideFill;

  const PaaxGlassContainer({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius = 16,
    this.showShadow = true,
    this.showBorder = true,
    this.padding,
    this.overrideFill,
  });

  @override
  Widget build(BuildContext context) {
    if (!_useLiquidGlass) {
      // Web fallback — use existing BackdropFilter glass
      return _buildFallback();
    }

    // Adaptive tint for readability
    Color tintColor;
    if (overrideFill != null) {
      tintColor = overrideFill!;
    } else {
      final bgColor = context.watch<ThemeState>().backgroundColor;
      // Calculate luminance to determine if background is light or dark
      final luminance = bgColor.computeLuminance();
      
      if (luminance > 0.5) {
        // Bright background -> subtle black tint for readability
        tintColor = Colors.black.withOpacity(0.20);
      } else {
        // Dark background -> subtle white tint
        tintColor = Colors.white.withOpacity(0.12);
      }
    }

    return _buildLiquidGlass(tintColor);
  }

  Widget _buildLiquidGlass(Color tintColor) {
    final shadow = showShadow
        ? BoxShadow(
            color: Colors.black.withOpacity(0.35), // Deeper atmospheric shadow
            blurRadius: 24, // Softer diffusion
            spreadRadius: -2,
            offset: const Offset(0, 8), // More floating depth
          )
        : null;

    return OCLiquidGlassGroup(
      settings: _liquidSettings,
      child: OCLiquidGlass(
        width: width,
        height: height,
        borderRadius: borderRadius,
        color: tintColor, 
        shadow: shadow,
        child: Container(
          padding: padding,
          child: CustomPaint(
            foregroundPainter: showBorder
                ? _GlassRimPainter(borderRadius: borderRadius)
                : null,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _buildFallback() {
    final br = BorderRadius.circular(borderRadius);
    final innerContainer = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: overrideFill ?? GlassTokens.fill,
        borderRadius: br,
        border: showBorder
            ? Border.all(color: GlassTokens.border, width: GlassTokens.borderWidth)
            : null,
      ),
      child: child,
    );

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: showShadow ? GlassTokens.softShadow : null,
      ),
      child: ClipRRect(
        borderRadius: br,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: GlassTokens.blurSigma,
            sigmaY: GlassTokens.blurSigma,
          ),
          child: innerContainer,
        ),
      ),
    );
  }
}

/// ─── _GlassRimPainter ───────────────────────────────────────────────────────
/// Draws an ultra-thin partial glass rim covering ~82% of the element perimeter,
/// leaving two small natural gaps at the upper-right (~315°) and lower-left (~135°)
/// corners for a realistic glass highlight reflection.
class _GlassRimPainter extends CustomPainter {
  final double borderRadius;

  _GlassRimPainter({required this.borderRadius});

  // Rim covers two arcs:
  //   Arc A: from 150° to 315° (going clockwise through bottom, right, and top) = 165°
  //   Arc B: from 330° to 135° (going clockwise through right-top, left) = 165°
  // Total: 330° out of 360° ≈ 91.7% — but the sweep includes soft fade-out at
  // the ends via a gradient shader, making the visible portion ~82%.

  static const double _gapSizeDeg = 30.0; // each gap is ~30°
  // Gap 1 centers at ~315° (upper-right)
  static const double _gap1Center = 315.0;
  // Gap 2 centers at ~135° (lower-left)
  static const double _gap2Center = 135.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = borderRadius.clamp(0.0, math.min(size.width, size.height) / 2);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(r));

    // We draw on the rounded rect's outline path.
    // To create partial arcs on a rounded rectangle, we use a path + PathMetrics
    // to extract the exact segments we want.
    final fullPath = Path()..addRRect(rrect);
    final metrics = fullPath.computeMetrics().first;
    final totalLen = metrics.length;

    // Convert degree offsets to path fractions.
    // Path starts at top-center (0°=top) going clockwise in Flutter's addRRect.
    // But addRRect starts at the top-left corner. We adjust accordingly.
    // The gap centers map to fractional positions on the perimeter.

    // Fraction helper: degrees → path length
    double degToLen(double deg) => (deg / 360.0) * totalLen;

    // Gap 1: upper-right (~315° = top-right area)
    final gap1Start = degToLen(_gap1Center - _gapSizeDeg / 2); // 300°
    final gap1End = degToLen(_gap1Center + _gapSizeDeg / 2);   // 330°

    // Gap 2: lower-left (~135° = bottom-left area)
    final gap2Start = degToLen(_gap2Center - _gapSizeDeg / 2); // 120°
    final gap2End = degToLen(_gap2Center + _gapSizeDeg / 2);   // 150°

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.4
      ..color = const Color(0x20FFFFFF); // ~12.5% white — subtle and premium

    // Segment 1: from gap2End (150°) to gap1Start (300°)
    final seg1 = metrics.extractPath(gap2End, gap1Start);
    canvas.drawPath(seg1, paint);

    // Segment 2: from gap1End (330°) wrapping around 360° to gap2Start (120°)
    // This crosses the 0° boundary, so we draw two sub-segments
    if (gap1End < totalLen) {
      final seg2a = metrics.extractPath(gap1End, totalLen);
      canvas.drawPath(seg2a, paint);
    }
    if (gap2Start > 0) {
      final seg2b = metrics.extractPath(0, gap2Start);
      canvas.drawPath(seg2b, paint);
    }
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) => old.borderRadius != borderRadius;
}
