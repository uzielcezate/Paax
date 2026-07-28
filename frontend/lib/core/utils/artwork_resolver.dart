/// Canonical artwork URL resolution (Phase 3.3 §7).
///
/// Historically each surface (Home circles, Search cards, onboarding grid,
/// Artist detail) read a *different* image key from a *different* response
/// shape, so an artist image that was present on the full Artist screen went
/// missing everywhere else. This is the single place that decides "which URL"
/// for an artist/album/track image, given any of the response shapes we consume:
///
///   * normalized `/v2` responses (camelCase): `imageUrl`, `coverUrl`
///   * legacy `/v2` / Deezer-shaped responses: `picture`, `pictureXl`,
///     `pictureBig`, `cover`, `coverXl`, `coverBig`
///   * raw Supabase rows (snake_case): `image_cached_url`, `image_original_url`,
///     `cover_cached_url`, `cover_original_url`
///
/// Resolution order per §7: a valid cached URL, then a valid original/remote
/// URL, then nothing (the caller's widget shows the Paax placeholder). We never
/// require the cached copy to exist before showing the original remote image,
/// and never return a placeholder when a valid original URL is present.
class ArtworkResolver {
  ArtworkResolver._();

  /// Ordered artist-image keys (Phase 3.3.1 §1): cached → original → Deezer
  /// picture_xl → picture_big → picture_medium → generic picture.
  static const List<String> _artistKeys = [
    'image_cached_url', 'imageCachedUrl',
    'image_original_url', 'imageOriginalUrl',
    'imageUrl', 'image_url',
    'pictureXl', 'picture_xl',
    'pictureBig', 'picture_big',
    'pictureMedium', 'picture_medium',
    'picture',
    'image',
  ];

  /// Ordered album/cover-image keys, cached first then original/remote.
  static const List<String> _coverKeys = [
    'cover_cached_url', 'coverCachedUrl',
    'coverUrl', 'cover_url',
    'cover_original_url', 'coverOriginalUrl',
    'coverXl', 'cover_xl',
    'coverBig', 'cover_big',
    'cover',
    'image_cached_url', 'imageUrl', 'image_original_url', 'picture',
  ];

  static bool _valid(Object? v) {
    if (v is! String) return false;
    final s = v.trim();
    if (s.isEmpty || s.toLowerCase() == 'null') return false;
    // Treat a malformed (non-http/data) value as absent so it never suppresses
    // a valid lower-priority URL (Phase 3.3.1 §1).
    return s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('data:');
  }

  static String _firstValid(Map<dynamic, dynamic> json, List<String> keys) {
    for (final k in keys) {
      final v = json[k];
      if (_valid(v)) return (v as String).trim();
    }
    return '';
  }

  /// Best artist image URL from any known response/row shape. Returns `''`
  /// when none is usable (widgets then render the placeholder).
  static String artist(Map<dynamic, dynamic>? json) =>
      json == null ? '' : _firstValid(json, _artistKeys);

  /// Best album/cover image URL from any known response/row shape.
  static String cover(Map<dynamic, dynamic>? json) =>
      json == null ? '' : _firstValid(json, _coverKeys);

  /// Pick the first usable URL from an explicit ordered candidate list.
  /// Useful when the caller already holds separate cached/original strings.
  static String pick(List<String?> candidates) {
    for (final c in candidates) {
      if (_valid(c)) return c!.trim();
    }
    return '';
  }
}
