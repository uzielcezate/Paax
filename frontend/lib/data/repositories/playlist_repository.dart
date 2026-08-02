// lib/data/repositories/playlist_repository.dart
//
// Phase 3.4.1 — the facade the controller/UI use for cloud playlists. Supabase
// (via the RPC data source) is authoritative; writes are optimistic on the
// caller side and this layer:
//   * runs the transactional RPC when online,
//   * journals the op for replay when the network fails,
//   * surfaces version conflicts / lost-permission so the caller reconciles.
// Track identity is resolved from local Deezer ids → catalog UUIDs here so the
// UI keeps working with local Track objects.

import '../../domain/entities/track.dart';
import '../local/playlist_ops_journal.dart';
import '../remote/catalog_resolver.dart';
import '../remote/playlist_remote_data_source.dart';
import '../sync/playlist_op.dart';
import '../sync/playlist_sync_service.dart';

class PlaylistRepository {
  final PlaylistRemoteDataSource _remote;
  final CatalogResolver _resolver;
  final PlaylistSyncService _sync;

  PlaylistRepository({
    PlaylistRemoteDataSource? remote,
    CatalogResolver? resolver,
    PlaylistSyncService? sync,
  })  : _remote = remote ?? PlaylistRemoteDataSource(),
        _resolver = resolver ?? CatalogResolver(),
        _sync = sync ?? PlaylistSyncService(PlaylistOpsJournal());

  String? get currentUserId => _remote.currentUserId;

  static String _newOpId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${identityHashCode(Object())}';

  // Resolve local tracks → ordered catalog UUIDs (unresolvable ones dropped).
  Future<List<String>> _resolveTrackUuids(List<Track> tracks) async {
    final deezerIds = tracks.map((t) => t.deezerTrackId).toList();
    final map = await _resolver.resolveTracks(deezerIds);
    final out = <String>[];
    for (final t in tracks) {
      final u = map[(t.deezerTrackId ?? '').trim()];
      if (u != null) out.add(u);
    }
    return out;
  }

  Future<T> _online<T>(
    Future<T> Function() run, {
    PlaylistOp? journalOnNetworkError,
  }) async {
    try {
      return await run();
    } on PlaylistConflictException {
      rethrow;
    } on PlaylistForbiddenException {
      rethrow;
    } catch (_) {
      if (journalOnNetworkError != null) {
        await _sync.enqueue(journalOnNetworkError);
      }
      rethrow;
    }
  }

  // ── writes ──
  Future<Map<String, dynamic>> createPlaylist({
    required String name,
    String visibility = 'private',
    List<Track> tracks = const [],
    String? clientId,
  }) async {
    final uuids = await _resolveTrackUuids(tracks);
    return _remote.createPlaylist(
        name: name, visibility: visibility, trackUuids: uuids, id: clientId);
  }

  Future<Map<String, dynamic>> saveOrder(
      String playlistId, List<Track> orderedTracks, int expectedVersion) async {
    final uuids = await _resolveTrackUuids(orderedTracks);
    final uid = currentUserId;
    return _online(
      () => _remote.saveOrder(playlistId, uuids, expectedVersion),
      journalOnNetworkError: uid == null
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: playlistId,
              type: PlaylistOpType.saveOrder,
              createdAt: DateTime.now(),
              expectedVersion: expectedVersion,
              payload: {'ids': uuids},
            ),
    );
  }

  Future<Map<String, dynamic>> addTracks(String playlistId, List<Track> tracks) async {
    final uuids = await _resolveTrackUuids(tracks);
    final uid = currentUserId;
    return _online(
      () => _remote.addTracks(playlistId, uuids),
      journalOnNetworkError: uid == null
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: playlistId,
              type: PlaylistOpType.addTracks,
              createdAt: DateTime.now(),
              payload: {'ids': uuids},
            ),
    );
  }

  Future<Map<String, dynamic>> removeTracks(String playlistId, List<Track> tracks) async {
    final uuids = await _resolveTrackUuids(tracks);
    final uid = currentUserId;
    return _online(
      () => _remote.removeTracks(playlistId, uuids),
      journalOnNetworkError: uid == null
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: playlistId,
              type: PlaylistOpType.removeTracks,
              createdAt: DateTime.now(),
              payload: {'ids': uuids},
            ),
    );
  }

  Future<Map<String, dynamic>> updateMetadata(
    String playlistId, {
    String? name,
    String? description,
    String? visibility,
    bool? collaborative,
    required int expectedVersion,
  }) =>
      _remote.updateMetadata(playlistId,
          name: name,
          description: description,
          visibility: visibility,
          collaborative: collaborative,
          expectedVersion: expectedVersion);

  Future<void> deletePlaylist(String playlistId) => _remote.deletePlaylist(playlistId);

  Future<int> setFollow(String playlistId, bool follow) =>
      _remote.setFollow(playlistId, follow);

  Future<Map<String, dynamic>> clone(String playlistId, {String? newTitle}) =>
      _remote.clone(playlistId, newTitle: newTitle);

  Future<Map<String, dynamic>> addTracksFromSource(String sourceId, String targetId) =>
      _remote.addTracksFromSource(sourceId, targetId);

  // ── collaboration ──
  Future<String?> resolveUserIdByUsername(String username) =>
      _remote.resolveUserIdByUsername(username);
  Future<void> invite(String playlistId, String userId, {String role = 'editor'}) =>
      _remote.invite(playlistId, userId, role: role);
  Future<void> respondInvitation(String playlistId, bool accept) =>
      _remote.respondInvitation(playlistId, accept);
  Future<void> leave(String playlistId) => _remote.leave(playlistId);
  Future<void> removeCollaborator(String playlistId, String userId, {String? reason}) =>
      _remote.removeCollaborator(playlistId, userId, reason: reason);
  Future<Map<String, dynamic>> transferOwnership(String playlistId, String newOwner) =>
      _remote.transferOwnership(playlistId, newOwner);

  // ── reads ──
  Future<Map<String, dynamic>?> fetchPlaylist(String playlistId) =>
      _remote.fetchPlaylist(playlistId);
  Future<List<Map<String, dynamic>>> fetchTracks(String playlistId) =>
      _remote.fetchTracks(playlistId);
  Future<List<Map<String, dynamic>>> fetchCollaborators(String playlistId) =>
      _remote.fetchCollaborators(playlistId);
  Future<Map<String, dynamic>?> fetchLatestActivity(String playlistId) =>
      _remote.fetchLatestActivity(playlistId);
  Future<bool> isFollowing(String playlistId) async {
    final uid = currentUserId;
    if (uid == null) return false;
    return _remote.fetchIsFollowing(playlistId, uid);
  }
  Future<Map<String, String>> resolveUsernames(Iterable<String> ids) =>
      _remote.resolveUsernames(ids);

  // ── offline replay ──
  Future<PlaylistFlushResult> flushPending() async {
    final uid = currentUserId;
    if (uid == null) return const PlaylistFlushResult();
    return _sync.flush(uid, _execute);
  }

  Future<OpOutcome> _execute(PlaylistOp op) async {
    try {
      final ids = (op.payload['ids'] as List?)?.cast<String>() ?? const <String>[];
      switch (op.type) {
        case PlaylistOpType.saveOrder:
          await _remote.saveOrder(op.playlistId, ids, op.expectedVersion);
          break;
        case PlaylistOpType.addTracks:
          await _remote.addTracks(op.playlistId, ids);
          break;
        case PlaylistOpType.removeTracks:
          await _remote.removeTracks(op.playlistId, ids);
          break;
        case PlaylistOpType.delete:
          await _remote.deletePlaylist(op.playlistId);
          break;
        case PlaylistOpType.setFollow:
          await _remote.setFollow(op.playlistId, op.payload['follow'] == true);
          break;
        default:
          // Other op types are executed inline (not queued) in this phase.
          break;
      }
      return OpOutcome.success;
    } on PlaylistConflictException {
      return OpOutcome.conflict;
    } on PlaylistForbiddenException {
      return OpOutcome.forbidden;
    } catch (_) {
      return OpOutcome.retry;
    }
  }
}
