import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Singleton service that extracts and caches the dominant color from
/// network artwork images.  Preserves pastel / light colors faithfully.
class DominantColorService {
  DominantColorService._();
  static final instance = DominantColorService._();

  final Map<String, Color> _cache = {};
  final Map<String, Completer<Color>> _pending = {};
  static const Color fallback = Color(0xFF000000);

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

    if (palette.colors.isEmpty) return fallback;

    // Calculate population-weighted average luminance
    int totalPop = 0;
    double weightedLuminance = 0;
    for (var pc in palette.paletteColors) {
      totalPop += pc.population;
      weightedLuminance += pc.color.computeLuminance() * pc.population;
    }
    final avgLuminance = totalPop > 0 ? weightedLuminance / totalPop : 1.0;

    // If the image is overwhelmingly dark, force the background to be dark
    // This fixes the "Black Panther" / "111XPANTIA" parental advisory label bug
    if (avgLuminance < 0.15) {
      return palette.darkMutedColor?.color ?? palette.darkVibrantColor?.color ?? fallback;
    }

    final dominant = palette.dominantColor;
    
    // If the dominant color is very bright but the overall image is not that bright,
    // or if the dominant color is just a tiny high-contrast cluster, prefer something more muted.
    if (dominant != null && dominant.color.computeLuminance() > 0.6 && dominant.population < totalPop * 0.2 && avgLuminance < 0.4) {
       return palette.darkMutedColor?.color ?? palette.darkVibrantColor?.color ?? palette.mutedColor?.color ?? dominant.color;
    }

    // Prefer dominant, then try lighter/pastel-friendly fallbacks
    final raw = dominant?.color
        ?? palette.lightMutedColor?.color
        ?? palette.vibrantColor?.color
        ?? palette.mutedColor?.color
        ?? palette.darkVibrantColor?.color
        ?? fallback;

    return raw;
  }
}
