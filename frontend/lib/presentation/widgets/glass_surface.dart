import 'dart:ui';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'paax_glass_container.dart';

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
    // On mobile with blur enabled, use liquid glass
    if (enableBlur && !kIsWeb) {
      return PaaxGlassContainer(
        width: width,
        height: height,
        borderRadius: borderRadius.resolve(TextDirection.ltr).topLeft.x,
        showShadow: showShadow,
        showBorder: showBorder,
        padding: padding,
        overrideFill: overrideFill,
        child: child,
      );
    }

    // Web fallback or blur disabled
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selectedColor ?? Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: textColor ?? Colors.black,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    // Unselected — liquid glass on mobile, BackdropFilter on web
    return GestureDetector(
      onTap: onTap,
      child: PaaxGlassContainer(
        borderRadius: 20,
        showShadow: false,
        showBorder: true,
        overrideFill: unselectedColor ?? const Color(0x0BFFFFFF),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          label,
          style: TextStyle(
            color: textColor ?? Colors.white.withValues(alpha: 0.8),
            fontSize: 13,
            fontWeight: FontWeight.w500,
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
    this.size = 46,
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
/// The child widget (typically an OverflowMenu) is constrained and centered
/// with padding so the icon never touches the circle edge.
class GlassMenuButton extends StatelessWidget {
  final Widget child;
  final double size;
  final bool enableBlur;

  const GlassMenuButton({
    super.key,
    required this.child,
    this.size = 46,
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
      height: 46,
      showShadow: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          GestureDetector(
            onTap: onBack,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 38,
              height: 46,
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
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
          if (trailing != null)
            SizedBox(
              width: 42,
              height: 46,
              child: Center(child: IconTheme.merge(
                data: IconThemeData(color: foregroundColor),
                child: trailing!,
              )),
            )
          else
            const SizedBox(width: 42),
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
      child: AnimatedCrossFade(
        duration: const Duration(milliseconds: 70),
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
                child: bottomChild,
              ),
              Positioned(
                key: topKey,
                top: 0,
                bottom: 0,
                left: 0,
                right: 0,
                child: topChild,
              ),
            ],
          );
        },
        firstChild: SizedBox(
          height: 46,
          child: defaultControls,
        ),
        secondChild: SizedBox(
          height: 46,
          child: scrolledPill,
        ),
      ),
    );
  }
}

/// ─── DynamicEdgeFade ────────────────────────────────────────────────────────
/// Unified edge-fade overlay for ALL screens.
///
/// **Static screens** (Home, Search, Profile, Library):
///   `DynamicEdgeFade.black()`  — classic black fade, full intensity.
///
/// **Dynamic detail screens** (Artist, Album, Playlist, Discography, Genre):
///   `DynamicEdgeFade.dynamic(color: dominantColor, contentId: '...')`
///   — uses the screen's dominant color at 75 % intensity / 75 % height.
///
/// Always wrap with a [ValueKey] based on the content (artistId, albumId, etc.)
/// so Flutter discards the old widget when navigating between detail pages.
class DynamicEdgeFade extends StatelessWidget {
  final Color color;
  final double height;
  final double maxOpacity;
  final bool fromTop;

  // ── Factory: black fade for static screens ──
  const DynamicEdgeFade.black({
    super.key,
    this.height = 130,
    this.fromTop = true,
  })  : color = const Color(0xFF000000),
        maxOpacity = 0.95;

  // ── Factory: dynamic color fade for detail screens ──
  // 75 % height (130 → 97) and 75 % opacity (0.95 → 0.71)
  const DynamicEdgeFade.dynamic({
    super.key,
    required this.color,
    this.height = 97,
    this.maxOpacity = 0.71,
    this.fromTop = true,
  });

  // ── Factory: dynamic bottom fade — stronger to dissolve content ──
  // behind mini player and bottom nav. Goes nearly opaque at the edge.
  const DynamicEdgeFade.dynamicBottom({
    super.key,
    required this.color,
    this.height = 200,
    this.maxOpacity = 0.98,
  }) : fromTop = false;

  // ── Fully custom ──
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

    // Bottom fades use a stronger 5-stop gradient that ramps hard
    // in the lower portion to dissolve content behind mini player/nav.
    final List<Color> colors;
    final List<double> stops;

    if (!fromTop) {
      colors = [
        color.withOpacity(maxOpacity),
        color.withOpacity(maxOpacity * 0.85),
        color.withOpacity(maxOpacity * 0.45),
        color.withOpacity(maxOpacity * 0.12),
        Colors.transparent,
      ];
      stops = const [0.0, 0.25, 0.55, 0.80, 1.0];
    } else {
      colors = [
        color.withOpacity(maxOpacity),
        color.withOpacity(maxOpacity * 0.58),
        color.withOpacity(maxOpacity * 0.21),
        Colors.transparent,
      ];
      stops = const [0.0, 0.3, 0.6, 1.0];
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
/// Kept for backward compatibility with Search and other inline usages.
class TopFadeGradient extends StatelessWidget {
  final double height;
  final Color color;

  const TopFadeGradient({super.key, this.height = 130, this.color = const Color(0xFF000000)});

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
      color: const Color(0xFF000000),
      height: height,
      fromTop: fromTop,
    );
  }
}
