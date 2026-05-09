import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/utils/dominant_color_service.dart';
import '../state/theme_state.dart';

/// Full-screen SOLID COLOR background that matches artwork's dominant color.
/// No gradients, no darkening — one flat color that the hero image fades into.
class DynamicBackground extends StatefulWidget {
  final String? imageUrl;
  final ValueChanged<Color>? onColorExtracted;
  /// When true, prefers colorful alternatives over pure black for dark artwork.
  /// Used by album and playlist screens.
  final bool excludeBlack;

  const DynamicBackground({
    super.key,
    required this.imageUrl,
    this.onColorExtracted,
    this.excludeBlack = false,
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
    final service = DominantColorService.instance;
    final cached = service.getCachedColor(widget.imageUrl);
    if (cached != DominantColorService.fallback) {
      _apply(cached);
      return;
    }
    final color = widget.excludeBlack
        ? await service.extractColorExcludeBlack(widget.imageUrl)
        : await service.extractColor(widget.imageUrl);
    _apply(color);
  }

  void _apply(Color color) {
    if (!mounted) return;
    setState(() => _dominantColor = color);
    widget.onColorExtracted?.call(color);
    
    // Globally update the theme state for mini player and bottom nav
    final fgColor = DominantColorService.foregroundOn(color);
    context.read<ThemeState>().updateColors(color, fgColor);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        curve: Curves.easeOut,
        color: _dominantColor,  // ONE solid color. No gradient.
      ),
    );
  }
}

