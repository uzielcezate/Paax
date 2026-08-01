// lib/core/utils/library_layout.dart
//
// Phase 3.3.6 — single source of truth for the Library content-list top inset.
//
// The floating Library header (safe area + title + chip tabs + search/sort row)
// overlays the tab content, so each tab pads its list down by the header height.
// The old code hardcoded `safeTop + 230`, which over-reserved ~80px vs the real
// ~150px header and left a large blank gap before the first result. This helper
// pads to the MEASURED header height (exact, text-scale aware); before the first
// measurement it uses a close composed fallback so there is no first-frame jump.
class LibraryLayout {
  const LibraryLayout._();

  /// Composed fallback header content height below the safe-area top:
  /// title block (~46) + chip tabs (56) + search/sort row (56).
  static const double headerFallback = 158.0;

  /// Normal breathing gap between the search row and the first list item.
  static const double gap = 8.0;

  /// Top inset for a Library list. [measuredHeader] is the measured floating
  /// header height (0 until measured); [safeTop] is the top safe-area padding.
  static double listTopInset({
    required double safeTop,
    required double measuredHeader,
  }) {
    final base = measuredHeader > 0 ? measuredHeader : safeTop + headerFallback;
    return base + gap;
  }
}
