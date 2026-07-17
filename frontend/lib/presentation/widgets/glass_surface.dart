import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// Paax Surface System — Phase 1 (Cinematic Black)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Simple dark surfaces without BackdropFilter.
// All glass widgets now render as solid dark containers with subtle borders.
// No blur, no heavy shaders, no refraction.
// ═══════════════════════════════════════════════════════════════════════════════

/// ─── Design Tokens ──────────────────────────────────────────────────────────
class BeatyGlassTokens {
  BeatyGlassTokens._();

  // Dimensions
  static const double heightCompact = 38.0;
  static const double heightRegular = 44.0;
  static const double radius = 16.0;
  static const double radiusPill = 24.0;

  // Fill
  static const double tintOpacity = 0.32;
  static const double tintOpacityLight = 0.18;

  // Border
  static const double borderOpacity = 0.08;
  static const double borderWidth = 0.5;

  // Shadow
  static const double shadowOpacity = 0.18;

  // Spacing
  static const double hPadding = 14.0;
  static const double vPadding = 8.0;

  // Inner highlight gradient strength
  static const double highlightOpacity = 0.06;
}

/// Legacy alias — some consumers reference `GlassTokens`.
class GlassTokens {
  GlassTokens._();

  static const double blurSigma = 0; // No blur
  static Color fill = AppColors.surface;
  static Color border = Colors.white.withOpacity(BeatyGlassTokens.borderOpacity);
  static const double borderWidth = BeatyGlassTokens.borderWidth;
  static Color fillLight = AppColors.elevatedSurface;

  static List<BoxShadow> softShadow = [
    BoxShadow(
      color: Colors.black.withOpacity(0.10),
      blurRadius: 12,
      spreadRadius: 0,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: Colors.black.withOpacity(0.05),
      blurRadius: 6,
      spreadRadius: -1,
      offset: Offset.zero,
    ),
  ];
}

/// ─── BlurCapability (disabled — always solid) ───────────────────────────────
class BlurCapability {
  static bool? _canBlur;
  static bool forceSolidGlass = true; // Always solid

  static bool canBlur(BuildContext context) => false;
  static void reset() => _canBlur = null;
}

/// ─── BeatyGlassSurface ─────────────────────────────────────────────────────
/// Solid dark surface container. No BackdropFilter.
class BeatyGlassSurface extends StatelessWidget {
  final Widget child;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final bool showBorder;
  final bool showShadow;
  final bool enableBlur; // Ignored — always solid
  final EdgeInsetsGeometry? padding;
  final Color? overrideFill;

  const BeatyGlassSurface({
    super.key,
    required this.child,
    this.width,
    this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(BeatyGlassTokens.radius)),
    this.showBorder = true,
    this.showShadow = true,
    this.enableBlur = true,
    this.padding,
    this.overrideFill,
  });

  @override
  Widget build(BuildContext context) {
    final br = borderRadius;

    final border = showBorder
        ? Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 0.5,
          )
        : null;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: br,
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.10),
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: br,
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: overrideFill ?? AppColors.surface,
            borderRadius: br,
            border: border,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// ─── GlassSurface (API-compatible wrapper) ──────────────────────────────────
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
    return BeatyGlassSurface(
      width: width,
      height: height,
      borderRadius: borderRadius,
      showBorder: showBorder,
      showShadow: showShadow,
      enableBlur: enableBlur,
      padding: padding,
      overrideFill: overrideFill,
      child: child,
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
    this.height = 48,
    this.showShadow = true,
    this.enableBlur = true,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return BeatyGlassSurface(
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
class GlassChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  final Color? selectedColor;
  final Color? unselectedColor;
  final Color? textColor;

  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
    this.unselectedColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selectedColor ?? Colors.white.withOpacity(0.88),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: textColor ?? Colors.black,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: unselectedColor ?? AppColors.elevatedSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: textColor ?? Colors.white.withOpacity(0.8),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
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
    this.size = 40,
    this.iconSize = 18,
    this.iconColor = Colors.white,
    this.enableBlur = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 8,
              offset: const Offset(0, 1),
            ),
          ],
        ),
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
    this.size = 40,
    this.enableBlur = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.surface,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withOpacity(0.08),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 8,
            offset: const Offset(0, 1),
          ),
        ],
      ),
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
class ScrolledTopPill extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final Widget? trailing;
  final Color foregroundColor;

  const ScrolledTopPill({
    super.key,
    required this.title,
    required this.onBack,
    this.trailing,
    this.foregroundColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return GlassPill(
      height: 40,
      showShadow: true,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 34,
              height: 40,
              child: Center(
                child: Icon(Icons.arrow_back_ios_new, size: 18, color: foregroundColor),
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foregroundColor,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          if (trailing != null)
            SizedBox(
              width: 36,
              height: 40,
              child: Center(child: IconTheme.merge(
                data: IconThemeData(color: foregroundColor),
                child: trailing!,
              )),
            )
          else
            const SizedBox(width: 36),
        ],
      ),
    );
  }
}

/// ─── FloatingTopControls ────────────────────────────────────────────────────
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
    const pillRadius = BorderRadius.all(Radius.circular(20));

    return Positioned(
      top: topPadding + 4,
      left: 12,
      right: 12,
      height: 40,
      child: AnimatedCrossFade(
        duration: const Duration(milliseconds: 60),
        firstCurve: Curves.linear,
        secondCurve: Curves.linear,
        crossFadeState: showScrolledPill ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        layoutBuilder: (topChild, topKey, bottomChild, bottomKey) {
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                key: bottomKey,
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: ClipRRect(
                  borderRadius: pillRadius,
                  child: bottomChild,
                ),
              ),
              Positioned(
                key: topKey,
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: ClipRRect(
                  borderRadius: pillRadius,
                  child: topChild,
                ),
              ),
            ],
          );
        },
        firstChild: SizedBox(
          height: 40,
          child: defaultControls,
        ),
        secondChild: SizedBox(
          height: 40,
          child: scrolledPill,
        ),
      ),
    );
  }
}

/// ─── DynamicEdgeFade ────────────────────────────────────────────────────────
/// Unified edge-fade overlay for ALL screens.
/// Default color is now AppColors.background (#121212).
class DynamicEdgeFade extends StatelessWidget {
  final Color color;
  final double height;
  final double maxOpacity;
  final bool fromTop;

  const DynamicEdgeFade.black({
    super.key,
    this.height = 130,
    this.fromTop = true,
  })  : color = const Color(0xFF121212),
        maxOpacity = 0.95;

  const DynamicEdgeFade.dynamic({
    super.key,
    required this.color,
    this.height = 130,
    this.maxOpacity = 0.92,
    this.fromTop = true,
  });

  const DynamicEdgeFade.dynamicBottom({
    super.key,
    required this.color,
    this.height = 240,
    this.maxOpacity = 0.98,
  }) : fromTop = false;

  const DynamicEdgeFade({
    super.key,
    required this.color,
    this.height = 130,
    this.maxOpacity = 0.95,
    this.fromTop = true,
  });

  @override
  Widget build(BuildContext context) {
    final begin = fromTop ? Alignment.topCenter : Alignment.bottomCenter;
    final end   = fromTop ? Alignment.bottomCenter : Alignment.topCenter;

    final List<Color> colors;
    final List<double> stops;

    if (!fromTop) {
      colors = [
        color.withOpacity(maxOpacity),
        color.withOpacity(maxOpacity * 0.90),
        color.withOpacity(maxOpacity * 0.65),
        color.withOpacity(maxOpacity * 0.30),
        color.withOpacity(maxOpacity * 0.08),
        Colors.transparent,
      ];
      stops = const [0.0, 0.20, 0.40, 0.65, 0.85, 1.0];
    } else {
      colors = [
        color.withOpacity(maxOpacity),
        color.withOpacity(maxOpacity * 0.70),
        color.withOpacity(maxOpacity * 0.35),
        color.withOpacity(maxOpacity * 0.10),
        Colors.transparent,
      ];
      stops = const [0.0, 0.25, 0.50, 0.75, 1.0];
    }

    return Positioned(
      top: fromTop ? 0 : null,
      bottom: fromTop ? null : 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Container(
          height: height,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: begin,
              end: end,
              colors: colors,
              stops: stops,
            ),
          ),
        ),
      ),
    );
  }
}

/// ─── TopFadeGradient (deprecated — prefer DynamicEdgeFade) ──────────────────
class TopFadeGradient extends StatelessWidget {
  final double height;
  final Color color;

  const TopFadeGradient({super.key, this.height = 130, this.color = const Color(0xFF121212)});

  @override
  Widget build(BuildContext context) {
    return DynamicEdgeFade(color: color, height: height);
  }
}

/// ─── EdgeGradient (deprecated — prefer DynamicEdgeFade) ─────────────────────
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
    return DynamicEdgeFade(
      color: AppColors.background,
      height: height,
      fromTop: fromTop,
    );
  }
}
