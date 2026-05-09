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

/// ─── Liquid Glass Settings (Apple Music style) ──────────────────────────────
/// Very subtle, premium feel — not milky, not heavy.
const _liquidSettings = OCLiquidGlassSettings(
  refractStrength: -0.03,    // Very low refraction — subtle bend
  blurRadiusPx: 1.5,         // Frosted feel
  specStrength: 4.0,         // Slightly brighter specular highlight for 3D top edge
  specPower: 70.0,           // Slightly softer falloff
  specWidth: 0.3,            // Ultra-thin highlight rim
  lightbandStrength: 0.05,   // Very subtle light band
  lightbandColor: Color(0x0DFFFFFF), // Extremely faint white
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
        // Dark background -> subtle white tint or lower black tint
        // A low opacity white helps text pop, but if too dark, black tint can also work.
        // Usually white 0.15 looks good on dark.
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
          decoration: showBorder
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(borderRadius),
                  border: Border.all(
                    color: const Color(0x1AFFFFFF), // ~10% white for a clearer glass rim
                    width: 0.3, // Ultra-thin border
                  ),
                )
              : null,
          child: child,
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
