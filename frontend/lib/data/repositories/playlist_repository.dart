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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/playlist.dart';
import '../../domain/entities/playlist_activity.dart';
import '../../domain/entities/track.dart';
import '../local/playlist_ops_journal.dart';
import '../remote/catalog_resolver.dart';
import '../remote/playlist_remote_data_source.dart';
import '../sync/playlist_op.dart';
import '../sync/playlist_op_failure.dart';
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
    final uid = currentUserId;
    return _online(
      () => _remote.createPlaylist(
          name: name, visibility: visibility, trackUuids: uuids, id: clientId),
      journalOnNetworkError: (uid == null || clientId == null)
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: clientId,
              type: PlaylistOpType.create,
              createdAt: DateTime.now(),
              payload: {'name': name, 'visibility': visibility, 'ids': uuids, 'clientId': clientId},
            ),
    );
  }

  Future<Map<String, dynamic>> saveOrder(
      String playlistId, List<Track> orderedTracks, int? expectedVersion) async {
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
    int? expectedVersion,
  }) =>
      _remote.updateMetadata(playlistId,
          name: name,
          description: description,
          visibility: visibility,
          collaborative: collaborative,
          expectedVersion: expectedVersion);

  Future<void> deletePlaylist(String playlistId) => _remote.deletePlaylist(playlistId);

  /// True when [playlistId] exists ONLY locally: it was created offline and its
  /// `create` op is still queued, so no cloud row exists yet.
  ///
  /// A client-generated UUID is indistinguishable from a cloud UUID by shape, so
  /// "looks like a UUID" is NOT sufficient to decide whether the cloud knows
  /// about a playlist. Without this check, deleting an offline-created playlist
  /// calls `playlist_delete` for a non-existent row, gets NOT_FOUND, throws, and
  /// the user is left with an undeletable ghost.
  bool isLocalOnly(String playlistId) {
    final uid = currentUserId;
    if (uid == null) return false;
    return _sync
        .pending(uid)
        .any((o) => o.playlistId == playlistId && o.type == PlaylistOpType.create);
  }

  /// Cancels a never-synced playlist: drops its queued `create` and every
  /// dependent op, so nothing is ever created remotely.
  ///
  /// Implemented by enqueueing a `delete` and letting
  /// [PlaylistOpsJournal.compact] collapse the create+delete pair to nothing —
  /// one code path for "born and died offline", exhaustively unit-tested, rather
  /// than a second hand-rolled removal routine that could drift.
  Future<void> cancelLocalOnly(String playlistId) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _sync.enqueue(PlaylistOp(
      opId: _newOpId(),
      userId: uid,
      playlistId: playlistId,
      type: PlaylistOpType.delete,
      createdAt: DateTime.now(),
    ));
  }

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
  Future<void> inviteByUsername(String playlistId, String username,
          {String role = 'editor'}) =>
      _remote.inviteByUsername(playlistId, username, role: role);
  Future<List<Map<String, dynamic>>> searchInvitableProfiles(
          String playlistId, String query, {int limit = 10}) =>
      _remote.searchInvitableProfiles(playlistId, query, limit: limit);
  Future<List<Map<String, dynamic>>> fetchPublicProfiles(Iterable<String> ids) =>
      _remote.fetchPublicProfiles(ids);
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

  /// One page of activity as domain entities (newest-first, actor + avatar
  /// resolved). Keyset pagination via [before] (the oldest loaded timestamp).
  Future<List<PlaylistActivity>> fetchActivityTimeline(
    String playlistId, {
    int limit = 30,
    DateTime? before,
  }) async {
    final rows = await _remote.fetchActivityPage(
      playlistId,
      limit: limit,
      beforeIso: before?.toUtc().toIso8601String(),
    );
    return rows.map(PlaylistActivity.fromRpcRow).toList();
  }
  Future<bool> isFollowing(String playlistId) async {
    final uid = currentUserId;
    if (uid == null) return false;
    return _remote.fetchIsFollowing(playlistId, uid);
  }
  Future<Map<String, String>> resolveUsernames(Iterable<String> ids) =>
      _remote.resolveUsernames(ids);

  // ── hydration (cloud → local Playlist entities) ──
  /// The current user's cloud playlists: owned + accepted-collaborating +
  /// followed, deduped, each mapped to a local [Playlist] entity (tracks
  /// resolved to playable videoIds; accepted collaborators + owner username
  /// resolved). Best-effort per playlist.
  Future<List<Playlist>> hydrateLibrary() async {
    final uid = currentUserId;
    if (uid == null) return const [];
    final owned = await _remote.fetchOwnedPlaylists(uid);
    final ownedIds = owned.map((r) => r['id'].toString()).toSet();
    final followed = await _remote.fetchFollowedPlaylistIds(uid);
    final collab = await _remote.fetchCollaboratingPlaylistIds(uid);
    final extraIds =
        {...followed, ...collab}.where((id) => !ownedIds.contains(id)).toList();
    final extras = await _remote.fetchPlaylistsByIds(extraIds);
    final rows = [...owned, ...extras];
    final out = <Playlist>[];
    for (final row in rows) {
      try {
        out.add(await hydrateEntity(row));
      } catch (_) {}
    }
    return out;
  }

  Future<Playlist> hydrateEntity(Map<String, dynamic> row) async {
    final id = row['id'].toString();
    final trackRows = await _remote.fetchTracks(id);
    final tracks = <Track>[];
    for (final tr in trackRows) {
      final t = _mapCloudTrack(tr);
      if (t != null) tracks.add(t);
    }
    final collabRows = await _remote.fetchCollaborators(id);
    final accepted =
        collabRows.where((c) => c['status']?.toString() == 'accepted').toList();
    final ids = <String>{
      if (row['owner_id'] != null) row['owner_id'].toString(),
      ...accepted.map((c) => c['user_id']?.toString() ?? ''),
    }..removeWhere((e) => e.isEmpty);
    final names = await _remote.resolveUsernames(ids);

    final collabsJson = jsonEncode(accepted.map((c) {
      final cid = c['user_id']?.toString() ?? '';
      final prof = c['profiles'];
      final uname = names[cid] ??
          (prof is Map ? (prof['username'] ?? prof['display_name']) : null);
      return {
        'userId': cid,
        if (uname != null) 'username': uname.toString(),
        'role': c['role']?.toString() ?? 'editor',
        'status': 'accepted',
        'position': DateTime.tryParse(c['joined_at']?.toString() ?? '')
                ?.millisecondsSinceEpoch ??
            0,
      };
    }).toList());

    return Playlist(
      id: id,
      name: row['name']?.toString() ?? '',
      tracks: tracks,
      createdAt: DateTime.tryParse(row['created_at']?.toString() ?? '') ??
          DateTime.now(),
      ownerId: row['owner_id']?.toString(),
      ownerUsername: names[row['owner_id']?.toString()],
      visibility: row['visibility']?.toString(),
      isCollaborative: row['collaborative'] == true,
      collaboratorsJson: collabsJson,
      trackPositions: List<int>.generate(tracks.length, (i) => i),
    );
  }

  Track? _mapCloudTrack(Map<String, dynamic> row) {
    final t = row['tracks'];
    if (t is! Map) return null;
    final videoId = t['preferred_youtube_video_id']?.toString();
    if (videoId == null || videoId.isEmpty) return null; // unplayable — skip
    final dur = t['duration_seconds'];
    return Track(
      id: videoId,
      title: t['title']?.toString() ?? '',
      artistName: '',
      albumId: '',
      albumTitle: '',
      artworkUrl:
          (t['image_cached_url'] ?? t['image_original_url'] ?? '').toString(),
      duration: dur is int ? dur : int.tryParse('${dur ?? ''}') ?? 0,
      deezerTrackId: t['deezer_id']?.toString(),
    );
  }

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
        case PlaylistOpType.create:
          await _remote.createPlaylist(
            name: op.payload['name']?.toString() ?? '',
            visibility: op.payload['visibility']?.toString() ?? 'private',
            trackUuids: ids,
            id: op.payload['clientId']?.toString(),
          );
          break;
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
    } on PlaylistConflictException catch (e) {
      // TERMINAL. Reported with the authoritative version so the sync engine can
      // quarantine it with enough context to rebase. Deliberately NOT mapped to
      // `retry` under any circumstance — see playlist_sync_service.dart.
      signalConflict(e.actualVersion);
    } catch (e) {
      // Phase 3.4.4 — every failure is classified explicitly. There is no
      // "assume transient" default: an unrecognised error becomes `unknown`,
      // whose policy is conservative (see playlist_op_failure.dart).
      throw classifyPlaylistOpError(e);
    }
  }

  /// Maps a thrown error to an explicit [PlaylistOpFailure].
  ///
  /// Exposed (and pure) so the taxonomy can be exhaustively unit-tested without
  /// a network. Ordering matters: typed exceptions first, then message
  /// signatures, then `unknown`.
  static PlaylistOpFailure classifyPlaylistOpError(Object e) {
    if (e is PlaylistConflictException) {
      return PlaylistOpFailure(PlaylistFailureKind.versionConflict,
          actualVersion: e.actualVersion, cause: e);
    }
    if (e is PlaylistForbiddenException) {
      return PlaylistOpFailure(PlaylistFailureKind.authorization, cause: e);
    }
    if (e is AuthException) {
      return PlaylistOpFailure(PlaylistFailureKind.authentication, cause: e);
    }
    if (e is SocketException || e is TimeoutException || e is HttpException) {
      return PlaylistOpFailure(PlaylistFailureKind.transientNetwork, cause: e);
    }

    if (e is PostgrestException) {
      final code = e.code ?? '';
      if (code == PlaylistConflictException.code) {
        return PlaylistOpFailure(PlaylistFailureKind.versionConflict, cause: e);
      }
      if (code == '42501' || code == '401' || code == '403') {
        return PlaylistOpFailure(PlaylistFailureKind.authorization, cause: e);
      }
      // 3-digit gateway statuses: 5xx is transient, other 4xx is validation.
      if (code.length == 3) {
        final s = int.tryParse(code);
        if (s != null) {
          return PlaylistOpFailure(
            s >= 500
                ? PlaylistFailureKind.transientNetwork
                : PlaylistFailureKind.validation,
            cause: e,
          );
        }
      }
      // SQLSTATE classes: 08/53/57 = server-side transient.
      if (code.length == 5 &&
          (code.startsWith('08') ||
              code.startsWith('53') ||
              code.startsWith('57'))) {
        return PlaylistOpFailure(PlaylistFailureKind.transientNetwork, cause: e);
      }
    }

    final msg = e is PlaylistRemoteException ? e.message : e.toString();
    if (msg.contains('NOT_FOUND')) {
      return PlaylistOpFailure(PlaylistFailureKind.notFound, cause: e);
    }
    const validationSignatures = [
      'ORDER_SET_MISMATCH', 'EMPTY_RESULT', 'INVALID', 'NAME_REQUIRED',
      'MISMATCH', 'CANNOT_', 'ALREADY_', 'USER_NOT_FOUND', 'SELF_INVITE',
    ];
    if (validationSignatures.any(msg.contains)) {
      return PlaylistOpFailure(PlaylistFailureKind.validation, cause: e);
    }
    if (msg.contains('FORBIDDEN') || msg.contains('NOT_OWNER')) {
      return PlaylistOpFailure(PlaylistFailureKind.authorization, cause: e);
    }
    if (msg.contains('UNRESOLVED_TRACK') || msg.contains('FormatException')) {
      return PlaylistOpFailure(PlaylistFailureKind.localIntegrity, cause: e);
    }
    final lower = msg.toLowerCase();
    if (lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection closed') ||
        lower.contains('connection reset') ||
        lower.contains('connection refused') ||
        lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('503') ||
        lower.contains('504') ||
        lower.contains('service unavailable')) {
      return PlaylistOpFailure(PlaylistFailureKind.transientNetwork, cause: e);
    }

    // Explicitly unknown — conservative policy, never "assume transient".
    return PlaylistOpFailure(PlaylistFailureKind.unknown, cause: e);
  }
}
