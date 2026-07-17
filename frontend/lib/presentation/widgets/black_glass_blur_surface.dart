import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Scrolled top-bar surface — solid dark, no blur.
class BlackGlassBlurSurface extends StatelessWidget {
  final Widget child;
  final double blurSigma; // Ignored — no blur
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
    final borderColor = Colors.white.withOpacity(0.08);

    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: topBorder
              ? BorderSide(color: borderColor, width: 0.5)
              : BorderSide.none,
          bottom: bottomBorder
              ? BorderSide(color: borderColor, width: 0.5)
              : BorderSide.none,
        ),
      ),
      child: child,
    );
  }
}
