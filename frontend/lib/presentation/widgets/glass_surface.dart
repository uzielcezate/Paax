import 'dart:ui';
import 'package:flutter/material.dart';

/// ─── Glass Design Tokens ────────────────────────────────────────────────────
/// Shared constants for the iOS-style white frosted glass system.
class GlassTokens {
  GlassTokens._();

  // Blur
  static const double blurSigma = 14.0;

  // Colors — slightly more transparent than Phase 4 v1
  static Color fill = Colors.white.withOpacity(0.07);
  static Color border = Colors.white.withOpacity(0.14);
  static Color fillLight = Colors.white.withOpacity(0.04);

  // Shadows
  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.22),
      blurRadius: 14,
      offset: const Offset(0, 3),
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
  final bool enableBlur;
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
    this.enableBlur = true,
    this.padding,
    this.overrideFill,
  });

  @override
  Widget build(BuildContext context) {
    final innerContainer = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: overrideFill ?? GlassTokens.fill,
        borderRadius: borderRadius,
        border: showBorder
            ? Border.all(color: GlassTokens.border, width: 0.5)
            : null,
      ),
      child: child,
    );

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: showShadow ? GlassTokens.softShadow : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: enableBlur
            ? BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: GlassTokens.blurSigma,
                  sigmaY: GlassTokens.blurSigma,
                ),
                child: innerContainer,
              )
            : innerContainer,
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
  final bool enableBlur;
  final EdgeInsetsGeometry? padding;

  const GlassPill({
    super.key,
    required this.child,
    this.width,
    this.height = 56,
    this.showShadow = true,
    this.enableBlur = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(height / 2),
      showShadow: showShadow,
      enableBlur: enableBlur,
      padding: padding,
      child: child,
    );
  }
}

/// ─── GlassCircleButton ──────────────────────────────────────────────────────
/// A circular frosted glass button — used for back/menu icons in top bars.
///
/// Set [enableBlur] to false when this button is already inside a parent glass
/// surface (e.g. scrolled pill top bar) to avoid double-blur stacking.
class GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;
  final Color iconColor;
  final bool enableBlur;

  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 38,
    this.iconSize = 20,
    this.iconColor = Colors.white,
    this.enableBlur = true,
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
        enableBlur: enableBlur,
        child: Center(
          child: Icon(icon, size: iconSize, color: iconColor),
        ),
      ),
    );
  }
}

/// ─── GlassMenuButton ────────────────────────────────────────────────────────
/// Wraps a child widget (like OverflowMenu) inside a circular glass surface.
class GlassMenuButton extends StatelessWidget {
  final Widget child;
  final double size;
  final bool enableBlur;

  const GlassMenuButton({
    super.key,
    required this.child,
    this.size = 38,
    this.enableBlur = true,
  });

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(size / 2),
      showShadow: false,
      enableBlur: enableBlur,
      child: Center(child: child),
    );
  }
}

/// ─── EdgeGradient ───────────────────────────────────────────────────────────
/// Fade gradient for top/bottom edges so content dissolves behind chrome.
class EdgeGradient extends StatelessWidget {
  final bool fromTop;
  final double height;

  const EdgeGradient({
    super.key,
    this.fromTop = true,
    this.height = 80,
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
              Color(0xFF0B0B10), // AppColors.background — full opacity
              Color(0x000B0B10), // fully transparent
            ],
          ),
        ),
      ),
    );
  }
}
