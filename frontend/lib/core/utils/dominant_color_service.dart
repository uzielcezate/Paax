import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Singleton service that extracts and caches the dominant color from
/// network artwork images.
class DominantColorService {
  DominantColorService._();
  static final instance = DominantColorService._();

  final Map<String, Color> _cache = {};
  final Map<String, Completer<Color>> _pending = {};
  static const Color fallback = Color(0xFF000000);
  static const double _maxLightness = 0.50;
  static const double _maxSaturation = 0.75;

  /// Returns appropriate foreground color (black or white) for [bg].
  static Color foregroundOn(Color bg) {
    return bg.computeLuminance() > 0.35
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
  }

  /// Whether [color] is considered "light" for UI purposes.
  static bool isLight(Color color) => color.computeLuminance() > 0.35;

  Color getCachedColor(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return fallback;
    return _cache[imageUrl] ?? fallback;
  }

  Future<Color> extractColor(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return fallback;
    if (_cache.containsKey(imageUrl)) return _cache[imageUrl]!;
    if (_pending.containsKey(imageUrl)) return _pending[imageUrl]!.future;

    final completer = Completer<Color>();
    _pending[imageUrl] = completer;
    try {
      final color = await _extract(imageUrl);
      _cache[imageUrl] = color;
      completer.complete(color);
    } catch (e) {
      debugPrint('[DominantColor] Extraction failed: $e');
      _cache[imageUrl] = fallback;
      completer.complete(fallback);
    } finally {
      _pending.remove(imageUrl);
    }
    return completer.future;
  }

  Future<Color> _extract(String imageUrl) async {
    final imageProvider = ResizeImage(NetworkImage(imageUrl), width: 80, height: 80);
    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const ui.Size(80, 80),
      maximumColorCount: 16,
    ).timeout(const Duration(seconds: 5));

    final raw = palette.dominantColor?.color
        ?? palette.vibrantColor?.color
        ?? palette.darkVibrantColor?.color
        ?? palette.mutedColor?.color
        ?? fallback;
    return _processForUI(raw);
  }

  Color _processForUI(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness(hsl.lightness.clamp(0.08, _maxLightness))
        .withSaturation(hsl.saturation.clamp(0.0, _maxSaturation))
        .toColor();
  }
}
