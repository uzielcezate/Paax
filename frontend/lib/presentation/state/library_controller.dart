import '../../domain/entities/edit_order_diff.dart';
import '../../domain/entities/playlist_mutation_result.dart';
import '../../data/sync/playlist_op_failure.dart';
import '../../data/remote/playlist_remote_data_source.dart';
import 'package:flutter/material.dart';
import '../../core/utils/uuid.dart';
import '../../data/local/hive_storage.dart';
import '../../data/repositories/library_repository.dart';
import '../../data/repositories/playlist_repository.dart';
import '../../data/sync/playlist_migration_service.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/genre.dart';

class LibraryController extends ChangeNotifier {
  List<Track> _likedTracks = [];
  List<Playlist> _playlists = [];
  List<SavedAlbum> _savedAlbums = [];
  Set<String> _hiddenTrackIds = {};
  Map<String, int> _pinnedPlaylistMap = {};

  /// Phase 3.2A — optional cloud-sync repository. Null keeps the controller
  /// purely local (existing tests/usages compile unchanged).
  final LibraryRepository? _repo;

  /// Phase 3.4.1 — optional cloud PLAYLIST repository. Null keeps playlists
  /// purely local. Every cloud call below is best-effort and guarded so it can
  /// NEVER break the authoritative local Hive flow.
  final PlaylistRepository? _cloud;

  List<Track> get likedTracks => _likedTracks;
  List<Playlist> get playlists => _playlists;
  List<SavedAlbum> get savedAlbums => _savedAlbums;

  LibraryController([this._repo, this._cloud]) {
    _loadData();
  }

  bool get _cloudEnabled => _cloud != null;

  /// Tracks the last auth identity handled so a ProxyProvider can safely call
  /// [onUserSession] on every AuthController notification without re-hydrating.
  String? _sessionUid;
  bool _sessionUidSet = false;

  /// Wire the auth flow to this: pushes any pending ops, hydrates cloud data
  /// into Hive, runs the one-time migration, then reloads from Hive. No-op when
  /// no repository was injected. Idempotent per identity — repeated calls with
  /// the same user id are ignored. Never throws to the UI.
  Future<void> onUserSession(String? userId) async {
    // Scope DEVICE-LOCAL pin state to this account so pins never leak across
    // accounts on the same device (Phase 3.3.6). Safe to set even without a repo.
    HiveStorage.setCurrentAccount(userId);
    if (_repo == null) {
      _loadData();
      return;
    }
    if (_sessionUidSet && userId == _sessionUid) return; // same identity — skip
    final isAccountSwitch = _sessionUidSet && _sessionUid != null && userId != _sessionUid;
    _sessionUid = userId;
    _sessionUidSet = true;
    // On a real account switch the repo clears the local boxes and rehydrates;
    // drop the previous account's in-memory lists IMMEDIATELY so its data is
    // never shown to the new user during the async sync window.
    if (isAccountSwitch) {
      _likedTracks = [];
      _savedAlbums = [];
      _followedArtists = [];
      _followedGenres = [];
      _hiddenTrackIds = {};
      // Phase 3.4.1 (review H2): playlists are cloud-backed now — drop the
      // previous account's local playlists so private ones don't leak into the
      // new account. The new account re-hydrates its own; unsynced local
      // playlists survive in the per-user pending-op journal.
      _playlists = [];
      await HiveStorage.clearPlaylists();
      notifyListeners();
    }
    try {
      await _repo.onUserSession(userId);
    } catch (_) {
      // Cloud sync is best-effort; local library is already authoritative.
    }
    // Stamp the canonical owner on any playlist that predates ownership (derive
    // owner from the current profile when missing — Phase 3.3.6). Idempotent.
    if (userId != null) {
      await HiveStorage.migratePlaylists(ownerId: userId);
    }
    _loadData();
    // Phase 3.4.1 — cloud playlist sync (migrate local → cloud, flush queued
    // ops, hydrate owned/collaborating/followed). Best-effort; guarded.
    if (userId != null) {
      await _syncCloudPlaylists(userId);
    }
  }

  /// Replays the offline journal NOW.
  ///
  /// THE RECONNECT BUG (fixed 2026-08-09). `flushPending` had exactly one
  /// caller: `_syncCloudPlaylists`, which had exactly one caller:
  /// `onUserSession` — which early-returns when the user id is unchanged
  /// (`if (_sessionUidSet && userId == _sessionUid) return;`).
  ///
  /// So the journal was flushed EXACTLY ONCE per account per app session, at
  /// sign-in. Regaining connectivity, resuming the app, or opening the playlist
  /// again triggered nothing, and queued reorders/removals/creates sat in Hive
  /// until the app was restarted or the account changed. That is precisely what
  /// manual QA saw: "the app says it will sync later" and it never does.
  ///
  /// This is the public entry point the connectivity source calls on
  /// offline→online. It is safe to call repeatedly: PlaylistSyncService applies
  /// process-wide single-flight, and a failed flush releases that guard so a
  /// later reconnect can retry.
  Future<void> flushPendingNow() async {
    final uid = _sessionUid;
    if (!_cloudEnabled || uid == null) return;
    // The adoption transaction: re-key every LOCAL reference to the cloud UUID
    // before dependent operations are released. Idempotent — rekeyPlaylist and
    // the pin move are both no-ops if already applied.
    _cloud!.onPlaylistAdopted = (localId, cloudId, version) async {
      if (localId == cloudId) return;
      final wasPinned = HiveStorage.isPlaylistPinned(localId);
      await HiveStorage.rekeyPlaylist(localId, cloudId);
      if (wasPinned) {
        await HiveStorage.unpinPlaylist(localId);
        await HiveStorage.pinPlaylist(cloudId);
      }
      _loadData();
    };
    try {
      await _cloud.flushPending();
      // Re-hydrate so the UI reflects whatever the server now holds (adopted
      // UUIDs, applied removals, rejected ops).
      await _hydrateAfterFlush(uid);
    } catch (_) {
      // Best-effort; local Hive remains authoritative and the ops stay queued.
    }
    _loadData();
  }

  /// Called by the shared connectivity source on an offline→online transition.
  ///
  /// Gated on readiness: replaying before auth/Hive are ready would fail every
  /// op and burn retry budget for no reason.
  Future<void> onConnectivityRestored() async {
    if (!_sessionUidSet || _sessionUid == null) return; // auth not ready yet
    await flushPendingNow();
  }

  Future<void> _hydrateAfterFlush(String uid) async {
    final hydrated = await _cloud!.hydrateLibrary();
    final localById = {for (final p in HiveStorage.getPlaylists()) p.id: p};
    for (final h in hydrated) {
      final existing = localById[h.id];
      if (existing == null) {
        await HiveStorage.savePlaylist(h);
        continue;
      }
      // METADATA-PRESERVING RECONCILIATION. This previously did an
      // unconditional `savePlaylist(h)`, replacing fully-populated local Tracks
      // with the membership query's artist-less skeletons — the "Unknown
      // Artist after replay" bug. Membership and ORDER come from the server;
      // per-track metadata is kept from the local cache where it is richer.
      final merged = PlaylistRepository.reconcileTracks(
        cached: existing.tracks,
        cloud: h.tracks,
      );
      await HiveStorage.savePlaylist(existing.copyWith(
        ownerId: h.ownerId,
        ownerUsername: h.ownerUsername,
        visibility: h.visibility,
        isCollaborative: h.isCollaborative,
        collaboratorsJson: h.collaboratorsJson,
        tracks: merged,
      ));
    }
  }

  /// Phase 3.4.1 — reconcile local playlists with the cloud. Never throws;
  /// the local Hive library stays authoritative for the UI throughout.
  Future<void> _syncCloudPlaylists(String uid) async {
    if (!_cloudEnabled) return;
    try {
      // 1) One-time migration of pre-3.4.1 local (millis-id) playlists → cloud,
      //    then re-key each local playlist to its cloud UUID (only after the
      //    migration fully succeeded, so every cloud row exists first).
      final migration = PlaylistMigrationService();
      // Review H3: apply the SAME cross-account guard the library uses — never
      // upload a pre-existing UNATTRIBUTED local library (another user's leftover
      // playlists) to the first signer. Those stay local-only until clearly
      // owned; the id-map is per-user so a pre-allocated UUID can't be handed to
      // a different account.
      final unattributed = _repo?.lastSessionUnattributed ?? false;
      if (!unattributed && !migration.isMigrated(uid)) {
        final locals =
            HiveStorage.getPlaylists().where((p) => !isUuid(p.id)).toList();
        await migration.migrateForUser(uid, locals);
        if (migration.isMigrated(uid)) {
          for (final p in locals) {
            final cloudId = migration.cloudIdFor(uid, p.id);
            if (cloudId != null && cloudId != p.id) {
              await HiveStorage.rekeyPlaylist(p.id, cloudId);
            }
          }
        }
      }
      // 2) Replay any queued offline ops before hydrating.
      await _cloud!.flushPending();
      // 3) Hydrate owned + accepted-collaborating + followed cloud playlists.
      final hydrated = await _cloud!.hydrateLibrary();
      final localById = {for (final p in HiveStorage.getPlaylists()) p.id: p};
      for (final h in hydrated) {
        final existing = localById[h.id];
        if (existing == null) {
          await HiveStorage.savePlaylist(h); // nothing local to preserve
          continue;
        }
        // Same metadata-preserving reconciliation as the post-flush path.
        //
        // This branch previously did one of two wrong things: for an OWNED
        // playlist it kept the local track list wholesale (so a membership
        // change made elsewhere — or by the flush on the line above — never
        // appeared), and for a COLLABORATING playlist it did a full
        // `savePlaylist(h)`, replacing rich local Tracks with the membership
        // query's artist-less skeletons. The second is the Unknown-Artist bug
        // on the sign-in path, which the post-flush fix alone did not cover.
        await HiveStorage.savePlaylist(existing.copyWith(
          ownerId: h.ownerId,
          ownerUsername: h.ownerUsername,
          visibility: h.visibility,
          isCollaborative: h.isCollaborative,
          collaboratorsJson: h.collaboratorsJson,
          tracks: PlaylistRepository.reconcileTracks(
            cached: existing.tracks,
            cloud: h.tracks,
          ),
        ));
      }
      _loadData();
    } catch (_) {
      // Best-effort; local library remains authoritative.
    }
  }

  List<Artist> _followedArtists = [];
  List<Artist> get followedArtists => _followedArtists;

  /// Dedupe followed artists (by Deezer id, then UUID) and drop entries that
  /// cannot navigate to an artist screen (no Deezer id and no UUID). §13.
  static List<Artist> _dedupeNavigableArtists(List<Artist> list) {
    final seen = <String>{};
    final out = <Artist>[];
    for (final a in list) {
      final id = a.id.trim();
      final uuid = (a.uuid ?? '').trim();
      if (id.isEmpty && uuid.isEmpty) continue; // un-navigable
      final key = id.isNotEmpty ? 'd:$id' : 'u:$uuid';
      if (!seen.add(key)) continue; // duplicate
      out.add(a);
    }
    return out;
  }

  List<Genre> _followedGenres = [];
  List<Genre> get followedGenres => _followedGenres;

  void _loadData() {
    _likedTracks = HiveStorage.getLikedTracks();
    _playlists = HiveStorage.getPlaylists();
    _savedAlbums = HiveStorage.getSavedAlbums();
    // Phase 3.3 §13: dedupe followed artists and drop any that can't navigate
    // (no Deezer id AND no canonical UUID) so Home never renders dead cards.
    _followedArtists = _dedupeNavigableArtists(HiveStorage.getFollowedArtists());
    _followedGenres = HiveStorage.getFollowedGenres();
    _hiddenTrackIds = HiveStorage.getHiddenTrackIds();
    _pinnedPlaylistMap = HiveStorage.getPinnedPlaylistMap();
    // Clean up stale pinned entries for deleted playlists
    final existingIds = _playlists.map((p) => p.id).toSet();
    HiveStorage.cleanPinnedPlaylists(existingIds);
    notifyListeners();
  }

  Future<void> toggleFollowArtist(Artist artist) async {
    await HiveStorage.toggleFollowArtist(artist);
    _loadData();
    // Fire-and-forget cloud sync with the post-toggle state.
    _repo?.pushFollow(artist, nowFollowed: HiveStorage.isArtistFollowed(artist.id));
  }

  bool isArtistFollowed(String id) {
    return HiveStorage.isArtistFollowed(id);
  }

  Future<void> toggleFollowGenre(Genre genre) async {
    await HiveStorage.toggleFollowGenre(genre);
    _loadData();
    // Fire-and-forget cloud sync with the post-toggle state.
    _repo?.pushFollowGenre(genre,
        nowFollowed: HiveStorage.isGenreFollowed(genre.id));
  }

  bool isGenreFollowed(String deezerId) {
    return HiveStorage.isGenreFollowed(deezerId);
  }

  Future<void> toggleLike(Track track) async {
    print("LibraryController: Toggling like for ${track.title} (ID: ${track.id})");
    // Ensure we work with ID
    await HiveStorage.toggleLike(track);
    _loadData();
    _repo?.pushLike(track, nowLiked: HiveStorage.isLiked(track.id));
  }
  
  bool isLiked(Track track) {
    return HiveStorage.isLiked(track.id);
  }
  // Helper for ID check
  bool isLikedId(String id) {
    return HiveStorage.isLiked(id);
  }
  
  Future<void> createPlaylist(String name) async {
    // Phase 3.4.1: a NEW playlist is cloud-backed from creation — its local id
    // IS the cloud UUID, so it syncs and the Detail screen's cloud features
    // (contributors/last-modified/followers/roles) activate immediately.
    final id = _cloudEnabled ? newUuidV4() : DateTime.now().millisecondsSinceEpoch.toString();
    final newPlaylist = Playlist(
      id: id,
      name: name,
      tracks: [],
      createdAt: DateTime.now(),
      coverColor: 0xFF2A2A2E, // Default neutral dark gray
      ownerId: HiveStorage.currentAccountId,
      visibility: PlaylistVisibility.private,
      isCollaborative: false,
      trackPositions: const [],
    );
    await HiveStorage.savePlaylist(newPlaylist);
    _loadData();
    // Cloud create (best-effort; journals for replay when offline).
    await _guardCloud(() =>
        _cloud!.createPlaylist(name: name, visibility: 'private', tracks: const [], clientId: id));
  }

  Future<void> addToPlaylist(Playlist playlist, Track track) async {
    // Check for duplicates
    if (!playlist.tracks.any((t) => t.id == track.id)) {
      // Appended after the current maximum position (list end); positions are
      // re-normalized on persist so they stay contiguous with no duplicates.
      playlist.tracks.add(track);
      await _persistPlaylist(playlist);
      await _pushCloud(playlist.id, () => _cloud!.addTracks(playlist.id, [track]));
    }
  }

  Future<void> addTracksToPlaylist(Playlist playlist, List<Track> tracks) async {
    final added = <Track>[];
    for (var track in tracks) {
      if (!playlist.tracks.any((t) => t.id == track.id)) {
        playlist.tracks.add(track);
        added.add(track);
      }
    }
    if (added.isNotEmpty) {
      await _persistPlaylist(playlist);
      await _pushCloud(playlist.id, () => _cloud!.addTracks(playlist.id, added));
    }
  }

  /// Removes [track] from [playlist] and reports the CANONICAL outcome.
  ///
  /// Phase 3.4.4: returns a [PlaylistMutationResult] instead of silently
  /// swallowing failures, so the caller can tell "removed", "queued offline"
  /// and "the server refused" apart. Local state is updated optimistically and
  /// ROLLED BACK on an authoritative refusal (conflict/forbidden), so the UI can
  /// never diverge from the server on a rejected mutation.
  Future<PlaylistMutationResult> removeFromPlaylist(
      Playlist playlist, Track track) async {
    final index = playlist.tracks.indexWhere((t) => t.id == track.id);
    if (index < 0) return PlaylistMutationResult.applied; // already absent
    final removed = playlist.tracks[index];

    // Removal never corrupts the remaining order — positions are re-normalized.
    playlist.tracks.removeAt(index);
    await _persistPlaylist(playlist);

    if (!_cloudEnabled || !isUuid(playlist.id)) {
      return PlaylistMutationResult.applied; // local-only playlist
    }
    try {
      await _cloud!.removeTracks(playlist.id, [track]);
      return PlaylistMutationResult.applied;
    } on PlaylistConflictException {
      await _restoreTrack(playlist, removed, index);
      return PlaylistMutationResult.conflict;
    } on PlaylistForbiddenException {
      await _restoreTrack(playlist, removed, index);
      return PlaylistMutationResult.forbidden;
    } catch (e) {
      // Journalled by the repository on a network error — the removal stands
      // locally and replays later. Anything else is a genuine failure.
      final kind = PlaylistRepository.classifyPlaylistOpError(e).kind;
      if (kind == PlaylistFailureKind.transientNetwork) {
        return PlaylistMutationResult.queuedOffline;
      }
      await _restoreTrack(playlist, removed, index);
      return PlaylistMutationResult.failed;
    }
  }

  /// Puts an optimistically-removed track back at its original position.
  Future<void> _restoreTrack(Playlist playlist, Track track, int index) async {
    final at = index.clamp(0, playlist.tracks.length);
    playlist.tracks.insert(at, track);
    await _persistPlaylist(playlist);
  }

  /// Commit a manually-reordered track list (Phase 3.3.6). Called ONLY when the
  /// user presses Save in Edit Order mode. Persists to Hive, then pushes the
  /// atomic reorder to the cloud (best-effort; journaled offline).
  Future<PlaylistMutationResult> commitPlaylistOrder(
      Playlist playlist, List<Track> newOrder,
      {int? expectedVersion, List<Track>? originalOrder}) async {
    final ordered = List<Track>.from(newOrder);

    // Phase 3.4.4 — decompose the Save into the operations that actually
    // happened, so Activity reflects reality.
    //
    // `playlist_save_order` REJECTS a changed membership (ORDER_SET_MISMATCH)
    // and logs only `tracks_reordered`, so a removal made in Edit Order could
    // neither be committed through it nor be seen in Activity. Removals go
    // through removeTracks, additions through addTracks, and the reorder runs
    // only when the surviving tracks' relative order actually changed.
    final diff = originalOrder == null
        ? null
        : EditOrderDiff.between(originalOrder, ordered);

    playlist.tracks
      ..clear()
      ..addAll(ordered);
    await _persistPlaylist(playlist);

    if (!_cloudEnabled || !isUuid(playlist.id)) {
      return PlaylistMutationResult.applied;
    }

    try {
      if (diff != null && diff.removed.isNotEmpty) {
        await _cloud!.removeTracks(playlist.id, diff.removed);
      }
      if (diff != null && diff.added.isNotEmpty) {
        await _cloud!.addTracks(playlist.id, diff.added);
      }
      // Only reorder when order genuinely changed. After a membership change the
      // server version has moved, so the caller's expectedVersion is stale by
      // design — pass null and let the membership RPCs' own authorization stand.
      if (diff == null || diff.reordered) {
        await _cloud!.saveOrder(
          playlist.id,
          ordered,
          diff != null && diff.hasMembershipChange ? null : expectedVersion,
        );
      }
      return PlaylistMutationResult.applied;
    } on PlaylistConflictException {
      return PlaylistMutationResult.conflict;
    } on PlaylistForbiddenException {
      return PlaylistMutationResult.forbidden;
    } catch (e) {
      final kind = PlaylistRepository.classifyPlaylistOpError(e).kind;
      return kind == PlaylistFailureKind.transientNetwork
          ? PlaylistMutationResult.queuedOffline
          : PlaylistMutationResult.failed;
    }
  }

  /// Locally unfollow a non-owned (followed) playlist: remove it from the local
  /// library + pin, and best-effort cloud unfollow. Used from the Library row's
  /// overflow for playlists the user does not own.
  Future<void> unfollowPlaylist(String playlistId) async {
    await HiveStorage.deletePlaylist(playlistId);
    await HiveStorage.unpinPlaylist(playlistId);
    _loadData();
    if (_cloudEnabled && isUuid(playlistId)) {
      try {
        await _cloud!.setFollow(playlistId, false);
      } catch (_) {}
    }
  }

  /// Persist a playlist with normalized explicit track positions, then reload so
  /// the in-memory list reflects the stored object.
  Future<void> _persistPlaylist(Playlist playlist) async {
    final normalized = playlist.withNormalizedPositions();
    await HiveStorage.savePlaylist(normalized);
    _loadData();
  }

  /// Delete an OWNED playlist (Phase 3.4.1.1 B). For a cloud-backed (UUID)
  /// playlist the soft-delete RPC runs FIRST — only on success is the local
  /// cache + device-local pin removed, so a failed/offline delete can never
  /// leave a local/cloud divergence (it throws; the UI keeps the playlist and
  /// shows an error). Legacy local (non-UUID) playlists delete locally only.
  Future<void> deletePlaylist(Playlist playlist) async {
    final id = playlist.id;
    // A playlist created OFFLINE already has a client UUID, so `isUuid` alone
    // cannot tell us whether the cloud knows about it. Calling the delete RPC
    // for a row that was never created returns NOT_FOUND and throws, leaving an
    // undeletable ghost. Cancel the queued create instead — nothing was ever
    // created remotely, so nothing needs deleting remotely.
    if (_cloudEnabled && _cloud!.isLocalOnly(id)) {
      await _cloud!.cancelLocalOnly(id);
    } else if (_cloudEnabled && isUuid(id)) {
      try {
        await _cloud!.deletePlaylist(id); // authoritative when reachable
      } catch (e) {
        // OFFLINE-FIRST DELETE (Phase 3.4.8). The repository has already
        // journalled the delete for replay, so a connectivity failure is NOT a
        // failure from the user's point of view — showing "Couldn't delete the
        // playlist" was wrong. Hide it locally and let replay soft-delete it.
        //
        // Anything that is NOT a connectivity failure (forbidden, not-found,
        // conflict) still propagates so the UI can surface a real refusal.
        final kind = PlaylistRepository.classifyPlaylistOpError(e).kind;
        if (kind != PlaylistFailureKind.transientNetwork) rethrow;
      }
    }
    await HiveStorage.deletePlaylist(id);
    await HiveStorage.unpinPlaylist(id); // remove device-local pin (spec H)
    _loadData();
  }

  /// Accepted collaborator leaves a playlist: remove it from THIS user's library
  /// (+ pin) and call the leave RPC. The source playlist is untouched.
  Future<void> leavePlaylist(String playlistId) async {
    await HiveStorage.deletePlaylist(playlistId);
    await HiveStorage.unpinPlaylist(playlistId);
    _loadData();
    if (_cloudEnabled && isUuid(playlistId)) {
      try {
        await _cloud!.leave(playlistId);
      } catch (_) {}
    }
  }

  Future<void> renamePlaylist(Playlist playlist, String newName) async {
    // copyWith preserves owner/collaborators/visibility/positions (Phase 3.3.6).
    await HiveStorage.savePlaylist(playlist.copyWith(name: newName));
    _loadData();
    await _pushCloud(playlist.id,
        () => _cloud!.updateMetadata(playlist.id, name: newName));
  }

  // ── cloud push helpers (best-effort; never throw to the UI) ──
  Future<void> _guardCloud(Future<void> Function() run) async {
    if (!_cloudEnabled) return;
    try {
      await run();
    } catch (_) {/* journaled by the repo or reconciled next session */}
  }

  /// Push a mutation only for a cloud-backed (UUID) playlist. Local-only
  /// (non-UUID) playlists never hit the cloud.
  Future<void> _pushCloud(String playlistId, Future<void> Function() run) async {
    if (!_cloudEnabled || !isUuid(playlistId)) return;
    try {
      await run();
    } catch (_) {/* addTracks/removeTracks/saveOrder journal on network error */}
  }
  
  Future<void> toggleSaveAlbum(SavedAlbum album) async {
    await HiveStorage.toggleSaveAlbum(album);
    _loadData();
    _repo?.pushSave(album, nowSaved: HiveStorage.isAlbumSaved(album.albumId));
  }
  
  bool isAlbumSaved(String id) {
    return HiveStorage.isAlbumSaved(id);
  }

  // ── Hidden Tracks ──

  bool isHidden(String trackId) => _hiddenTrackIds.contains(trackId);

  Future<void> toggleHideTrack(String trackId) async {
    await HiveStorage.toggleHideTrack(trackId);
    _hiddenTrackIds = HiveStorage.getHiddenTrackIds();
    notifyListeners();
    // Best-effort: recover the Track (for its Deezer id) from the loaded liked
    // list so the cloud side can resolve it. If not found, pushHide is a
    // documented local-only no-op.
    Track? track;
    for (final t in _likedTracks) {
      if (t.id == trackId) {
        track = t;
        break;
      }
    }
    _repo?.pushHide(trackId,
        nowHidden: HiveStorage.isTrackHidden(trackId), track: track);
  }

  // ── Pinned Playlists ──

  bool isPlaylistPinned(String playlistId) =>
      _pinnedPlaylistMap.containsKey(playlistId);

  int get pinnedCount => _pinnedPlaylistMap.length;

  /// Returns the pinnedAt timestamp for sorting. 0 if not pinned.
  int pinnedAt(String playlistId) => _pinnedPlaylistMap[playlistId] ?? 0;

  /// Toggle pin. Returns true=pinned, false=unpinned, null=limit reached.
  Future<bool?> togglePinPlaylist(String playlistId) async {
    final result = await HiveStorage.togglePinPlaylist(playlistId);
    _pinnedPlaylistMap = HiveStorage.getPinnedPlaylistMap();
    notifyListeners();
    return result;
  }
}
