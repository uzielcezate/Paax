import 'package:flutter/material.dart';
import '../../core/utils/dominant_color_service.dart';

/// Full-screen SOLID COLOR background that matches artwork's dominant color.
/// No gradients, no darkening — one flat color that the hero image fades into.
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
    return Positioned.fill(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        color: _dominantColor,  // ONE solid color. No gradient.
      ),
    );
  }
}
