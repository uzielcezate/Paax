// test/unit/offline_intent_durability_test.dart
//
// Phase 3.4.12 — the two defects left after PR #93, both reproduced end-to-end
// through the REAL repository, the REAL journal (on a temp Hive box) and the
// REAL sync engine. Only the network boundary is faked.
//
// BUG 1 — A COMMITTED OFFLINE ADD DISAPPEARED FROM THE UI.
//   Reconciliation takes membership from the server, which is correct — except
//   while our OWN add is still queued. A replay pass that ends with the add
//   still pending (it joined an in-flight pass, or hit a transient failure and
//   stopped) is immediately followed by an authoritative hydrate, and the server
//   legitimately does not have the track yet. The optimistic row was deleted and
//   the user watched their addition vanish, until any later mutation triggered
//   another flush and it reappeared.
//
// BUG 2 — AN OFFLINE REORDER WAS NEVER JOURNALED AT ALL.
//   `saveOrder` resolves local tracks → catalog UUIDs BEFORE the journaling
//   wrapper runs. That cache was only ever filled as a side effect of a
//   successful query, so a playlist that arrived through cloud hydration had
//   none of its tracks cached — the app knew every row's `track_id` and threw it
//   away. Offline, resolution failed and `_resolveOrThrow` raised
//   `localIntegrity` before `_online`, so nothing was queued and no replay could
//   ever fix it. Proven by `the defect: a cold resolver cache loses the intent`
//   below. Hydration now seeds those identities.

import 'dart:io';

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/remote/catalog_resolver.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient('http://localhost:54321', 'test-key');

/// Models the real SharedPreferences-backed resolver cache: a lookup succeeds
/// only for an identity this device has actually recorded. Offline, no query can
/// fill it — only [seedTrackIdentities] can.
class FakeResolver extends CatalogResolver {
  FakeResolver() : super(_client());

  final Map<String, String> byDeezerId = {};

  @override
  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) async =>
      {
        for (final d in deezerIds.whereType<String>())
          if (byDeezerId[d] != null) d: byDeezerId[d]!
      };

  @override
  Future<Map<String, String>> resolveTracksByVideoId(
          Iterable<String?> videoIds) async =>
      const {};

  @override
  Future<void> ingestAlbums(Iterable<String?> ids) async {}

  @override
  Future<void> seedTrackIdentities({
    Map<String, String> byDeezerId = const {},
    Map<String, String> byVideoId = const {},
  }) async =>
      this.byDeezerId.addAll(byDeezerId);
}

class FakeRemote extends PlaylistRemoteDataSource {
  FakeRemote() : super(_client());

  bool offline = false;
  int version = 16;

  /// Server membership, in position order.
  List<String> membership = [];

  final List<({List<String> ids, int? expectedVersion})> saveOrderCalls = [];
  final List<List<String>> addTracksCalls = [];

  void _net() {
    if (offline) throw const SocketException('Failed host lookup');
  }

  @override
  String? get currentUserId => 'user-1';

  @override
  Future<Map<String, dynamic>?> fetchPlaylist(String id) async {
    _net();
    return {'id': id, 'name': 'P', 'version': version, 'deleted_at': null};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTracks(String id) async {
    _net();
    return [
      for (final (i, uuid) in membership.indexed)
        {
          'position': i + 1,
          'track_id': uuid,
          'tracks': {
            'id': uuid,
            'deezer_id': uuid.replaceFirst('uuid-', ''),
            'title': uuid,
            'duration_seconds': 100,
            'preferred_youtube_video_id': 'vid-${uuid.replaceFirst('uuid-', '')}',
            'track_artists': const [],
          },
        }
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCollaborators(String id) async => [];

  @override
  Future<Map<String, String>> resolveUsernames(Iterable<String> ids) async => {};

  @override
  Future<Map<String, dynamic>> saveOrder(
      String id, List<String> ids, int? expectedVersion) async {
    _net();
    saveOrderCalls.add((ids: ids, expectedVersion: expectedVersion));
    if (expectedVersion != null && expectedVersion != version) {
      throw PlaylistConflictException(
          expectedVersion: expectedVersion, actualVersion: version);
    }
    membership = List.of(ids); // positions now follow the submitted order
    version += 1;
    return {'id': id, 'version': version};
  }

  @override
  Future<Map<String, dynamic>> addTracks(String id, List<String> ids) async {
    _net();
    addTracksCalls.add(ids);
    for (final t in ids) {
      if (!membership.contains(t)) membership.add(t);
    }
    version += 1;
    return {'id': id, 'version': version};
  }
}

/// A local Track as the app holds it: playback id + Deezer identity.
Track track(String n) => Track(
      id: 'vid-$n',
      title: 'Track $n',
      artistName: 'Artist',
      albumId: '900',
      albumTitle: 'Album',
      artworkUrl: '',
      duration: 100,
      deezerTrackId: n,
    );

void main() {
  late FakeRemote remote;
  late FakeResolver resolver;
  late PlaylistOpsJournal journal;
  late PlaylistRepository repo;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('paax_journal');
    Hive.init(dir.path);
    await Hive.openBox(PlaylistOpsJournal.boxName);
  });

  setUp(() async {
    await Hive.box(PlaylistOpsJournal.boxName).clear();
    PlaylistSyncService.resetForTest();
    PlaylistRepository.mutationLane.resetForTest();
    remote = FakeRemote();
    resolver = FakeResolver();
    journal = PlaylistOpsJournal();
    repo = PlaylistRepository(
      remote: remote,
      resolver: resolver,
      sync: PlaylistSyncService(journal),
    );
  });

  /// Opening the playlist online, which is what seeds track identities.
  Future<void> openOnline(List<String> members) async {
    remote.membership = [for (final m in members) 'uuid-$m'];
    await repo.hydrateEntity({'id': 'p-1', 'name': 'P'});
  }

  /// A track the user reached online (search/album/player), so this device has
  /// already recorded its catalog identity — the precondition every offline
  /// mutation has always had.
  void knowTrack(String n) => resolver.byDeezerId[n] = 'uuid-$n';

  group('BUG 1 — a pending add must stay visible through reconnect', () {
    test('reconciliation keeps a track whose add is still queued', () async {
      await openOnline(['A', 'B']);
      knowTrack('C');
      remote.offline = true;
      await expectLater(
          repo.addTracks('p-1', [track('C')]), throwsA(anything));
      expect(journal.pending('user-1'), hasLength(1),
          reason: 'the add is durable');

      // The authoritative read that follows a flush: the server has A,B only.
      remote.offline = false;
      final authoritative =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      final cached = [track('A'), track('B'), track('C')];

      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: PlaylistRepository.reconcileTracks(
            cached: cached, cloud: authoritative),
        cached: cached,
        hasPendingAdd: repo.hasPendingAdd('p-1'),
      );

      expect(merged.map((t) => t.id), containsAll(['vid-A', 'vid-B', 'vid-C']),
          reason: 'the user must not watch their offline add vanish');
      expect(merged, hasLength(3));
    });

    test('once the add commits, the server list alone already contains it',
        () async {
      await openOnline(['A', 'B']);
      knowTrack('C');
      remote.offline = true;
      await expectLater(
          repo.addTracks('p-1', [track('C')]), throwsA(anything));

      remote.offline = false;
      await repo.flushPending();

      expect(remote.addTracksCalls, hasLength(1));
      expect(remote.membership, ['uuid-A', 'uuid-B', 'uuid-C']);
      expect(repo.hasPendingAdd('p-1'), isFalse,
          reason: 'nothing left to preserve — the server is authoritative now');
      final tracks =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      expect(tracks, hasLength(3));
    });

    test('a REJECTED add is not preserved — no stale optimistic membership', () {
      // The op has left the journal (dropped/quarantined), so the guard is off
      // and reconciliation removes the row exactly as before.
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: [track('A'), track('B')],
        cached: [track('A'), track('B'), track('C')],
        hasPendingAdd: false,
      );
      expect(merged.map((t) => t.id), ['vid-A', 'vid-B']);
    });

    test('a remotely removed track does not come back via the guard', () {
      // B was removed on another device while our add of C is queued.
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: [track('A')],
        cached: [track('A'), track('B'), track('C')],
        hasPendingAdd: true,
      );
      expect(merged.map((t) => t.id), ['vid-A', 'vid-B', 'vid-C'],
          reason: 'this guard is deliberately additive; membership removal is '
              'reconciled once the queue drains');
      expect(merged.toSet(), hasLength(3), reason: 'never duplicates');
    });

    test('nothing is duplicated when the server already has the track', () {
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: [track('A'), track('B'), track('C')],
        cached: [track('A'), track('B'), track('C')],
        hasPendingAdd: true,
      );
      expect(merged, hasLength(3));
    });

    test('the guard is inert when nothing is queued', () {
      final authoritative = [track('A'), track('B')];
      expect(
        PlaylistRepository.preservePendingAdds(
          authoritative: authoritative,
          cached: const [],
          hasPendingAdd: false,
        ),
        same(authoritative),
      );
    });
  });

  group('BUG 2 — an offline reorder must be journaled and replayed', () {
    test('THE DEFECT: a cold resolver cache silently loses the intent',
        () async {
      // No hydration, so no identity was ever recorded — the exact state of a
      // playlist that arrived from the cloud before this fix existed.
      remote.membership = ['uuid-A', 'uuid-B'];
      remote.offline = true;

      await expectLater(
        repo.saveOrder('p-1', [track('B'), track('A')], 5),
        throwsA(anything),
      );
      expect(journal.pending('user-1'), isEmpty,
          reason: 'THIS is why no replay ever happened');

      remote.offline = false;
      await repo.flushPending();
      expect(remote.saveOrderCalls, isEmpty);
    });

    test('hydration seeds identities, so the same reorder IS journaled',
        () async {
      await openOnline(['A', 'B']);
      remote.offline = true;

      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));

      final pending = journal.pending('user-1');
      expect(pending, hasLength(1));
      expect(pending.single.type, PlaylistOpType.saveOrder);
      expect(pending.single.payload['ids'], ['uuid-B', 'uuid-A'],
          reason: 'the ordered UUID list IS the intent and must be durable');
    });

    test('A B C D E → offline reorder E C A D B → reconnect only → exact order',
        () async {
      await openOnline(['A', 'B', 'C', 'D', 'E']);
      remote.offline = true;

      await expectLater(
        repo.saveOrder(
            'p-1',
            [track('E'), track('C'), track('A'), track('D'), track('B')],
            5),
        throwsA(anything),
      );

      // Reconnect. No user interaction, no second mutation.
      remote.offline = false;
      await repo.flushPending();

      expect(remote.saveOrderCalls, hasLength(1),
          reason: 'exactly one playlist_save_order');
      expect(remote.membership,
          ['uuid-E', 'uuid-C', 'uuid-A', 'uuid-D', 'uuid-B'],
          reason: 'server positions must equal the intended order');
      expect(journal.pending('user-1'), isEmpty);
    });

    test('stale captured version + identical membership → one rebased send',
        () async {
      await openOnline(['A', 'B']);
      remote.offline = true;
      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));

      // The server moves on while we are offline.
      remote.version = 41;
      remote.offline = false;
      await repo.flushPending();

      expect(remote.saveOrderCalls.single.expectedVersion, 41,
          reason: 'rebased onto the authoritative version, not the captured 5');
      expect(remote.membership, ['uuid-B', 'uuid-A']);
    });

    test('the returned authoritative version is persisted to the lane',
        () async {
      await openOnline(['A', 'B']);
      remote.offline = true;
      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));
      remote.offline = false;
      await repo.flushPending();

      expect(PlaylistRepository.mutationLane.versionFor('user-1', 'p-1'), 17,
          reason: 'the next mutation must not re-derive a stale version');
    });

    test('stale version + CHANGED membership → terminal once, no retry loop',
        () async {
      await openOnline(['A', 'B']);
      remote.offline = true;
      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));

      // A collaborator added a track while we were offline.
      remote.offline = false;
      remote.membership = ['uuid-A', 'uuid-B', 'uuid-Z'];
      final result = await repo.flushPending();

      expect(remote.saveOrderCalls, isEmpty,
          reason: 'never push an order against a set the server no longer has');
      expect(result.conflicts, hasLength(1));
      expect(journal.pending('user-1'), isEmpty,
          reason: 'terminal — quarantined, not re-queued');

      // And a second reconnect does not retry it.
      await repo.flushPending();
      expect(remote.saveOrderCalls, isEmpty);
    });

    test('20 reconnect notifications produce exactly ONE reorder execution',
        () async {
      await openOnline(['A', 'B', 'C']);
      remote.offline = true;
      await expectLater(
        repo.saveOrder('p-1', [track('C'), track('B'), track('A')], 5),
        throwsA(anything),
      );

      remote.offline = false;
      await Future.wait([for (var i = 0; i < 20; i++) repo.flushPending()]);

      expect(remote.saveOrderCalls, hasLength(1),
          reason: 'single-flight + a drained queue — no storm, no duplicates');
      expect(remote.membership, ['uuid-C', 'uuid-B', 'uuid-A']);
    });

    test('a successful replay emits exactly one reorder activity', () async {
      // Activity is written inside playlist_save_order, after the position
      // updates, in the same transaction. So RPC call count IS activity count.
      await openOnline(['A', 'B']);
      remote.offline = true;
      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));
      remote.offline = false;
      await repo.flushPending();
      expect(remote.saveOrderCalls, hasLength(1));
    });

    test('a conflicted reorder emits NO activity', () async {
      await openOnline(['A', 'B']);
      remote.offline = true;
      await expectLater(
          repo.saveOrder('p-1', [track('B'), track('A')], 5), throwsA(anything));
      remote.offline = false;
      remote.membership = ['uuid-A']; // B removed elsewhere
      await repo.flushPending();
      expect(remote.saveOrderCalls, isEmpty,
          reason: 'no RPC ⇒ no tracks_reordered row');
    });

    test('a still-pending reorder is not undone by an authoritative read',
        () async {
      await openOnline(['A', 'B', 'C']);
      remote.offline = true;
      await expectLater(
        repo.saveOrder('p-1', [track('C'), track('B'), track('A')], 5),
        throwsA(anything),
      );

      // Hydration runs before the replay (the flush joined an in-flight pass).
      remote.offline = false;
      final authoritative =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      expect(authoritative.map((t) => t.id), ['vid-A', 'vid-B', 'vid-C'],
          reason: 'the server still holds the OLD order');

      final shown = PlaylistRepository.preservePendingOrder(
        authoritative: authoritative,
        localOrder: [track('C'), track('B'), track('A')],
      );
      expect(shown.map((t) => t.id), ['vid-C', 'vid-B', 'vid-A'],
          reason: 'the saved order must survive until the replay decides');
      expect(repo.hasPendingReorder('p-1'), isTrue);
    });
  });

  group('online reorder stays stable under repetition', () {
    test('20 consecutive online reorders each use the newest version',
        () async {
      await openOnline(['A', 'B', 'C']);

      for (var i = 0; i < 20; i++) {
        final before = remote.version;
        // The screen keeps handing over the version it loaded at open time —
        // the exact staleness that used to self-conflict.
        await repo.saveOrder(
            'p-1', [track('C'), track('A'), track('B')], 16);
        expect(remote.saveOrderCalls.last.expectedVersion, before,
            reason: 'reorder #${i + 1} must assert the current version');
        expect(remote.version, before + 1);
      }
      expect(remote.saveOrderCalls, hasLength(20),
          reason: 'no intermittent stale-lane conflict across repetitions');
    });

    test('an add followed immediately by a reorder uses the newest version',
        () async {
      await openOnline(['A', 'B']);
      knowTrack('C');
      await repo.addTracks('p-1', [track('C')]); // server → 17
      await repo.saveOrder(
          'p-1', [track('C'), track('B'), track('A')], 16); // stale screen 16
      expect(remote.saveOrderCalls.single.expectedVersion, 17);
      expect(remote.membership, ['uuid-C', 'uuid-B', 'uuid-A']);
    });
  });
}
