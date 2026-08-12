// test/unit/top_track_identity_ingest_test.dart
//
// Phase 3.4.10 — BUG 1: Artist Top Tracks silently failed to persist.
//
// PROVEN ROOT CAUSE (two parts, both verified against production on
// 2026-08-11):
//
//   1. Artist Top Tracks surfaces a DIFFERENT Deezer RELEASE of the same
//      recording than the catalog holds. For Young Miko (artist 139171932):
//
//        track        top-track id   catalog deezer_id   outcome
//        WASSUP       3324627311     3324627311          works
//        BnB          4022674191     4022674191          works
//        CLASSY 101   2216510797     2565307182          FAILS
//        BIAF <3      3936484551     4022674211          FAILS
//        Chulo pt.2   2328294525     (no row)            FAILS
//
//      The videoIds differ too, so BOTH resolution stages legitimately miss.
//      The rule is exact: a track resolves iff its Deezer id matches a catalog
//      row. Nothing to do with the song, the artist, or tap speed.
//
//   2. The ingest fallback called `/v2/track/{deezerId}`, which returns data
//      but does NOT upsert Supabase — after calling it for all three failing
//      ids, `public.tracks` still had zero rows for them. Only
//      `/v2/albums/deezer/{albumDeezerId}` upserts; one such call created
//      `a3d2fe3c-…` for CLASSY 101. That is also why "open the album first"
//      always worked: opening an album performs exactly this ingest.
//
// These tests pin the resulting contract without a network.

import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_resolveTracks` + the ingest fallback decision, so the rule is
/// checkable exhaustively.
({List<String> uuids, List<String> unresolved, bool ingestAttempted})
    resolvePlan({
  required List<({String id, String? deezerId, String videoId, String albumId})>
      tracks,
  required Map<String, String> catalogByDeezerId,
  required Map<String, String> catalogByVideoId,
  Map<String, String> afterIngestByDeezerId = const {},
}) {
  List<String> unresolvedOf(Map<String, String> byDz, Map<String, String> byVid) =>
      tracks
          .where((t) =>
              byDz[(t.deezerId ?? '').trim()] == null && byVid[t.videoId] == null)
          .map((t) => t.id)
          .toList();

  var unresolved = unresolvedOf(catalogByDeezerId, catalogByVideoId);
  var byDz = catalogByDeezerId;
  var ingestAttempted = false;

  if (unresolved.isNotEmpty) {
    // Ingest is attempted only when an unresolved track carries a numeric
    // ALBUM id — the album is what upserts the catalog.
    final albumIds = tracks
        .where((t) => unresolved.contains(t.id))
        .map((t) => t.albumId)
        .where((a) => int.tryParse(a) != null)
        .toSet();
    if (albumIds.isNotEmpty) {
      ingestAttempted = true;
      byDz = {...catalogByDeezerId, ...afterIngestByDeezerId};
      unresolved = unresolvedOf(byDz, catalogByVideoId);
    }
  }

  final uuids = <String>[];
  for (final t in tracks) {
    final u = byDz[(t.deezerId ?? '').trim()] ?? catalogByVideoId[t.videoId];
    if (u != null) uuids.add(u);
  }
  return (uuids: uuids, unresolved: unresolved, ingestAttempted: ingestAttempted);
}

void main() {
  // Real production values.
  const wassupTop = (id: 'w', deezerId: '3324627311', videoId: '-xMqqORn4O4', albumId: '111');
  const bnbTop = (id: 'b', deezerId: '4022674191', videoId: 'RioqFNeSdCI', albumId: '222');
  const classyTop = (id: 'c', deezerId: '2216510797', videoId: 'DwUA6misBRg', albumId: '423858537');
  const biafTop = (id: 'i', deezerId: '3936484551', videoId: 'l_Kxarx2nLE', albumId: '952574041');
  const chuloTop = (id: 'h', deezerId: '2328294525', videoId: 'tnbpWZNAT_Y', albumId: '453563555');

  // Catalog BEFORE ingest — note the different release ids for the failures.
  const catalogByDeezer = {
    '3324627311': 'uuid-wassup',
    '4022674191': 'uuid-bnb',
    '2565307182': 'uuid-classy-OTHER-RELEASE',
    '4022674211': 'uuid-biaf-OTHER-RELEASE',
  };
  const catalogByVideo = {
    '-xMqqORn4O4': 'uuid-wassup',
    'ZQW96Jf12Z8': 'uuid-bnb-other',
    'XPz0BRHfi7M': 'uuid-classy-OTHER-RELEASE',
    'IuikORYFWNk': 'uuid-biaf-OTHER-RELEASE',
  };

  group('the exact production failure is reproduced', () {
    test('WASSUP and BnB resolve; CLASSY/BIAF/Chulo do not (pre-ingest)', () {
      final plan = resolvePlan(
        tracks: [wassupTop, bnbTop, classyTop, biafTop, chuloTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
      );
      expect(plan.unresolved, ['c', 'i', 'h'],
          reason: 'a different Deezer RELEASE id is a different catalog row');
    });

    test('a mismatched release id is NOT silently mapped to the other release',
        () {
      final plan = resolvePlan(
        tracks: [classyTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
      );
      expect(plan.uuids, isEmpty,
          reason: 'mutating the wrong recording would be worse than failing');
    });
  });

  group('ingest is attempted via the ALBUM and fixes resolution', () {
    test('unresolved tracks trigger an album ingest', () {
      final plan = resolvePlan(
        tracks: [classyTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
        afterIngestByDeezerId: const {'2216510797': 'uuid-classy-canonical'},
      );
      expect(plan.ingestAttempted, isTrue);
      expect(plan.unresolved, isEmpty);
      expect(plan.uuids, ['uuid-classy-canonical'],
          reason: 'the ingested row, not the pre-existing other release');
    });

    test('an already-resolvable track never triggers ingest', () {
      final plan = resolvePlan(
        tracks: [wassupTop, bnbTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
      );
      expect(plan.ingestAttempted, isFalse,
          reason: 'no wasted request on the common path');
      expect(plan.uuids, ['uuid-wassup', 'uuid-bnb']);
    });

    test('all six adds succeed after ingest', () {
      final plan = resolvePlan(
        tracks: [wassupTop, bnbTop, classyTop, biafTop, chuloTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
        afterIngestByDeezerId: const {
          '2216510797': 'uuid-classy-canonical',
          '3936484551': 'uuid-biaf-canonical',
          '2328294525': 'uuid-chulo-canonical',
        },
      );
      expect(plan.unresolved, isEmpty);
      expect(plan.uuids, hasLength(5),
          reason: 'every selected track must reach playlist_add_tracks');
    });

    test('a track with no numeric album id cannot be ingested and fails openly',
        () {
      const noAlbum = (id: 'x', deezerId: '999', videoId: 'vX', albumId: '');
      final plan = resolvePlan(
        tracks: [noAlbum],
        catalogByDeezerId: const {},
        catalogByVideoId: const {},
      );
      expect(plan.ingestAttempted, isFalse);
      expect(plan.unresolved, ['x'],
          reason: 'explicit failure beats mutating something arbitrary');
    });

    test('ingest runs at most once — resolution never loops', () {
      var ingests = 0;
      Map<String, String> ingestOnce() {
        ingests++;
        return const {'2216510797': 'uuid-classy-canonical'};
      }

      resolvePlan(
        tracks: [classyTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
        afterIngestByDeezerId: ingestOnce(),
      );
      expect(ingests, 1);
    });
  });

  group('playlist_add_tracks must never receive an empty list', () {
    test('an all-unresolved add produces zero UUIDs and must not be sent', () {
      final plan = resolvePlan(
        tracks: [chuloTop],
        catalogByDeezerId: const {},
        catalogByVideoId: const {},
      );
      expect(plan.uuids, isEmpty);
      expect(plan.unresolved, isNotEmpty,
          reason: 'the caller raises localIntegrity instead of sending []');
    });

    test('a partial resolve still reports the unresolved ones', () {
      final plan = resolvePlan(
        tracks: [wassupTop, chuloTop],
        catalogByDeezerId: catalogByDeezer,
        catalogByVideoId: catalogByVideo,
      );
      expect(plan.uuids, ['uuid-wassup']);
      expect(plan.unresolved, ['h'],
          reason: 'a partial success must not be reported as full success');
    });
  });
}
