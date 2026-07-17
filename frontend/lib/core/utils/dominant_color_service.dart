import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

// ── Cinematic Result ────────────────────────────────────────────────────────

/// Result of adaptive cinematic processing.
/// Contains the processed background color, foreground contrast, and whether
/// the background is in light or dark cinematic mode.
class CinematicColor {
  final Color background;
  final Color foreground;
  final bool isLightMode;

  const CinematicColor({
    required this.background,
    required this.foreground,
    required this.isLightMode,
  });

  static const fallback = CinematicColor(
    background: Color(0xFF0A0A0F),
    foreground: Color(0xFFFFFFFF),
    isLightMode: false,
  );
}

// ── DominantColorService ────────────────────────────────────────────────────

/// Singleton service that extracts the dominant color from the LOWER REGION
/// of artwork images, then applies adaptive cinematic processing.
///
/// Two cinematic modes:
///   - DARK MODE: deepens, enriches, adds atmospheric depth (dark covers)
///   - LIGHT MODE: preserves brightness with subtle cinematic contrast (light covers)
class DominantColorService {
  DominantColorService._();
  static final instance = DominantColorService._();

  final Map<String, Color> _cache = {};
  final Map<String, Completer<Color>> _pending = {};
  final Map<String, CinematicColor> _cinematicCache = {};
  final Map<String, Completer<CinematicColor>> _cinematicPending = {};
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
  static Color adaptiveSheetColor(Color bg) {
    final lum = bg.computeLuminance();
    final hsl = HSLColor.fromColor(bg);
    if (lum < 0.03) {
      return hsl.withLightness(0.08).toColor();
    }
    if (lum > 0.85) {
      return hsl.withLightness(0.88).toColor();
    }
    return bg;
  }

  // ── Adaptive Cinematic Processing ─────────────────────────────────────

  /// Apply adaptive cinematic treatment to a raw extracted color.
  ///
  /// Detects whether the color calls for LIGHT or DARK cinematic mode
  /// based on luminance, then applies appropriate processing:
  ///
  /// DARK MODE (lum <= 0.45):
  ///   - Deepen and enrich
  ///   - Boost saturation slightly
  ///   - Atmospheric darkness
  ///
  /// LIGHT MODE (lum > 0.45):
  ///   - Preserve overall brightness
  ///   - Very subtle darkening only
  ///   - Slight saturation boost for richness
  ///   - Keep the mood light and airy
  static CinematicColor cinematic(Color color) {
    final hsl = HSLColor.fromColor(color);
    final lum = color.computeLuminance();

    // Light cinematic threshold
    if (lum > 0.45) {
      return _lightCinematic(hsl, lum);
    } else {
      return _darkCinematic(hsl, lum);
    }
  }

  /// LIGHT CINEMATIC MODE
  /// Preserves brightness with subtle cinematic depth.
  /// Lust For Life → soft silver/white
  /// The Life of Pablo → warm beige/cream
  /// Cloud 9 → soft pastel pink
  static CinematicColor _lightCinematic(HSLColor hsl, double lum) {
    double sat = hsl.saturation;
    double light = hsl.lightness;

    // Slight saturation boost for richness — not too much
    sat = (sat * 1.15 + 0.03).clamp(0.05, 0.50);

    // Very subtle darkening — just enough for cinematic feel
    // High luminance → barely touch it. Lower luminance → slightly more.
    if (lum > 0.72) {
      // Very bright: subtle darkening
      light = (light * 0.88).clamp(0.65, 0.88);
    } else {
      // Medium-light: slightly more cinematic depth
      light = (light * 0.82).clamp(0.45, 0.75);
    }

    final bg = hsl.withSaturation(sat).withLightness(light).toColor();
    return CinematicColor(
      background: bg,
      foreground: const Color(0xFF000000), // Light bg → black text
      isLightMode: true,
    );
  }

  /// DARK CINEMATIC MODE
  /// Deepens and enriches for atmospheric immersion.
  /// att. → deep dark
  /// SOS → deep navy
  /// EL ÚLTIMO TOUR DEL MUNDO → rich dark
  static CinematicColor _darkCinematic(HSLColor hsl, double lum) {
    double sat = hsl.saturation;
    double light = hsl.lightness;

    if (lum < 0.01) {
      // True black / near-black — keep it black, minimal touch
      // This is valid for dark artwork like att., Yeezus, etc.
      sat = (sat + 0.05).clamp(0.0, 0.30);
      light = light.clamp(0.03, 0.08);
    } else if (lum < 0.05) {
      // Very dark: preserve darkness, subtle enrichment
      sat = (sat * 1.1).clamp(0.05, 0.50);
      light = light.clamp(0.05, 0.14);
    } else if (lum < 0.10) {
      // Dark: enrich slightly
      sat = (sat * 1.15).clamp(0.10, 0.60);
      light = light.clamp(0.06, 0.16);
    } else {
      // Medium-dark: deepen moderately, boost saturation
      sat = (sat * 1.1 + 0.05).clamp(0.15, 0.65);
      light = (light * 0.65).clamp(0.08, 0.22);
    }

    final bg = hsl.withSaturation(sat).withLightness(light).toColor();
    return CinematicColor(
      background: bg,
      foreground: const Color(0xFFFFFFFF), // Dark bg → white text
      isLightMode: false,
    );
  }

  // ── Cache Access ──────────────────────────────────────────────────────

  Color getCachedColor(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return fallback;
    return _cache[imageUrl] ?? fallback;
  }

  CinematicColor? getCachedCinematic(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return null;
    return _cinematicCache[imageUrl];
  }

  // ── Cinematic Extraction (primary API) ────────────────────────────────

  /// Extract from the LOWER REGION of the artwork and apply cinematic processing.
  /// This is the primary API for DynamicBackground.
  Future<CinematicColor> extractCinematic(String? imageUrl, {bool excludeBlack = false}) async {
    if (imageUrl == null || imageUrl.isEmpty) return CinematicColor.fallback;
    final cacheKey = '${imageUrl}_cine${excludeBlack ? '_nb' : ''}';
    if (_cinematicCache.containsKey(cacheKey)) return _cinematicCache[cacheKey]!;
    if (_cinematicPending.containsKey(cacheKey)) return _cinematicPending[cacheKey]!.future;

    final completer = Completer<CinematicColor>();
    _cinematicPending[cacheKey] = completer;
    try {
      final rawColor = await _extractBottomRegion(imageUrl, excludeBlack: excludeBlack);
      final result = cinematic(rawColor);
      _cinematicCache[cacheKey] = result;
      _cache[imageUrl] = result.background; // Also populate legacy cache
      completer.complete(result);
    } catch (e) {
      debugPrint('[DominantColor] Cinematic extraction failed: $e');
      _cinematicCache[cacheKey] = CinematicColor.fallback;
      completer.complete(CinematicColor.fallback);
    } finally {
      _cinematicPending.remove(cacheKey);
    }
    return completer.future;
  }

  // ── Hybrid Extraction (bottom-region + global accent fallback) ──────────

  /// Extract from the LOWER REGION of the artwork, with intelligent fallback
  /// to global accent when the bottom region lacks emotional identity.
  ///
  /// Albums like YHLQMDLG have dark/muddy bottom regions but vibrant overall
  /// color identity — this hybrid approach rescues those cases.
  Future<Color> _extractBottomRegion(String imageUrl, {bool excludeBlack = false}) async {
    final imageProvider = ResizeImage(NetworkImage(imageUrl), width: 100, height: 100);

    // Sample bottom 30% of the image — this is where the artwork fades into background
    const bottomRegion = Rect.fromLTRB(0, 70, 100, 100);

    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const ui.Size(100, 100),
      region: bottomRegion,
      maximumColorCount: 16,
    ).timeout(const Duration(seconds: 5));

    if (palette.colors.isEmpty) return fallback;

    final bottomColor = _pickBestColor(palette, excludeBlack: excludeBlack);

    // ── Quality gate: does the bottom color have emotional identity? ──
    final bottomHSL = HSLColor.fromColor(bottomColor);
    final bottomLum = bottomColor.computeLuminance();
    final isEmotionallyFlat = bottomHSL.saturation < 0.12 && bottomLum < 0.08;

    if (isEmotionallyFlat) {
      // Bottom is too dark/desaturated — blend with global accent
      final globalAccent = await _extractGlobalAccent(imageUrl, excludeBlack: excludeBlack);
      if (globalAccent != null) {
        final globalHSL = HSLColor.fromColor(globalAccent);
        // Only blend if global accent actually has color identity
        if (globalHSL.saturation > 0.15 || globalAccent.computeLuminance() > 0.10) {
          return _blendColors(bottomColor, globalAccent, globalWeight: 0.6);
        }
      }
    }

    return bottomColor;
  }

  /// Extract a global accent color from the FULL image.
  /// Prioritizes vibrant/muted swatches that carry emotional identity.
  Future<Color?> _extractGlobalAccent(String imageUrl, {bool excludeBlack = false}) async {
    try {
      final imageProvider = ResizeImage(NetworkImage(imageUrl), width: 80, height: 80);
      final palette = await PaletteGenerator.fromImageProvider(
        imageProvider,
        size: const ui.Size(80, 80),
        maximumColorCount: 20,
      ).timeout(const Duration(seconds: 4));

      if (palette.colors.isEmpty) return null;

      // Prefer vibrant/muted accents that carry the artwork's emotional identity
      final accent = palette.vibrantColor?.color
          ?? palette.mutedColor?.color
          ?? palette.darkVibrantColor?.color
          ?? palette.lightVibrantColor?.color
          ?? palette.darkMutedColor?.color;

      if (accent != null && accent.computeLuminance() > 0.02) {
        return accent;
      }

      // Fallback: find the most saturated non-black color
      for (var pc in palette.paletteColors) {
        final hsl = HSLColor.fromColor(pc.color);
        if (hsl.saturation > 0.20 && pc.color.computeLuminance() > 0.03) {
          return pc.color;
        }
      }

      return null;
    } catch (e) {
      debugPrint('[DominantColor] Global accent extraction failed: $e');
      return null;
    }
  }

  /// Blend two colors in HSL space with weighted interpolation.
  Color _blendColors(Color a, Color b, {double globalWeight = 0.5}) {
    final hslA = HSLColor.fromColor(a);
    final hslB = HSLColor.fromColor(b);
    final localWeight = 1.0 - globalWeight;

    // For hue, use circular interpolation to avoid wrapping artifacts
    double blendedHue;
    final hueDiff = (hslB.hue - hslA.hue).abs();
    if (hueDiff > 180) {
      // Wrap around
      final adjustedA = hslA.hue < hslB.hue ? hslA.hue + 360 : hslA.hue;
      final adjustedB = hslB.hue < hslA.hue ? hslB.hue + 360 : hslB.hue;
      blendedHue = (adjustedA * localWeight + adjustedB * globalWeight) % 360;
    } else {
      blendedHue = hslA.hue * localWeight + hslB.hue * globalWeight;
    }

    final blendedSat = (hslA.saturation * localWeight + hslB.saturation * globalWeight)
        .clamp(0.0, 1.0);
    final blendedLight = (hslA.lightness * localWeight + hslB.lightness * globalWeight)
        .clamp(0.0, 1.0);

    return HSLColor.fromAHSL(1.0, blendedHue, blendedSat, blendedLight).toColor();
  }

  /// Pick the best color from a palette, optionally excluding near-black.
  Color _pickBestColor(PaletteGenerator palette, {bool excludeBlack = false}) {
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
        // Try to find a colorful alternative, but if the artwork is
        // genuinely black, accept it — don't force a random color.
        final colorful = palette.darkVibrantColor?.color
            ?? palette.darkMutedColor?.color
            ?? palette.vibrantColor?.color
            ?? palette.mutedColor?.color;
        if (colorful != null && colorful.computeLuminance() > 0.02) {
          return colorful;
        }
        for (var pc in palette.paletteColors) {
          final hsl = HSLColor.fromColor(pc.color);
          if (hsl.saturation > 0.15 && pc.color.computeLuminance() > 0.03) {
            return pc.color;
          }
        }
        // No colorful alternative found — artwork is genuinely dark.
        // Return the actual dominant dark color instead of a hardcoded one.
        final darkColors = palette.paletteColors
            .where((pc) => pc.color.computeLuminance() < 0.20)
            .toList()
          ..sort((a, b) => b.population.compareTo(a.population));
        if (darkColors.isNotEmpty) return darkColors.first.color;
        return fallback;
      }

      final darkColors = palette.paletteColors
          .where((pc) => pc.color.computeLuminance() < 0.20)
          .toList()
        ..sort((a, b) => b.population.compareTo(a.population));

      if (darkColors.isNotEmpty) return darkColors.first.color;
      return palette.darkMutedColor?.color
          ?? palette.darkVibrantColor?.color
          ?? fallback;
    }

    final dominant = palette.dominantColor;

    if (dominant != null &&
        dominant.color.computeLuminance() > 0.6 &&
        dominant.population < totalPop * 0.2 &&
        avgLuminance < 0.4) {
      return palette.darkMutedColor?.color
          ?? palette.darkVibrantColor?.color
          ?? palette.mutedColor?.color
          ?? dominant.color;
    }

    return dominant?.color
        ?? palette.lightMutedColor?.color
        ?? palette.vibrantColor?.color
        ?? palette.mutedColor?.color
        ?? palette.darkVibrantColor?.color
        ?? fallback;
  }

  // ── Legacy Single-Color API (used by non-background consumers) ────────

  Future<Color> extractColor(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return fallback;
    if (_cache.containsKey(imageUrl)) return _cache[imageUrl]!;
    if (_pending.containsKey(imageUrl)) return _pending[imageUrl]!.future;

    final completer = Completer<Color>();
    _pending[imageUrl] = completer;
    try {
      final color = await _extractLegacy(imageUrl);
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

  Future<Color> extractColorExcludeBlack(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return fallback;
    final cacheKey = '${imageUrl}_noBlack';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey]!;
    if (_pending.containsKey(cacheKey)) return _pending[cacheKey]!.future;

    final completer = Completer<Color>();
    _pending[cacheKey] = completer;
    try {
      final color = await _extractLegacy(imageUrl, excludeBlack: true);
      _cache[cacheKey] = color;
      completer.complete(color);
    } catch (e) {
      _cache[cacheKey] = fallback;
      completer.complete(fallback);
    } finally {
      _pending.remove(cacheKey);
    }
    return completer.future;
  }

  /// Legacy full-image extraction (for non-background use cases)
  Future<Color> _extractLegacy(String imageUrl, {bool excludeBlack = false}) async {
    final imageProvider = ResizeImage(NetworkImage(imageUrl), width: 80, height: 80);
    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const ui.Size(80, 80),
      maximumColorCount: 16,
    ).timeout(const Duration(seconds: 5));

    if (palette.colors.isEmpty) return fallback;
    return _pickBestColor(palette, excludeBlack: excludeBlack);
  }
}
