import 'dart:ui';
import 'package:flutter/material.dart';

/// ─── Glass Design Tokens ────────────────────────────────────────────────────
class GlassTokens {
  GlassTokens._();

  static const double blurSigma = 14.0;

  // Slightly transparent white — subtle, not too white
  static Color fill = Colors.white.withOpacity(0.07);
  static Color border = Colors.white.withOpacity(0.14);
  static Color fillLight = Colors.white.withOpacity(0.04);

  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.22),
      blurRadius: 14,
      offset: const Offset(0, 3),
    ),
  ];
}

/// ─── GlassSurface ───────────────────────────────────────────────────────────
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

/// ─── ScrolledTopPill ────────────────────────────────────────────────────────
/// Floating pill for the scrolled state: [back | title | trailing].
/// Single BackdropFilter — no double blur.
class ScrolledTopPill extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final Widget? trailing;

  const ScrolledTopPill({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPill(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox(
              width: 38,
              height: 46,
              child: Center(
                child: Icon(Icons.arrow_back_ios_new, size: 18, color: Colors.white),
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          if (trailing != null)
            SizedBox(width: 38, height: 46, child: Center(child: trailing!))
          else
            const SizedBox(width: 38),
        ],
      ),
    );
  }
}

/// ─── FloatingTopControls ────────────────────────────────────────────────────
/// Overlay widget that crossfades between separate circles (default)
/// and a single scrolled pill. Prevents double-blur by only rendering
/// one set of controls at a time.
class FloatingTopControls extends StatelessWidget {
  final bool showScrolledPill;
  final Widget defaultControls;
  final Widget scrolledPill;
  final double topPadding;

  const FloatingTopControls({
    super.key,
    required this.showScrolledPill,
    required this.defaultControls,
    required this.scrolledPill,
    required this.topPadding,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: topPadding + 6,
      left: 12,
      right: 12,
      child: Stack(
        children: [
          // Default circles (fade out on scroll)
          AnimatedOpacity(
            opacity: showScrolledPill ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: showScrolledPill,
              child: defaultControls,
            ),
          ),
          // Scrolled pill (fade in on scroll)
          AnimatedOpacity(
            opacity: showScrolledPill ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !showScrolledPill,
              child: scrolledPill,
            ),
          ),
        ],
      ),
    );
  }
}

/// ─── TopFadeGradient ────────────────────────────────────────────────────────
/// Strong dark fade from top edge — content disappears under top controls.
class TopFadeGradient extends StatelessWidget {
  final double height;

  const TopFadeGradient({super.key, this.height = 120});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Container(
          height: height,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xCC0B0B10),
                Color(0x660B0B10),
                Color(0x000B0B10),
              ],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}

/// ─── EdgeGradient ───────────────────────────────────────────────────────────
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
              Color(0xFF0B0B10),
              Color(0x000B0B10),
            ],
          ),
        ),
      ),
    );
  }
}
