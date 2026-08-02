// lib/data/repositories/library_repository.dart
//
// Phase 3.2A — Cloud Library Sync orchestrator.
//
// Coordinates the local library (HiveStorage), the cloud relation tables
// (LibraryRemoteDataSource), Deezer→UUID resolution (CatalogResolver), and the
// sync bookkeeping / pending-ops journal (LibrarySyncState).
//
// DESIGN — offline-first, best-effort cloud:
//   - The optimistic LOCAL write already happened in LibraryController BEFORE
//     these push* methods run. These methods only do the CLOUD side.
//   - Every cloud call is wrapped: a failure degrades to a pending journal
//     entry. NOTHING here throws to the UI.
//
// CONFLICT RULES (cloud is the durable authority after auth):
//   - Optimistic local writes that have not reached the cloud are captured as
//     pending ops, so they WIN until synced.
//   - hydrateFromCloud() only ever ADDS items to the local library.
//   - A removal (unlike/unfollow/unsave/unhide) must NOT be resurrected by a
//     hydrate. This is enforced by SKIPPING any cloud item that has a pending
//     'remove' op for its Deezer id — i.e. a pending removal cancels a
//     hydrated add. flushPending() later pushes the removal to the cloud.
//
// ACCOUNT SWITCH:
//   - onUserSession clears the local library boxes only when a DIFFERENT,
//     previously-known account signs in on this device (lastUserId != null &&
//     lastUserId != userId). On the very first sign-in (lastUserId == null) the
//     pre-auth local library is PRESERVED so migrateLocalToCloud() can push it.

import 'package:flutter/foundation.dart';

import '../../core/utils/artwork_resolver.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/genre.dart';
import '../../domain/entities/playlist_contributors.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/track.dart';
import '../local/hive_storage.dart';
import '../local/library_sync_state.dart';
import '../remote/catalog_resolver.dart';
import '../remote/library_remote_data_source.dart';

class LibraryRepository {
  final LibraryRemoteDataSource _remote;
  final CatalogResolver _resolver;
  final LibrarySyncState _syncState;

  /// Phase 3.4.1 — true when the most recent [onUserSession] classified the
  /// pre-existing local library as UNATTRIBUTED (a first sign-in whose local
  /// data can't be safely attributed to this account). Playlist migration reads
  /// this to apply the SAME cross-account safety guard (don't upload another
  /// user's leftover local playlists to the first signer).
  bool _lastUnattributed = false;
  bool get lastSessionUnattributed => _lastUnattributed;

  LibraryRepository({
    LibraryRemoteDataSource? remote,
    CatalogResolver? resolver,
    LibrarySyncState? syncState,
  })  : _remote = remote ?? LibraryRemoteDataSource(),
        _resolver = resolver ?? CatalogResolver(),
        _syncState = syncState ?? LibrarySyncState();

  void _log(String msg) {
    if (kDebugMode) debugPrint('[LibrarySync] $msg');
  }

  // ── PUSH (cloud side of an already-applied local mutation) ────────

  Future<void> pushFollow(Artist a, {required bool nowFollowed}) async {
    await _push(
      kind: SyncOpKind.follow,
      add: nowFollowed,
      deezerId: a.id,
      resolve: () => _resolver.resolveArtist(a.id),
      remoteAdd: _remote.followArtist,
      remoteRemove: _remote.unfollowArtist,
    );
  }

  Future<void> pushFollowGenre(Genre g, {required bool nowFollowed}) async {
    await _push(
      kind: SyncOpKind.genreFollow,
      add: nowFollowed,
      deezerId: g.id,
      resolve: () => _resolver.resolveGenre(g.id),
      remoteAdd: _remote.followGenre,
      remoteRemove: _remote.unfollowGenre,
    );
  }

  Future<void> pushLike(Track t, {required bool nowLiked}) async {
    await _push(
      kind: SyncOpKind.like,
      add: nowLiked,
      deezerId: t.deezerTrackId,
      resolve: () => _resolver.resolveTrack(t.deezerTrackId),
      remoteAdd: _remote.likeTrack,
      remoteRemove: _remote.unlikeTrack,
    );
  }

  Future<void> pushSave(SavedAlbum al, {required bool nowSaved}) async {
    await _push(
      kind: SyncOpKind.save,
      add: nowSaved,
      deezerId: al.albumId,
      resolve: () => _resolver.resolveAlbum(al.albumId),
      remoteAdd: _remote.saveAlbum,
      remoteRemove: _remote.unsaveAlbum,
    );
  }

  /// Hide/unhide the cloud side. [trackId] is the local videoId; to resolve to
  /// a catalog UUID we need the track's Deezer id, so a [track] is required.
  /// If no [track] (or it lacks a Deezer id) is available we can neither push
  /// nor journal (a pending op needs a Deezer id), so this is a no-op —
  /// documented local-only behaviour.
  Future<void> pushHide(
    String trackId, {
    required bool nowHidden,
    Track? track,
  }) async {
    final deezerId = track?.deezerTrackId;
    if (deezerId == null || deezerId.trim().isEmpty) {
      _log('pushHide skipped — no Deezer id for videoId=$trackId (local-only).');
      return;
    }
    await _push(
      kind: SyncOpKind.hide,
      add: nowHidden,
      deezerId: deezerId,
      resolve: () => _resolver.resolveTrack(deezerId),
      remoteAdd: _remote.hideTrack,
      remoteRemove: _remote.unhideTrack,
    );
  }

  /// Shared push path: resolve the Deezer id, run the matching remote call,
  /// and on ANY failure (unresolved id or network error) enqueue a pending op.
  Future<void> _push({
    required SyncOpKind kind,
    required bool add,
    required String? deezerId,
    required Future<String?> Function() resolve,
    required Future<void> Function(String uuid) remoteAdd,
    required Future<void> Function(String uuid) remoteRemove,
  }) async {
    if (deezerId == null || deezerId.trim().isEmpty) {
      _log('push ${kind.name}: missing Deezer id — staying local-only.');
      return;
    }
    try {
      final uuid = await resolve();
      if (uuid == null) {
        await _enqueue(kind, add, deezerId);
        return;
      }
      if (add) {
        await remoteAdd(uuid);
      } else {
        await remoteRemove(uuid);
      }
    } catch (e) {
      _log('push ${kind.name} failed ($e) — journaling pending op.');
      await _enqueue(kind, add, deezerId);
    }
  }

  Future<void> _enqueue(SyncOpKind kind, bool add, String deezerId) async {
    await _syncState.enqueue(PendingOp(
      op: add ? SyncOpType.add : SyncOpType.remove,
      kind: kind,
      deezerId: deezerId.trim(),
    ));
  }

  // ── PLAYLIST TRACK ORDER (cloud-ready seam, Phase 3.3.6) ──────────
  //
  // Manual playlist ordering is persisted LOCALLY (Hive) by LibraryController;
  // this is the contract Phase 3.4 will implement to push explicit, normalized
  // positions to Supabase `playlist_tracks`. NO Supabase call is made yet.
  //
  //   updatePlaylistTrackPositions(playlistId, [{playlistTrackId, position}, …])
  //
  // Positions are zero-based, contiguous and de-duplicated by the caller.
  Future<void> updatePlaylistTrackPositions(
    String playlistId,
    List<PlaylistTrackPosition> positions,
  ) async {
    _log('updatePlaylistTrackPositions(playlist=$playlistId, '
        '${positions.length} tracks) — local-only this phase (Phase 3.4 cloud).');
    // Intentionally no cloud call yet — the seam exists so the UI/controller
    // contract is stable before Supabase playlist sync lands.
  }

  // ── FLUSH pending journal ─────────────────────────────────────────

  Future<void> flushPending() async {
    final ops = await _syncState.getPendingOps();
    if (ops.isEmpty) return;
    _log('flushPending: ${ops.length} op(s).');

    // Batch-resolve all Deezer ids per kind up front (no per-op catalog query).
    final byKind = <SyncOpKind, Set<String>>{};
    for (final o in ops) {
      byKind.putIfAbsent(o.kind, () => <String>{}).add(o.deezerId);
    }
    final resolved = <SyncOpKind, Map<String, String>>{};
    for (final entry in byKind.entries) {
      resolved[entry.key] = await _resolveForKind(entry.key, entry.value);
    }

    final remaining = <PendingOp>[];
    for (final op in ops) {
      final uuid = resolved[op.kind]?[op.deezerId];
      if (uuid == null) {
        // Unresolved: an 'add' may resolve once the catalog catches up — keep
        // it. A 'remove' for an item that isn't in the catalog was never in the
        // cloud — safe to DROP.
        if (op.op == SyncOpType.add) remaining.add(op);
        continue;
      }
      try {
        await _applyRemote(op.kind, op.op, uuid);
      } catch (e) {
        _log('flush op ${op.kind.name}/${op.op.name} failed ($e) — retained.');
        remaining.add(op);
      }
    }

    await _syncState.replaceAll(remaining);
    _log('flushPending done: ${remaining.length} op(s) remain.');
  }

  Future<Map<String, String>> _resolveForKind(
    SyncOpKind kind,
    Iterable<String> deezerIds,
  ) {
    switch (kind) {
      case SyncOpKind.follow:
        return _resolver.resolveArtists(deezerIds);
      case SyncOpKind.genreFollow:
        return _resolver.resolveGenres(deezerIds);
      case SyncOpKind.save:
        return _resolver.resolveAlbums(deezerIds);
      case SyncOpKind.like:
      case SyncOpKind.hide:
        return _resolver.resolveTracks(deezerIds);
    }
  }

  Future<void> _applyRemote(SyncOpKind kind, SyncOpType op, String uuid) {
    final add = op == SyncOpType.add;
    switch (kind) {
      case SyncOpKind.follow:
        return add ? _remote.followArtist(uuid) : _remote.unfollowArtist(uuid);
      case SyncOpKind.genreFollow:
        return add ? _remote.followGenre(uuid) : _remote.unfollowGenre(uuid);
      case SyncOpKind.save:
        return add ? _remote.saveAlbum(uuid) : _remote.unsaveAlbum(uuid);
      case SyncOpKind.like:
        return add ? _remote.likeTrack(uuid) : _remote.unlikeTrack(uuid);
      case SyncOpKind.hide:
        return add ? _remote.hideTrack(uuid) : _remote.unhideTrack(uuid);
    }
  }

  // ── HYDRATE (cloud → local, ADD-only, respecting pending removals) ─

  Future<void> hydrateFromCloud() async {
    // Pending removals cancel hydrated adds (conflict rule).
    final pending = await _syncState.getPendingOps();
    Set<String> removedIds(SyncOpKind kind) => pending
        .where((o) => o.op == SyncOpType.remove && o.kind == kind)
        .map((o) => o.deezerId)
        .toSet();
    final removedLikes = removedIds(SyncOpKind.like);
    final removedSaves = removedIds(SyncOpKind.save);
    final removedFollows = removedIds(SyncOpKind.follow);
    final removedGenreFollows = removedIds(SyncOpKind.genreFollow);
    final removedHidden = removedIds(SyncOpKind.hide);

    try {
      final artistUuids = await _remote.fetchFollowedArtistIds();
      final genreUuids = await _remote.fetchFollowedGenreIds();
      final albumUuids = await _remote.fetchSavedAlbumIds();
      final likedUuids = await _remote.fetchLikedTrackIds();
      final hiddenUuids = await _remote.fetchHiddenTrackIds();

      // Artists
      if (artistUuids.isNotEmpty) {
        final rows = await _remote.fetchCatalogArtists(artistUuids);
        for (final row in rows) {
          final dz = row['deezer_id']?.toString();
          // Skip un-navigable rows (no Deezer id → the artist screen can't open).
          if (dz == null || dz.isEmpty) continue;
          if (removedFollows.contains(dz)) continue;

          // Canonical resolver: cached → original → …; never blanks when a
          // valid image exists on the row (Phase 3.3 §7/§13).
          final resolved = ArtworkResolver.artist(row);
          final existing = HiveStorage.getFollowedArtist(dz);

          // Phase 3.3.1 §1: UPSERT (not skip) so an already-followed artist whose
          // stored picture is empty gets backfilled once the catalog row has an
          // image. Never regress a good stored picture to empty.
          final picture = resolved.isNotEmpty
              ? resolved
              : (existing?.picture ?? '');
          if (existing != null &&
              existing.picture == picture &&
              existing.uuid == (row['id']?.toString())) {
            continue; // nothing changed
          }
          await HiveStorage.putFollowedArtist(Artist(
            id: dz,
            name: (row['name'] ?? existing?.name ?? '').toString(),
            picture: picture,
            nbFans: existing?.nbFans ?? 0,
            uuid: row['id']?.toString(),
          ));
        }
      }

      // Followed genres
      if (genreUuids.isNotEmpty) {
        final rows = await _remote.fetchCatalogGenres(genreUuids);
        for (final row in rows) {
          final dz = row['deezer_id']?.toString();
          if (dz == null || dz.isEmpty) continue;
          if (removedGenreFollows.contains(dz)) continue;
          if (HiveStorage.isGenreFollowed(dz)) continue;
          await HiveStorage.toggleFollowGenre(Genre(
            id: dz,
            name: (row['name'] ?? '').toString(),
            imageUrl: (row['image_cached_url'] ?? row['image_original_url'])
                ?.toString(),
            slug: row['slug']?.toString(),
            supabaseId: row['id']?.toString(),
          ));
        }
      }

      // Albums
      if (albumUuids.isNotEmpty) {
        final rows = await _remote.fetchCatalogAlbums(albumUuids);
        for (final row in rows) {
          final dz = row['deezer_id']?.toString();
          if (dz == null || dz.isEmpty) continue;
          if (removedSaves.contains(dz)) continue;
          if (HiveStorage.isAlbumSaved(dz)) continue;
          await HiveStorage.toggleSaveAlbum(SavedAlbum(
            albumId: dz,
            title: (row['title'] ?? '').toString(),
            artistName: '',
            artworkUrl: (row['cover_cached_url'] ??
                    row['cover_original_url'] ??
                    '')
                .toString(),
          ));
        }
      }

      // Liked tracks
      if (likedUuids.isNotEmpty) {
        final rows = await _remote.fetchCatalogTracks(likedUuids);
        for (final row in rows) {
          final dz = row['deezer_id']?.toString();
          final videoId = row['preferred_youtube_video_id']?.toString();
          if (videoId == null || videoId.isEmpty) continue; // unplayable
          if (dz != null && removedLikes.contains(dz)) continue;
          if (HiveStorage.isLiked(videoId)) continue;
          await HiveStorage.toggleLike(_trackFromCatalog(row, videoId, dz));
        }
      }

      // Hidden tracks (stored locally as videoId strings)
      if (hiddenUuids.isNotEmpty) {
        final rows = await _remote.fetchCatalogTracks(hiddenUuids);
        for (final row in rows) {
          final dz = row['deezer_id']?.toString();
          final videoId = row['preferred_youtube_video_id']?.toString();
          if (videoId == null || videoId.isEmpty) continue;
          if (dz != null && removedHidden.contains(dz)) continue;
          if (HiveStorage.isTrackHidden(videoId)) continue;
          await HiveStorage.toggleHideTrack(videoId);
        }
      }
      _log('hydrateFromCloud done.');
    } catch (e) {
      _log('hydrateFromCloud failed ($e) — kept local library.');
    }
  }

  Track _trackFromCatalog(
    Map<String, dynamic> row,
    String videoId,
    String? deezerId,
  ) {
    final durSecs = row['duration_seconds'];
    return Track(
      id: videoId,
      title: (row['title'] ?? '').toString(),
      artistName: '',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: durSecs is int ? durSecs : int.tryParse('${durSecs ?? ''}') ?? 0,
      deezerTrackId: deezerId,
    );
  }

  // ── SESSION lifecycle ─────────────────────────────────────────────

  Future<void> onUserSession(String? userId) async {
    if (userId == null) return; // signed out — no-op.

    final lastUserId = await _syncState.getLastUserId();
    final switchedAccount = lastUserId != null && lastUserId != userId;
    if (switchedAccount) {
      _log('account switch ($lastUserId -> $userId) — clearing local library.');
      await HiveStorage.clearLibraryBoxes();
      // Pending ops + resolver-independent state belonged to the previous user.
      await _syncState.clearPending();
    }
    // A pre-existing local library with NO recorded owner (lastUserId == null)
    // predates cloud sync and cannot be safely attributed to this account — it
    // may be a different user's data left on this device before Phase 3.2A.
    // Uploading it would be a cross-account write, so we keep it LOCAL-ONLY
    // (never discarded) and suppress the one-time bulk migration for it. New
    // in-session actions still sync normally; a later real account switch clears
    // the local boxes. Only genuinely unattributable data is affected.
    final unattributedLocal = !switchedAccount &&
        lastUserId == null &&
        _hasLocalLibrary();
    _lastUnattributed = unattributedLocal;

    await _syncState.setLastUserId(userId);

    // Order matters: push local removals/adds first so hydrate sees the truth.
    await flushPending();
    await hydrateFromCloud();
    if (unattributedLocal) {
      _log('first sync with a pre-existing, unowned local library — keeping it '
          'local-only (no bulk upload) to avoid a cross-account write.');
      await _syncState.setMigrated(userId);
    } else {
      await migrateLocalToCloud();
    }
  }

  /// True when any cloud-syncable local library box currently holds data.
  bool _hasLocalLibrary() {
    return HiveStorage.getLikedTracks().isNotEmpty ||
        HiveStorage.getFollowedArtists().isNotEmpty ||
        HiveStorage.getFollowedGenres().isNotEmpty ||
        HiveStorage.getSavedAlbums().isNotEmpty ||
        HiveStorage.getHiddenTrackIds().isNotEmpty;
  }

  // ── One-time local → cloud migration (per user) ───────────────────

  /// Pushes the pre-existing local library to the cloud once per user. The
  /// [userId] guard defaults to the currently authenticated user.
  Future<void> migrateLocalToCloud([String? userId]) async {
    final uid = userId ?? _remote.currentUserId;
    if (uid == null) return;
    if (await _syncState.isMigrated(uid)) return;

    int pushed = 0;
    int unresolved = 0;

    try {
      // Follows
      final artists = HiveStorage.getFollowedArtists();
      final artistMap =
          await _resolver.resolveArtists(artists.map((a) => a.id));
      for (final a in artists) {
        final uuid = artistMap[a.id.trim()];
        if (uuid == null) {
          unresolved++;
          continue;
        }
        try {
          await _remote.followArtist(uuid);
          pushed++;
        } catch (_) {}
      }

      // Followed genres
      final genres = HiveStorage.getFollowedGenres();
      final genreMap =
          await _resolver.resolveGenres(genres.map((g) => g.id));
      for (final g in genres) {
        final uuid = genreMap[g.id.trim()];
        if (uuid == null) {
          unresolved++;
          continue;
        }
        try {
          await _remote.followGenre(uuid);
          pushed++;
        } catch (_) {}
      }

      // Saves
      final albums = HiveStorage.getSavedAlbums();
      final albumMap =
          await _resolver.resolveAlbums(albums.map((al) => al.albumId));
      for (final al in albums) {
        final uuid = albumMap[al.albumId.trim()];
        if (uuid == null) {
          unresolved++;
          continue;
        }
        try {
          await _remote.saveAlbum(uuid);
          pushed++;
        } catch (_) {}
      }

      // Likes
      final liked = HiveStorage.getLikedTracks();
      final likedMap = await _resolver
          .resolveTracks(liked.map((t) => t.deezerTrackId));
      for (final t in liked) {
        final dz = t.deezerTrackId?.trim();
        final uuid = dz == null ? null : likedMap[dz];
        if (uuid == null) {
          unresolved++;
          continue;
        }
        try {
          await _remote.likeTrack(uuid);
          pushed++;
        } catch (_) {}
      }

      // Hidden — stored as videoIds only. Best-effort: recover Deezer ids from
      // any locally-known Track (liked + recently played). Hidden tracks with
      // no matching local Track cannot be migrated and stay local-only.
      final hiddenIds = HiveStorage.getHiddenTrackIds();
      if (hiddenIds.isNotEmpty) {
        final videoToDeezer = <String, String>{};
        for (final t in [...liked, ...HiveStorage.getRecentlyPlayed()]) {
          final dz = t.deezerTrackId;
          if (dz != null && dz.trim().isNotEmpty) {
            videoToDeezer[t.id] = dz.trim();
          }
        }
        final hiddenDeezerIds =
            hiddenIds.map((v) => videoToDeezer[v]).whereType<String>();
        final hiddenMap = await _resolver.resolveTracks(hiddenDeezerIds);
        for (final v in hiddenIds) {
          final dz = videoToDeezer[v];
          final uuid = dz == null ? null : hiddenMap[dz];
          if (uuid == null) {
            unresolved++;
            continue;
          }
          try {
            await _remote.hideTrack(uuid);
            pushed++;
          } catch (_) {}
        }
      }

      await _syncState.setMigrated(uid);
      _log('migrateLocalToCloud done: pushed=$pushed unresolved=$unresolved '
          '(stay local-only).');
    } catch (e) {
      // Do NOT mark migrated on a hard failure — retry next session.
      _log('migrateLocalToCloud aborted ($e) — will retry next session.');
    }
  }
}
