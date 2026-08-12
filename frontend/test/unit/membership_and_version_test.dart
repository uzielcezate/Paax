// test/unit/membership_and_version_test.dart
//
// Phase 3.4.11 — two production defects, both proven against the live DB.
//
// Every test here drives the REAL production implementation
// (`PlaylistRepository.membershipFromRows`, `.mapCloudTrack`,
// `.authoritativeVersion`, `.planSaveOrderReplay`, `.preservePendingOrder`,
// `.executeOp` and the real `PlaylistMutationLane`). Nothing is re-implemented
// locally: a copied rule cannot fail when production regresses, which is the
// only thing a regression lock is for.
//
// BUG 1: MEMBERSHIP IS NOT METADATA.
//   `_mapCloudTrack` returned null when `preferred_youtube_video_id` was empty,
//   which silently removed an authoritative playlist_tracks row from the UI.
//   Since PR #92 ingests a track's album on demand, a freshly-ingested row
//   exists with youtube_match_status='pending' and a NULL videoId for a while.
//   Verified in production: CLASSY 101 (a3d2fe3c…), BIAF <3 (14f90bf3…) and
//   Desesperados (d5fcf54d…) all had videoId NULL — exactly the tracks that
//   disappeared from the playlist seconds after being added, while the server
//   correctly held all six rows.
//
// BUG 2: THE VERSION SELF-CONFLICT, online and offline.
//   Online, `expected ?? expectedVersion` let the mutation lane's value win even
//   when it was OLDER than the version the screen had just loaded. Offline,
//   replay sent `op.expectedVersion` — the version captured WHILE OFFLINE —
//   which by replay time is stale by construction, so the reorder 409'd, was
//   quarantined as terminal, and the positions were never written.

import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/remote/catalog_resolver.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/data/sync/playlist_mutation_lane.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── production row shapes ────────────────────────────────────────────────────

/// One `playlist_tracks` row exactly as `fetchTracks` selects it.
Map<String, dynamic> ptRow({
  required int position,
  required String uuid,
  String? videoId,
  String title = 'Song',
  String? deezerId = '123',
  int? duration = 180,
  List<Map<String, dynamic>>? artists = const [
    {'artist_id': 'a1', 'artists': {'id': 'a1', 'name': 'Young Miko'}}
  ],
  String? artwork = 'https://cdn/img.jpg',
}) =>
    {
      'position': position,
      'track_id': uuid,
      'added_by': 'u1',
      'tracks': {
        'id': uuid,
        'deezer_id': deezerId,
        'title': title,
        'duration_seconds': duration,
        'preferred_youtube_video_id': videoId,
        'image_cached_url': artwork,
        'image_original_url': artwork,
        'track_artists': artists,
      },
    };

/// The exact production reproduction: Young Miko's Top 5 + Qué Pasaría…,
/// six authoritative rows, two of them still awaiting a YouTube match.
List<Map<String, dynamic>> sixAuthoritativeRows() => [
      ptRow(position: 1, uuid: 'u-bnb', videoId: 'ZQW96Jf12Z8', title: 'BnB'),
      ptRow(position: 2, uuid: 'a3d2fe3c', videoId: null, title: 'CLASSY 101'),
      ptRow(position: 3, uuid: 'u-wassup', videoId: '-xMqqORn4O4', title: 'WASSUP'),
      ptRow(position: 4, uuid: '14f90bf3', videoId: null, title: 'BIAF <3'),
      ptRow(position: 5, uuid: 'u-fina', videoId: 'Saw2EI_avWs', title: 'FINA'),
      ptRow(
          position: 6,
          uuid: 'u-que',
          videoId: 'g08y_x83d5E',
          title: 'Qué Pasaría...'),
    ];

Track t(String id) => Track(
      id: id,
      title: id,
      artistName: 'A',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: 1,
    );

// ── a fake remote, so replay runs the REAL repository code ───────────────────

class FakeRemote extends PlaylistRemoteDataSource {
  FakeRemote({
    this.playlistRow,
    this.membership = const [],
    this.savedVersion = 17,
  }) : super(SupabaseClient('http://localhost:54321', 'test-anon-key'));

  /// null models a deleted / no-longer-visible playlist.
  Map<String, dynamic>? playlistRow;
  List<String> membership;
  int savedVersion;

  final List<({List<String> ids, int? expectedVersion})> saveOrderCalls = [];
  int fetchPlaylistCalls = 0;

  @override
  String? get currentUserId => 'user-1';

  @override
  Future<Map<String, dynamic>?> fetchPlaylist(String playlistId) async {
    fetchPlaylistCalls++;
    return playlistRow;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTracks(String playlistId) async =>
      [for (final (i, id) in membership.indexed) ptRow(position: i + 1, uuid: id)];

  @override
  Future<Map<String, dynamic>> saveOrder(
      String playlistId, List<String> orderedTrackUuids, int? expectedVersion) async {
    saveOrderCalls
        .add((ids: orderedTrackUuids, expectedVersion: expectedVersion));
    return {'id': playlistId, 'version': savedVersion};
  }
}

PlaylistRepository repoWith(FakeRemote remote) => PlaylistRepository(
      remote: remote,
      resolver: CatalogResolver(
          SupabaseClient('http://localhost:54321', 'test-anon-key')),
    );

PlaylistOp reorderOp(List<String> ids, {int? expectedVersion}) => PlaylistOp(
      opId: 'op-1',
      userId: 'user-1',
      playlistId: 'p-1',
      type: PlaylistOpType.saveOrder,
      createdAt: DateTime(2026, 8, 12),
      expectedVersion: expectedVersion,
      payload: {'ids': ids},
    );

void main() {
  setUp(() {
    PlaylistRepository.mutationLane.resetForTest();
    PlaylistSyncService.resetForTest();
  });

  group('BUG 1 — hydration must never shrink membership', () {
    test('six authoritative rows produce exactly six UI members', () {
      final tracks =
          PlaylistRepository.membershipFromRows(sixAuthoritativeRows());
      expect(tracks, hasLength(6),
          reason: 'the server held 6 rows; the UI must hold 6');
      expect(tracks.map((t) => t.title), [
        'BnB',
        'CLASSY 101',
        'WASSUP',
        'BIAF <3',
        'FINA',
        'Qué Pasaría...',
      ]);
    });

    test('a NULL preferred_youtube_video_id does not remove membership', () {
      final t = PlaylistRepository.mapCloudTrack(
          ptRow(position: 1, uuid: 'a3d2fe3c', videoId: null));
      expect(t, isNotNull, reason: 'a metadata gap must not delete a member');
      expect(t!.id, 'a3d2fe3c',
          reason: 'identity falls back to the catalog UUID');
    });

    test('an empty-string video id does not remove membership either', () {
      expect(
          PlaylistRepository.mapCloudTrack(
              ptRow(position: 1, uuid: 'a3d2fe3c', videoId: '')),
          isNotNull);
    });

    test('a matched track still uses its videoId — playback is unchanged', () {
      final t = PlaylistRepository.mapCloudTrack(
          ptRow(position: 1, uuid: 'u-bnb', videoId: 'ZQW96Jf12Z8'));
      expect(t!.id, 'ZQW96Jf12Z8');
    });

    test('missing optional metadata never changes cardinality', () {
      final rows = [
        ptRow(position: 1, uuid: 'x1', videoId: 'v1', artists: null),
        ptRow(position: 2, uuid: 'x2', videoId: 'v2', deezerId: null),
        ptRow(position: 3, uuid: 'x3', videoId: 'v3', duration: null),
        ptRow(position: 4, uuid: 'x4', videoId: 'v4', artwork: null),
        ptRow(position: 5, uuid: 'x5', videoId: null, artists: const []),
      ];
      final tracks = PlaylistRepository.membershipFromRows(rows);
      expect(tracks, hasLength(5));
      expect(tracks.map((t) => t.id), ['v1', 'v2', 'v3', 'v4', 'x5']);
    });

    test('only a row with genuinely no track identity is rejected', () {
      // No embedded track graph at all.
      expect(
          PlaylistRepository.mapCloudTrack({'position': 1, 'track_id': 'x'}),
          isNull);
      // A track graph with neither a video id nor a catalog id.
      expect(
        PlaylistRepository.mapCloudTrack({
          'position': 1,
          'track_id': 'x',
          'tracks': {'title': 'orphan'},
        }),
        isNull,
        reason: 'nothing can render, play, remove or reorder this',
      );
    });

    test('hydration cannot turn 6 authoritative rows into 4', () {
      final rows = sixAuthoritativeRows();
      // The OLD rule, stated once so the regression itself is pinned: keep the
      // row only when a YouTube match already exists.
      final underOldRule = rows
          .where((r) =>
              ((r['tracks'] as Map)['preferred_youtube_video_id'] ?? '')
                  .toString()
                  .isNotEmpty)
          .length;
      expect(underOldRule, 4, reason: 'this is what production did');
      expect(PlaylistRepository.membershipFromRows(rows), hasLength(6),
          reason: 'and this is what it must do now');
    });

    test('a repeated refresh is stable — cardinality never decays', () {
      final rows = sixAuthoritativeRows();
      for (var refresh = 0; refresh < 5; refresh++) {
        expect(PlaylistRepository.membershipFromRows(rows), hasLength(6));
      }
    });

    test('membership is ordered by playlist_tracks.position, not by arrival',
        () {
      final shuffled = sixAuthoritativeRows().reversed.toList();
      final tracks = PlaylistRepository.membershipFromRows(shuffled);
      expect(tracks.map((t) => t.title).toList(), [
        'BnB',
        'CLASSY 101',
        'WASSUP',
        'BIAF <3',
        'FINA',
        'Qué Pasaría...',
      ], reason: 'position is part of the membership contract');
    });

    test('every member keeps a unique id — dedupe/remove/reorder stay sound',
        () {
      final ids = PlaylistRepository.membershipFromRows(sixAuthoritativeRows())
          .map((t) => t.id)
          .toSet();
      expect(ids, hasLength(6));
    });

    test('collage and song count read the SAME membership', () {
      final tracks =
          PlaylistRepository.membershipFromRows(sixAuthoritativeRows());
      // The collage takes the first four of the authoritative list; the count is
      // that list's length. Both must come from one source, so a pending match
      // can never make them disagree.
      final collage = tracks.take(4).toList();
      expect(tracks.length, 6);
      expect(collage, hasLength(4));
      expect(collage.map((t) => t.title),
          ['BnB', 'CLASSY 101', 'WASSUP', 'BIAF <3']);
    });

    test('an unmatched track still carries its real metadata', () {
      final t = PlaylistRepository.mapCloudTrack(ptRow(
          position: 2, uuid: 'a3d2fe3c', videoId: null, title: 'CLASSY 101'));
      expect(t!.title, 'CLASSY 101');
      expect(t.artistName, 'Young Miko',
          reason: 'a placeholder member must not read as Unknown Artist');
    });
  });

  group('BUG 2 online — the newest authoritative version wins', () {
    test('THE FAILING REPRODUCTION: server 16, stale lane 1 → send 16', () {
      expect(PlaylistRepository.authoritativeVersion(1, 16), 16,
          reason: '`expected ?? expectedVersion` sent 1 and self-conflicted');
    });

    test('a stale SCREEN version cannot drag the lane backward', () {
      expect(PlaylistRepository.authoritativeVersion(16, 1), 16);
    });

    test('either source alone is used when it is the only one known', () {
      expect(PlaylistRepository.authoritativeVersion(null, 9), 9);
      expect(PlaylistRepository.authoritativeVersion(7, null), 7);
    });

    test('unknown on both sides asserts NO version', () {
      expect(PlaylistRepository.authoritativeVersion(null, null), isNull,
          reason: 'never fabricate a version — that was the earlier `1` bug');
    });

    test('optimistic concurrency is preserved — a real version is still sent',
        () {
      expect(PlaylistRepository.authoritativeVersion(16, 3), 16);
    });

    test('the real lane advances on a server response and never regresses',
        () async {
      final lane = PlaylistMutationLane();
      lane.recordVersion('u', 'p', 16);
      expect(lane.versionFor('u', 'p'), 16);
      lane.recordVersion('u', 'p', 3); // a late response from an older mutation
      expect(lane.versionFor('u', 'p'), 16, reason: 'monotonic by contract');
    });

    test('a successful mutation advances the lane for the next one', () async {
      final lane = PlaylistMutationLane();
      final seen = <int?>[];
      await lane.run<void>('u', 'p', (expected) async {
        seen.add(expected);
        return (result: null, version: 8); // server committed 8
      });
      await lane.run<void>('u', 'p', (expected) async {
        seen.add(expected);
        return (result: null, version: 9);
      });
      expect(seen, [null, 8], reason: 'add A → 8 persisted → add B expects 8');
      expect(lane.versionFor('u', 'p'), 9);
    });

    test('add/remove followed by reorder uses the newest version', () async {
      final lane = PlaylistMutationLane();
      lane.recordVersion('u', 'p', 4); // opening the playlist seeded 4
      await lane.run<void>('u', 'p', (_) async => (result: null, version: 5));
      await lane.run<void>('u', 'p', (_) async => (result: null, version: 6));
      // The screen still shows the version it loaded before those two edits.
      expect(
          PlaylistRepository.authoritativeVersion(
              lane.versionFor('u', 'p'), 4),
          6);
    });

    test('20 sequential mutations keep the version monotonically increasing',
        () async {
      final lane = PlaylistMutationLane();
      final expectedSeen = <int?>[];
      for (var server = 1; server <= 20; server++) {
        await lane.run<void>('u', 'p', (expected) async {
          expectedSeen.add(expected);
          return (result: null, version: server);
        });
        // A stale screen observation arrives between every mutation.
        expect(
            PlaylistRepository.authoritativeVersion(
                lane.versionFor('u', 'p'), 1),
            server);
      }
      expect(lane.versionFor('u', 'p'), 20);
      expect(expectedSeen.last, 19, reason: 'mutation 20 expected version 19');
    });
  });

  group('BUG 2 offline — a queued reorder rebases instead of self-conflicting',
      () {
    test('THE FAILING REPRODUCTION: queued with 1, server at 16 → sends 16',
        () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B', 'C', 'D', 'E'],
        savedVersion: 17,
      );
      final repo = repoWith(remote);

      final outcome = await repo.executeOp(
          reorderOp(['E', 'C', 'A', 'D', 'B'], expectedVersion: 1));

      expect(outcome, OpOutcome.success);
      expect(remote.saveOrderCalls, hasLength(1));
      expect(remote.saveOrderCalls.single.expectedVersion, 16,
          reason: 'the version captured while offline must not be trusted');
    });

    test('the intended order survives reconnect exactly', () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B', 'C', 'D', 'E'],
      );
      await repoWith(remote).executeOp(
          reorderOp(['E', 'C', 'A', 'D', 'B'], expectedVersion: 1));
      expect(remote.saveOrderCalls.single.ids, ['E', 'C', 'A', 'D', 'B'],
          reason: 'the journal carries the INTENT, not a snapshot of state');
    });

    test('a successful replay advances the mutation lane', () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B'],
        savedVersion: 17,
      );
      await repoWith(remote).executeOp(reorderOp(['B', 'A'], expectedVersion: 1));
      expect(PlaylistRepository.mutationLane.versionFor('user-1', 'p-1'), 17,
          reason: 'the next mutation must expect 17, not 16');
    });

    test('replay reads the authoritative version exactly once', () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B'],
      );
      await repoWith(remote).executeOp(reorderOp(['B', 'A'], expectedVersion: 1));
      expect(remote.fetchPlaylistCalls, 1, reason: 'no refetch loop');
    });

    test('exactly ONE save_order call per queued reorder — no duplicate activity',
        () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B'],
      );
      await repoWith(remote).executeOp(reorderOp(['B', 'A'], expectedVersion: 1));
      expect(remote.saveOrderCalls, hasLength(1));
    });

    test('membership changed while offline → terminal, and NOTHING is sent',
        () async {
      final remote = FakeRemote(
        playlistRow: {'id': 'p-1', 'version': 16},
        membership: ['A', 'B', 'C'], // a collaborator added C meanwhile
      );
      final repo = repoWith(remote);

      // Terminal by contract: the sync engine quarantines it and never retries.
      await expectLater(
          repo.executeOp(reorderOp(['B', 'A'], expectedVersion: 1)),
          throwsA(anything));
      expect(remote.saveOrderCalls, isEmpty,
          reason: 'a failed reorder must emit ZERO reorder activity');
    });

    test('a deleted / invisible playlist never gets a reorder pushed at it',
        () async {
      final remote = FakeRemote(playlistRow: null, membership: const []);
      final repo = repoWith(remote);
      await expectLater(
          repo.executeOp(reorderOp(['B', 'A'], expectedVersion: 1)),
          throwsA(anything));
      expect(remote.saveOrderCalls, isEmpty);
    });
  });

  group('the reorder replay decision table', () {
    test('same set → send, with the freshest version', () {
      final plan = PlaylistRepository.planSaveOrderReplay(
        intendedOrder: ['A', 'B', 'C'],
        serverMembership: ['C', 'A', 'B'],
        serverVersion: 16,
        laneVersion: 1,
      );
      expect(plan.action, SaveOrderReplayAction.send);
      expect(plan.expectedVersion, 16);
    });

    test('a fresher lane than the server read still wins', () {
      final plan = PlaylistRepository.planSaveOrderReplay(
        intendedOrder: ['A'],
        serverMembership: ['A'],
        serverVersion: 12,
        laneVersion: 14,
      );
      expect(plan.expectedVersion, 14);
    });

    test('an added track makes the intended order inapplicable', () {
      expect(
        PlaylistRepository.planSaveOrderReplay(
          intendedOrder: ['A', 'B'],
          serverMembership: ['A', 'B', 'C'],
          serverVersion: 16,
        ).action,
        SaveOrderReplayAction.membershipConflict,
      );
    });

    test('a removed track makes the intended order inapplicable', () {
      expect(
        PlaylistRepository.planSaveOrderReplay(
          intendedOrder: ['A', 'B', 'C'],
          serverMembership: ['A', 'B'],
          serverVersion: 16,
        ).action,
        SaveOrderReplayAction.membershipConflict,
      );
    });

    test('a swapped-for-foreign id of the same size is rejected', () {
      expect(
        PlaylistRepository.planSaveOrderReplay(
          intendedOrder: ['A', 'B', 'Z'],
          serverMembership: ['A', 'B', 'C'],
          serverVersion: 16,
        ).action,
        SaveOrderReplayAction.membershipConflict,
      );
    });

    test('a duplicated id is rejected — the RPC would raise ORDER_SET_MISMATCH',
        () {
      expect(
        PlaylistRepository.planSaveOrderReplay(
          intendedOrder: ['A', 'A', 'B'],
          serverMembership: ['A', 'B', 'C'],
          serverVersion: 16,
        ).action,
        SaveOrderReplayAction.membershipConflict,
      );
    });

    test('an unreadable playlist is `playlistGone`, not a blind push', () {
      expect(
        PlaylistRepository.planSaveOrderReplay(
          intendedOrder: ['A'],
          serverMembership: null,
          serverVersion: null,
        ).action,
        SaveOrderReplayAction.playlistGone,
      );
    });

    test('an unknown version asserts none rather than fabricating one', () {
      final plan = PlaylistRepository.planSaveOrderReplay(
        intendedOrder: ['A'],
        serverMembership: ['A'],
        serverVersion: null,
        laneVersion: null,
      );
      expect(plan.action, SaveOrderReplayAction.send);
      expect(plan.expectedVersion, isNull);
    });
  });

  group('hydration cannot undo a still-pending reorder', () {
    test('the local order survives an authoritative read', () {
      final merged = PlaylistRepository.preservePendingOrder(
        authoritative: [t('A'), t('B'), t('C'), t('D'), t('E')], // server order
        localOrder: [t('E'), t('C'), t('A'), t('D'), t('B')], // saved locally
      );
      expect(merged.map((t) => t.id), ['E', 'C', 'A', 'D', 'B'],
          reason: 'the old server order must not visibly replace the save');
    });

    test('server membership still wins — a new track appears', () {
      final merged = PlaylistRepository.preservePendingOrder(
        authoritative: [t('A'), t('B'), t('C'), t('NEW')],
        localOrder: [t('C'), t('A'), t('B')],
      );
      expect(merged.map((t) => t.id), ['C', 'A', 'B', 'NEW'],
          reason: 'membership is authoritative; only ORDER is deferred');
    });

    test('a remotely removed track does not come back', () {
      final merged = PlaylistRepository.preservePendingOrder(
        authoritative: [t('A'), t('B')],
        localOrder: [t('B'), t('GONE'), t('A')],
      );
      expect(merged.map((t) => t.id), ['B', 'A']);
    });

    test('cardinality always matches the authoritative list', () {
      final merged = PlaylistRepository.preservePendingOrder(
        authoritative: [t('A'), t('B'), t('C')],
        localOrder: const [],
      );
      expect(merged, hasLength(3));
    });
  });
}
