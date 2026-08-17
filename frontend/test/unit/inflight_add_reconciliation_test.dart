// test/unit/inflight_add_reconciliation_test.dart
//
// Phase 3.4.14 — THE OFFLINE TOP-TRACK ADD THAT DISAPPEARED AFTER RECONNECT.
//
// PROVEN IN PRODUCTION, not inferred. For playlist `biza`
// (73a91d11-e753-4c5e-b0ae-435a439c5a92):
//
//   tracks.created_at        15:44:29.207  ← the catalog row was INGESTED
//   playlist_tracks.added_at 15:44:29.476  ← 269 ms later the add committed
//   the tap that started it  ~15:42        ← two minutes earlier, while offline
//
// A journal replay NEVER ingests (it replays catalog UUIDs it already holds),
// so that ingest proves the add was a LIVE `addTracks` call that was still in
// flight the whole time the device was offline — hanging inside
// `_resolveOrThrow`'s ingest on a stalled socket. It also proves the add could
// not have been journaled: the UUID it needed did not exist yet, so
// `preservePendingAdds` (gated on a queued op) could never have protected it.
//
// Reconnect fires the connectivity observer, which flushes the journal and
// immediately hydrates — CONCURRENTLY with that still-running add. The
// authoritative read observes membership WITHOUT the track, nothing is queued,
// so reconciliation deleted the optimistic row. The add committed a few hundred
// milliseconds later: server right, UI wrong, and no later mutation could fix
// it (an online reorder then submits the UI's short membership and is rejected
// with ORDER_SET_MISMATCH — the "reorder behaves inconsistently" report).
//
// The fix is causal, not temporal: an add fence captured BEFORE the read, so
// reconciliation can ask "did any add overlap this snapshot?", plus canonical
// identity aliases so the optimistic copy (Track.id == videoId) and the
// authoritative copy (Track.id == catalog UUID, YouTube match still pending)
// are recognised as ONE track. No polling, no timers, no delays.
//
// Every test drives the REAL repository, the REAL journal (temp Hive box), the
// REAL sync engine and the REAL merge (`reconcileHydrated`). Only the network
// boundary is faked.

import 'dart:async';
import 'dart:io';

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/remote/catalog_resolver.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient('http://localhost:54321', 'test-key');

/// The catalog as the SERVER holds it, plus the device-local cache, modelled
/// exactly as the real resolver does: a lookup succeeds either from a cache
/// this device filled earlier, or from a query — and a query needs the network.
class FakeResolver extends CatalogResolver {
  FakeResolver() : super(_client());

  bool offline = false;

  /// deezer id → uuid, and videoId → uuid, as the catalog would answer.
  final Map<String, String> serverByDeezer = {};
  final Map<String, String> serverByVideo = {};

  /// What THIS DEVICE has recorded (survives going offline).
  final Map<String, String> cacheByDeezer = {};
  final Map<String, String> cacheByVideo = {};

  /// Held open to model the real production stall: the ingest request is
  /// already on the wire when connectivity drops, so it neither fails nor
  /// completes until the network comes back.
  Completer<void>? ingestGate;
  int ingestCalls = 0;

  /// Ingesting an album creates the catalog rows for [ingestCreates].
  final Map<String, ({String deezerId, String? videoId, String uuid})>
      ingestCreates = {};

  @override
  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) async {
    final out = <String, String>{};
    for (final raw in deezerIds.whereType<String>()) {
      final d = raw.trim();
      if (d.isEmpty) continue;
      final cached = cacheByDeezer[d];
      if (cached != null) {
        out[d] = cached;
        continue;
      }
      if (offline) continue; // a query cannot run — exactly the real behaviour
      final hit = serverByDeezer[d];
      if (hit != null) {
        cacheByDeezer[d] = hit;
        out[d] = hit;
      }
    }
    return out;
  }

  @override
  Future<Map<String, String>> resolveTracksByVideoId(
      Iterable<String?> videoIds) async {
    final out = <String, String>{};
    for (final raw in videoIds.whereType<String>()) {
      final v = raw.trim();
      if (v.isEmpty) continue;
      final cached = cacheByVideo[v];
      if (cached != null) {
        out[v] = cached;
        continue;
      }
      if (offline) continue;
      final hit = serverByVideo[v];
      if (hit != null) {
        cacheByVideo[v] = hit;
        out[v] = hit;
      }
    }
    return out;
  }

  @override
  Future<void> ingestAlbums(Iterable<String?> albumDeezerIds) async {
    ingestCalls++;
    final gate = ingestGate;
    if (gate != null) await gate.future; // stalled socket, then connectivity
    for (final entry in ingestCreates.values) {
      serverByDeezer[entry.deezerId] = entry.uuid;
      if (entry.videoId != null) serverByVideo[entry.videoId!] = entry.uuid;
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
  int version = 16;

  /// Server membership, in position order.
  List<String> membership = [];

  /// Catalog rows keyed by uuid, as `fetchTracks` would embed them.
  final Map<String, Map<String, dynamic>> catalog = {};

  final List<({List<String> ids, int? expectedVersion})> saveOrderCalls = [];
  final List<List<String>> addTracksCalls = [];

  /// Every read that hit the network, so a "storm" can be counted.
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
        {
          'position': i + 1,
          'track_id': uuid,
          'tracks': catalog[uuid],
        }
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCollaborators(String id) async {
    _net();
    reads++;
    return [];
  }

  @override
  Future<Map<String, String>> resolveUsernames(Iterable<String> ids) async {
    reads++;
    return {};
  }

  @override
  Future<Map<String, dynamic>> saveOrder(
      String id, List<String> ids, int? expectedVersion) async {
    _net();
    saveOrderCalls.add((ids: ids, expectedVersion: expectedVersion));
    // playlist_save_order requires an EXACT set — this is ORDER_SET_MISMATCH.
    final same = ids.toSet().length == ids.length &&
        ids.toSet().length == membership.toSet().length &&
        ids.toSet().containsAll(membership);
    if (!same) {
      throw const PlaylistRemoteException('ORDER_SET_MISMATCH');
    }
    if (expectedVersion != null && expectedVersion != version) {
      throw PlaylistConflictException(
          expectedVersion: expectedVersion, actualVersion: version);
    }
    membership = List.of(ids);
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

/// A catalog row exactly as production returns it. A freshly-ingested track has
/// NO `preferred_youtube_video_id` (`youtube_match_status = 'pending'`) — this
/// is what flips `Track.id` between the videoId and the catalog UUID.
Map<String, dynamic> catalogRow({
  required String uuid,
  required String deezerId,
  String? videoId,
  String title = 'Song',
  String artist = 'Bizarrap',
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
          'artists': {'id': 'a1', 'name': artist}
        }
      ],
    };

/// A local Track as an Artist Top Tracks row produces it: playback id IS the
/// YouTube videoId, Deezer identity alongside it.
Track topTrack(String deezerId,
        {required String videoId,
        String title = 'Song',
        String artist = 'Bizarrap'}) =>
    Track(
      id: videoId,
      title: title,
      artistName: artist,
      artistId: 'a1',
      artists: [
        {'name': artist, 'id': 'a1'}
      ],
      albumId: '900',
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
    final dir = await Directory.systemTemp.createTemp('paax_inflight_add');
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
      sleep: (_) async {}, // the real readiness loop, without real delays
    );
  });

  /// Seeds a playlist of already-catalogued, already-matched tracks and opens it
  /// online — which is what records their identities on this device.
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

  /// The Top Track from the report: NOT in the catalog, so adding it must ingest
  /// first, and the row it creates has no YouTube match yet.
  Track armUncataloguedTopTrack({
    String deezerId = '2304090785',
    String videoId = 'vid-peso',
    String uuid = 'uuid-peso',
    String title = 'Peso Pluma: Bzrp Music Sessions, Vol. 55/66',
  }) {
    resolver.ingestCreates[uuid] =
        (deezerId: deezerId, videoId: null, uuid: uuid);
    remote.catalog[uuid] = catalogRow(
        uuid: uuid, deezerId: deezerId, videoId: null, title: title);
    return topTrack(deezerId, videoId: videoId, title: title);
  }

  /// THE PRODUCTION RACE, deterministically: the add is in flight (stalled
  /// ingest), connectivity returns, the reconnect hydrate reads membership that
  /// does NOT contain the track yet, and the add commits before the merge runs.
  ///
  /// Returns the cached list, the (stale) authoritative list and the fence.
  Future<({List<Track> cached, List<Track> cloud, AddFence fence})>
      raceAddAgainstHydrate(List<Track> cached, Track added) async {
    final optimistic = [...cached, added]; // what Hive holds from the tap

    resolver.offline = true;
    remote.offline = true;
    resolver.ingestGate = Completer<void>();

    // The tap. It hangs inside _resolveOrThrow's ingest — no failure, no
    // journal op, nothing to roll back.
    final adding = repo.addTracks('p-1', [added]);
    await pumpEventQueue();

    // Reconnect: the connectivity observer flushes and hydrates.
    resolver.offline = false;
    remote.offline = false;
    final fence = repo.captureAddFence(); // BEFORE the read
    await repo.flushPending();
    final cloud = (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;

    // …and only now does the stalled add get its bytes through and commit.
    resolver.ingestGate!.complete();
    await adding;

    return (cached: optimistic, cloud: cloud, fence: fence);
  }

  group('1 — a committed in-flight Top Track add stays visible', () {
    test('optimistic videoId + authoritative catalog UUID → track survives',
        () async {
      final cached = await openOnline(4);
      final added = armUncataloguedTopTrack();

      final r = await raceAddAgainstHydrate(cached, added);

      expect(r.cloud, hasLength(4),
          reason: 'the read really did miss the add — this IS the race');
      expect(remote.membership, hasLength(5),
          reason: 'but the server committed it');

      final merged = await repo.reconcileHydrated(
        playlistId: 'p-1',
        cached: r.cached,
        cloud: r.cloud,
        fence: r.fence,
      );

      expect(merged, hasLength(5),
          reason: 'THE BUG: the user watched their add vanish after reconnect');
      expect(merged.last.title, contains('Peso Pluma'));
    });

    test('without the fence the row is lost — the defect is real', () async {
      final cached = await openOnline(4);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);

      // Exactly the previous behaviour: journal-gated only.
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: PlaylistRepository.reconcileTracks(
            cached: r.cached, cloud: r.cloud),
        cached: r.cached,
        hasPendingAdd: repo.hasPendingAdd('p-1'),
      );
      expect(repo.hasPendingAdd('p-1'), isFalse,
          reason: 'an un-catalogued track can never HAVE a queued op: the UUID '
              'it would carry does not exist while offline');
      expect(merged, hasLength(4), reason: 'this is what production did');
    });
  });

  group('2 — a journaled add whose op is already gone still survives', () {
    test('replayed and dequeued before the first reconciliation', () async {
      final cached = await openOnline(4);
      // Already catalogued, so the offline add CAN be journaled (PR #94 path).
      resolver.serverByDeezer['777'] = 'uuid-known';
      resolver.cacheByDeezer['777'] = 'uuid-known';
      remote.catalog['uuid-known'] =
          catalogRow(uuid: 'uuid-known', deezerId: '777', title: 'Known');
      final added = topTrack('777', videoId: 'vid-known', title: 'Known');
      final optimistic = [...cached, added];

      remote.offline = true;
      resolver.offline = true;
      await expectLater(repo.addTracks('p-1', [added]), throwsA(anything));
      expect(journal.pending('user-1'), hasLength(1));

      // Reconnect: read taken while the replay is still committing, so the op
      // has left the journal by the time the merge runs.
      remote.offline = false;
      resolver.offline = false;
      final fence = repo.captureAddFence();
      final cloud = (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      await repo.flushPending();

      expect(repo.hasPendingAdd('p-1'), isFalse, reason: 'op dequeued');
      final merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: optimistic, cloud: cloud, fence: fence);
      expect(merged, hasLength(5));
      expect(remote.membership, hasLength(5));
    });
  });

  group('3 — videoId → catalog UUID is ONE track, never two', () {
    test('no duplicate once the server reports the same song by UUID',
        () async {
      final cached = await openOnline(4);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);

      // A second hydrate — the server now returns the track, under its UUID,
      // while our cache still keys it by videoId.
      final fresh =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      expect(fresh.last.id, 'uuid-peso',
          reason: 'a pending YouTube match is reported by catalog UUID');
      expect(r.cached.last.id, 'vid-peso', reason: 'the cache still has videoId');

      final merged = await repo.reconcileHydrated(
        playlistId: 'p-1',
        cached: r.cached,
        cloud: fresh,
        // Still "overlapped" — the strictest case for duplication.
        fence: r.fence,
      );
      expect(merged, hasLength(5), reason: 'exactly one entry for the song');
      final keys = merged
          .map((t) => t.deezerTrackId ?? t.id)
          .toSet();
      expect(keys, hasLength(5), reason: 'and they are five DISTINCT songs');
    });
  });

  group('4 — metadata is preserved through the transition', () {
    test('title, artists, artwork and external ids all survive', () async {
      final cached = await openOnline(4);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);
      final fresh =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;

      final merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: r.cached, cloud: fresh, fence: r.fence);
      final song = merged.firstWhere((t) => t.title.contains('Peso Pluma'));

      expect(song.artistName, 'Bizarrap');
      expect(song.artists, isNotNull);
      expect(song.artworkUrl, isNotEmpty);
      expect(song.deezerTrackId, '2304090785');
      expect(merged.map((t) => t.artistName).every((a) => a.isNotEmpty), isTrue,
          reason: 'no Unknown Artist regression');
    });
  });

  group('5+6 — six tracks, a seventh added offline, then reorder', () {
    test('seven UI tracks and seven server rows after the first hydrate',
        () async {
      final cached = await openOnline(6);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);

      final merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: r.cached, cloud: r.cloud, fence: r.fence);

      expect(merged, hasLength(7));
      expect(remote.membership, hasLength(7));
    });

    test('an ONLINE reorder immediately after persists exactly, in one call',
        () async {
      final cached = await openOnline(6);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);
      final merged = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: r.cached, cloud: r.cloud, fence: r.fence);

      // The user drags the new track to the front and saves.
      final newOrder = [merged.last, ...merged.take(6)];
      await repo.saveOrder('p-1', newOrder, remote.version);

      expect(remote.saveOrderCalls, hasLength(1),
          reason: 'exactly one playlist_save_order');
      expect(remote.membership.first, 'uuid-peso');
      expect(remote.membership, hasLength(7));
    });

    test('the divergent state is what broke reorder — proven', () async {
      final cached = await openOnline(6);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);

      // Pre-fix membership: the UI kept six while the server holds seven.
      final divergent = PlaylistRepository.reconcileTracks(
          cached: r.cached, cloud: r.cloud);
      expect(divergent, hasLength(6));

      await expectLater(
        repo.saveOrder('p-1', divergent.reversed.toList(), remote.version),
        throwsA(anything),
        reason: 'ORDER_SET_MISMATCH: the server refuses a short membership, '
            'which is exactly why online reorder misbehaved while divergent',
      );
      expect(remote.membership.first, 'uuid-1',
          reason: 'and the DB positions were never updated');
    });
  });

  group('7 — repeated reconciliation is stable', () {
    test('20 refreshes after the commit never lose or duplicate the track',
        () async {
      final cached = await openOnline(6);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);

      var current = await repo.reconcileHydrated(
          playlistId: 'p-1', cached: r.cached, cloud: r.cloud, fence: r.fence);
      expect(current, hasLength(7));

      final readsBefore = remote.reads;
      for (var i = 0; i < 20; i++) {
        final fence = repo.captureAddFence();
        final cloud =
            (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
        current = await repo.reconcileHydrated(
            playlistId: 'p-1', cached: current, cloud: cloud, fence: fence);
        expect(current, hasLength(7), reason: 'stable at refresh $i');
      }
      expect(current.map((t) => t.id).toSet(), hasLength(7),
          reason: 'no duplicate identities accumulate');
      // No retry loop, no extra traffic: each refresh is the same three reads
      // hydration always did (tracks, collaborators, usernames) — the fence and
      // the alias table are pure local state.
      expect(remote.reads - readsBefore, 20 * 3);
    });

    test('the fence closes once no add overlaps the window', () async {
      final cached = await openOnline(4);
      final added = armUncataloguedTopTrack();
      final r = await raceAddAgainstHydrate(cached, added);
      expect(repo.addOverlapped('p-1', r.fence), isTrue);

      // A window opened after the add finished is NOT protected — a genuine
      // remote removal must still be able to remove the row.
      final later = repo.captureAddFence();
      expect(repo.addOverlapped('p-1', later), isFalse);
      final merged = await repo.reconcileHydrated(
          playlistId: 'p-1',
          cached: r.cached,
          cloud: r.cloud, // pretend the server no longer has it
          fence: later);
      expect(merged, hasLength(4),
          reason: 'the guard is bounded — it never pins membership forever');
    });
  });

  group('8+9 — nothing else changes', () {
    test('a plain offline add of a catalogued track behaves exactly as before',
        () async {
      final cached = await openOnline(2);
      resolver.cacheByDeezer['777'] = 'uuid-known';
      remote.catalog['uuid-known'] = catalogRow(
          uuid: 'uuid-known',
          deezerId: '777',
          videoId: 'vid-known',
          title: 'Known');
      final added = topTrack('777', videoId: 'vid-known', title: 'Known');

      remote.offline = true;
      await expectLater(repo.addTracks('p-1', [added]), throwsA(anything));
      expect(journal.pending('user-1'), hasLength(1),
          reason: 'still journaled for replay');
      expect(repo.hasPendingAdd('p-1'), isTrue);

      remote.offline = false;
      await repo.flushPending();
      expect(remote.addTracksCalls, [
        ['uuid-known']
      ]);
      expect(remote.membership, ['uuid-1', 'uuid-2', 'uuid-known']);
      final tracks =
          (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks;
      expect(tracks, hasLength(3));
      expect([...cached, added], hasLength(3));
    });

    test('an ONLINE Top Tracks add still ingests once and commits (PR #95)',
        () async {
      await openOnline(2);
      final added = armUncataloguedTopTrack();

      await repo.addTracks('p-1', [added]);

      expect(resolver.ingestCalls, 1, reason: 'one tap, one ingest');
      expect(remote.addTracksCalls, [
        ['uuid-peso']
      ]);
      expect(remote.membership, hasLength(3));
      expect(journal.pending('user-1'), isEmpty);
    });

    test('a REJECTED add is still rolled back, not preserved by the fence',
        () async {
      final cached = await openOnline(2);
      // No catalog row and no album id → unresolvable, permanently.
      final orphan = Track(
        id: 'vid-orphan',
        title: 'Orphan',
        artistName: 'X',
        albumId: '',
        albumTitle: '',
        artworkUrl: '',
        duration: 100,
      );
      final fence = repo.captureAddFence();
      await expectLater(repo.addTracks('p-1', [orphan]), throwsA(anything));

      // The caller reverts the optimistic row; reconciliation must agree.
      final merged = await repo.reconcileHydrated(
        playlistId: 'p-1',
        cached: cached, // already rolled back
        cloud: (await repo.hydrateEntity({'id': 'p-1', 'name': 'P'})).tracks,
        fence: fence,
      );
      expect(merged, hasLength(2));
      expect(journal.pending('user-1'), isEmpty);
    });
  });

  group('identity aliases — canonical UUID, derived not guessed', () {
    test('the same song keyed by videoId and by UUID shares one canonical key',
        () async {
      await openOnline(1);
      final local = topTrack('101', videoId: 'vid-1');
      final cloudCopy = Track(
        id: 'uuid-1', // pending match → reported by catalog UUID
        title: 'Track 1',
        artistName: '',
        albumId: '',
        albumTitle: '',
        artworkUrl: '',
        duration: 180,
      );
      final aliases = await repo.canonicalTrackUuids([local, cloudCopy]);
      expect(PlaylistRepository.trackKey(local, aliases),
          PlaylistRepository.trackKey(cloudCopy, aliases));
      expect(PlaylistRepository.trackKey(local, aliases), 'u:uuid-1');
    });

    test('with no alias known the previous keying is unchanged', () {
      final t = topTrack('101', videoId: 'vid-1');
      expect(PlaylistRepository.trackKey(t), 'd:101');
    });
  });
}
