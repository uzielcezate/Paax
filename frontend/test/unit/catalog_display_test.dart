// test/unit/catalog_display_test.dart
//
// Phase 3.3 regressions for the catalog display layer:
//  * ArtworkResolver — one canonical resolver with a multi-key fallback so an
//    artist/album image never blanks out just because it lives under a
//    different key than the Artist-detail response (§7).
//  * formatFollowers — Paax platform follower count with singular/plural (§6).
//  * compareReleaseDesc / releaseYmd — deterministic newest-first ordering that
//    no longer misparses ISO dates as year 0 (§5).

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/utils/artwork_resolver.dart';
import 'package:beaty/core/utils/string_utils.dart';

void main() {
  group('ArtworkResolver.artist', () {
    test('prefers cached over original over deezer picture', () {
      expect(
        ArtworkResolver.artist({
          'image_cached_url': 'cached',
          'image_original_url': 'original',
          'picture': 'pic',
        }),
        'cached',
      );
    });

    test('falls back to original when cached missing', () {
      expect(
        ArtworkResolver.artist({'image_cached_url': null, 'image_original_url': 'original'}),
        'original',
      );
    });

    test('reads normalized camelCase imageUrl', () {
      expect(ArtworkResolver.artist({'imageUrl': 'u'}), 'u');
    });

    test('reads legacy/Deezer picture and pictureXl', () {
      expect(ArtworkResolver.artist({'pictureXl': 'xl', 'picture': 'p'}), 'xl');
      expect(ArtworkResolver.artist({'picture': 'p'}), 'p');
    });

    test('returns empty when no usable url (placeholder path)', () {
      expect(ArtworkResolver.artist({'picture': '', 'imageUrl': null}), '');
      expect(ArtworkResolver.artist(null), '');
      expect(ArtworkResolver.artist({'picture': 'null'}), '');
    });

    test('never returns placeholder when original url is valid', () {
      // Cached not yet generated, but original present -> must show original.
      final url = ArtworkResolver.artist(
          {'image_cache_status': 'pending', 'image_original_url': 'orig'});
      expect(url, 'orig');
    });
  });

  group('ArtworkResolver.cover', () {
    test('prefers cover cached then coverUrl then original', () {
      expect(ArtworkResolver.cover({'cover_cached_url': 'c', 'coverUrl': 'u'}), 'c');
      expect(ArtworkResolver.cover({'coverUrl': 'u', 'cover_original_url': 'o'}), 'u');
      expect(ArtworkResolver.cover({'cover_original_url': 'o'}), 'o');
    });
  });

  group('ArtworkResolver.pick', () {
    test('returns the first valid candidate', () {
      expect(ArtworkResolver.pick([null, '', 'null', 'real', 'x']), 'real');
      expect(ArtworkResolver.pick([null, '']), '');
    });
  });

  group('formatFollowers (§6 singular/plural)', () {
    test('zero / one / many', () {
      expect(formatFollowers(0), '0 Followers');
      expect(formatFollowers(1), '1 Follower');
      expect(formatFollowers(2), '2 Followers');
      expect(formatFollowers(999), '999 Followers');
    });

    test('K / M scaling', () {
      expect(formatFollowers(1500), '1.5K Followers');
      expect(formatFollowers(1200000), '1.2M Followers');
    });
  });

  group('releaseYmd / compareReleaseDesc (§5)', () {
    test('ISO date is not misparsed as year 0', () {
      expect(releaseYmd('2025-03-15'), (2025, 3, 15));
      expect(releaseYmd('2022'), (2022, 0, 0));
      expect(releaseYmd(null), (0, 0, 0));
      expect(releaseYmd(''), (0, 0, 0));
    });

    test('newest first by exact date', () {
      final list = ['2019-01-01', '2024-06-15', '2021-11-30'];
      list.sort((a, b) => compareReleaseDesc(a, 'x', b, 'x'));
      expect(list, ['2024-06-15', '2021-11-30', '2019-01-01']);
    });

    test('same-year ISO dates order by month/day', () {
      final list = ['2023-01-01', '2023-12-31', '2023-06-15'];
      list.sort((a, b) => compareReleaseDesc(a, 'x', b, 'x'));
      expect(list, ['2023-12-31', '2023-06-15', '2023-01-01']);
    });

    test('year fallback and title tie-break', () {
      final rows = [
        ('2022', 'Zebra'),
        ('2022', 'apple'),
        ('2023', 'mid'),
      ];
      rows.sort((a, b) => compareReleaseDesc(a.$1, a.$2, b.$1, b.$2));
      expect(rows.map((r) => r.$2).toList(), ['mid', 'apple', 'Zebra']);
    });

    test('undated sinks last', () {
      final list = [null, '2018-01-01', '2015'];
      list.sort((a, b) => compareReleaseDesc(a, 'x', b, 'x'));
      expect(list.last, null);
      expect(list.first, '2018-01-01');
    });
  });
}
