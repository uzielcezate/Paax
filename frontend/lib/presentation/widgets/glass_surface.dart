import 'dart:ui';
import 'package:flutter/material.dart';

/// ─── Glass Design Tokens ────────────────────────────────────────────────────
/// Shared constants for the iOS-style white frosted glass system.
class GlassTokens {
  GlassTokens._();

  // Blur
  static const double blurSigma = 14.0;

  // Colors
  static Color fill = Colors.white.withOpacity(0.10);
  static Color border = Colors.white.withOpacity(0.18);
  static Color fillLight = Colors.white.withOpacity(0.06);

  // Shadows
  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.25),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];
}

/// ─── GlassSurface ───────────────────────────────────────────────────────────
/// Base frosted glass container — clips content and applies backdrop blur
/// with a translucent white tint. Used as building block for pills/circles.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final bool showBorder;
  final bool showShadow;
  final EdgeInsetsGeometry? padding;
  final Color? overrideFill;

  const GlassSurface({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.showBorder = true,
    this.showShadow = true,
    this.padding,
    this.overrideFill,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: showShadow ? GlassTokens.softShadow : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: GlassTokens.blurSigma,
            sigmaY: GlassTokens.blurSigma,
          ),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: overrideFill ?? GlassTokens.fill,
              borderRadius: borderRadius,
              border: showBorder
                  ? Border.all(color: GlassTokens.border, width: 0.5)
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// ─── GlassPill ──────────────────────────────────────────────────────────────
/// A capsule-shaped frosted glass surface (fully rounded ends).
class GlassPill extends StatelessWidget {
  final Widget child;
  final double? width;
  final double height;
  final bool showShadow;
  final EdgeInsetsGeometry? padding;

  const GlassPill({
    super.key,
    required this.child,
    this.width,
    this.height = 56,
    this.showShadow = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(height / 2),
      showShadow: showShadow,
      padding: padding,
      child: child,
    );
  }
}

/// ─── GlassCircleButton ──────────────────────────────────────────────────────
/// A circular frosted glass button — used for back/menu icons in top bars.
class GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final Color iconColor;

  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 38,
    this.iconSize = 20,
    this.iconColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: GlassSurface(
        width: size,
        height: size,
        borderRadius: BorderRadius.circular(size / 2),
        showShadow: false,
        child: Center(
          child: Icon(icon, size: iconSize, color: iconColor),
        ),
      ),
    );
  }
}

/// ─── WhiteGlassAppBar ───────────────────────────────────────────────────────
/// Full-width frosted glass top bar used when scroll threshold is passed.
/// Replaces BlackGlassBlurSurface with white-tinted glass.
class WhiteGlassAppBar extends StatelessWidget {
  final double height;
  final double width;

  const WhiteGlassAppBar({
    super.key,
    required this.height,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: GlassTokens.blurSigma,
          sigmaY: GlassTokens.blurSigma,
        ),
        child: Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: GlassTokens.fillLight,
            border: Border(
              bottom: BorderSide(color: GlassTokens.border, width: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// ─── EdgeGradient ───────────────────────────────────────────────────────────
/// Subtle fade gradient for top/bottom edges so content dissolves behind chrome.
class EdgeGradient extends StatelessWidget {
  final bool fromTop;
  final double height;

  const EdgeGradient({
    super.key,
    this.fromTop = true,
    this.height = 60,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: fromTop ? Alignment.topCenter : Alignment.bottomCenter,
            end: fromTop ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [
              Color(0xFF0B0B10), // AppColors.background
              Color(0x000B0B10),
            ],
          ),
        ),
      ),
    );
  }
}
