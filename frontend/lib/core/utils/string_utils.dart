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
