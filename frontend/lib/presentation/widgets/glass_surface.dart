import 'dart:ui';
import 'package:flutter/material.dart';

/// ─── Glass Design Tokens ────────────────────────────────────────────────────
class GlassTokens {
  GlassTokens._();

  // Strong blur for true frosted-glass look
  static const double blurSigma = 22.0;

  // Very subtle white tint — clear frosted glass over pure black
  static Color fill = Colors.white.withOpacity(0.045);
  // Thinner, more subtle bubble border
  static Color border = Colors.white.withOpacity(0.08);
  static const double borderWidth = 0.4;
  static Color fillLight = Colors.white.withOpacity(0.025);

  // Subtle floating shadow — creates iOS-style depth
  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.35),
      blurRadius: 20,
      spreadRadius: -2,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.15),
      blurRadius: 8,
      offset: const Offset(0, 2),
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
            ? Border.all(color: GlassTokens.border, width: GlassTokens.borderWidth)
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

/// ─── GlassChip ──────────────────────────────────────────────────────────────
/// A filter chip with real BackdropFilter blur when unselected, and solid
/// white fill when selected. Used by Search and Discography screens.
class GlassChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    // Unselected — real frosted glass with blur
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.045),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withOpacity(0.08),
                width: GlassTokens.borderWidth,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
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
    this.iconSize = 18,
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
        showShadow: true,
        enableBlur: enableBlur,
        child: Center(
          child: Icon(icon, size: iconSize, color: iconColor),
        ),
      ),
    );
  }
}

/// ─── GlassMenuButton ────────────────────────────────────────────────────────
/// The child widget (typically an OverflowMenu) is constrained and centered
/// with padding so the icon never touches the circle edge.
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
      showShadow: true,
      enableBlur: enableBlur,
      padding: const EdgeInsets.all(1),
      child: Center(
        child: SizedBox(
          width: size - 2,
          height: size - 2,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// ─── ScrolledTopPill ────────────────────────────────────────────────────────
/// Floating pill for the scrolled state: [back | title | trailing].
/// Single BackdropFilter — no double blur.
/// Height = 46px. Internal back button occupies left 42px (4px pill padding
/// + 38px hit area) matching the exact left position of the default
/// GlassCircleButton (which is also 38px wide, left-aligned in the same
/// 46px-high Positioned container).
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
            SizedBox(
              width: 38,
              height: 46,
              child: Center(
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(child: trailing!),
                ),
              ),
            )
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
///
/// Both states render inside a fixed 46px height container.
/// The defaultControls are padded with 4px horizontal to match the
/// ScrolledTopPill's internal padding — so circle icons sit at exactly
/// the same x-position as the pill's back/trailing buttons.
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
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Default circles (fade out on scroll)
          AnimatedOpacity(
            opacity: showScrolledPill ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: showScrolledPill,
              child: Padding(
                // Match ScrolledTopPill's internal horizontal: 4 padding
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  height: 46,
                  child: defaultControls,
                ),
              ),
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
/// Deep dark fade from top edge — content disappears under top controls.
/// Uses pure black base to match #000000 background.
class TopFadeGradient extends StatelessWidget {
  final double height;

  const TopFadeGradient({super.key, this.height = 130});

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
                Color(0xF0000000), // Very dark at top
                Color(0xAA000000),
                Color(0x44000000),
                Color(0x00000000),
              ],
              stops: [0.0, 0.3, 0.6, 1.0],
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
              Color(0xFF000000),
              Color(0x00000000),
            ],
          ),
        ),
      ),
    );
  }
}
