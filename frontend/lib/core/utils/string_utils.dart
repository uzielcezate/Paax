// ─── Artist Name Utilities ─────────────────────────────────────────────────

/// Returns true if [s] looks like a view/play/stream count rather than an
/// artist name (e.g. "2.3M views", "1.1B plays", "543K listeners").
/// Also rejects null or blank strings.
bool isViewCountString(String? s) {
  if (s == null || s.trim().isEmpty) return true;
  final lower = s.trim().toLowerCase();
  // Match patterns like "2.3M views", "543 plays", "1.1b streams", "17M listeners"
  return RegExp(
    r'^\d[\d,\.]*\s*[kmb]?\s*(view|play|stream|listener|like)',
    caseSensitive: false,
  ).hasMatch(lower);
}

/// Joins [names] into a comma-separated display string.
/// Returns "Unknown Artist" if the list is empty or all entries are blank.
///
/// Example: ["Calvin Harris", "Dua Lipa"] → "Calvin Harris, Dua Lipa"
String formatArtistNames(List<String> names) {
  final clean = names.where((n) => n.trim().isNotEmpty).toList();
  if (clean.isEmpty) return 'Unknown Artist';
  return clean.join(', ');
}

// ─── Placeholder Artist Detection ─────────────────────────────────────────

/// Returns true if the artist name appears to be a placeholder/compilation name
/// rather than a real artist (e.g., "Various Artists", "80's Greatest Hits", etc.)
bool isPlaceholderArtist(String? name) {
  if (name == null || name.trim().isEmpty) return false;
  final normalized = name.trim().toLowerCase();

  // 1. Exact matches for common placeholder names
  const exactPlaceholders = {
    'various artists',
    'varios artistas',
    'various',
    'unknown artist',
    'unknown',
    'soundtrack',
    'original soundtrack',
    'ost',
    'compilation',
    'top hits',
    'greatest hits',
    'best of',
  };
  if (exactPlaceholders.contains(normalized)) return true;

  // 2. Pattern: Decade-based names like "60s", "70's", "80s", "90s", "2000s"
  //    Combined with keywords like hits, songs, pop, band, love, rock, classics, etc.
  final decadePattern = RegExp(
    r"(^|[^a-z])(the\s+)?(19)?(5|6|7|8|9)0'?s|20[0-2]0'?s",
    caseSensitive: false,
  );
  
  if (decadePattern.hasMatch(normalized)) {
    // Check if it also contains compilation-related keywords
    const compilationKeywords = [
      'hits', 'songs', 'band', 'pop', 'rock', 'love', 'classics',
      'greatest', 'best', 'top', 'favorites', 'favourites', 'music',
      'dance', 'disco', 'ballads', 'power', 'anthems', 'jams',
      'essentials', 'collection', 'mix', 'radio', 'party',
    ];
    for (final keyword in compilationKeywords) {
      if (normalized.contains(keyword)) return true;
    }
    
    // Also block names that are ONLY decade references like "80's" or "The 90s"
    final onlyDecadePattern = RegExp(
      r"^(the\s+)?(19)?(5|6|7|8|9)0'?s$|^20[0-2]0'?s$",
      caseSensitive: false,
    );
    if (onlyDecadePattern.hasMatch(normalized)) return true;
  }

  // 3. Pattern: Names containing "various" or "assorted"
  if (normalized.contains('various') || normalized.contains('assorted')) {
    return true;
  }

  // 4. Pattern: Pure genre + compilation names
  const genreCompilationPatterns = [
    'greatest hits',
    'super hits',
    'mega hits',
    'top hits',
    'classic hits',
    'gold hits',
    'platinum hits',
    'love songs',
    'power ballads',
    'rock anthems',
    'pop classics',
    'dance hits',
    'disco hits',
    'party hits',
    'summer hits',
    'workout hits',
    'running hits',
  ];
  for (final pattern in genreCompilationPatterns) {
    if (normalized.contains(pattern)) return true;
  }

  return false;
}

/// Formats fan count with K/M suffixes and 1 decimal place.
/// Examples:
/// 54 -> "54 Fans"
/// 1500 -> "1.5 K Fans"
/// 1200000 -> "1.2 M Fans"
String formatFans(int fans) {
  if (fans < 1000) return '$fans Fans';
  
  if (fans < 1000000) {
    final k = (fans / 1000).toStringAsFixed(1);
    return '$k K Fans';
  }
  
  final m = (fans / 1000000).toStringAsFixed(1);
  return '$m M Fans';
}

/// Formats a Paax **platform follower** count with correct singular/plural
/// (Phase 3.3 §6). Unlike [formatFans] (external Deezer fans), this represents
/// real Paax users who follow the artist.
/// Examples:
/// 0 -> "0 Followers"
/// 1 -> "1 Follower"
/// 2 -> "2 Followers"
/// 1500 -> "1.5K Followers"
/// 1200000 -> "1.2M Followers"
String formatFollowers(int count) {
  if (count == 1) return '1 Follower';
  if (count < 1000) return '$count Followers';
  if (count < 1000000) {
    return '${(count / 1000).toStringAsFixed(1)}K Followers';
  }
  return '${(count / 1000000).toStringAsFixed(1)}M Followers';
}

// ─── Release Metadata Utilities ───────────────────────────────────────────

/// Safely extracts a 4-digit year from a date string or year value.
///
/// Handles:
/// - `"2025"` → `"2025"`
/// - `"2025-03-15"` → `"2025"`
/// - `null` / `""` → `null`
/// - Unparseable values → `null`
String? extractYear(String? dateOrYear) {
  if (dateOrYear == null || dateOrYear.trim().isEmpty) return null;
  final trimmed = dateOrYear.trim();

  // Already a 4-digit year
  final yearOnly = RegExp(r'^\d{4}$');
  if (yearOnly.hasMatch(trimmed)) return trimmed;

  // ISO date: "2025-03-15" or similar
  final isoMatch = RegExp(r'^(\d{4})-').firstMatch(trimmed);
  if (isoMatch != null) return isoMatch.group(1);

  // Any 4-digit sequence
  final anyYear = RegExp(r'(\d{4})').firstMatch(trimmed);
  if (anyYear != null) return anyYear.group(1);

  return null;
}

/// Parses a release date/year string into a sortable `(year, month, day)`.
/// Returns `(0, 0, 0)` when nothing usable exists so the release sorts last.
///
/// Fixes the Phase 3.3 §5 bug where `int.tryParse("2025-03-15")` returned
/// `null → 0`, collapsing all ISO-dated releases to the same rank.
(int, int, int) releaseYmd(String? dateOrYear) {
  if (dateOrYear == null) return (0, 0, 0);
  final s = dateOrYear.trim();
  final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(s);
  if (iso != null) {
    return (int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
  }
  final ym = RegExp(r'^(\d{4})-(\d{2})').firstMatch(s);
  if (ym != null) {
    return (int.parse(ym.group(1)!), int.parse(ym.group(2)!), 0);
  }
  final year = extractYear(s);
  if (year != null) return (int.parse(year), 0, 0);
  return (0, 0, 0);
}

/// Comparator for releases, **newest first**, mirroring the backend's canonical
/// ordering (Phase 3.3 §5): exact date desc → year desc → title asc. Undated
/// releases sink last. Use as a safe deterministic presentation sort so
/// malformed upstream ordering never leaks into the UI.
int compareReleaseDesc(String? dateA, String? titleA, String? dateB, String? titleB) {
  final a = releaseYmd(dateA);
  final b = releaseYmd(dateB);
  if (a.$1 != b.$1) return b.$1.compareTo(a.$1);
  if (a.$2 != b.$2) return b.$2.compareTo(a.$2);
  if (a.$3 != b.$3) return b.$3.compareTo(a.$3);
  return (titleA ?? '').toLowerCase().compareTo((titleB ?? '').toLowerCase());
}

/// Returns an English display label for a normalized release type.
///
/// - `'album'`  → `'Album'`
/// - `'single'` → `'Single'`
/// - `'ep'`     → `'EP'`
/// - default    → `'Album'`
String displayReleaseType(String? type) {
  switch (type) {
    case 'album':
      return 'Album';
    case 'single':
      return 'Single';
    case 'ep':
      return 'EP';
    default:
      return 'Album';
  }
}

/// Normalizes raw release type strings to canonical lowercase values.
///
/// Maps:
/// - `"album"`, `"Album"`, `"ALBUM"` → `"album"`
/// - `"single"`, `"Single"`, `"song"`, `"Song"`, `"track"`, `"Track"` → `"single"`
/// - `"ep"`, `"EP"`, `"Ep"`, `"extended play"` → `"ep"`
///
/// Returns [defaultType] for `null` or unrecognized values.
String normalizeReleaseType(dynamic raw, {String defaultType = 'album'}) {
  if (raw == null) return defaultType;
  final t = raw.toString().toLowerCase().trim();
  if (t == 'album') return 'album';
  if (t == 'single' || t == 'song' || t == 'track') return 'single';
  if (t == 'ep' || t == 'extended play') return 'ep';
  return defaultType;
}
