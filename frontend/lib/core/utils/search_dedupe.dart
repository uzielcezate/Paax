/// Presentation-time de-duplication for search results (Phase 3.3.3).
///
/// Collapses exact duplicate rows caused by joins / repeated ingestion while
/// PRESERVING legitimate alternate versions. An item is deduped by its canonical
/// id first (Deezer id / UUID); the secondary key (e.g. normalized title +
/// primary artist + duration) is used ONLY for items that lack an id, so two
/// legitimately-different releases (distinct ids) are never merged.
List<T> dedupeBy<T>(
  Iterable<T> items, {
  required String? Function(T) id,
  required String Function(T) fallbackKey,
}) {
  final seenId = <String>{};
  final seenKey = <String>{};
  final out = <T>[];
  for (final it in items) {
    final i = id(it)?.trim();
    if (i != null && i.isNotEmpty) {
      if (!seenId.add(i)) continue;
    } else {
      if (!seenKey.add(fallbackKey(it))) continue;
    }
    out.add(it);
  }
  return out;
}

String normalizeForDedupe(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
