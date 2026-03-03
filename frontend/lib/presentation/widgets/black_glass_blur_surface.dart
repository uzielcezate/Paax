import 'dart:ui';
import 'package:flutter/material.dart';

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
    this.blurSigma = 18.0,
    this.topBorder = false,
    this.bottomBorder = false,
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Background glass blur (must blur content behind app bar)
        IgnorePointer(
          ignoring: true,
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: Container(
                height: height,
                width: width,
                // dark black overlay
                color: Colors.black.withOpacity(0.50),
              ),
            ),
          ),
        ),

        // subtle top->bottom gradient
        IgnorePointer(
          ignoring: true,
          child: Container(
            height: height,
            width: width,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.60),
                  Colors.black.withOpacity(0.40),
                ],
              ),
            ),
          ),
        ),

        // Borders
        if (topBorder)
          IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.topCenter,
              child: Container(
                height: 1,
                width: width,
                color: Colors.white.withOpacity(0.06),
              ),
            ),
          ),
          
        if (bottomBorder)
          IgnorePointer(
            ignoring: true,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                height: 1,
                width: width,
                color: Colors.white.withOpacity(0.06),
              ),
            ),
          ),
          
        // Content
        SizedBox(
          height: height,
          width: width,
          child: child,
        ),
      ],
    );
  }
}
