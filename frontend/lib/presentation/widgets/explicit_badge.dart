import 'package:flutter/material.dart';

/// Filled "E" badge for explicit content.
///
/// Solid background with contrasting letter — matches Spotify/Apple Music.
/// Adapts to the current foreground context.
class ExplicitBadge extends StatelessWidget {
  /// Foreground color context. Badge background adapts to this.
  final Color foregroundColor;
  /// Optional size scaling factor (default 1.0).
  final double scale;

  const ExplicitBadge({
    super.key,
    this.foregroundColor = Colors.white,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    final size = 16.0 * scale;
    final fontSize = 10.0 * scale;
    // Filled: badge background is the foreground color at reduced opacity,
    // letter is the opposite contrast (dark on light, light on dark).
    final bgColor = foregroundColor.withOpacity(0.5);
    final letterColor = foregroundColor.computeLuminance() > 0.5
        ? Colors.black.withOpacity(0.85)
        : Colors.white.withOpacity(0.95);

    return Container(
      width: size,
      height: size,
      margin: EdgeInsets.only(right: 4.0 * scale),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(2.5 * scale),
      ),
      alignment: Alignment.center,
      child: Text(
        'E',
        style: TextStyle(
          color: letterColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.1,
          letterSpacing: 0,
        ),
      ),
    );
  }
}
