import 'dart:ui';
import 'package:flutter/material.dart';
import 'glass_surface.dart';

/// Scrolled top-bar glass surface used across detail screens.
///
/// Historically black-tinted; now uses the shared white glass system
/// for consistency with the Phase 4 bubble UI.
class BlackGlassBlurSurface extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final bool topBorder;
  final bool bottomBorder;
  final double? height;
  final double? width;

  const BlackGlassBlurSurface({
    super.key,
    required this.child,
    this.blurSigma = 14.0,
    this.topBorder = false,
    this.bottomBorder = false,
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          height: height,
          width: width,
          decoration: BoxDecoration(
            color: GlassTokens.fillLight,
            border: Border(
              top: topBorder
                  ? BorderSide(color: GlassTokens.border, width: 0.5)
                  : BorderSide.none,
              bottom: bottomBorder
                  ? BorderSide(color: GlassTokens.border, width: 0.5)
                  : BorderSide.none,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
