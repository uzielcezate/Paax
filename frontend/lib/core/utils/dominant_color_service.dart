import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Singleton service that extracts and caches the dominant color from
/// network artwork images. Used by detail screens to build dynamic
/// ambient backgrounds.
///
/// • Extracts from a tiny 80px resize — fast (~20-50ms)
/// • Caches by URL — never re-extracts for the same image
/// • Auto-darkens light colors so the app never looks "light theme"
/// • Falls back to pure black on any failure
class DominantColorService {
  DominantColorService._();
  static final instance = DominantColorService._();

  /// In-memory cache: imageUrl → darkened dominant color.
  final Map<String, Color> _cache = {};

  /// Urls currently being extracted (prevents duplicate parallel extractions).
  final Map<String, Completer<Color>> _pending = {};

  static const Color _fallback = Color(0xFF000000);

  /// Maximum lightness (HSL) for the returned color.
  /// Colors brighter than this get darkened to maintain a premium dark look.
  static const double _maxLightness = 0.25;

  /// Maximum saturation — prevents neon-like oversaturation.
  static const double _maxSaturation = 0.65;

  /// Returns the cached dominant color, or [_fallback] if not yet extracted.
  /// Useful for synchronous checks (e.g. in build methods).
  Color getCachedColor(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return _fallback;
    return _cache[imageUrl] ?? _fallback;
  }

  /// Extracts the dominant color from [imageUrl].
  /// Returns a darkened, desaturated version suitable for dark UI backgrounds.
  /// Results are cached; subsequent calls for the same URL return instantly.
  Future<Color> extractColor(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) return _fallback;

    // Cache hit
    if (_cache.containsKey(imageUrl)) return _cache[imageUrl]!;

    // Dedup: if already extracting this URL, wait for that result
    if (_pending.containsKey(imageUrl)) return _pending[imageUrl]!.future;

    final completer = Completer<Color>();
    _pending[imageUrl] = completer;

    try {
      final color = await _extract(imageUrl);
      _cache[imageUrl] = color;
      completer.complete(color);
    } catch (e) {
      debugPrint('[DominantColor] Extraction failed for $imageUrl: $e');
      _cache[imageUrl] = _fallback;
      completer.complete(_fallback);
    } finally {
      _pending.remove(imageUrl);
    }

    return completer.future;
  }

  Future<Color> _extract(String imageUrl) async {
    // Use a small resize for speed
    final imageProvider = ResizeImage(
      NetworkImage(imageUrl),
      width: 80,
      height: 80,
    );

    final palette = await PaletteGenerator.fromImageProvider(
      imageProvider,
      size: const ui.Size(80, 80),
      maximumColorCount: 16,
    ).timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Color extraction timed out'),
    );

    // Pick the best color: dominant > vibrant > darkVibrant > muted > fallback
    final raw = palette.dominantColor?.color
        ?? palette.vibrantColor?.color
        ?? palette.darkVibrantColor?.color
        ?? palette.mutedColor?.color
        ?? _fallback;

    return _darkenForUI(raw);
  }

  /// Ensures the color is dark and desaturated enough for a premium dark UI.
  Color _darkenForUI(Color color) {
    final hsl = HSLColor.fromColor(color);

    final clampedLightness = hsl.lightness.clamp(0.05, _maxLightness);
    final clampedSaturation = hsl.saturation.clamp(0.0, _maxSaturation);

    return hsl
        .withLightness(clampedLightness)
        .withSaturation(clampedSaturation)
        .toColor();
  }
}
