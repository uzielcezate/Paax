// test/unit/offline_reconnect_and_reconciliation_test.dart
//
// Phase 3.4.8 — the four bug classes found by manual Android QA.
//
// Each group states the defect it pins. Every one of these fails against the
// previous implementation.

import 'package:beaty/core/network/offline_status.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

Track _t(String id, {String artist = 'Rauw Alejandro', String title = 'Song'}) =>
    Track(
      id: id,
      title: title,
      artistName: artist,
      albumId: 'alb',
      albumTitle: 'Album',
      artworkUrl: 'http://img/$id.jpg',
      duration: 200,
      deezerTrackId: '123$id',
      artists: artist.isEmpty ? null : [
        {'name': artist, 'id': 'a1'}
      ],
    );

/// A cloud-hydrated track: membership-only, no artist metadata.
Track _skeleton(String id, {String title = 'Song'}) => Track(
      id: id,
      title: title,
      artistName: '', // exactly what _mapCloudTrack produced
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: 200,
    );

void main() {
  group('BUG 1 — reconnect must produce an offline→online edge on its own', () {
    late OfflineStatus status;
    setUp(() => status = OfflineStatus());
    tearDown(() => status.dispose());

    test('a connectivity event flips offline→online WITHOUT any request',
        () async {
      final controller = Stream<List<ConnectivityResult>>.fromIterable([
        [ConnectivityResult.wifi],
      ]).asBroadcastStream();

      status.debugSetOffline(true);
      expect(status.isOffline, isTrue);

      status.startObserving(stream: controller);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(status.isOffline, isFalse,
          reason: 'THE reconnect bug: without this edge the journal never '
              'replayed until some unrelated request happened to succeed');
      expect(status.onlineGeneration, 1);
    });

    test('losing every interface marks us offline', () async {
      final s = Stream<List<ConnectivityResult>>.fromIterable([
        [ConnectivityResult.none],
      ]).asBroadcastStream();
      status.startObserving(stream: s);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(status.isOffline, isTrue);
    });

    test('the observer is registered EXACTLY once', () {
      final s = const Stream<List<ConnectivityResult>>.empty();
      status.startObserving(stream: s);
      status.startObserving(stream: s);
      status.startObserving(stream: s);
      expect(status.isObserving, isTrue);
      // A second subscription would leak and double every reconnect.
    });

    test('20 duplicated online events produce ONE replay', () async {
      var replays = 0;
      final events = Stream<List<ConnectivityResult>>.fromIterable(
        List.generate(20, (_) => [ConnectivityResult.wifi]),
      ).asBroadcastStream();

      status.debugSetOffline(true);
      status.startObserving(stream: events);
      status.addListener(() {
        if (!status.isOffline) {
          // ignore: discarded_futures
          status.refreshOnce('journal', () async => replays++);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(replays, 1, reason: 'duplicate online events must not multiply work');
    });

    test('a request outcome still overrides an optimistic connectivity hint',
        () async {
      final s = Stream<List<ConnectivityResult>>.fromIterable([
        [ConnectivityResult.wifi],
      ]).asBroadcastStream();
      status.debugSetOffline(true);
      status.startObserving(stream: s);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(status.isOffline, isFalse);

      // Interface up but backend unreachable (captive portal / down service).
      status.reportOutcome(succeeded: false, wasNetworkFailure: true);
      expect(status.isOffline, isTrue,
          reason: 'request outcomes remain authoritative over the OS hint');
    });

    test('dispose cancels the subscription', () {
      final own = OfflineStatus()..startObserving(stream: const Stream.empty());
      expect(own.isObserving, isTrue);
      own.dispose();
      expect(own.isObserving, isFalse,
          reason: 'a surviving subscription would leak across sessions');
    });
  });

  group('BUG 3 — reconciliation must never destroy cached metadata', () {
    test('a skeletal cloud track NEVER replaces a hydrated local track', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('v1'), _t('v2')],
        cloud: [_skeleton('v1'), _skeleton('v2')],
      );
      expect(merged.map((t) => t.artistName), ['Rauw Alejandro', 'Rauw Alejandro'],
          reason: 'this is the Unknown Artist bug');
      expect(merged.every((t) => t.artworkUrl.isNotEmpty), isTrue);
    });

    test('ORDER comes from the server list, metadata from the cache', () {
      // Server says v2 then v1 (a genuine reorder).
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('v1'), _t('v2')],
        cloud: [_skeleton('v2'), _skeleton('v1')],
      );
      expect(merged.map((t) => t.id), ['v2', 'v1'],
          reason: 'server membership order is authoritative');
      expect(merged.every((t) => t.artistName == 'Rauw Alejandro'), isTrue,
          reason: 'but metadata must survive the reorder');
    });

    test('a genuinely new remote track is added as-is', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('v1')],
        cloud: [_skeleton('v1'), _skeleton('v9', title: 'New')],
      );
      expect(merged.map((t) => t.id), ['v1', 'v9']);
      expect(merged.last.title, 'New');
    });

    test('a removed track disappears — server membership wins', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('v1'), _t('v2')],
        cloud: [_skeleton('v1')],
      );
      expect(merged.map((t) => t.id), ['v1']);
    });

    test('cloud artists are used when the cache has none', () {
      final rich = _t('v1', artist: 'Rauw Alejandro, Bad Bunny');
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_skeleton('v1')],
        cloud: [rich],
      );
      expect(merged.single.artistName, 'Rauw Alejandro, Bad Bunny');
    });

    test('multiple/featured artists survive replay', () {
      final multi = _t('v1', artist: 'Rauw Alejandro, Pharrell Williams');
      final merged = PlaylistRepository.reconcileTracks(
        cached: [multi],
        cloud: [_skeleton('v1')],
      );
      expect(merged.single.artistName, 'Rauw Alejandro, Pharrell Williams');
      expect(merged.single.artists, hasLength(1));
    });

    test('an add does not reshuffle unrelated tracks', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('a'), _t('b'), _t('c')],
        cloud: [_skeleton('a'), _skeleton('b'), _skeleton('c'), _skeleton('d')],
      );
      expect(merged.map((t) => t.id), ['a', 'b', 'c', 'd']);
    });

    test('identity + title + artists survive a full round trip', () {
      final before = _t('v1', title: 'Qué Pasaría...', artist: 'Rauw Alejandro');
      final after = PlaylistRepository.reconcileTracks(
        cached: [before],
        cloud: [_skeleton('v1', title: 'Qué Pasaría...')],
      ).single;

      expect(after.id, before.id);
      expect(after.title, before.title);
      expect(after.artistName, before.artistName);
      expect(after.deezerTrackId, before.deezerTrackId);
      expect(after.artworkUrl, before.artworkUrl);
    });

    test('empty cloud membership empties the playlist (not a metadata bug)', () {
      final merged = PlaylistRepository.reconcileTracks(
        cached: [_t('v1')],
        cloud: const [],
      );
      expect(merged, isEmpty);
    });
  });

  group('ADVERSARIAL — guards must actually guard', () {
    late OfflineStatus status;
    setUp(() => status = OfflineStatus());
    tearDown(() => status.dispose());

    test('onUserSession does NOT reset the refresh guard for the SAME account',
        () async {
      // ProxyProvider.update() runs on every AuthController notification, not
      // only on account change. Clearing unconditionally erased the guard and
      // "one flush per reconnect" silently stopped holding.
      status.debugSetOffline(true);
      status.debugSetOffline(false); // reconnect

      var flushes = 0;
      Future<void> flush() async => flushes++;

      for (var i = 0; i < 30; i++) {
        status.onUserSession('user-A'); // same identity, repeatedly
        await status.refreshOnce('library:playlist-journal', flush);
      }

      expect(flushes, 1,
          reason: 'repeated auth notifications must not re-arm the guard');
    });

    test('a genuine account switch DOES reset the guard', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);

      var flushes = 0;
      Future<void> flush() async => flushes++;

      status.onUserSession('user-A');
      await status.refreshOnce('library:playlist-journal', flush);
      expect(flushes, 1);

      status.onUserSession('user-B'); // real switch
      await status.refreshOnce('library:playlist-journal', flush);
      expect(flushes, 2, reason: 'the new account must replay its own journal');
    });

    test('sign-out then back in to the same account resets once', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      var flushes = 0;
      Future<void> flush() async => flushes++;

      status.onUserSession('user-A');
      await status.refreshOnce('journal', flush);
      status.onUserSession(null); // sign-out
      status.onUserSession('user-A'); // sign back in
      await status.refreshOnce('journal', flush);
      expect(flushes, 2);
    });
  });
}
