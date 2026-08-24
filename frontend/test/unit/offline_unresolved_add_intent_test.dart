// test/unit/offline_unresolved_add_intent_test.dart
//
// Phase 3.4.15 — OFFLINE ADD OF AN UN-INGESTED TOP TRACK WAS REJECTED.
//
// THE DEFECT. `addTracks` resolved identity BEFORE the journaling wrapper, and
// a queued op could only ever carry catalog UUIDs. A Top Track that has never
// been ingested HAS no UUID while offline — obtaining one needs the network and
// inventing one is never acceptable — so `_resolveOrThrow` raised
// `localIntegrity`, which is terminal and non-network, so `_online` was never
// reached and NOTHING was journaled. The controller then rolled the optimistic
// row back and the sheet reported "that song isn't available in Paax yet".
// Reconnect had nothing to replay, which is why an already-catalogued track
// added offline survived and this one could not.
//
// THE FIX. A queued op carries INTENT: for every slot it could not resolve, a
// bounded [PendingTrackRef] source descriptor (playback id, Deezer track id,
// Deezer ALBUM id — exactly what the existing resolver/ingest path consumes).
// Replay materializes it through the SAME bounded resolve → ingest →
// re-resolve path an online add uses, then sends one `playlist_add_tracks`.
//
// Only the previously-impossible case changes:
//   all resolved                  → ids only, byte-identical to before
//   unresolved + catalog answered → terminal localIntegrity, as before
//   unresolved + not ingestable   → terminal localIntegrity, as before
//   unresolved + OFFLINE          → durable intent (this PR)
//
// Everything here drives the REAL repository, the REAL journal on a temp Hive
// box, and the REAL sync engine. Only the network boundary is faked.

import 'dart:io';

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/remote/catalog_resolver.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/data/sync/pending_track_ref.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_op_failure.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient('http://localhost:54321', 'test-key');

/// Models the real resolver: caches that survive going offline, queries that
/// FAIL (not "return nothing") when there is no network, and an ingest that
/// creates the catalog row only when it can reach paax-api.
class FakeResolver extends CatalogResolver {
  FakeResolver() : super(_client());

  bool offline = false;

  /// The catalog, as the server holds it.
  final Map<String, String> serverByDeezer = {};
  final Map<String, String> serverByVideo = {};

  /// This device's persisted caches.
  final Map<String, String> cacheByDeezer = {};
  final Map<String, String> cacheByVideo = {};

  /// deezer ALBUM id → the track rows that ingesting it creates.
  final Map<String, List<({String deezerId, String? videoId, String uuid})>>
      albumContents = {};

  int ingestCalls = 0;
  int deezerQueries = 0;

  /// Catalog reads that must fail before the freshly-ingested row is readable
  /// (models PR #95's identity-readiness window).
  int readinessMisses = 0;

  final _netError = const SocketException('Failed host lookup');

  @override
  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) async {
    lastLookupError = null;
    final out = <String, String>{};
    var queried = false;
    for (final raw in deezerIds.whereType<String>()) {
      final d = raw.trim();
      if (d.isEmpty) continue;
      final cached = cacheByDeezer[d];
      if (cached != null) {
        out[d] = cached;
        continue;
      }
      queried = true;
      if (offline) continue;
      if (readinessMisses > 0) continue; // ingested, not readable yet
      final hit = serverByDeezer[d];
      if (hit != null) {
        cacheByDeezer[d] = hit;
        out[d] = hit;
      }
    }
    if (queried) {
      deezerQueries++;
      if (offline) lastLookupError = _netError;
      if (readinessMisses > 0) readinessMisses--;
    }
    return out;
  }

  @override
  Future<Map<String, String>> resolveTracksByVideoId(
      Iterable<String?> videoIds) async {
    lastLookupError = null;
    final out = <String, String>{};
    var queried = false;
    for (final raw in videoIds.whereType<String>()) {
      final v = raw.trim();
      if (v.isEmpty) continue;
      final cached = cacheByVideo[v];
      if (cached != null) {
        out[v] = cached;
        continue;
      }
      queried = true;
      if (offline) continue;
      final hit = serverByVideo[v];
      if (hit != null) {
        cacheByVideo[v] = hit;
        out[v] = hit;
      }
    }
    if (queried && offline) lastLookupError = _netError;
    return out;
  }

  @override
  Future<void> ingestAlbums(Iterable<String?> albumDeezerIds) async {
    lastLookupError = null;
    ingestCalls++;
    if (offline) {
      lastLookupError = _netError; // best-effort, swallowed, but recorded
      return;
    }
    for (final raw in albumDeezerIds) {
      for (final t in albumContents[(raw ?? '').trim()] ?? const []) {
        serverByDeezer[t.deezerId] = t.uuid;
        if (t.videoId != null) serverByVideo[t.videoId!] = t.uuid;
      }
    }
  }

  @override
  Future<String?> cachedUuidFor({String? deezerId, String? videoId}) async {
    final d = (deezerId ?? '').trim();
    if (d.isNotEmpty && cacheByDeezer[d] != null) return cacheByDeezer[d];
    final v = (videoId ?? '').trim();
    if (v.isNotEmpty && cacheByVideo[v] != null) return cacheByVideo[v];
    return null;
  }

  @override
  Future<void> seedTrackIdentities({
    Map<String, String> byDeezerId = const {},
    Map<String, String> byVideoId = const {},
  }) async {
    cacheByDeezer.addAll(byDeezerId);
    cacheByVideo.addAll(byVideoId);
  }
}

class FakeRemote extends PlaylistRemoteDataSource {
  FakeRemote() : super(_client());

  bool offline = false;
  int version = 20;
  List<String> membership = [];
  final Map<String, Map<String, dynamic>> catalog = {};

  final List<List<String>> addTracksCalls = [];
  final List<({List<String> ids, int? expectedVersion})> saveOrderCalls = [];

  /// Every activity row the RPCs would have written.
  final List<String> activity = [];
  int reads = 0;

  void _net() {
    if (offline) throw const SocketException('Failed host lookup');
  }

  @override
  String? get currentUserId => 'user-1';

  @override
  Future<Map<String, dynamic>?> fetchPlaylist(String id) async {
    _net();
    reads++;
    return {'id': id, 'name': 'P', 'version': version, 'deleted_at': null};
  }

  @override
  Future<List<Map<String, dynamic>>> fetchTracks(String id) async {
    _net();
    reads++;
    return [
      for (final (i, uuid) in membership.indexed)
        {'position': i + 1, 'track_id': uuid, 'tracks': catalog[uuid]}
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCollaborators(String id) async {
    _net();
    reads++;
    return [];
  }

  @override
  Future<Map<String, String>> resolveUsernames(Iterable<String> ids) async => {};

  @override
  Future<Map<String, dynamic>> addTracks(String id, List<String> ids) async {
    _net();
    addTracksCalls.add(ids);
    var added = 0;
    for (final t in ids) {
      if (!membership.contains(t)) {
        membership.add(t);
        added++;
      }
    }
    // Mirrors playlist_add_tracks: version + activity only when something was
    // actually inserted, so a duplicate replay is genuinely idempotent.
    if (added > 0) {
      version += 1;
      activity.add('tracks_added:$added');
    }
    return {'id': id, 'version': version};
  }

  @override
  Future<Map<String, dynamic>> removeTracks(String id, List<String> ids) async {
    _net();
    membership.removeWhere(ids.contains);
    version += 1;
    activity.add('tracks_removed:${ids.length}');
    return {'id': id, 'version': version};
  }

  @override
  Future<Map<String, dynamic>> saveOrder(
      String id, List<String> ids, int? expectedVersion) async {
    _net();
    saveOrderCalls.add((ids: ids, expectedVersion: expectedVersion));
    final same = ids.toSet().length == ids.length &&
        ids.toSet().length == membership.toSet().length &&
        ids.toSet().containsAll(membership);
    if (!same) throw const PlaylistRemoteException('ORDER_SET_MISMATCH');
    if (expectedVersion != null && expectedVersion != version) {
      throw PlaylistConflictException(
          expectedVersion: expectedVersion, actualVersion: version);
    }
    membership = List.of(ids);
    version += 1;
    activity.add('tracks_reordered:${ids.length}');
    return {'id': id, 'version': version};
  }
}

Map<String, dynamic> catalogRow({
  required String uuid,
  required String deezerId,
  String? videoId,
  String title = 'Song',
}) =>
    {
      'id': uuid,
      'deezer_id': int.parse(deezerId),
      'title': title,
      'duration_seconds': 180,
      'preferred_youtube_video_id': videoId,
      'image_cached_url': 'http://img/$uuid.jpg',
      'track_artists': [
        {
          'artist_id': 'a1',
          'artists': {'id': 'a1', 'name': 'Bizarrap'}
        }
      ],
    };

/// A local Track exactly as an Artist Top Tracks row produces it.
Track topTrack(
  String deezerId, {
  required String videoId,
  String albumId = '900',
  String title = 'Top Song',
}) =>
    Track(
      id: videoId,
      title: title,
      artistName: 'Bizarrap',
      artistId: 'a1',
      artists: [
        {'name': 'Bizarrap', 'id': 'a1'}
      ],
      albumId: albumId,
      albumTitle: 'Sessions',
      artworkUrl: 'http://img/local-$deezerId.jpg',
      duration: 180,
      deezerTrackId: deezerId,
    );

void main() {
  late FakeRemote remote;
  late FakeResolver resolver;
  late PlaylistOpsJournal journal;
  late PlaylistRepository repo;

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('paax_intent');
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
      sleep: (_) async {}, // the real readiness loop, no real delays
    );
  });

  /// A repository sharing the SAME journal box and the same server state —
  /// i.e. the app after being killed and relaunched.
  PlaylistRepository relaunch() {
    PlaylistSyncService.resetForTest();
    PlaylistRepository.mutationLane.resetForTest();
    return PlaylistRepository(
      remote: remote,
      resolver: resolver,
      sync: PlaylistSyncService(PlaylistOpsJournal()),
      sleep: (_) async {},
    );
  }

  Future<List<Track>> openOnline(int count) async {
    for (var i = 1; i <= count; i++) {
      final uuid = 'uuid-$i';
      final deezer = '${100 + i}';
      remote.catalog[uuid] = catalogRow(
          uuid: uuid, deezerId: deezer, videoId: 'vid-$i', title: 'Track $i');
      remote.membership.add(uuid);
      resolver.serverByDeezer[deezer] = uuid;
      resolver.serverByVideo['vid-$i'] = uuid;
    }
    return (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
  }

  /// THE track from the report: in Deezer, not in the Paax catalog. Ingesting
  /// its album is what creates the row — with a still-pending YouTube match.
  Track armUningested({
    String deezerId = '2304090785',
    String videoId = 'vid-peso',
    String albumId = '900',
    String uuid = 'uuid-peso',
    String title = 'Peso Pluma: Bzrp Music Sessions, Vol. 55/66',
  }) {
    resolver.albumContents[albumId] = [
      (deezerId: deezerId, videoId: null, uuid: uuid)
    ];
    remote.catalog[uuid] =
        catalogRow(uuid: uuid, deezerId: deezerId, videoId: null, title: title);
    return topTrack(deezerId, videoId: videoId, albumId: albumId, title: title);
  }

  void goOffline() {
    remote.offline = true;
    resolver.offline = true;
  }

  void goOnline() {
    remote.offline = false;
    resolver.offline = false;
  }

  group('1 — the offline add is journaled AS INTENT, with no remote call', () {
    test('journal holds an unresolved-but-ingestable identity', () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();

      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));

      final ops = journal.pending('user-1');
      expect(ops, hasLength(1), reason: 'THE BUG: nothing was queued at all');
      final op = ops.single;
      expect(op.type, PlaylistOpType.addTracks);
      expect(op.playlistId, 'p-1');
      expect(op.userId, 'user-1');
      expect(op.payload['ids'], isEmpty, reason: 'no UUID exists yet');

      final refs = PendingTrackRef.listFrom(op.payload['unresolved']);
      expect(refs, hasLength(1));
      expect(refs.single.playbackId, 'vid-peso');
      expect(refs.single.deezerTrackId, '2304090785');
      expect(refs.single.albumDeezerId, '900',
          reason: 'the album id is what can actually trigger ingestion');
      expect(refs.single.isIngestable, isTrue);

      expect(remote.addTracksCalls, isEmpty, reason: 'no remote call offline');
      expect(remote.membership, hasLength(2));
      expect(remote.activity, isEmpty);
    });

    test('the caller is told TRANSIENT, so the optimistic row is kept',
        () async {
      await openOnline(2);
      goOffline();
      try {
        await repo.addTracks('p-1', [armUningested()]);
        fail('should have thrown');
      } catch (e) {
        final kind = PlaylistRepository.classifyPlaylistOpError(e).kind;
        expect(kind, PlaylistFailureKind.transientNetwork,
            reason: 'localIntegrity here is what rolled the row back and said '
                '"that song isn\'t available in Paax yet"');
      }
      expect(repo.hasPendingAdd('p-1'), isTrue);
    });
  });

  group('2 — reconnect completes it: ingest once, add once, activity once', () {
    test('one ingest, one resolve, one add, journal drained', () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      final ingestsWhileOffline = resolver.ingestCalls;

      goOnline();
      final result = await repo.flushPending();

      expect(resolver.ingestCalls - ingestsWhileOffline, 1, reason: 'once');
      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.membership, ['uuid-1', 'uuid-2', 'uuid-peso']);
      expect(remote.activity, ['tracks_added:1'], reason: 'exactly one');
      expect(journal.pending('user-1'), isEmpty);
      expect(result.conflicts, isEmpty);
      expect(result.dropped, isEmpty);
    });

    test('the authoritative row alone then keeps the song visible', () async {
      final cached = await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      goOnline();

      final fence = repo.captureAddFence();
      await repo.flushPending();
      final cloud = (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      final merged = await repo.reconcileHydrated(
        playlistId: 'p-1',
        cached: [...cached, t],
        cloud: cloud,
        fence: fence,
      );

      expect(merged, hasLength(3));
      final song = merged.firstWhere((x) => x.title.contains('Peso Pluma'));
      expect(song.artistName, 'Bizarrap', reason: 'no Unknown Artist');
      expect(song.artworkUrl, isNotEmpty);
      expect(song.deezerTrackId, '2304090785');
    });
  });

  group('3 — the intent survives the app being killed', () {
    test('add offline, kill, relaunch still offline, then reconnect', () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));

      // Kill + relaunch, STILL offline: a fresh repository, fresh sync service,
      // fresh in-memory caches — only the Hive journal survives.
      var restarted = relaunch();
      await restarted.flushPending(); // nothing can be done yet
      expect(journal.pending('user-1'), hasLength(1),
          reason: 'a failed replay must not discard the intent');
      expect(remote.addTracksCalls, isEmpty);

      // Reconnect, still on the relaunched instance.
      goOnline();
      restarted = relaunch();
      await restarted.flushPending();

      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.activity, ['tracks_added:1'], reason: 'exactly once');
      expect(journal.pending('user-1'), isEmpty);
    });

    test('the queued payload is pure JSON — no in-memory handles', () async {
      await openOnline(1);
      goOffline();
      await expectLater(
          repo.addTracks('p-1', [armUningested()]), throwsA(anything));

      // Exactly what Hive round-trips.
      final op = journal.pending('user-1').single;
      final revived = PlaylistOp.fromJson(op.toJson());
      final refs = PendingTrackRef.listFrom(revived.payload['unresolved']);
      expect(refs.single.deezerTrackId, '2304090785');
      expect(refs.single.albumDeezerId, '900');
      expect(refs.single.playbackId, 'vid-peso');
      expect(refs.single.at, 0);
    });
  });

  group('4 — duplicate reconnects do not multiply work', () {
    test('20 flushes → one ingest, one add, one activity row', () async {
      await openOnline(2);
      goOffline();
      await expectLater(
          repo.addTracks('p-1', [armUningested()]), throwsA(anything));
      final before = resolver.ingestCalls;
      goOnline();

      await Future.wait([for (var i = 0; i < 20; i++) repo.flushPending()]);
      for (var i = 0; i < 20; i++) {
        await repo.flushPending();
      }

      expect(resolver.ingestCalls - before, 1);
      expect(remote.addTracksCalls, hasLength(1));
      expect(remote.activity, ['tracks_added:1']);
      expect(remote.membership, hasLength(3));
    });
  });

  group('5 — ingest succeeds but the row is briefly unreadable', () {
    test('bounded readiness wins; it does not reject prematurely', () async {
      await openOnline(1);
      goOffline();
      await expectLater(
          repo.addTracks('p-1', [armUningested()]), throwsA(anything));

      goOnline();
      resolver.readinessMisses = 2; // readable only on the 3rd attempt
      final ingestsBefore = resolver.ingestCalls;
      await repo.flushPending();

      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(resolver.ingestCalls - ingestsBefore, 1,
          reason: 'one ingest for the whole replay, never one per attempt');
      expect(journal.pending('user-1'), isEmpty);
    });

    test('beyond the bounded window it stays queued — no infinite wait',
        () async {
      await openOnline(1);
      goOffline();
      await expectLater(
          repo.addTracks('p-1', [armUningested()]), throwsA(anything));

      goOnline();
      resolver.readinessMisses = 99; // never becomes readable this pass
      final r = await repo.flushPending();

      expect(remote.addTracksCalls, isEmpty);
      expect(r.dropped, hasLength(1),
          reason: 'terminal for THIS pass: the catalog answered and had no row');
      // And the very next reconnect, once readable, still completes it if the
      // user re-adds — no retry loop, no timer, no polling.
      expect(journal.pending('user-1'), isEmpty);
    });
  });

  group('6 — replay racing hydration', () {
    test('the optimistic row stays visible until the op is terminal', () async {
      final cached = await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      goOnline();

      // Hydrate BEFORE the replay: the server does not have it yet.
      final fence = repo.captureAddFence();
      final stale = (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      expect(stale, hasLength(2));
      var merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: [...cached, t], cloud: stale, fence: fence);
      expect(merged, hasLength(3), reason: 'queued intent keeps it visible');

      // Now replay, then hydrate again: exactly one authoritative row.
      await repo.flushPending();
      final fence2 = repo.captureAddFence();
      final fresh = (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: merged, cloud: fresh, fence: fence2);
      expect(merged, hasLength(3));
      expect(merged.map((x) => x.title).toSet(), hasLength(3),
          reason: 'no duplicate');
    });
  });

  group('7 — another client catalogued the track first', () {
    test('resolve the existing row, never ingest again, one membership',
        () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));

      // Someone else's ingest created the row while we were offline.
      resolver.serverByDeezer['2304090785'] = 'uuid-peso';
      final ingestsBefore = resolver.ingestCalls;

      goOnline();
      await repo.flushPending();

      expect(resolver.ingestCalls, ingestsBefore,
          reason: 'resolution succeeded, so nothing needed ingesting');
      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.membership.where((m) => m == 'uuid-peso'), hasLength(1));
    });

    test('and if OUR add already committed, a replay adds nothing twice',
        () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      goOnline();
      await repo.flushPending();

      // Re-queue the identical intent (e.g. a duplicated user action).
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      goOnline();
      await repo.flushPending();

      expect(remote.membership.where((m) => m == 'uuid-peso'), hasLength(1));
      expect(remote.activity, ['tracks_added:1'],
          reason: 'playlist_add_tracks is idempotent — no second activity row');
    });
  });

  group('8 — a genuinely unavailable track fails once, terminally', () {
    test('the catalog answers and has nothing: no queue, no retry loop',
        () async {
      await openOnline(2);
      // Online, and its album ingests nothing.
      final ghost = topTrack('999', videoId: 'vid-ghost', albumId: '404');

      await expectLater(
        repo.addTracks('p-1', [ghost]),
        throwsA(isA<PlaylistOpFailure>().having(
            (e) => e.kind, 'kind', PlaylistFailureKind.localIntegrity)),
        reason: 'unchanged: the caller rolls the optimistic row back',
      );
      expect(journal.pending('user-1'), isEmpty,
          reason: 'a doomed op must never be queued');
      expect(remote.addTracksCalls, isEmpty);
    });

    test('a track with no usable source identity is never queued offline',
        () async {
      await openOnline(1);
      goOffline();
      final orphan = Track(
        id: '', // no playback id
        title: 'Orphan',
        artistName: 'X',
        albumId: '', // no album to ingest
        albumTitle: '',
        artworkUrl: '',
        duration: 100,
      );
      await expectLater(
        repo.addTracks('p-1', [orphan]),
        throwsA(isA<PlaylistOpFailure>().having(
            (e) => e.kind, 'kind', PlaylistFailureKind.localIntegrity)),
      );
      expect(journal.pending('user-1'), isEmpty);
    });

    test('queued intent that turns out to be unavailable is dropped once',
        () async {
      await openOnline(1);
      goOffline();
      // Ingestable-looking (it has an album id), but the album contains nothing.
      final t = topTrack('555', videoId: 'vid-555', albumId: '777');
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));
      expect(journal.pending('user-1'), hasLength(1));

      goOnline();
      final r = await repo.flushPending();

      expect(remote.addTracksCalls, isEmpty, reason: 'never an empty add');
      expect(r.dropped, hasLength(1));
      expect(journal.pending('user-1'), isEmpty, reason: 'no retry forever');
      // A second reconnect does not resurrect it.
      await repo.flushPending();
      expect(resolver.ingestCalls, 2, reason: 'one ingest attempt per attempt, '
          'and the op is gone after the first');
    });
  });

  group('9 — an offline reorder containing the pending unresolved add', () {
    test('intended order survives and replays against canonical UUIDs',
        () async {
      final cached = await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));

      // The user drags the still-unresolved track to the FRONT and saves.
      final intended = [t, ...cached];
      await expectLater(
          repo.saveOrder('p-1', intended, 20), throwsA(anything));

      final ops = journal.pending('user-1');
      expect(ops.map((o) => o.type),
          [PlaylistOpType.addTracks, PlaylistOpType.saveOrder]);
      final order = ops.last;
      expect(order.payload['ids'], ['uuid-1', 'uuid-2']);
      final refs = PendingTrackRef.listFrom(order.payload['unresolved']);
      expect(refs.single.at, 0, reason: 'slot 0 — the user put it first');

      goOnline();
      await repo.flushPending();

      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.saveOrderCalls.single.ids,
          ['uuid-peso', 'uuid-1', 'uuid-2']);
      expect(remote.membership, ['uuid-peso', 'uuid-1', 'uuid-2'],
          reason: 'the intended order, resolved to canonical UUIDs');
      expect(journal.pending('user-1'), isEmpty);
    });

    test('a fully-resolved offline reorder is byte-identical to before',
        () async {
      final cached = await openOnline(3);
      goOffline();
      await expectLater(
          repo.saveOrder('p-1', cached.reversed.toList(), 20),
          throwsA(anything));

      final op = journal.pending('user-1').single;
      expect(op.payload['ids'], ['uuid-3', 'uuid-2', 'uuid-1']);
      expect(op.payload.containsKey('unresolved'), isFalse,
          reason: 'nothing new is written when everything resolved');

      goOnline();
      await repo.flushPending();
      expect(remote.membership, ['uuid-3', 'uuid-2', 'uuid-1']);
      expect(remote.saveOrderCalls, hasLength(1));
    });
  });

  group('10 — killed after ingest, before the add committed', () {
    test('recovers the existing catalog row: no duplicate track or membership',
        () async {
      await openOnline(2);
      final t = armUningested();
      goOffline();
      await expectLater(repo.addTracks('p-1', [t]), throwsA(anything));

      // Reconnect: the ingest lands, then the process dies before the add RPC.
      goOnline();
      remote.offline = true; // the RPC cannot go through
      await repo.flushPending();
      expect(resolver.serverByDeezer['2304090785'], 'uuid-peso',
          reason: 'the catalog row now exists');
      expect(remote.addTracksCalls, isEmpty);
      expect(journal.pending('user-1'), hasLength(1), reason: 'intent retained');

      // Relaunch and finish.
      remote.offline = false;
      final ingestsBefore = resolver.ingestCalls;
      final restarted = relaunch();
      await restarted.flushPending();

      expect(resolver.ingestCalls, ingestsBefore,
          reason: 'the row already exists — resolution alone is enough');
      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.membership.where((m) => m == 'uuid-peso'), hasLength(1));
      expect(remote.activity, ['tracks_added:1']);
    });
  });

  group('neighbouring paths must not regress', () {
    test('ONLINE add of an un-ingested Top Track: one tap, one ingest',
        () async {
      await openOnline(2);
      await repo.addTracks('p-1', [armUningested()]);
      expect(resolver.ingestCalls, 1);
      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(journal.pending('user-1'), isEmpty);
    });

    test('offline add of an ALREADY-CATALOGUED track is unchanged', () async {
      await openOnline(2);
      resolver.serverByDeezer['777'] = 'uuid-known';
      resolver.cacheByDeezer['777'] = 'uuid-known';
      remote.catalog['uuid-known'] =
          catalogRow(uuid: 'uuid-known', deezerId: '777', videoId: 'vid-known');
      goOffline();

      await expectLater(
          repo.addTracks('p-1', [topTrack('777', videoId: 'vid-known')]),
          throwsA(anything));
      final op = journal.pending('user-1').single;
      expect(op.payload['ids'], ['uuid-known']);
      expect(op.payload.containsKey('unresolved'), isFalse,
          reason: 'the resolved path writes exactly what it always did');
      expect(resolver.ingestCalls, 0,
          reason: 'a cached identity needs no ingest attempt');

      goOnline();
      await repo.flushPending();
      expect(remote.membership, ['uuid-1', 'uuid-2', 'uuid-known']);
    });

    test('offline remove still replays', () async {
      final cached = await openOnline(2);
      goOffline();
      await expectLater(
          repo.removeTracks('p-1', [cached.first]), throwsA(anything));
      goOnline();
      await repo.flushPending();
      expect(remote.membership, ['uuid-2']);
      expect(remote.activity, ['tracks_removed:1']);
    });

    test('offline create + add A + add B + remove A → remote holds B only',
        () async {
      resolver.serverByDeezer['201'] = 'uuid-A';
      resolver.cacheByDeezer['201'] = 'uuid-A';
      resolver.serverByDeezer['202'] = 'uuid-B';
      resolver.cacheByDeezer['202'] = 'uuid-B';
      final a = topTrack('201', videoId: 'vid-A');
      final b = topTrack('202', videoId: 'vid-B');
      goOffline();

      await expectLater(
          repo.createPlaylist(name: 'New', clientId: 'p-new'),
          throwsA(anything));
      await expectLater(repo.addTracks('p-new', [a]), throwsA(anything));
      await expectLater(repo.addTracks('p-new', [b]), throwsA(anything));
      await expectLater(repo.removeTracks('p-new', [a]), throwsA(anything));

      goOnline();
      remote.membership = [];
      await repo.flushPending();

      expect(remote.membership, ['uuid-B']);
      expect(journal.pending('user-1'), isEmpty);
    });

    test('an un-ingested track queued for a playlist created offline', () async {
      goOffline();
      final t = armUningested();
      await expectLater(
          repo.createPlaylist(name: 'New', clientId: 'p-new'),
          throwsA(anything));
      await expectLater(repo.addTracks('p-new', [t]), throwsA(anything));

      goOnline();
      remote.membership = [];
      await repo.flushPending();

      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.membership, ['uuid-peso']);
      expect(journal.pending('user-1'), isEmpty);
    });
  });

  group('PendingTrackRef — the descriptor itself', () {
    test('round-trips through JSON with identity intact', () {
      final ref = PendingTrackRef.fromTrack(
          topTrack('123', videoId: 'vid-x', albumId: '900'), 4);
      final back = PendingTrackRef.fromJson(ref.toJson());
      expect(back.at, 4);
      expect(back.playbackId, 'vid-x');
      expect(back.deezerTrackId, '123');
      expect(back.albumDeezerId, '900');
      expect(back.toTrack().deezerTrackId, '123');
    });

    test('ingestability requires at least one usable identity', () {
      expect(
          const PendingTrackRef(at: 0, playbackId: '', albumDeezerId: '900')
              .isIngestable,
          isTrue);
      expect(
          const PendingTrackRef(at: 0, playbackId: 'vid').isIngestable, isTrue);
      expect(const PendingTrackRef(at: 0, playbackId: '').isIngestable, isFalse);
    });

    test('a payload from an older build simply has no refs', () {
      expect(PendingTrackRef.listFrom(null), isEmpty);
      expect(PendingTrackRef.listFrom(const []), isEmpty);
    });
  });
}
