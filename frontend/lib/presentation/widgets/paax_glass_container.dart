import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:oc_liquid_glass/oc_liquid_glass.dart';
import 'package:provider/provider.dart';
import '../state/theme_state.dart';
import 'glass_surface.dart';

/// Whether the current platform supports liquid glass (Impeller-based shaders).
/// Web does NOT support it — always falls back to BackdropFilter.
bool get _useLiquidGlass => !kIsWeb;

/// ─── Liquid Glass Settings ──────────────────────────────────────────────────
/// Tuned to match the OC Liquid Glass reference.
/// Uses the shader's native lightband for the full reflective band effect.
const _liquidSettings = OCLiquidGlassSettings(
  blendPx: 5,
  refractStrength: -0.2,
  distortFalloffPx: 45,
  distortExponent: 4,
  blurRadiusPx: 25,
  specAngle: 4,
  specStrength: 0.5,
  specPower: 120,
  specWidth: 10,
  lightbandOffsetPx: 10,
  lightbandWidthPx: 30,
  lightbandStrength: 0.9,
  lightbandColor: Colors.white,
);

/// ─── PaaxGlassContainer ─────────────────────────────────────────────────────
/// Single integration point for liquid glass on mobile.
///
/// On Android/iOS: renders via `OCLiquidGlassGroup` + `OCLiquidGlass`.
/// On Web: falls back to the existing `BackdropFilter` + `GlassTokens` system.
///
/// Shadow is rendered by a separate outer `DecoratedBox` that is clipped with
/// `ClipRRect` to the exact `borderRadius`, preventing any rectangular
/// bounding-box artifacts during opacity transitions.
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
      return _buildFallback();
    }

    // Adaptive tint for readability — preserves existing icon/text color logic
    Color tintColor;
    if (overrideFill != null) {
      tintColor = overrideFill!;
    } else {
      final bgColor = context.watch<ThemeState>().backgroundColor;
      final luminance = bgColor.computeLuminance();
      if (luminance > 0.5) {
        tintColor = const Color(0x33000000); // 20% black on bright backgrounds
      } else {
        tintColor = const Color(0x1FFFFFFF); // 12% white on dark backgrounds
      }
    }

    return _buildLiquidGlass(tintColor);
  }

  Widget _buildLiquidGlass(Color tintColor) {
    final br = BorderRadius.circular(borderRadius);

    // The glass effect itself — shadow is NOT passed to OCLiquidGlass to avoid
    // the library's internal Container rendering a rectangular bounding box.
    Widget glass = OCLiquidGlassGroup(
      settings: _liquidSettings,
      child: OCLiquidGlass(
        width: width,
        height: height,
        borderRadius: borderRadius,
        color: tintColor,
        // No shadow here — we handle it ourselves with a clipped outer layer
        child: Container(
          padding: padding,
          child: child,
        ),
      ),
    );

    if (!showShadow) return glass;

    // Outer shadow layer, properly clipped to the rounded shape.
    // This completely prevents rectangular shadow artifacts.
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000), // 25% black — soft atmospheric depth
            blurRadius: 20,
            spreadRadius: -4,
            offset: Offset(0, 6),
            blurStyle: BlurStyle.normal,
          ),
        ],
      ),
      child: glass,
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
