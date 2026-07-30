// test/unit/search_relevance_test.dart
//
// Phase 3.3.3 issue 1 — the Top Result is relevance-ranked, not the first
// name-matching artist. Generic scoring; NO artist name is hardcoded in the
// implementation.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/search_relevance.dart';
import 'package:beaty/core/utils/search_dedupe.dart';

void main() {
  group('SearchRelevance.rankArtists', () {
    test('"Dai Dai": Shakira (primary of strongest exact matches) outranks '
        'name-only "DAIDAI"', () {
      final ranked = SearchRelevance.rankArtists(
        query: 'Dai Dai',
        tracks: [
          (title: 'Dai Dai', artist: 'Shakira'),
          (title: 'Dai Dai', artist: 'Shakira'),
          (title: 'Dai Dai', artist: 'Shakira'),
          (title: 'Dai Dai (Remix)', artist: 'Steeve Anderson'),
        ],
        albums: [
          (title: 'Dai Dai', artist: 'Shakira'),
          (title: 'Dai Dai', artist: 'Gianni Maragliano'),
        ],
        artists: [
          (name: 'DAI DAI DAI', followers: 500),
          (name: 'DAIDAI', followers: 9000),
          (name: 'The Dai Dai', followers: 10),
        ],
      );
      expect(ranked.first.name, 'Shakira');
      expect(ranked.first.inArtistResults, isFalse); // derived → caller resolves
      // Shakira scores far above any name-only match.
      final daidai = ranked.firstWhere((r) => r.name == 'DAIDAI');
      expect(ranked.first.score, greaterThan(daidai.score * 3));
    });

    test('genuine exact artist match with strong context stays Top Result', () {
      final ranked = SearchRelevance.rankArtists(
        query: 'Skrillex',
        tracks: [
          (title: 'Rumble', artist: 'Skrillex'),
          (title: 'Rumble', artist: 'Skrillex'),
        ],
        albums: [
          (title: 'Quest for Fire', artist: 'Skrillex'),
        ],
        artists: [
          (name: 'Skrillex', followers: 1000000),
          (name: 'Skrillex Fan', followers: 5),
        ],
      );
      expect(ranked.first.name, 'Skrillex');
      expect(ranked.first.inArtistResults, isTrue);
    });

    test('exact name match beats a weaker prefix match (no context)', () {
      final ranked = SearchRelevance.rankArtists(
        query: 'Feid',
        tracks: const [],
        albums: const [],
        artists: [
          (name: 'Feid', followers: 100),
          (name: 'Feid Fanpage', followers: 100000),
        ],
      );
      expect(ranked.first.name, 'Feid');
    });

    test('popularity is only a tie-breaker, never overrides context', () {
      final ranked = SearchRelevance.rankArtists(
        query: 'wave',
        tracks: [(title: 'Wave', artist: 'Real Artist')],
        albums: const [],
        artists: [
          (name: 'Waver', followers: 50000000), // huge but weaker relevance
        ],
      );
      expect(ranked.first.name, 'Real Artist');
    });

    test('empty query → no candidates', () {
      expect(
        SearchRelevance.rankArtists(query: '', tracks: const [], albums: const [], artists: const []),
        isEmpty,
      );
    });
  });

  group('dedupeBy (search dedup)', () {
    test('collapses exact-id duplicate rows (join dups)', () {
      final rows = [
        (id: '1', k: 'a'),
        (id: '1', k: 'a'), // dup id
        (id: '2', k: 'b'),
      ];
      final out = dedupeBy(rows, id: (r) => r.id, fallbackKey: (r) => r.k);
      expect(out.length, 2);
      expect(out.map((r) => r.id).toList(), ['1', '2']);
    });

    test('preserves legitimate versions with distinct ids (same title)', () {
      final rows = [
        (id: '10', k: 'dai dai|shakira'),
        (id: '11', k: 'dai dai|shakira'), // different release, distinct id → kept
      ];
      final out = dedupeBy(rows, id: (r) => r.id, fallbackKey: (r) => r.k);
      expect(out.length, 2);
    });

    test('id-less rows dedupe by the fallback key', () {
      final rows = [
        (id: '', k: 'dai dai|shakira|180'),
        (id: '', k: 'dai dai|shakira|180'), // id-less exact dup → collapsed
        (id: '', k: 'dai dai|shakira|200'),
      ];
      final out = dedupeBy(rows, id: (r) => r.id, fallbackKey: (r) => r.k);
      expect(out.length, 2);
    });
  });
}
