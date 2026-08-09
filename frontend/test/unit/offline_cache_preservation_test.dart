// test/unit/offline_cache_preservation_test.dart
//
// Phase 3.4.5 — "never clear good cached state because a refresh failed".
//
// The dangerous shape here is specific: PlaylistDetailController marks a
// playlist DELETED when `fetchPlaylist` returns null, and a deleted playlist
// ejects the user from the screen. That is correct for an authoritative "no row"
// (soft-deleted, or access revoked under RLS) and catastrophic for a network
// error — offline would silently look like "this playlist was deleted".
//
// The distinction rests entirely on `fetchPlaylist` THROWING on transport
// failure and returning null ONLY when the server answered. These tests pin that
// contract from the controller's side, so a future refactor that "helpfully"
// swallows errors into null is caught here rather than on a user's device.

import 'dart:io';

import 'package:beaty/data/remote/playlist_realtime_service.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/presentation/state/playlist_detail_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRepo implements PlaylistRepository {
  Object? throwOnFetch;
  Map<String, dynamic>? row;
  int fetchCalls = 0;

  @override
  Future<Map<String, dynamic>?> fetchPlaylist(String playlistId) async {
    fetchCalls++;
    if (throwOnFetch != null) throw throwOnFetch!;
    return row;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchCollaborators(String id) async => [];
  @override
  Future<List<Map<String, dynamic>>> fetchTracks(String id) async => [];
  @override
  Future<bool> isFollowing(String id) async => false;
  @override
  Future<Map<String, dynamic>?> fetchLatestActivity(String id) async => null;
  @override
  Future<List<Map<String, dynamic>>> fetchPublicProfiles(
          Iterable<String> ids) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _FakeRealtime implements PlaylistRealtimeService {
  int subscribeCalls = 0;
  int listenerCount = 0;

  @override
  Future<void> subscribe(String playlistId) async {
    subscribeCalls++;
  }

  @override
  void addListener(String playlistId, void Function(PlaylistRealtimeEvent) cb) {
    listenerCount++;
  }

  @override
  void removeListener(String playlistId, void Function(PlaylistRealtimeEvent) cb) {
    listenerCount--;
  }

  @override
  Future<void> unsubscribe(String playlistId) async {}

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

PlaylistDetailController _controller(_FakeRepo repo, _FakeRealtime rt) =>
    PlaylistDetailController(
      repository: repo,
      realtime: rt,
      currentUserId: 'u1',
      playlistId: '11111111-2222-3333-4444-555555555555',
      initialOwnerId: 'u1',
      initialOwnerUsername: 'iamleizu',
    );

void main() {
  group('an offline refresh must not look like a deletion', () {
    for (final failure in <Object>[
      const SocketException('Failed host lookup'),
      Exception('ClientException with SocketException'),
      Exception('503 Service Unavailable'),
    ]) {
      test('network failure ($failure) does NOT mark the playlist deleted',
          () async {
        final repo = _FakeRepo()..throwOnFetch = failure;
        final c = _controller(repo, _FakeRealtime());
        await c.load(); // establishes isCloud; also fails offline
        await c.refresh();

        expect(c.isDeleted, isFalse,
            reason: 'offline must never eject the user from a cached playlist');
        c.dispose();
      });
    }

    test('an AUTHORITATIVE null (soft-deleted / access revoked) DOES mark it '
        'deleted', () async {
      final repo = _FakeRepo()..row = null; // server answered: no row
      final c = _controller(repo, _FakeRealtime());
      await c.load();
      await c.refresh();

      expect(c.isDeleted, isTrue,
          reason: 'a real deletion must still eject the user');
      c.dispose();
    });

    test('cached owner/visibility survive a failed refresh', () async {
      final repo = _FakeRepo()..throwOnFetch = const SocketException('offline');
      final c = _controller(repo, _FakeRealtime());
      await c.load();
      await c.refresh();

      expect(c.ownerUsername, 'iamleizu');
      expect(c.visibility, 'private');
      c.dispose();
    });

    test('repeated failed refreshes never accumulate deletion state', () async {
      final repo = _FakeRepo()..throwOnFetch = const SocketException('offline');
      final c = _controller(repo, _FakeRealtime());
      await c.load();
      repo.fetchCalls = 0;

      for (var i = 0; i < 5; i++) {
        await c.refresh();
      }

      expect(c.isDeleted, isFalse);
      expect(repo.fetchCalls, 5);
      c.dispose();
    });
  });
}
