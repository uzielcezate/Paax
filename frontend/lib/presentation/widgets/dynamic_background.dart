import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/utils/dominant_color_service.dart';
import '../state/theme_state.dart';
import '../screens/main_wrapper.dart';

/// Adaptive cinematic ambient background with TWO modes:
///
/// DARK CINEMATIC: Deep atmospheric color, subtle radial ambient glow,
///   imperceptible edge darkening. For dark album covers.
///
/// LIGHT CINEMATIC: Preserved brightness with subtle cinematic contrast,
///   very soft vignette, gentle depth. For light/bright covers.
///
/// The background color is extracted from the BOTTOM REGION of the artwork
/// (where the visual fade begins), then processed through the adaptive
/// cinematic system.
class DynamicBackground extends StatefulWidget {
  final String? imageUrl;
  final ValueChanged<Color>? onColorExtracted;
  /// When true, prefers colorful alternatives over pure black for dark artwork.
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

class _DynamicBackgroundState extends State<DynamicBackground> with RouteAware {
  CinematicColor _cinematic = CinematicColor.fallback;
  RouteObserver<ModalRoute<dynamic>>? _observer;

  /// Monotonically increasing version to prevent stale async overwrites.
  /// When a new extraction starts, we increment this. When the result arrives,
  /// we only apply it if the version still matches (i.e. no newer request came in).
  int _extractionVersion = 0;

  @override
  void initState() {
    super.initState();
    _extractColor();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is ModalRoute) {
      _observer = MainWrapper.activeObserver;
      _observer!.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    _observer?.unsubscribe(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(DynamicBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) _extractColor();
  }

  @override
  void didPopNext() {
    _reapplyColor();
  }

  @override
  void didPush() {}

  Future<void> _extractColor() async {
    final version = ++_extractionVersion;
    final service = DominantColorService.instance;

    // Check cinematic cache first — apply instantly
    final cached = service.getCachedCinematic(widget.imageUrl);
    if (cached != null) {
      _apply(cached, version);
      return;
    }

    final result = await service.extractCinematic(
      widget.imageUrl,
      excludeBlack: widget.excludeBlack,
    );

    // Only apply if this is still the latest extraction request
    if (version == _extractionVersion) {
      _apply(result, version);
    }
  }

  void _apply(CinematicColor result, int version) {
    if (!mounted) return;
    if (version != _extractionVersion) return; // Stale result — discard
    _cinematic = result;
    setState(() {});
    // Update ThemeState FIRST so screens reading foregroundColor
    // in onColorExtracted get the correct contrast value.
    context.read<ThemeState>().updateColors(result.background, result.foreground);
    widget.onColorExtracted?.call(result.background);
  }

  void _reapplyColor() {
    if (!mounted) return;
    if (_cinematic == CinematicColor.fallback) return;
    context.read<ThemeState>().updateColors(_cinematic.background, _cinematic.foreground);
  }

  @override
  Widget build(BuildContext context) {
    final bg = _cinematic.background;
    final isLight = _cinematic.isLightMode;

    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Layer 1: Solid cinematic color fill
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              color: bg,
            ),

            // Layer 2: Ultra-subtle ambient glow — nearly invisible
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.3),
                    radius: 1.0,
                    colors: isLight
                        ? [
                            // Light mode: barely perceptible warm center
                            Colors.white.withValues(alpha: 0.02),
                            Colors.black.withValues(alpha: 0.015),
                          ]
                        : [
                            // Dark mode: minimal atmospheric darkening at edges
                            bg.withValues(alpha: 0.0),
                            Colors.black.withValues(alpha: 0.06),
                          ],
                    stops: const [0.3, 1.0],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
