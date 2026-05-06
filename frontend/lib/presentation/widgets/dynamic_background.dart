import 'package:flutter/material.dart';
import '../../core/utils/dominant_color_service.dart';

/// Full-screen animated gradient that adapts to artwork's dominant color.
/// Provides [onColorExtracted] callback so parent screens can adapt
/// text/icon contrast.
class DynamicBackground extends StatefulWidget {
  final String? imageUrl;
  final ValueChanged<Color>? onColorExtracted;

  const DynamicBackground({
    super.key,
    required this.imageUrl,
    this.onColorExtracted,
  });

  @override
  State<DynamicBackground> createState() => _DynamicBackgroundState();
}

class _DynamicBackgroundState extends State<DynamicBackground> {
  Color _dominantColor = DominantColorService.fallback;

  @override
  void initState() {
    super.initState();
    _extractColor();
  }

  @override
  void didUpdateWidget(DynamicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _extractColor();
  }

  Future<void> _extractColor() async {
    final cached = DominantColorService.instance.getCachedColor(widget.imageUrl);
    if (cached != DominantColorService.fallback) {
      _apply(cached);
      return;
    }
    final color = await DominantColorService.instance.extractColor(widget.imageUrl);
    _apply(color);
  }

  void _apply(Color color) {
    if (!mounted) return;
    setState(() => _dominantColor = color);
    widget.onColorExtracted?.call(color);
  }

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(_dominantColor);

    // Gradient stays in the same hue family — Apple Music style
    final top = _dominantColor;
    final mid = hsl
        .withLightness((hsl.lightness * 0.4).clamp(0.03, 0.15))
        .toColor();
    final bottom = hsl
        .withLightness(0.03)
        .withSaturation((hsl.saturation * 0.4).clamp(0.0, 0.25))
        .toColor();

    return Positioned.fill(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, mid, bottom],
            stops: const [0.0, 0.45, 0.85],
          ),
        ),
      ),
    );
  }
}
