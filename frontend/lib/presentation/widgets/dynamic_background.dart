import 'package:flutter/material.dart';
import '../../core/utils/dominant_color_service.dart';

/// Full-screen animated gradient that adapts to artwork's dominant color.
/// Apple Music-style: the ENTIRE screen stays within the artwork's color
/// family — no black fades anywhere.
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

    // Apple Music-style: entire gradient stays in the same hue family.
    // No black at all — just progressively darker/desaturated tints.
    final top = _dominantColor;

    // Mid: darker version, slightly desaturated — readable over
    final mid = hsl
        .withLightness((hsl.lightness * 0.55).clamp(0.06, 0.22))
        .withSaturation((hsl.saturation * 0.8).clamp(0.0, 0.55))
        .toColor();

    // Bottom: very dark tinted version — still colored, never pure black
    final bottom = hsl
        .withLightness((hsl.lightness * 0.25).clamp(0.03, 0.10))
        .withSaturation((hsl.saturation * 0.6).clamp(0.0, 0.40))
        .toColor();

    return Positioned.fill(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, top, mid, bottom],
            stops: const [0.0, 0.25, 0.55, 1.0],
          ),
        ),
      ),
    );
  }
}
