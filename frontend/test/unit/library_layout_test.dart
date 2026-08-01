// test/unit/library_layout_test.dart
//
// Phase 3.3.6 — Library content-list top inset. Guards the fix for the large
// blank gap: the reserved space must track the real (measured) header height and
// be materially smaller than the old hardcoded `safeTop + 230`.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/library_layout.dart';

void main() {
  const safeTop = 47.0; // typical notch inset

  test('before measurement, uses a close composed fallback (not 230)', () {
    final inset =
        LibraryLayout.listTopInset(safeTop: safeTop, measuredHeader: 0);
    // safeTop + 158 + 8 = 213 for this device — well below the old safeTop+230.
    expect(inset, safeTop + LibraryLayout.headerFallback + LibraryLayout.gap);
    expect(inset, lessThan(safeTop + 230));
  });

  test('after measurement, pads to the exact header height + small gap', () {
    // Real header measured at ~150 (incl. safe area) → 158 total.
    final inset =
        LibraryLayout.listTopInset(safeTop: safeTop, measuredHeader: 150);
    expect(inset, 150 + LibraryLayout.gap);
    // No ~80px dead band that the old constant produced.
    expect(inset, lessThan(safeTop + 230));
  });

  test('gap keeps the first item shortly below the header, not flush', () {
    final inset =
        LibraryLayout.listTopInset(safeTop: safeTop, measuredHeader: 150);
    expect(inset - 150, LibraryLayout.gap);
    expect(LibraryLayout.gap, greaterThan(0));
  });
}
