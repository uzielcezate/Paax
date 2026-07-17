import 'package:flutter/material.dart';
import 'glass_surface.dart';

/// ─── PaaxGlassContainer ─────────────────────────────────────────────────────
/// Thin wrapper that delegates to [BeatyGlassSurface].
///
/// Previously used `oc_liquid_glass` — now uses the Beaty Glass design system.
/// Kept for backward compatibility with `GlassSurface` and `GlassChip`.
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
    return BeatyGlassSurface(
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(borderRadius),
      showShadow: showShadow,
      showBorder: showBorder,
      enableBlur: true,
      padding: padding,
      overrideFill: overrideFill,
      child: child,
    );
  }
}
