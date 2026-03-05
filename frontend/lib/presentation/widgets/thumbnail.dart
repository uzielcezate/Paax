import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';

/// -------------------------------------------------------------------
/// Thumbnail
/// -------------------------------------------------------------------
/// The single, canonical image widget for all music thumbnails in Paax.
///
/// Drop-in for any track, album, artist or playlist thumbnail.
///
/// Features (all inherited from [AppImage]):
/// - Platform-aware:  CachedNetworkImage on mobile, Image.network on web
/// - Visibility-gated: never loads off-screen images
/// - Custom CacheManager: 30-day disk cache, 2 000 objects (mobile)
/// - Browser cache:  URLs are used exactly as-is; no query params added (web)
/// - Retry on error: reports to request queue → retried on next visibility
/// - Fallback:       music-note icon shown while loading or on error
/// - Domain sharding: lh3→lh3/4/5/6 rotation via [Lh3UrlBuilder]
///
/// Thumbnail selection:
/// If you have a list of thumbnail objects from the API, use
/// [Thumbnail.fromList] which picks the size closest to [targetPx].
///
/// Example:
/// ```dart
/// // From a direct URL:
/// Thumbnail(
///   url: track.artworkUrl,
///   sizePx: Lh3UrlBuilder.listSize,
///   width: 56, height: 56, borderRadius: 8,
/// )
///
/// // From a list of thumbnails provided by the API:
/// Thumbnail.fromList(
///   thumbnails: item['thumbnails'],
///   targetPx: Lh3UrlBuilder.listSize,
///   width: 56, height: 56,
/// )
/// ```
class Thumbnail extends StatelessWidget {
  final String url;

  /// Target logical resolution in pixels used for:
  /// - lh3 URL sizing (`=wN-hN` parameter)
  /// - CachedNetworkImage memCache / disk cache limits
  final int sizePx;

  final double? width;
  final double? height;
  final double borderRadius;
  final BoxFit fit;
  final bool isCircular;
  final Color? placeholderColor;

  const Thumbnail({
    super.key,
    required this.url,
    required this.sizePx,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.fit = BoxFit.cover,
    this.isCircular = false,
    this.placeholderColor,
  });

  // ---------------------------------------------------------------------------
  // Named constructors for common use-cases
  // ---------------------------------------------------------------------------

  /// List / grid tile thumbnail (56–160 px display).
  factory Thumbnail.list({
    Key? key,
    required String url,
    double size = 56,
    double borderRadius = 8,
    Color? placeholderColor,
  }) {
    return Thumbnail(
      key: key,
      url: url,
      sizePx: Lh3UrlBuilder.listSize,
      width: size,
      height: size,
      borderRadius: borderRadius,
      placeholderColor: placeholderColor,
    );
  }

  /// Circular artist avatar.
  factory Thumbnail.artist({
    Key? key,
    required String url,
    double radius = 28,
  }) {
    return Thumbnail(
      key: key,
      url: url,
      sizePx: Lh3UrlBuilder.listSize,
      width: radius * 2,
      height: radius * 2,
      isCircular: true,
    );
  }

  /// Full-player / album-detail header (fits its parent).
  factory Thumbnail.hero({
    Key? key,
    required String url,
    double? size,
    double borderRadius = 12,
  }) {
    return Thumbnail(
      key: key,
      url: url,
      sizePx: Lh3UrlBuilder.fullPlayerSize,
      width: size,
      height: size,
      borderRadius: borderRadius,
    );
  }

  // ---------------------------------------------------------------------------
  // Static helpers
  // ---------------------------------------------------------------------------

  /// Pick the best URL from a raw API thumbnail list.
  ///
  /// Expects each entry to have at least `{'url': String}` and optionally
  /// `{'width': int}` and/or `{'height': int}`.
  ///
  /// Selection strategy:
  /// 1. Find the thumbnail whose larger dimension is closest to [targetPx].
  /// 2. If tie or no size info, prefer the largest available.
  static String pickUrl(List<dynamic>? thumbnails, {int targetPx = 160}) {
    if (thumbnails == null || thumbnails.isEmpty) return '';

    String? bestUrl;
    int bestDiff = 999999;
    int bestSize = 0;

    for (final t in thumbnails) {
      if (t is! Map) continue;
      final url = t['url']?.toString() ?? '';
      if (url.isEmpty) continue;

      final w = (t['width'] as num?)?.toInt() ?? 0;
      final h = (t['height'] as num?)?.toInt() ?? 0;
      final size = w > h ? w : h; // larger dimension

      if (size == 0) {
        // No size info — use as fallback
        bestUrl ??= url;
        continue;
      }

      final diff = (size - targetPx).abs();
      if (diff < bestDiff || (diff == bestDiff && size > bestSize)) {
        bestDiff = diff;
        bestSize = size;
        bestUrl = url;
      }
    }

    return bestUrl ?? '';
  }

  /// Build a [Thumbnail] by picking the best URL from an API thumbnail list.
  factory Thumbnail.fromList({
    Key? key,
    required List<dynamic>? thumbnails,
    int targetPx = 160,
    double? width,
    double? height,
    double borderRadius = 0,
    BoxFit fit = BoxFit.cover,
    bool isCircular = false,
    Color? placeholderColor,
  }) {
    final url = pickUrl(thumbnails, targetPx: targetPx);
    return Thumbnail(
      key: key,
      url: url,
      sizePx: targetPx,
      width: width,
      height: height,
      borderRadius: borderRadius,
      fit: fit,
      isCircular: isCircular,
      placeholderColor: placeholderColor,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Delegate completely to AppImage — it handles:
    //   • Web vs mobile rendering divergence
    //   • CachedNetworkImage with PlatformCacheManager
    //   • Visibility-based deferred loading
    //   • Error → placeholder fallback with retry
    //   • lh3 URL normalisation / domain sharding
    return AppImage(
      url: url,
      sizePx: sizePx,
      width: width,
      height: height,
      borderRadius: borderRadius,
      fit: fit,
      isCircular: isCircular,
      placeholderColor: placeholderColor,
    );
  }
}
