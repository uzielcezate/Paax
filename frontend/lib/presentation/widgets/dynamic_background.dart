import 'package:flutter/material.dart';
import '../../core/utils/dominant_color_service.dart';

/// A full-screen animated gradient background that adapts to the dominant
/// color of an artwork image. Used as the first child in detail screen
/// Stacks to create an ambient, mood-matched backdrop.
///
/// • Starts as pure black immediately (no flash)
/// • Extracts color asynchronously via [DominantColorService]
/// • Animates smoothly (300ms) when the color resolves or changes
/// • If [imageUrl] is null/empty, stays pure black
class DynamicBackground extends StatefulWidget {
  final String? imageUrl;

  const DynamicBackground({
    super.key,
    required this.imageUrl,
  });

  @override
  State<DynamicBackground> createState() => _DynamicBackgroundState();
}

class _DynamicBackgroundState extends State<DynamicBackground> {
  Color _dominantColor = const Color(0xFF000000);

  @override
  void initState() {
    super.initState();
    _extractColor();
  }

  @override
  void didUpdateWidget(DynamicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _extractColor();
    }
  }

  Future<void> _extractColor() async {
    // Immediately show cached color if available (no flicker)
    final cached = DominantColorService.instance.getCachedColor(widget.imageUrl);
    if (cached != const Color(0xFF000000) && mounted) {
      setState(() => _dominantColor = cached);
      return;
    }

    final color = await DominantColorService.instance.extractColor(widget.imageUrl);
    if (mounted) {
      setState(() => _dominantColor = color);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Build a 3-stop gradient: dominant (top) → darkened (mid) → black (bottom)
    final hsl = HSLColor.fromColor(_dominantColor);
    final darker = hsl.withLightness((hsl.lightness * 0.5).clamp(0.02, 0.12)).toColor();

    return Positioned.fill(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _dominantColor.withOpacity(0.45), // Dominant tint at top
              darker.withOpacity(0.65),          // Darkened mid
              const Color(0xFF000000),            // Pure black bottom
            ],
            stops: const [0.0, 0.4, 0.75],
          ),
        ),
      ),
    );
  }
}
