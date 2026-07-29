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
  // Phase 3.3.1 §1 required fixtures. Real (http) URLs — the resolver treats a
  // non-http value as malformed/absent.
  const cached = 'https://storage.example/cached.webp';
  const original = 'https://cdn-images.dzcdn.net/original.jpg';
  const xl = 'https://e-cdns-images.dzcdn.net/xl.jpg';
  const big = 'https://e-cdns-images.dzcdn.net/big.jpg';
  const medium = 'https://e-cdns-images.dzcdn.net/medium.jpg';

  group('ArtworkResolver.artist (§1 priority)', () {
    test('cached present → cached', () {
      expect(
        ArtworkResolver.artist({
          'image_cached_url': cached,
          'image_original_url': original,
          'picture': xl,
        }),
        cached,
      );
    });

    test('cached absent, original present → original', () {
      expect(
        ArtworkResolver.artist({'image_cached_url': null, 'image_original_url': original}),
        original,
      );
    });

    test('only Deezer picture_xl present → picture_xl', () {
      expect(ArtworkResolver.artist({'picture_xl': xl}), xl);
      expect(ArtworkResolver.artist({'pictureXl': xl}), xl);
    });

    test('priority xl > big > medium > picture', () {
      expect(
        ArtworkResolver.artist({'picture_big': big, 'picture_medium': medium, 'picture_xl': xl}),
        xl,
      );
      expect(ArtworkResolver.artist({'picture_big': big, 'picture_medium': medium}), big);
      expect(ArtworkResolver.artist({'picture_medium': medium, 'picture': original}), medium);
    });

    test('malformed cached URL with valid original → original', () {
      // A missing/garbage cached URL must NEVER suppress a valid original.
      expect(
        ArtworkResolver.artist({'image_cached_url': 'not-a-url', 'image_original_url': original}),
        original,
      );
      expect(
        ArtworkResolver.artist({'image_cached_url': 'null', 'image_original_url': original}),
        original,
      );
    });

    test('all image fields missing → placeholder (empty)', () {
      expect(ArtworkResolver.artist({'picture': '', 'imageUrl': null}), '');
      expect(ArtworkResolver.artist(null), '');
      expect(ArtworkResolver.artist({'picture': 'null'}), '');
      expect(ArtworkResolver.artist({'name': 'x'}), '');
    });

    test('pending cache status does not suppress a valid original', () {
      expect(
        ArtworkResolver.artist({'image_cache_status': 'pending', 'image_original_url': original}),
        original,
      );
    });
  });

  group('ArtworkResolver.cover', () {
    const cCached = 'https://storage.example/cover_c.webp';
    const cOrig = 'https://cdn-images.dzcdn.net/cover_o.jpg';
    test('prefers cover cached then original', () {
      expect(ArtworkResolver.cover({'cover_cached_url': cCached, 'coverUrl': cOrig}), cCached);
      expect(ArtworkResolver.cover({'cover_original_url': cOrig}), cOrig);
    });
  });

  group('ArtworkResolver.pick', () {
    test('returns the first valid candidate', () {
      const real = 'https://x/real.jpg';
      expect(ArtworkResolver.pick([null, '', 'null', 'not-a-url', real, 'x']), real);
      expect(ArtworkResolver.pick([null, '']), '');
    });
  });

  group('reconcileFollowerCount (3.3.2 issue 2 — Drake stale-cache)', () {
    test('stale base 0 while following shows 1, not 0 (Drake)', () {
      // DB=1 but paax-api cache returned 0; user follows, no in-session toggle.
      expect(reconcileFollowerCount(0, 0, isFollowing: true), 1);
    });

    test('not following, base 0 → 0', () {
      expect(reconcileFollowerCount(0, 0, isFollowing: false), 0);
    });

    test('follow moves 0 → 1 exactly once (delta +1)', () {
      expect(reconcileFollowerCount(0, 1, isFollowing: true), 1);
    });

    test('fresh count already includes the user → no double count', () {
      expect(reconcileFollowerCount(1, 0, isFollowing: true), 1);
      expect(reconcileFollowerCount(100, 0, isFollowing: true), 100);
    });

    test('unfollow decrements once, never below zero', () {
      expect(reconcileFollowerCount(1, -1, isFollowing: false), 0);
      expect(reconcileFollowerCount(0, -1, isFollowing: false), 0);
      expect(reconcileFollowerCount(100, -1, isFollowing: false), 99);
    });

    test('re-follow after unfollow returns to floor', () {
      expect(reconcileFollowerCount(0, 0, isFollowing: true), 1);
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

    test('identical date+title break deterministically on id', () {
      final rows = [
        ('2020-01-01', 'same', 'id-b'),
        ('2020-01-01', 'same', 'id-a'),
      ];
      rows.sort((a, b) =>
          compareReleaseDesc(a.$1, a.$2, b.$1, b.$2, idA: a.$3, idB: b.$3));
      expect(rows.map((r) => r.$3).toList(), ['id-a', 'id-b']);
    });
  });
}
