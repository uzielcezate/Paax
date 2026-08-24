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
import '../sync/pending_track_ref.dart';
import '../sync/playlist_op.dart';
import '../sync/playlist_op_failure.dart';
import '../sync/playlist_sync_service.dart';

/// What a queued reorder should do when it is finally replayed.
enum SaveOrderReplayAction {
  /// Membership still matches — push the intended order.
  send,

  /// The playlist's contents changed while we were offline, so the intended
  /// order is no longer applicable. TERMINAL: surfaced once, never retried.
  membershipConflict,

  /// The playlist is deleted or no longer visible to this user.
  playlistGone,
}

class SaveOrderReplayPlan {
  final SaveOrderReplayAction action;

  /// The version to assert, re-derived at replay time — never the one captured
  /// while offline.
  final int? expectedVersion;

  const SaveOrderReplayPlan(this.action, {this.expectedVersion});
}

/// An immutable snapshot of "how many adds had finished per playlist", taken
/// immediately BEFORE an authoritative read is issued so the read's result can
/// be interpreted causally. See [PlaylistRepository.addOverlapped].
class AddFence {
  final Map<String, int> completed;
  const AddFence(this.completed);
  static const AddFence empty = AddFence({});
}

class PlaylistRepository {
  final PlaylistRemoteDataSource _remote;
  final CatalogResolver _resolver;
  final PlaylistSyncService _sync;

  /// Injected so tests exercise the real readiness loop without real delays.
  final Future<void> Function(Duration) _sleep;

  /// Bounded post-ingest identity wait: at most 3 attempts ~200 ms apart, so a
  /// single Add tap can never take more than ~0.4 s longer than before.
  static const int _identityReadyAttempts = 3;
  static const Duration _identityReadyBackoff = Duration(milliseconds: 200);

  PlaylistRepository({
    PlaylistRemoteDataSource? remote,
    CatalogResolver? resolver,
    PlaylistSyncService? sync,
    Future<void> Function(Duration)? sleep,
  })  : _remote = remote ?? PlaylistRemoteDataSource(),
        _resolver = resolver ?? CatalogResolver(),
        _sync = sync ?? PlaylistSyncService(PlaylistOpsJournal()),
        _sleep = sleep ?? Future<void>.delayed;

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
    final slots = await _resolveSlots(tracks);
    final uuids = <String>[];
    final unresolved = <Track>[];
    for (var i = 0; i < tracks.length; i++) {
      final u = slots[i];
      if (u != null) {
        uuids.add(u);
      } else {
        unresolved.add(tracks[i]);
      }
    }
    return (uuids: uuids, unresolved: unresolved);
  }

  /// The same two-stage resolution, reported POSITIONALLY: `slots[i]` is the
  /// catalog UUID for `tracks[i]`, or null when it has none yet.
  ///
  /// Position matters for an order-sensitive op: a queued reorder must be able
  /// to splice a later-resolved UUID back into the exact slot the user put it
  /// in, which a compacted "resolved ids + leftovers" pair cannot express.
  Future<List<String?>> _resolveSlots(List<Track> tracks) async {
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

    return [
      for (final t in tracks)
        byDeezer[(t.deezerTrackId ?? '').trim()] ?? byVideoId[t.id.trim()]
    ];
  }

  /// Resolves [tracks], throwing rather than silently losing any of them.
  ///
  /// Throws [PlaylistOpFailure] with `localIntegrity` when ANY track cannot be
  /// mapped to a catalog UUID. `localIntegrity` is deliberate: this is not a
  /// network problem and retrying cannot fix it, so the op is discarded rather
  /// than queued forever — and, critically, the caller rolls the optimistic UI
  /// back instead of leaving a phantom track on screen.
  Future<List<String>> _resolveOrThrow(List<Track> tracks) async {
    final r = await _resolveWithIngest(tracks);
    final unresolved = [
      for (var i = 0; i < tracks.length; i++)
        if (r.slots[i] == null) tracks[i]
    ];
    if (unresolved.isNotEmpty) {
      throw _unresolvedFailure(unresolved);
    }
    return r.slots.cast<String>();
  }

  static PlaylistOpFailure _unresolvedFailure(List<Track> unresolved) {
    final titles = unresolved.map((t) => t.title).take(3).join(', ');
    return PlaylistOpFailure(
      PlaylistFailureKind.localIntegrity,
      cause: 'UNRESOLVED_TRACK: ${unresolved.length} track(s) are not in '
          'the Paax catalog and cannot be synced ($titles)',
    );
  }

  /// Resolve → ingest-on-miss → bounded re-resolve, reported per slot.
  ///
  /// This is the whole of the old [_resolveOrThrow] minus its final throw, so
  /// the ONLINE behaviour is byte-identical and there is exactly one ingest
  /// path in the app: an offline add that queues intent and the replay that
  /// completes it both run THIS function, not a copy of it.
  ///
  /// [lookupError] is what the resolver last hit, so the caller can tell
  /// "the catalog says no" from "we never reached the catalog".
  Future<({List<String?> slots, Object? lookupError})> _resolveWithIngest(
      List<Track> tracks) async {
    var slots = await _resolveSlots(tracks);
    var lookupError = _resolver.lastLookupError;
    List<Track> stillMissing() => [
          for (var i = 0; i < tracks.length; i++)
            if (slots[i] == null) tracks[i]
        ];
    var unresolved = stillMissing();

    // INGEST-ON-MISS (Phase 3.4.8). Artist Top Tracks was the only add-to-
    // playlist entry point that never triggers catalog ingestion — Album,
    // Search and Player all reach paax-api endpoints that upsert the catalog
    // graph as a side effect. So the SAME song was addable from an album and
    // not from the artist's Top Tracks, purely because its row did not exist
    // yet. (Verified: the Top Tracks payload carries the correct deezer id and
    // videoId; the catalog simply had no row. The catalog grew 544→584 during
    // one debugging session just by opening albums.)
    //
    // Asking paax-api for the track ingests it, so we retry resolution ONCE.
    // Bounded and non-recursive: one ingest attempt, one re-resolve, then an
    // explicit failure.
    if (unresolved.isNotEmpty) {
      // Ingest via the track's ALBUM. `/v2/track/{id}` returns data but does
      // NOT write to Supabase (verified: three top-track ids still had zero
      // catalog rows after calling it), whereas `/v2/albums/deezer/{id}`
      // upserts the whole album graph. That is exactly why "open the album
      // first, then add" always worked and adding straight from Artist Top
      // Tracks did not.
      final albumIds = unresolved
          .map((t) => t.albumId.trim())
          .where((id) => int.tryParse(id) != null)
          .toSet();
      if (albumIds.isNotEmpty) {
        await _resolver.ingestAlbums(albumIds);
        lookupError = _resolver.lastLookupError ?? lookupError;
        // IDENTITY READINESS (Phase 3.4.13). This used to re-resolve exactly
        // ONCE, immediately. Ingestion returns as soon as paax-api answers, but
        // the catalog rows it upserts are not always readable by the very next
        // query — so the first Add tap failed with "Couldn't add…", having done
        // nothing except make the row exist, and the SECOND identical tap
        // succeeded. Requiring the user to tap twice is the bug.
        //
        // One tap is now one bounded logical operation: ingest, then wait for
        // the identity it created, for a strictly bounded number of short
        // attempts. Bounded means bounded — a few hundred milliseconds, never a
        // poll loop, and it stops the instant every track resolves.
        for (var attempt = 0; attempt < _identityReadyAttempts; attempt++) {
          slots = await _resolveSlots(tracks);
          // The LAST attempt's outcome is what decides offline vs absent: a
          // successful query that simply found no row clears this.
          lookupError = _resolver.lastLookupError;
          unresolved = stillMissing();
          if (unresolved.isEmpty) break;
          if (attempt < _identityReadyAttempts - 1) {
            await _sleep(_identityReadyBackoff);
          }
        }
      }
    }

    return (slots: slots, lookupError: lookupError);
  }

  /// True when [error] means "we never reached the catalog" rather than "the
  /// catalog answered and does not have it". Uses the app's ONE taxonomy.
  static bool _isConnectivity(Object? error) =>
      error != null &&
      classifyPlaylistOpError(error).kind ==
          PlaylistFailureKind.transientNetwork;

  /// What a mutation should put in the journal for [tracks].
  ///
  /// THE OFFLINE UN-INGESTED TOP TRACK (Phase 3.4.15). `ids` alone cannot
  /// express "this song, whose UUID does not exist yet". When resolution fails
  /// because we are OFFLINE and the track carries an ingestable source
  /// identity, its slot is recorded as a [PendingTrackRef] instead — the intent
  /// is durable and replay finishes it. Every other case is unchanged:
  ///
  ///   all resolved                     → ids only, exactly as before
  ///   unresolved, catalog answered     → throws localIntegrity, as before
  ///   unresolved, not ingestable       → throws localIntegrity, as before
  ///
  /// So this can only ever turn a guaranteed failure into a durable intent.
  Future<({List<String> ids, List<PendingTrackRef> unresolved})> _planQueue(
      List<Track> tracks) async {
    final r = await _resolveWithIngest(tracks);
    final ids = <String>[];
    final refs = <PendingTrackRef>[];
    final hard = <Track>[];
    final offline = _isConnectivity(r.lookupError);
    for (var i = 0; i < tracks.length; i++) {
      final uuid = r.slots[i];
      if (uuid != null) {
        ids.add(uuid);
        continue;
      }
      final ref = PendingTrackRef.fromTrack(tracks[i], i);
      if (offline && ref.isIngestable) {
        refs.add(ref);
      } else {
        hard.add(tracks[i]);
      }
    }
    if (hard.isNotEmpty) throw _unresolvedFailure(hard);
    return (ids: ids, unresolved: refs);
  }

  /// Resolution AT REPLAY TIME, where "not resolved" has two very different
  /// meanings and only one of them is terminal.
  ///
  /// A TRANSIENT UNRESOLVED STATE IS NOT TERMINAL (Phase 3.4.15). Replay runs
  /// the moment connectivity is reported back, and a reconnect edge is not a
  /// guarantee that the catalog is reachable yet — nor is a relaunch that
  /// happens while still offline, which flushes as soon as auth is ready. If
  /// those attempts raised `localIntegrity` the op would be DISCARDED and the
  /// user's queued add destroyed by the very mechanism meant to complete it.
  /// So the failure keeps the shape of its cause: unreachable → transient
  /// (stays queued, bounded retries); the catalog answered and has no such
  /// track → terminal, exactly as a live add would report.
  Future<List<String>> _resolveForReplay(List<Track> tracks) async {
    final r = await _resolveWithIngest(tracks);
    final missing = [
      for (var i = 0; i < tracks.length; i++)
        if (r.slots[i] == null) tracks[i]
    ];
    if (missing.isEmpty) return r.slots.cast<String>();
    if (_isConnectivity(r.lookupError)) {
      throw PlaylistOpFailure(
        PlaylistFailureKind.transientNetwork,
        cause: r.lookupError,
      );
    }
    throw _unresolvedFailure(missing);
  }

  /// Rebuilds the full ordered id list of a queued op, resolving (and ingesting
  /// for) any slot that had no UUID when it was queued.
  ///
  /// Runs the SAME bounded path an online add runs, so a replayed intent and a
  /// live add cannot diverge. Throws exactly like [_resolveOrThrow]: terminal
  /// localIntegrity when the catalog authoritatively lacks the track, and the
  /// underlying connectivity error (classified transient) when we still cannot
  /// reach it — which leaves the op queued for the next reconnect.
  Future<List<String>> _materializeIds(PlaylistOp op) async {
    final ids = (op.payload['ids'] as List?)?.map((e) => '$e').toList() ??
        const <String>[];
    final refs = PendingTrackRef.listFrom(op.payload['unresolved']);
    if (refs.isEmpty) return ids;

    final resolved = await _resolveForReplay([for (final r in refs) r.toTrack()]);

    // Splice each late-resolved UUID back into the slot the user put it in.
    final total = ids.length + refs.length;
    final out = List<String?>.filled(total, null);
    for (var i = 0; i < refs.length; i++) {
      final at = refs[i].at;
      if (at >= 0 && at < total && out[at] == null) out[at] = resolved[i];
    }
    var next = 0;
    for (final id in ids) {
      while (next < total && out[next] != null) {
        next++;
      }
      if (next >= total) break;
      out[next] = id;
    }
    return out.whereType<String>().toList();
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
    //
    // A reorder whose list contains a track added offline and NOT YET INGESTED
    // is the one case that cannot produce a complete UUID list yet. Its slot is
    // carried as intent and resolved at replay time, so the intended ORDER
    // survives — the reorder's own semantics (rebase, membership validation,
    // terminal conflicts) are untouched.
    final plan = await _planQueue(orderedTracks);
    final uuids = plan.ids;
    final uid = currentUserId;

    if (plan.unresolved.isNotEmpty) {
      if (uid == null) throw _unresolvedFailure(orderedTracks);
      await _sync.enqueue(PlaylistOp(
        opId: _newOpId(),
        userId: uid,
        playlistId: playlistId,
        type: PlaylistOpType.saveOrder,
        createdAt: DateTime.now(),
        expectedVersion: expectedVersion,
        payload: {
          'ids': uuids,
          'unresolved': PendingTrackRef.listToJson(plan.unresolved),
        },
      ));
      OfflineStatus.report(succeeded: false, wasNetworkFailure: true);
      throw const PlaylistOpFailure(
        PlaylistFailureKind.transientNetwork,
        cause: 'ORDER_QUEUED_FOR_INGEST: queued with the source identity of '
            'tracks the catalog has not ingested yet',
      );
    }

    return _online(
      // Reorder is NOT auto-rebasable: replaying an order against a membership
      // the server has since changed would push a wrong list. A 409 here is
      // terminal and surfaces for user recovery.
      () => _versioned(playlistId,
          (expected) => _remote.saveOrder(
              playlistId, uuids, authoritativeVersion(expected, expectedVersion)),
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

  /// The authoritative expected_version to send.
  ///
  /// THE SELF-CONFLICT BUG (Phase 3.4.11). This used to be
  /// `expected ?? expectedVersion`, so the mutation lane's value won even when
  /// it was OLDER than the version the screen had just authoritatively loaded.
  /// Lane versions only move forward, so once the lane held a stale value —
  /// e.g. seeded early in the session, or from a playlist opened before other
  /// changes — every reorder sent that stale number and the server correctly
  /// rejected it. Because reorder is deliberately non-rebasable, the client
  /// then reported the device's OWN mutation as "changed on another device",
  /// online and (after replay) offline alike.
  ///
  /// Both values are authoritative *observations* of the same monotonic
  /// counter, so the newest one wins. Null only when neither is known, which
  /// means "do not assert a version" rather than "assert 1".
  ///
  /// Public and static so the regression suite exercises THIS function rather
  /// than a copy of its rule.
  static int? authoritativeVersion(int? laneVersion, int? screenVersion) {
    if (laneVersion == null) return screenVersion;
    if (screenVersion == null) return laneVersion;
    return laneVersion > screenVersion ? laneVersion : screenVersion;
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
    _addsStarted[playlistId] = (_addsStarted[playlistId] ?? 0) + 1;
    try {
      return await _addTracks(playlistId, tracks);
    } finally {
      _addsCompleted[playlistId] = (_addsCompleted[playlistId] ?? 0) + 1;
    }
  }

  Future<Map<String, dynamic>> _addTracks(
      String playlistId, List<Track> tracks) async {
    // Throws localIntegrity rather than sending an empty/short array, which the
    // RPC would accept as a silent no-op success — except for a track that is
    // merely NOT INGESTED YET while we are offline, whose intent is queued.
    final plan = await _planQueue(tracks);
    final uuids = plan.ids;
    final uid = currentUserId;

    if (plan.unresolved.isNotEmpty) {
      // Nothing can be sent: the UUIDs do not exist yet, and inventing one is
      // never acceptable. Queue the INTENT and report the same transient
      // failure a dropped connection produces, so the caller keeps the
      // optimistic row and says "will sync when you're back online".
      if (uid == null) throw _unresolvedFailure(tracks);
      await _sync.enqueue(PlaylistOp(
        opId: _newOpId(),
        userId: uid,
        playlistId: playlistId,
        type: PlaylistOpType.addTracks,
        createdAt: DateTime.now(),
        payload: {
          'ids': uuids,
          'unresolved': PendingTrackRef.listToJson(plan.unresolved),
        },
      ));
      OfflineStatus.report(succeeded: false, wasNetworkFailure: true);
      throw const PlaylistOpFailure(
        PlaylistFailureKind.transientNetwork,
        cause: 'ADD_QUEUED_FOR_INGEST: the catalog is unreachable, so the add '
            'is queued with its source identity and completes on reconnect',
      );
    }

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
              expectedVersion: authoritativeVersion(expected, expectedVersion))),
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
  Future<Map<String, dynamic>?> fetchPlaylist(String playlistId) async {
    final row = await _remote.fetchPlaylist(playlistId);
    // Seed the lane from every authoritative read, so opening or refreshing a
    // playlist advances the shared version rather than leaving the lane pinned
    // to whatever it last saw. recordVersion is monotonic, so this can only
    // move the lane FORWARD.
    final v = row == null ? null : _versionOf(row);
    final uid = currentUserId;
    if (v != null && uid != null) mutationLane.recordVersion(uid, playlistId, v);
    return row;
  }
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
    final tracks = membershipFromRows(trackRows);
    // Hydration already holds the authoritative track_id for every row, which is
    // exactly what a later mutation must resolve. Seeding it here is what makes
    // an OFFLINE reorder/add possible at all — see seedTrackIdentities.
    await _seedIdentities(trackRows);
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

  /// Reconstructs playlist MEMBERSHIP from authoritative `playlist_tracks`
  /// rows, in `position` order.
  ///
  /// THE CARDINALITY INVARIANT (Phase 3.4.11). One authoritative row in, one
  /// entry out. Metadata hydration is a separate concern and is never allowed
  /// to change how many members a playlist has — the only rejected row is one
  /// carrying no track identity whatsoever, which cannot be rendered, played,
  /// removed or reordered by any code path.
  ///
  /// Sorting here (rather than trusting the query) is deliberate: the read used
  /// to come back DESCENDING, which silently reversed every playlist. Position
  /// order is part of the membership contract, so it is enforced where the
  /// contract lives.
  static List<Track> membershipFromRows(List<Map<String, dynamic>> rows) {
    final ordered = [...rows]..sort((a, b) => _positionOf(a).compareTo(_positionOf(b)));
    final out = <Track>[];
    for (final row in ordered) {
      final t = mapCloudTrack(row);
      if (t != null) out.add(t);
    }
    return out;
  }

  static int _positionOf(Map<String, dynamic> row) {
    final p = row['position'];
    return p is int ? p : int.tryParse('${p ?? ''}') ?? 0;
  }

  /// Maps ONE `playlist_tracks` row (with its embedded `tracks` graph) to a
  /// local [Track]. Public and static so the regression suite drives the real
  /// implementation instead of a copy of it.
  static Track? mapCloudTrack(Map<String, dynamic> row) {
    final t = row['tracks'];
    if (t is! Map) return null;

    // MEMBERSHIP IS NOT METADATA (Phase 3.4.11).
    //
    // This used to `return null` when `preferred_youtube_video_id` was empty,
    // which silently REMOVED an authoritative playlist_tracks row from the UI.
    // Since PR #92 ingests a track's album on demand, a freshly-ingested row
    // exists with `youtube_match_status = 'pending'` and a NULL videoId for a
    // while — so exactly the tracks the user just added (CLASSY 101, BIAF <3,
    // Desesperados) vanished a few seconds later, while the server correctly
    // held all six rows.
    //
    // A metadata gap must never mutate membership. The row is kept; the track
    // simply cannot play yet, which the playback layer already handles
    // ("Unable to play" + skip on auto-advance).
    final videoId = t['preferred_youtube_video_id']?.toString() ?? '';
    final catalogUuid = t['id']?.toString() ?? '';
    // Track.id doubles as the playback id. Falling back to the catalog UUID
    // keeps the entry uniquely identifiable for dedupe/removal/reorder while
    // being obviously non-playable.
    final trackId = videoId.isNotEmpty ? videoId : catalogUuid;
    if (trackId.isEmpty) return null; // no identity at all — genuinely unusable
    final dur = t['duration_seconds'];

    // Artist names from the canonical track_artists graph. This used to be
    // hardcoded `artistName: ''`, which is THE source of "Unknown Artist"
    // after an offline replay: hydration overwrote fully-populated local
    // Tracks with artist-less skeletons.
    final artistsList = <Map<String, String>>[];
    final ta = t['track_artists'];
    if (ta is List) {
      for (final row in ta) {
        if (row is! Map) continue;
        final a = row['artists'];
        if (a is! Map) continue;
        final name = a['name']?.toString() ?? '';
        if (name.isEmpty) continue;
        artistsList.add({'name': name, 'id': a['id']?.toString() ?? ''});
      }
    }

    return Track(
      id: trackId,
      title: t['title']?.toString() ?? '',
      artistName: artistsList.map((a) => a['name']!).join(', '),
      artistId: artistsList.isNotEmpty ? artistsList.first['id'] : null,
      artists: artistsList.isEmpty ? null : artistsList,
      albumId: '',
      albumTitle: '',
      artworkUrl:
          (t['image_cached_url'] ?? t['image_original_url'] ?? '').toString(),
      duration: dur is int ? dur : int.tryParse('${dur ?? ''}') ?? 0,
      deezerTrackId: t['deezer_id']?.toString(),
    );
  }

  /// Merges an authoritative cloud track list onto locally-cached tracks.
  ///
  /// RECONCILIATION INVARIANT (Phase 3.4.8): the server is authoritative for
  /// MEMBERSHIP and ORDER; the local cache is usually richer for METADATA
  /// (artist names, artwork, album). Replacing local tracks wholesale is what
  /// produced "Unknown Artist" and lost artwork after a replay.
  ///
  /// So: take membership + order from [cloud], but for each track prefer the
  /// cached object when it carries metadata the cloud row lacks. A cloud row is
  /// only allowed to ADD information, never to erase it.
  /// The identity two representations of the same song share.
  ///
  /// IDENTITY IS NOT STABLE ACROSS HYDRATION (Phase 3.4.13). `Track.id` is the
  /// YouTube videoId when one exists and the catalog UUID when the match is
  /// still pending, so the SAME song changes `id` the moment its match
  /// completes. Keying reconciliation on `id` alone therefore made a
  /// newly-ingested track look like a different song before and after the
  /// match: the cached copy no longer matched the cloud row, so its metadata
  /// was dropped and the membership guards could double-count it.
  ///
  /// The Deezer id is the one identifier both sides carry throughout, so it
  /// wins when present; `id` remains the fallback for tracks that have none.
  static String trackKey(Track t, [Map<String, String> aliases = const {}]) =>
      trackKeys(t, aliases).first;

  /// The canonical catalog UUID for every track whose identity this device
  /// already holds, as an alias table reconciliation can key on.
  ///
  /// Keyed by the identities a local [Track] can be recognised by (`i:<id>` and
  /// `d:<deezerId>`) so BOTH representations of the same song — the optimistic
  /// copy keyed by videoId and the authoritative copy keyed by catalog UUID —
  /// resolve to the same canonical value. Cache-only: no query, no ingest, and
  /// nothing here depends on a future resolver side effect.
  Future<Map<String, String>> canonicalTrackUuids(Iterable<Track> tracks) async {
    final out = <String, String>{};
    for (final t in tracks) {
      final uuid = await _resolver.cachedUuidFor(
          deezerId: t.deezerTrackId, videoId: t.id);
      if (uuid == null || uuid.isEmpty) continue;
      out['i:${t.id}'] = uuid;
      final d = (t.deezerTrackId ?? '').trim();
      if (d.isNotEmpty) out['d:$d'] = uuid;
    }
    return out;
  }

  /// EVERY identity a track can be recognised by, most specific first.
  ///
  /// Matching on the primary key alone is not enough: the cloud row for a
  /// track may carry no `deezer_id` at all, while the cached copy does (and
  /// vice versa). Indexing and looking up under both keys means two
  /// representations match whenever they agree on EITHER identity, so neither
  /// a pending-match id flip nor a missing Deezer id can make one song look
  /// like two.
  /// [aliases] is the canonical UUID table from [canonicalTrackUuids]. When it
  /// knows this track, the catalog UUID is the MOST specific identity and comes
  /// first, so the videoId→UUID flip can no longer make one song look like two.
  static List<String> trackKeys(Track t,
      [Map<String, String> aliases = const {}]) {
    final deezer = (t.deezerTrackId ?? '').trim();
    final uuid = aliases['i:${t.id}'] ??
        (deezer.isEmpty ? null : aliases['d:$deezer']);
    return [
      if (uuid != null && uuid.isNotEmpty) 'u:$uuid',
      if (deezer.isNotEmpty) 'd:$deezer',
      'i:${t.id}',
    ];
  }

  static Map<String, Track> _indexByIdentity(
      List<Track> tracks, Map<String, String> aliases) {
    final out = <String, Track>{};
    for (final t in tracks) {
      for (final k in trackKeys(t, aliases)) {
        out.putIfAbsent(k, () => t);
      }
    }
    return out;
  }

  static int? _rankOf(
      Map<String, int> rank, Track t, Map<String, String> aliases) {
    for (final k in trackKeys(t, aliases)) {
      final hit = rank[k];
      if (hit != null) return hit;
    }
    return null;
  }

  static Track? _lookup(
      Map<String, Track> index, Track t, Map<String, String> aliases) {
    for (final k in trackKeys(t, aliases)) {
      final hit = index[k];
      if (hit != null) return hit;
    }
    return null;
  }

  static List<Track> reconcileTracks({
    required List<Track> cached,
    required List<Track> cloud,
    Map<String, String> aliases = const {},
  }) {
    final byId = _indexByIdentity(cached, aliases);
    return [
      for (final c in cloud)
        () {
          final local = _lookup(byId, c, aliases);
          if (local == null) return c; // genuinely new membership
          final cloudHasArtists = c.artistName.trim().isNotEmpty;
          final localHasArtists = local.artistName.trim().isNotEmpty;
          // Keep the richer metadata; the cloud row still defines position by
          // virtue of its place in this list.
          if (!cloudHasArtists && localHasArtists) return local;
          if (cloudHasArtists && !localHasArtists) return c;
          // Both (or neither) have artists — prefer local, which also carries
          // album/artwork the membership query does not select.
          return local;
        }()
    ];
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
      executeOp,
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

  /// Replays a queued reorder by REBASING it onto the authoritative state.
  ///
  /// THE OFFLINE REORDER BUG (Phase 3.4.11). This used to be a single line:
  ///
  ///     await _remote.saveOrder(op.playlistId, ids, op.expectedVersion);
  ///
  /// `op.expectedVersion` is the version captured on the device WHILE OFFLINE.
  /// By replay time the server has almost always moved on — every queued add,
  /// remove and metadata op ahead of this one in the very same replay pass
  /// bumps it. So the reorder asserted a version that could not still be
  /// current, the RPC raised PLAYLIST_VERSION_CONFLICT, the sync engine
  /// (correctly) treated the conflict as terminal, and the positions were never
  /// written. The user saw the reconnect replay work for every other mutation
  /// while the old server order silently replaced their new one — and got
  /// "changed on another device" for a change only this device had made.
  ///
  /// The queued payload is the INTENT (the ordered track UUIDs). A version
  /// captured beside it is an observation, not part of the intent, so it is
  /// re-derived here instead of being trusted. Ordering is still safe because
  /// membership is validated against the server first: if the playlist's
  /// contents changed while we were offline, the intended order is genuinely no
  /// longer applicable and the op becomes a terminal conflict rather than a
  /// blind overwrite.
  Future<void> _replaySaveOrder(PlaylistOp op, List<String> ids) async {
    final uid = currentUserId ?? op.userId;

    // 1) The newest authoritative version, read once. A network failure here
    //    propagates and is classified transient, so the op stays queued.
    final row = await _remote.fetchPlaylist(op.playlistId);
    final serverVersion = row == null ? null : _versionOf(row);
    if (serverVersion != null) {
      mutationLane.recordVersion(uid, op.playlistId, serverVersion);
    }

    // 2) Current membership, so we never push an order against a set the
    //    server no longer has (which is exactly what ORDER_SET_MISMATCH
    //    protects, but detected here with a usable reason).
    final membership = row == null
        ? null
        : (await _remote.fetchTracks(op.playlistId))
            .map((r) => r['track_id']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();

    final plan = planSaveOrderReplay(
      intendedOrder: ids,
      serverMembership: membership,
      serverVersion: serverVersion,
      laneVersion: mutationLane.versionFor(uid, op.playlistId),
    );

    switch (plan.action) {
      case SaveOrderReplayAction.playlistGone:
        // Deleted or access lost. NOT_FOUND poisons the playlist's remaining
        // ops rather than retrying an impossible write.
        throw const PlaylistRemoteException('NOT_FOUND');
      case SaveOrderReplayAction.membershipConflict:
        // TERMINAL, and surfaced through the existing conflict path so the user
        // sees the external-change message exactly once. Never retried.
        throw PlaylistConflictException(
            expectedVersion: op.expectedVersion, actualVersion: serverVersion);
      case SaveOrderReplayAction.send:
        final saved = await _remote.saveOrder(
            op.playlistId, ids, plan.expectedVersion);
        final v = _versionOf(saved);
        if (v != null) mutationLane.recordVersion(uid, op.playlistId, v);
        // Reported so the sync engine persists the version before the next op
        // for this playlist runs.
        signalApplied(version: v);
    }
  }

  /// Decides what a queued reorder should do against the authoritative state
  /// observed at replay time. Pure, so the whole decision table is testable.
  static SaveOrderReplayPlan planSaveOrderReplay({
    required List<String> intendedOrder,
    required List<String>? serverMembership,
    required int? serverVersion,
    int? laneVersion,
  }) {
    if (serverMembership == null) {
      return const SaveOrderReplayPlan(SaveOrderReplayAction.playlistGone);
    }
    // The RPC requires an exact set: same cardinality, no duplicates, every id
    // present. Anything else is a membership change we cannot safely reorder.
    final intended = intendedOrder.toSet();
    final server = serverMembership.toSet();
    final sameSet = intended.length == intendedOrder.length &&
        intended.length == server.length &&
        intended.containsAll(server);
    if (!sameSet) {
      return const SaveOrderReplayPlan(SaveOrderReplayAction.membershipConflict);
    }
    return SaveOrderReplayPlan(
      SaveOrderReplayAction.send,
      // The freshest observation wins — never the version frozen while offline.
      expectedVersion: authoritativeVersion(laneVersion, serverVersion),
    );
  }

  /// Feeds the resolver the (deezer_id → uuid) and (videoId → uuid) pairs the
  /// authoritative membership read already contains. Best-effort: a caching
  /// failure must never break hydration.
  Future<void> _seedIdentities(List<Map<String, dynamic>> trackRows) async {
    final byDeezer = <String, String>{};
    final byVideo = <String, String>{};
    for (final row in trackRows) {
      final t = row['tracks'];
      if (t is! Map) continue;
      final uuid = t['id']?.toString() ?? '';
      if (uuid.isEmpty) continue;
      final deezer = t['deezer_id']?.toString() ?? '';
      if (deezer.isNotEmpty) byDeezer[deezer] = uuid;
      final video = t['preferred_youtube_video_id']?.toString() ?? '';
      if (video.isNotEmpty) byVideo[video] = uuid;
      // A track still awaiting a YouTube match is keyed by its catalog UUID
      // (Phase 3.4.11), so record that identity too — otherwise exactly the
      // tracks from BUG 1 would stay unresolvable offline.
      byVideo[uuid] = uuid;
    }
    if (byDeezer.isEmpty && byVideo.isEmpty) return;
    try {
      await _resolver
          .seedTrackIdentities(byDeezerId: byDeezer, byVideoId: byVideo);
    } catch (_) {
      // Caching is an optimization; hydration must still succeed.
    }
  }

  // ── in-flight add fence (Phase 3.4.14) ──
  /// Per-playlist counters of adds that have STARTED and that have FINISHED.
  /// Monotonic; the difference is the number currently in flight.
  final Map<String, int> _addsStarted = {};
  final Map<String, int> _addsCompleted = {};

  /// A snapshot of the completed-add counters, taken BEFORE an authoritative
  /// read is issued. See [addOverlapped].
  AddFence captureAddFence() => AddFence(Map<String, int>.from(_addsCompleted));

  /// True when an add for [playlistId] was in flight at ANY point between
  /// [since] being captured and now.
  ///
  /// THE DISAPPEARING TOP-TRACK ADD (Phase 3.4.14). [hasPendingAdd] protects an
  /// optimistic row only while a JOURNAL op exists — and a Top Track that is not
  /// in the catalog yet can never have one. Its add resolves nothing offline, so
  /// `_resolveOrThrow` ingests first and the whole call simply stays in flight
  /// on the stalled socket until connectivity returns (proven in production:
  /// `tracks.created_at` 15:44:29.207 → `playlist_tracks.added_at` 15:44:29.476,
  /// two minutes after the tap, and a replayed op never ingests). Reconnect then
  /// fires the journal flush and its authoritative hydrate CONCURRENTLY with
  /// that still-running add: the read observes membership without the track,
  /// nothing is queued, so reconciliation deleted the optimistic row — and the
  /// add committed a few hundred milliseconds later. Server right, UI wrong,
  /// with no further mutation able to fix it until some later hydrate.
  ///
  /// A plain "is one in flight right now?" check is not enough: the add can
  /// finish between the read and the check, which is exactly the losing race.
  /// The fence answers the causally correct question — did any add OVERLAP the
  /// window in which this authoritative snapshot was taken? Anything that
  /// started no later than the last completion observed before the window has
  /// already been accounted for by the server, so:
  ///
  ///     overlapped ⇔ startedNow > completedBefore
  bool addOverlapped(String playlistId, AddFence since) =>
      (_addsStarted[playlistId] ?? 0) > (since.completed[playlistId] ?? 0);

  /// THE hydration merge: authoritative membership + order, local metadata,
  /// unfinished local intent, one canonical identity per song.
  ///
  /// Both hydration paths (post-flush and sign-in) call exactly this, so the
  /// rule lives in one place and the regression suite drives the real thing.
  /// [fence] MUST have been captured before the read that produced [cloud].
  Future<List<Track>> reconcileHydrated({
    required String playlistId,
    required List<Track> cached,
    required List<Track> cloud,
    required AddFence fence,
  }) async {
    final aliases = await canonicalTrackUuids([...cached, ...cloud]);
    var merged =
        reconcileTracks(cached: cached, cloud: cloud, aliases: aliases);
    merged = preservePendingAdds(
      authoritative: merged,
      cached: cached,
      hasPendingAdd:
          hasPendingAdd(playlistId) || addOverlapped(playlistId, fence),
      aliases: aliases,
    );
    if (hasPendingReorder(playlistId)) {
      merged = preservePendingOrder(
        authoritative: merged,
        localOrder: cached,
        aliases: aliases,
      );
    }
    return merged;
  }

  /// True when an add for [playlistId] is still queued for replay.
  bool hasPendingAdd(String playlistId) {
    final uid = currentUserId;
    if (uid == null) return false;
    return _sync.pending(uid).any((o) =>
        o.playlistId == playlistId &&
        (o.type == PlaylistOpType.addTracks ||
            o.type == PlaylistOpType.create));
  }

  /// Keeps membership the user added locally but whose add has NOT reached the
  /// server yet.
  ///
  /// THE DISAPPEARING OFFLINE ADD (Phase 3.4.12). Reconciliation takes
  /// membership from the server, which is right — except while our own add is
  /// still queued. A replay pass that ends with the add still pending (it joined
  /// an in-flight pass, or hit a transient failure and stopped) is immediately
  /// followed by an authoritative hydrate, and the server legitimately does not
  /// have the track yet. The optimistic row was therefore deleted from the cache
  /// and the user watched their addition vanish — until any later mutation
  /// triggered another flush, the add finally committed, and it reappeared.
  ///
  /// This is deliberately gated on a QUEUED op, not on "is it missing from the
  /// server". Once the op leaves the journal — committed, rejected, dropped or
  /// quarantined — the track is no longer preserved, so a refusal still removes
  /// it exactly as before.
  static List<Track> preservePendingAdds({
    required List<Track> authoritative,
    required List<Track> cached,
    required bool hasPendingAdd,
    Map<String, String> aliases = const {},
  }) {
    if (!hasPendingAdd) return authoritative;
    // Keyed canonically: a track whose YouTube match is still pending is
    // reported by the server under its catalog UUID while the local optimistic
    // copy still carries its videoId, so an `id` comparison would treat the two
    // as different songs and show the track twice.
    final present = {for (final t in authoritative) ...trackKeys(t, aliases)};
    // Appended in their local order: playlist_add_tracks appends after the
    // current maximum position, so this is where the server will put them too.
    final pending = [
      for (final t in cached)
        if (!trackKeys(t, aliases).any(present.contains)) t
    ];
    return pending.isEmpty ? authoritative : [...authoritative, ...pending];
  }

  /// True when a reorder for [playlistId] is still queued for replay.
  ///
  /// Hydration uses this so an authoritative read cannot visibly revert an
  /// order the user has already saved but which has not reached the server yet.
  bool hasPendingReorder(String playlistId) {
    final uid = currentUserId;
    if (uid == null) return false;
    return _sync.pending(uid).any((o) =>
        o.playlistId == playlistId && o.type == PlaylistOpType.saveOrder);
  }

  /// Re-applies a still-pending local order on top of authoritative membership.
  ///
  /// Server membership always wins (adds/removes made elsewhere appear), but
  /// while a reorder is queued the ORDER stays the user's — otherwise hydration
  /// between "Save" and a successful replay bounces the list back to the old
  /// server order and looks like the save was lost. Members the local order
  /// does not know about keep their server-relative order, appended after the
  /// known ones.
  static List<Track> preservePendingOrder({
    required List<Track> authoritative,
    required List<Track> localOrder,
    Map<String, String> aliases = const {},
  }) {
    final rank = <String, int>{};
    for (var i = 0; i < localOrder.length; i++) {
      // Canonically keyed for the same reason as preservePendingAdds: a
      // pending match flips Track.id between videoId and catalog UUID.
      for (final k in trackKeys(localOrder[i], aliases)) {
        rank.putIfAbsent(k, () => i);
      }
    }
    final known = <Track>[];
    final unknown = <Track>[];
    for (final t in authoritative) {
      (_rankOf(rank, t, aliases) != null ? known : unknown).add(t);
    }
    known.sort(
        (a, b) => _rankOf(rank, a, aliases)!.compareTo(_rankOf(rank, b, aliases)!));
    return [...known, ...unknown];
  }

  /// Executes ONE queued op. Named (not `_execute`) so the replay contract can
  /// be driven directly by tests against a fake remote.
  Future<OpOutcome> executeOp(PlaylistOp op) async {
    try {
      // Resolves — and, when needed, INGESTS — any slot that had no catalog
      // UUID when this op was queued. For an op without `unresolved` (every op
      // written before this existed, and every fully-resolved one since) this
      // is the same `ids` list it always was, with no extra work.
      final ids = await _materializeIds(op);
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
          await _replaySaveOrder(op, ids);
          break;
        case PlaylistOpType.addTracks:
          // NEVER send an empty array: `playlist_add_tracks` gates its insert,
          // version bump and activity behind `if v_count > 0`, so an empty one
          // is a SILENT SUCCESS that would drop the user's add without a trace.
          if (ids.isEmpty) {
            throw const PlaylistOpFailure(
              PlaylistFailureKind.localIntegrity,
              cause: 'UNRESOLVED_TRACK: queued add resolved to no catalog ids',
            );
          }
          // Fenced like a live add: a replay makes membership grow too, so an
          // authoritative read taken while the pass is still running is just as
          // stale — and by the time the merge runs, the op has left the journal.
          _addsStarted[op.playlistId] = (_addsStarted[op.playlistId] ?? 0) + 1;
          try {
            await _remote.addTracks(op.playlistId, ids);
          } finally {
            _addsCompleted[op.playlistId] =
                (_addsCompleted[op.playlistId] ?? 0) + 1;
          }
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
    // Already classified — never re-derive it from a stringified message, which
    // would silently downgrade a deliberate kind (Phase 3.4.15: replay resolves
    // and ingests, so it can raise both terminal and transient failures itself).
    if (e is PlaylistOpFailure) return e;
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
