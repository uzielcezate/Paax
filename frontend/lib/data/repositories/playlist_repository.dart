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

import '../../core/network/offline_status.dart';
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
import '../sync/playlist_mutation_lane.dart';
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

  /// Resolve local tracks → ordered catalog UUIDs.
  ///
  /// SILENT DROPS ARE A DATA-LOSS BUG (fixed 2026-08-09). This previously
  /// discarded unresolvable tracks and returned a shorter list. A track with no
  /// numeric `deezerTrackId` can NEVER resolve, so the caller ended up invoking
  /// `playlist_add_tracks(playlist_id, '{}')` — and that RPC gates its insert,
  /// version bump and activity behind `if v_count > 0`, so an empty array is a
  /// SILENT SUCCESS that returns the playlist row unchanged.
  ///
  /// Net effect in production: the UI showed 4 tracks while the server had 1,
  /// with no error anywhere. Verified in the activity log — only 2 distinct
  /// track UUIDs ever reached the server across 13 versions of one playlist.
  ///
  /// Now the caller is told exactly what could not be resolved so it can refuse
  /// to report success. See [_resolveOrThrow].
  /// TWO-STAGE IDENTITY (Phase 3.4.7). Deezer identity is NOT mandatory for
  /// playlist membership:
  ///
  ///   1. `deezerTrackId` → `tracks.deezer_id`   (fast path, numeric ids only)
  ///   2. `Track.id` (the YouTube videoId) → `tracks.preferred_youtube_video_id`
  ///
  /// Stage 2 exists because a track surfaced from search/album often carries no
  /// numeric `deezerTrackId`, and stage 1 alone silently produced an EMPTY uuid
  /// list — which `playlist_add_tracks` accepts as a no-op success.
  ///
  /// Anything still unresolved after both stages is returned to the caller so it
  /// can fail loudly. Nothing is ever silently dropped.
  Future<({List<String> uuids, List<Track> unresolved})> _resolveTracks(
      List<Track> tracks) async {
    final byDeezer =
        await _resolver.resolveTracks(tracks.map((t) => t.deezerTrackId));

    // Only tracks stage 1 missed go to stage 2, so the extra query is skipped
    // entirely in the common all-resolved case.
    final needVideoId = tracks
        .where((t) => byDeezer[(t.deezerTrackId ?? '').trim()] == null)
        .toList();
    final byVideoId = needVideoId.isEmpty
        ? const <String, String>{}
        : await _resolver.resolveTracksByVideoId(needVideoId.map((t) => t.id));

    final uuids = <String>[];
    final unresolved = <Track>[];
    for (final t in tracks) {
      final u = byDeezer[(t.deezerTrackId ?? '').trim()] ??
          byVideoId[t.id.trim()];
      if (u != null) {
        uuids.add(u);
      } else {
        unresolved.add(t);
      }
    }
    return (uuids: uuids, unresolved: unresolved);
  }

  /// Resolves [tracks], throwing rather than silently losing any of them.
  ///
  /// Throws [PlaylistOpFailure] with `localIntegrity` when ANY track cannot be
  /// mapped to a catalog UUID. `localIntegrity` is deliberate: this is not a
  /// network problem and retrying cannot fix it, so the op is discarded rather
  /// than queued forever — and, critically, the caller rolls the optimistic UI
  /// back instead of leaving a phantom track on screen.
  Future<List<String>> _resolveOrThrow(List<Track> tracks) async {
    final r = await _resolveTracks(tracks);
    if (r.unresolved.isNotEmpty) {
      final titles = r.unresolved.map((t) => t.title).take(3).join(', ');
      throw PlaylistOpFailure(
        PlaylistFailureKind.localIntegrity,
        cause: 'UNRESOLVED_TRACK: ${r.unresolved.length} track(s) are not in '
            'the Paax catalog and cannot be synced ($titles)',
      );
    }
    return r.uuids;
  }

  /// Back-compat shim for read paths that legitimately tolerate partial
  /// resolution (e.g. best-effort hydration). Mutations must use
  /// [_resolveOrThrow].
  Future<List<String>> _resolveTrackUuids(List<Track> tracks) async =>
      (await _resolveTracks(tracks)).uuids;

  Future<T> _online<T>(
    Future<T> Function() run, {
    PlaylistOp? journalOnNetworkError,
  }) async {
    try {
      final r = await run();
      OfflineStatus.report(succeeded: true); // proves reachability
      return r;
    } on PlaylistConflictException {
      // The server answered — we are demonstrably online.
      OfflineStatus.report(succeeded: true);
      rethrow;
    } on PlaylistForbiddenException {
      OfflineStatus.report(succeeded: true);
      rethrow;
    } catch (e) {
      final kind = classifyPlaylistOpError(e).kind;
      final isNetwork = kind == PlaylistFailureKind.transientNetwork;
      OfflineStatus.report(succeeded: false, wasNetworkFailure: isNetwork);
      // Journal ONLY genuine connectivity failures. Queuing a validation or
      // localIntegrity failure would replay a doomed operation forever.
      if (journalOnNetworkError != null && isNetwork) {
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
    // A short array here would fail ORDER_SET_MISMATCH server-side anyway, but
    // failing locally gives the user an accurate reason instead of a generic
    // validation error.
    final uuids = await _resolveOrThrow(orderedTracks);
    final uid = currentUserId;
    return _online(
      // Reorder is NOT auto-rebasable: replaying an order against a membership
      // the server has since changed would push a wrong list. A 409 here is
      // terminal and surfaces for user recovery.
      () => _versioned(playlistId,
          (expected) => _remote.saveOrder(playlistId, uuids, expected ?? expectedVersion),
          rebasable: false),
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

  /// The per-playlist mutation lane. Shared across the repository so every
  /// version-checked mutation for one playlist is ordered.
  static final PlaylistMutationLane mutationLane = PlaylistMutationLane();

  /// Runs a version-checked mutation inside this playlist's lane, applying the
  /// once-only 409 rebase policy.
  ///
  /// Sequence guaranteed here:
  ///   add A (expected 7) → 8 persisted → add B (expected 8)
  ///
  /// On 409 we do NOT retry blindly. We refetch the authoritative version
  /// exactly once and re-run the SAME intent against it, but only when
  /// [rebasable] says the intent is still safely applicable. Anything else is
  /// terminal.
  Future<Map<String, dynamic>> _versioned(
    String playlistId,
    Future<Map<String, dynamic>> Function(int? expectedVersion) run, {
    bool rebasable = true,
  }) {
    final uid = currentUserId ?? 'anon';
    return mutationLane.run<Map<String, dynamic>>(uid, playlistId,
        (expected) async {
      try {
        final row = await run(expected);
        return (result: row, version: _versionOf(row));
      } on PlaylistConflictException catch (e) {
        if (!rebasable) rethrow; // e.g. reorder with changed membership
        // ONE authoritative read, then ONE rebased attempt. Never a loop.
        final actual = e.actualVersion ?? await _fetchVersion(playlistId);
        if (actual == null) rethrow;
        final row = await run(actual);
        return (result: row, version: _versionOf(row));
      }
    });
  }

  static int? _versionOf(Map<String, dynamic> row) {
    final v = row['version'];
    return v is int ? v : int.tryParse('${v ?? ''}');
  }

  Future<int?> _fetchVersion(String playlistId) async {
    try {
      final row = await _remote.fetchPlaylist(playlistId);
      return row == null ? null : _versionOf(row);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> addTracks(String playlistId, List<Track> tracks) async {
    // Throws localIntegrity rather than sending an empty/short array, which the
    // RPC would accept as a silent no-op success.
    final uuids = await _resolveOrThrow(tracks);
    final uid = currentUserId;
    return _online(
      // playlist_add_tracks is idempotent (it skips tracks already present) and
      // takes no expected_version, so it needs the lane for ORDERING — so each
      // add sees the previous one's committed state — but cannot 409.
      () => mutationLane.run<Map<String, dynamic>>(
          uid ?? 'anon', playlistId, (expected) async {
        final row = await _remote.addTracks(playlistId, uuids);
        return (result: row, version: _versionOf(row));
      }),
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
    final uuids = await _resolveOrThrow(tracks);
    final uid = currentUserId;
    return _online(
      () => mutationLane.run<Map<String, dynamic>>(
          uid ?? 'anon', playlistId, (expected) async {
        final row = await _remote.removeTracks(playlistId, uuids);
        return (result: row, version: _versionOf(row));
      }),
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

  /// Soft-deletes a cloud playlist, JOURNALLING when offline.
  ///
  /// This previously called the RPC directly with no `_online` wrapper, so an
  /// offline delete threw straight to the UI ("Couldn't delete the playlist")
  /// and nothing was queued — the only playlist mutation that bypassed the
  /// offline-first path entirely.
  Future<void> deletePlaylist(String playlistId) async {
    final uid = currentUserId;
    return _online(
      () => _remote.deletePlaylist(playlistId),
      journalOnNetworkError: uid == null
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: playlistId,
              type: PlaylistOpType.delete,
              createdAt: DateTime.now(),
            ),
    );
  }

  /// Changes visibility, JOURNALLING when offline so private↔public works
  /// offline and becomes authoritative on reconnect.
  Future<Map<String, dynamic>> setVisibility(
    String playlistId,
    String visibility, {
    int? expectedVersion,
  }) async {
    final uid = currentUserId;
    return _online(
      // Visibility is safely rebasable: the intent ("make it public") does not
      // depend on the rest of the playlist state.
      () => _versioned(
          playlistId,
          (expected) => _remote.updateMetadata(playlistId,
              visibility: visibility,
              expectedVersion: expected ?? expectedVersion)),
      journalOnNetworkError: uid == null
          ? null
          : PlaylistOp(
              opId: _newOpId(),
              userId: uid,
              playlistId: playlistId,
              type: PlaylistOpType.updateMetadata,
              createdAt: DateTime.now(),
              // No expectedVersion when queued: by replay time the local
              // version is certainly stale, and a version check would turn a
              // legitimate offline intent into a permanent conflict.
              payload: {'visibility': visibility},
            ),
    );
  }

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
  /// Called after a queued `create` commits, to atomically re-key every
  /// account-scoped reference from the local UUID to the authoritative cloud
  /// UUID. Injected by the controller, which owns Hive/pins/navigation.
  Future<void> Function(String localId, String cloudId, int? version)?
      onPlaylistAdopted;

  Future<PlaylistFlushResult> flushPending() async {
    final uid = currentUserId;
    if (uid == null) return const PlaylistFlushResult();
    return _sync.flush(
      uid,
      _execute,
      onAdopted: (localId, cloudId, version) async {
        // Persist the authoritative version into the lane BEFORE dependents
        // run, so the first dependent mutation uses it rather than a stale one.
        if (version != null) mutationLane.recordVersion(uid, cloudId, version);
        await onPlaylistAdopted?.call(localId, cloudId, version);
      },
      onVersion: (playlistId, version) async =>
          mutationLane.recordVersion(uid, playlistId, version),
    );
  }

  Future<OpOutcome> _execute(PlaylistOp op) async {
    try {
      final ids = (op.payload['ids'] as List?)?.cast<String>() ?? const <String>[];
      switch (op.type) {
        case PlaylistOpType.create:
          final row = await _remote.createPlaylist(
            name: op.payload['name']?.toString() ?? '',
            visibility: op.payload['visibility']?.toString() ?? 'private',
            trackUuids: ids,
            // Passing the client id makes create IDEMPOTENT: a replay after a
            // crash upserts the same row instead of creating a second playlist.
            id: op.payload['clientId']?.toString(),
          );
          signalApplied(
            cloudPlaylistId: row['id']?.toString(),
            version: _versionOf(row),
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
        case PlaylistOpType.updateMetadata:
          // Replayed WITHOUT expectedVersion: the queued version is stale by
          // definition, and a version check here would convert a legitimate
          // offline intent into a permanent conflict. Ownership is still
          // enforced by the RPC.
          await _remote.updateMetadata(
            op.playlistId,
            name: op.payload['name']?.toString(),
            description: op.payload['description']?.toString(),
            visibility: op.payload['visibility']?.toString(),
          );
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
