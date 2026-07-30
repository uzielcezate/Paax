// test/unit/track_credits_test.dart
//
// Phase 3.3.3 issue 3/4 — one canonical per-track credit resolver. Album track
// rows must show the real performing artists for THAT track, deterministically
// ordered and deduped, never collapsed to the album primary artist.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/track_credits.dart';

List<String> _names(List<Map<String, String>> c) =>
    c.map((e) => e['name']!).toList();

void main() {
  group('TrackCredits.resolve', () {
    test('SOMA / Duro → Skrillex, Young Miko (position order)', () {
      final c = TrackCredits.resolve([
        {'id': 'uuid-sk', 'deezerId': 525643, 'name': 'Skrillex', 'role': 'primary', 'position': 1},
        {'id': 'uuid-ym', 'deezerId': 139171932, 'name': 'Young Miko', 'role': 'primary', 'position': 2},
      ]);
      expect(_names(c), ['Skrillex', 'Young Miko']);
      expect(c[0]['id'], '525643'); // nav id = Deezer id
    });

    test('SOMA / Noche Without You → Skrillex, Feid', () {
      final c = TrackCredits.resolve([
        {'deezerId': 525643, 'name': 'Skrillex', 'role': 'primary', 'position': 1},
        {'deezerId': 222, 'name': 'Feid', 'role': 'primary', 'position': 2},
      ]);
      expect(_names(c), ['Skrillex', 'Feid']);
    });

    test('SOMA / Thistle → 4 primaries in position order', () {
      final c = TrackCredits.resolve([
        {'name': 'Skrillex', 'role': 'primary', 'position': 1},
        {'name': 'Randomer', 'role': 'primary', 'position': 2},
        {'name': 'Blawan', 'role': 'primary', 'position': 3},
        {'name': 'Mc Dricka', 'role': 'primary', 'position': 4},
      ]);
      expect(_names(c), ['Skrillex', 'Randomer', 'Blawan', 'Mc Dricka']);
    });

    test('single primary → shown once', () {
      final c = TrackCredits.resolve([
        {'deezerId': 525643, 'name': 'Skrillex', 'role': 'primary', 'position': 1},
      ]);
      expect(_names(c), ['Skrillex']);
    });

    test('primary before featured regardless of position', () {
      final c = TrackCredits.resolve([
        {'name': 'Guest', 'role': 'featured', 'position': 1},
        {'name': 'Lead', 'role': 'primary', 'position': 2},
      ]);
      expect(_names(c), ['Lead', 'Guest']);
    });

    test('dedupes by uuid, then deezerId, then name', () {
      final c = TrackCredits.resolve([
        {'id': 'u1', 'deezerId': 1, 'name': 'Skrillex', 'role': 'primary', 'position': 1},
        {'id': 'u1', 'deezerId': 1, 'name': 'Skrillex', 'role': 'featured', 'position': 5}, // dup uuid
        {'deezerId': 1, 'name': 'Skrillex dupe', 'role': 'primary', 'position': 2}, // dup deezerId
        {'name': 'skrillex', 'role': 'primary', 'position': 3}, // dup by normalized name
      ]);
      expect(c.length, 1);
      expect(c.first['name'], 'Skrillex');
    });

    test('excludes non-performing roles (producer/composer/remixer)', () {
      final c = TrackCredits.resolve([
        {'name': 'Skrillex', 'role': 'primary', 'position': 1},
        {'name': 'Some Producer', 'role': 'producer', 'position': 2},
        {'name': 'A Composer', 'role': 'composer', 'position': 3},
      ]);
      expect(_names(c), ['Skrillex']);
    });

    test('empty / malformed input → empty', () {
      expect(TrackCredits.resolve(const []), isEmpty);
      expect(TrackCredits.resolve([{'role': 'primary'}]), isEmpty); // no name
      expect(TrackCredits.resolve(['garbage', 42]), isEmpty);
    });
  });
}
