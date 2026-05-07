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

  // ── Shared Contrast Helpers ──────────────────────────────────────────

  /// Returns appropriate foreground color (black or white) for [bg].
  static Color foregroundOn(Color bg) {
    return bg.computeLuminance() > 0.35
        ? const Color(0xFF000000)
        : const Color(0xFFFFFFFF);
  }

  /// Whether [color] is considered "light" for UI purposes.
  static bool isLight(Color color) => color.computeLuminance() > 0.35;

  /// Muted foreground — for subtitles, secondary text.
  static Color mutedForeground(Color bg) {
    return foregroundOn(bg).withOpacity(0.7);
  }

  /// Icon color — same as foreground.
  static Color iconColor(Color bg) => foregroundOn(bg);

  /// Solid fill for selected chips/buttons: black on light, white on dark.
  static Color adaptiveButtonFill(Color bg) {
    return isLight(bg) ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  }

  /// Text inside adaptive button: inverse of button fill.
  static Color adaptiveButtonText(Color bg) {
    return isLight(bg) ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  }

  /// Solid sheet/menu background derived from the current dominant color.
  /// Returns the actual dominant color so menus match the screen's dynamic theme.
  /// For very dark colors, slightly lighten to ensure visibility.
  /// For very light colors, slightly darken for depth.
  static Color adaptiveSheetColor(Color bg) {
    final lum = bg.computeLuminance();
    final hsl = HSLColor.fromColor(bg);
    
    if (lum < 0.03) {
      // Near-black — lift slightly so sheet is distinguishable from pure black
      return hsl.withLightness(0.08).toColor();
    }
    if (lum > 0.85) {
      // Near-white — darken slightly for depth
      return hsl.withLightness(0.88).toColor();
    }
    // Return the color as-is — preserves saturation and hue
    return bg;
  }

  // ── Cache Access ──────────────────────────────────────────────────────

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

  // ── Core Extraction ───────────────────────────────────────────────────

  Future<Color> _extract(String imageUrl, {bool excludeBlack = false}) async {
    final imageProvider = ResizeImage(NetworkImage(imageUrl), width: 80, height: 80);
    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const ui.Size(80, 80),
      maximumColorCount: 16,
    ).timeout(const Duration(seconds: 5));

    if (palette.colors.isEmpty) return fallback;

    // Calculate population-weighted average luminance AND dark pixel ratio
    int totalPop = 0;
    int darkPop = 0;
    double weightedLuminance = 0;
    for (var pc in palette.paletteColors) {
      totalPop += pc.population;
      weightedLuminance += pc.color.computeLuminance() * pc.population;
      if (pc.color.computeLuminance() < 0.12) {
        darkPop += pc.population;
      }
    }
    final avgLuminance = totalPop > 0 ? weightedLuminance / totalPop : 1.0;
    final darkRatio = totalPop > 0 ? darkPop / totalPop : 0.0;

    // ── Dark image detection ──
    if (avgLuminance < 0.15 || darkRatio > 0.50) {
      if (excludeBlack) {
        // For album/playlist: prefer a colorful dark alternative over pure black
        // Try dark vibrant first (e.g. dark red from 111XPANTIA), then dark muted,
        // then any color with some saturation, then vibrant/muted
        final colorful = palette.darkVibrantColor?.color
            ?? palette.darkMutedColor?.color
            ?? palette.vibrantColor?.color
            ?? palette.mutedColor?.color;
        if (colorful != null && colorful.computeLuminance() > 0.02) {
          return colorful;
        }
        // All colors are near-black — try to find anything with saturation
        for (var pc in palette.paletteColors) {
          final hsl = HSLColor.fromColor(pc.color);
          if (hsl.saturation > 0.15 && pc.color.computeLuminance() > 0.03) {
            return pc.color;
          }
        }
        // Truly monochrome black image — use a dark gray so it's not pure black
        return const Color(0xFF1A1A2E);
      }

      // Default: pick most populous dark color (allows pure black)
      final darkColors = palette.paletteColors
          .where((pc) => pc.color.computeLuminance() < 0.20)
          .toList()
        ..sort((a, b) => b.population.compareTo(a.population));

      if (darkColors.isNotEmpty) {
        return darkColors.first.color;
      }
      return palette.darkMutedColor?.color
          ?? palette.darkVibrantColor?.color
          ?? fallback;
    }

    final dominant = palette.dominantColor;

    // If the dominant color is very bright but the overall image is not that
    // bright, or if the dominant is just a tiny high-contrast cluster (like a
    // parental advisory label), prefer something more muted.
    if (dominant != null &&
        dominant.color.computeLuminance() > 0.6 &&
        dominant.population < totalPop * 0.2 &&
        avgLuminance < 0.4) {
      return palette.darkMutedColor?.color
          ?? palette.darkVibrantColor?.color
          ?? palette.mutedColor?.color
          ?? dominant.color;
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

  /// Extract color but exclude pure black — for album and playlist screens.
  /// Prefers colorful alternatives (dark-vibrant, dark-muted) over pure black.
  Future<Color> extractColorExcludeBlack(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return const Color(0xFF1A1A2E);
    // Check cache first
    final cacheKey = '${imageUrl}_noBlack';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;
    if (_pending.containsKey(cacheKey)) return _pending[cacheKey]!.future;

    final completer = Completer<Color>();
    _pending[cacheKey] = completer;
    try {
      final color = await _extract(imageUrl, excludeBlack: true);
      _cache[cacheKey] = color;
      completer.complete(color);
    } catch (e) {
      debugPrint('[DominantColor] Extraction (noBlack) failed: $e');
      _cache[cacheKey] = const Color(0xFF1A1A2E);
      completer.complete(const Color(0xFF1A1A2E));
    } finally {
      _pending.remove(cacheKey);
    }
    return completer.future;
  }
}

