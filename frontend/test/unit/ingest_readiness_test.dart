// test/unit/ingest_readiness_test.dart
//
// Phase 3.4.13 — a track that needs on-demand ingestion had a transient
// inconsistent state. Every test drives the REAL production code
// (`PlaylistRepository`, its real resolve/ingest sequence, `trackKey`,
// `reconcileTracks`, `preservePendingAdds`, `preservePendingOrder`).
//
// DEFECT 1 — THE FIRST TAP ONLY PREPARED THE CATALOG.
//   `_resolveOrThrow` ingested the missing album and then re-resolved EXACTLY
//   ONCE, immediately. Ingestion returns as soon as paax-api answers, but the
//   rows it upserts are not always readable by the very next query — so the
//   first Add failed with "Couldn't add…" having only made the row exist, and
//   the second identical tap succeeded. One tap is now one bounded logical
//   operation.
//
// DEFECT 2 — IDENTITY IS NOT STABLE ACROSS A PENDING MATCH.
//   `Track.id` is the YouTube videoId when one exists and the catalog UUID while
//   the match is pending, so the SAME song changes id the moment matching
//   completes. Reconciliation keyed on `id` therefore treated the cached and
//   cloud copies as different songs: metadata was dropped and the membership
//   guards could double-count. `trackKey` keys on the Deezer id both sides carry.

import 'package:beaty/data/remote/catalog_resolver.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient('http://localhost:54321', 'test-key');

/// A catalog that only knows a track AFTER its album is ingested — and, like
/// production, not on the very first read that follows the ingest.
class IngestingResolver extends CatalogResolver {
  IngestingResolver({this.readsBeforeVisible = 1}) : super(_client());

  /// How many post-ingest reads still miss before the row becomes readable.
  final int readsBeforeVisible;

  final Map<String, String> known = {};
  int ingestCalls = 0;
  int resolveCalls = 0;
  int _readsSinceIngest = 0;
  final Set<String> _ingestedAlbums = {};

  @override
  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) async {
    resolveCalls++;
    if (_ingestedAlbums.isNotEmpty) {
      if (_readsSinceIngest >= readsBeforeVisible) {
        for (final d in deezerIds.whereType<String>()) {
          known[d] = 'uuid-$d';
        }
      }
      _readsSinceIngest++;
    }
    return {
      for (final d in deezerIds.whereType<String>())
        if (known[d] != null) d: known[d]!
    };
  }

  @override
  Future<Map<String, String>> resolveTracksByVideoId(
          Iterable<String?> videoIds) async =>
      const {};

  @override
  Future<void> ingestAlbums(Iterable<String?> ids) async {
    ingestCalls++;
    _ingestedAlbums.addAll(ids.whereType<String>());
    _readsSinceIngest = 0;
  }

  @override
  Future<void> seedTrackIdentities({
    Map<String, String> byDeezerId = const {},
    Map<String, String> byVideoId = const {},
  }) async =>
      known.addAll(byDeezerId);
}

class FakeRemote extends PlaylistRemoteDataSource {
  FakeRemote() : super(_client());

  int version = 4;
  List<String> membership = [];
  final List<List<String>> addTracksCalls = [];

  @override
  String? get currentUserId => 'user-1';

  @override
  Future<Map<String, dynamic>> addTracks(String id, List<String> ids) async {
    addTracksCalls.add(ids);
    for (final t in ids) {
      if (!membership.contains(t)) membership.add(t);
    }
    version += 1;
    return {'id': id, 'version': version};
  }

  @override
  Future<Map<String, dynamic>?> fetchPlaylist(String id) async =>
      {'id': id, 'version': version};
}

/// A Top Tracks entry: real Deezer identity, videoId as the playback id.
Track topTrack(String n, {String album = '900'}) => Track(
      id: 'vid-$n',
      title: 'Track $n',
      artistName: 'Young Miko',
      albumId: album,
      albumTitle: 'Album',
      artworkUrl: '',
      duration: 100,
      deezerTrackId: n,
    );

/// The same song as the server reports it while its YouTube match is pending:
/// identified by the catalog UUID, no videoId, minimal metadata.
Track pendingCloudCopy(String n) => Track(
      id: 'uuid-$n',
      title: 'Track $n',
      artistName: '',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: 100,
      deezerTrackId: n,
    );

void main() {
  group('DEFECT 1 — one Add tap must be one bounded operation', () {
    test('a track needing ingestion is added on the FIRST tap', () async {
      final resolver = IngestingResolver(); // invisible on the first read back
      final remote = FakeRemote();
      final repo = PlaylistRepository(
        remote: remote,
        resolver: resolver,
        sleep: (_) async {}, // no real waiting in tests
      );

      await repo.addTracks('p-1', [topTrack('101')]);

      expect(remote.addTracksCalls, hasLength(1),
          reason: 'the user must not have to tap Add twice');
      expect(remote.addTracksCalls.single, ['uuid-101']);
      expect(resolver.ingestCalls, 1, reason: 'ingest exactly once');
    });

    test('the first tap does not fail merely because ingest was needed',
        () async {
      final repo = PlaylistRepository(
        remote: FakeRemote(),
        resolver: IngestingResolver(readsBeforeVisible: 2),
        sleep: (_) async {},
      );
      // Would have thrown localIntegrity ("Couldn't add…") before the fix.
      await expectLater(repo.addTracks('p-1', [topTrack('101')]), completes);
    });

    test('3–5 fresh tracks added in sequence each commit on their first tap',
        () async {
      final remote = FakeRemote();
      final resolver = IngestingResolver();
      final repo = PlaylistRepository(
          remote: remote, resolver: resolver, sleep: (_) async {});

      for (final n in ['201', '202', '203', '204', '205']) {
        await repo.addTracks('p-1', [topTrack(n, album: '9$n')]);
      }
      expect(remote.addTracksCalls, hasLength(5));
      expect(remote.membership,
          ['uuid-201', 'uuid-202', 'uuid-203', 'uuid-204', 'uuid-205']);
    });

    test('the wait is BOUNDED — a genuinely absent track still fails', () async {
      final resolver = IngestingResolver(readsBeforeVisible: 999);
      final repo = PlaylistRepository(
        remote: FakeRemote(),
        resolver: resolver,
        sleep: (_) async {},
      );

      await expectLater(
          repo.addTracks('p-1', [topTrack('404')]), throwsA(anything),
          reason: 'never an unbounded poll loop');
      expect(resolver.ingestCalls, 1, reason: 'ingest is never repeated');
      expect(resolver.resolveCalls, lessThanOrEqualTo(5),
          reason: 'a strictly bounded number of attempts');
    });

    test('a track already in the catalog never triggers an ingest', () async {
      final resolver = IngestingResolver()..known['777'] = 'uuid-777';
      final repo = PlaylistRepository(
          remote: FakeRemote(), resolver: resolver, sleep: (_) async {});

      await repo.addTracks('p-1', [topTrack('777')]);
      expect(resolver.ingestCalls, 0);
      expect(resolver.resolveCalls, 1, reason: 'the fast path is untouched');
    });
  });

  group('DEFECT 2 — pending playback metadata is not invalid membership', () {
    test('the same song keeps ONE identity across a pending match', () {
      expect(PlaylistRepository.trackKey(topTrack('101')),
          PlaylistRepository.trackKey(pendingCloudCopy('101')),
          reason: 'videoId ⇄ catalog UUID must not read as two songs');
    });

    test('a track with no Deezer id still has a stable key', () {
      final t = Track(
          id: 'vid-x',
          title: '',
          artistName: '',
          albumId: '',
          albumTitle: '',
          artworkUrl: '',
          duration: 0);
      expect(PlaylistRepository.trackKey(t), 'i:vid-x');
    });

    test('a cloud row with NO deezer_id still matches its cached copy', () {
      // Matching must try BOTH identities: keying only on the Deezer id would
      // stop a metadata-less cloud row from finding its rich local copy, which
      // is the Unknown-Artist bug in a new disguise.
      final cloudNoDeezer = Track(
        id: 'vid-101', // same playback id, no deezer identity
        title: 'Track 101',
        artistName: '',
        albumId: '',
        albumTitle: '',
        artworkUrl: '',
        duration: 100,
      );
      final merged = PlaylistRepository.reconcileTracks(
        cached: [topTrack('101')],
        cloud: [cloudNoDeezer],
      );
      expect(merged.single.artistName, 'Young Miko');
    });

    test('reconciliation keeps the richer local copy of a pending track', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [topTrack('101')], // full metadata, videoId id
        cloud: [pendingCloudCopy('101')], // catalog UUID, no artist
      );
      expect(merged, hasLength(1), reason: 'membership is one song, not two');
      expect(merged.single.artistName, 'Young Miko',
          reason: 'a pending match must not blank the artist');
    });

    test('a committed pending track is NOT duplicated by the add guard', () {
      // The server already has it (as a UUID) while our add op is still queued.
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: [pendingCloudCopy('101')],
        cached: [topTrack('101')],
        hasPendingAdd: true,
      );
      expect(merged, hasLength(1),
          reason: 'the optimistic copy and the cloud row are the same song');
    });

    test('a genuinely new local track is still preserved while queued', () {
      final merged = PlaylistRepository.preservePendingAdds(
        authoritative: [pendingCloudCopy('101')],
        cached: [topTrack('101'), topTrack('202')],
        hasPendingAdd: true,
      );
      expect(merged.map(PlaylistRepository.trackKey), ['d:101', 'd:202']);
    });

    test('a pending reorder keeps its order across an identity flip', () {
      final shown = PlaylistRepository.preservePendingOrder(
        authoritative: [
          pendingCloudCopy('1'),
          pendingCloudCopy('2'),
          pendingCloudCopy('3'),
        ],
        localOrder: [topTrack('3'), topTrack('1'), topTrack('2')],
      );
      expect(shown.map((t) => t.deezerTrackId), ['3', '1', '2'],
          reason: 'the saved order must survive the id change');
    });

    test('membership hydration keeps every row with a canonical UUID', () {
      // Two of the three are pending: no videoId, no artists, minimal metadata.
      final rows = [
        {
          'position': 1,
          'track_id': 'uuid-1',
          'tracks': {
            'id': 'uuid-1',
            'deezer_id': '1',
            'title': 'One',
            'preferred_youtube_video_id': 'vid-1',
            'track_artists': const [],
          }
        },
        {
          'position': 2,
          'track_id': 'uuid-2',
          'tracks': {
            'id': 'uuid-2',
            'deezer_id': '2',
            'title': 'Two',
            'preferred_youtube_video_id': null,
            'youtube_match_status': 'pending',
            'track_artists': const [],
          }
        },
        {
          'position': 3,
          'track_id': 'uuid-3',
          'tracks': {
            'id': 'uuid-3',
            'deezer_id': '3',
            'title': 'Three',
            'youtube_match_status': 'pending',
            'track_artists': const [],
          }
        },
      ];
      final tracks = PlaylistRepository.membershipFromRows(rows);
      expect(tracks, hasLength(3),
          reason: 'playback readiness ≠ membership validity');
      expect(tracks.map((t) => t.title), ['One', 'Two', 'Three']);
    });

    test('an already-committed track needs no later mutation to be visible',
        () {
      // Post-replay state: the op has left the journal and the server holds the
      // track. Reconciliation alone must surface it.
      final merged = PlaylistRepository.reconcileTracks(
        cached: [topTrack('1')],
        cloud: [pendingCloudCopy('1'), pendingCloudCopy('2')],
      );
      final shown = PlaylistRepository.preservePendingAdds(
        authoritative: merged,
        cached: [topTrack('1')],
        hasPendingAdd: false, // nothing queued any more
      );
      expect(shown.map((t) => t.deezerTrackId), ['1', '2'],
          reason: 'no second user action may be required');
    });
  });

  group('reorder is available immediately after an add', () {
    test('the add advances the lane, so the next reorder has a usable version',
        () async {
      final remote = FakeRemote()..version = 16;
      final repo = PlaylistRepository(
        remote: remote,
        resolver: IngestingResolver()..known['1'] = 'uuid-1',
        sleep: (_) async {},
      );
      PlaylistRepository.mutationLane.resetForTest();

      await repo.addTracks('p-1', [topTrack('1')]);

      expect(PlaylistRepository.mutationLane.versionFor('user-1', 'p-1'), 17,
          reason: 'a reorder straight after an add must not assert a stale '
              'version and be refused');
    });

    test('a freshly ingested track resolves for the FOLLOWING reorder',
        () async {
      // The reorder path resolves the whole playlist. Once the add has ingested
      // the track, that identity is cached, so "Couldn't save the new order"
      // cannot follow a successful add.
      final resolver = IngestingResolver();
      final repo = PlaylistRepository(
          remote: FakeRemote(), resolver: resolver, sleep: (_) async {});

      await repo.addTracks('p-1', [topTrack('101')]);
      final after = await resolver.resolveTracks(['101']);

      expect(after['101'], 'uuid-101',
          reason: 'identity established by the add is reusable immediately');
    });
  });
}
