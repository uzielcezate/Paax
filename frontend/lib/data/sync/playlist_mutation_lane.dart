// lib/data/sync/playlist_mutation_lane.dart
//
// Per-playlist serialization for version-checked mutations (Phase 3.4.7).
//
// THE PROBLEM
// -----------
// Optimistic concurrency only works if mutations for one playlist are ordered.
// Two adds fired close together both read the same local version:
//
//     add A (expected 7) ─┐
//     add B (expected 7) ─┘   both in flight
//
// One wins and moves the server to 8; the other gets a 409 and its track is
// lost from the server while remaining on screen. That is exactly the "four
// tracks locally, two remotely" symptom.
//
// THE RULE
// --------
//     add A (expected 7) → success returns 8 → persist 8 → add B (expected 8)
//
// Serialization is PER PLAYLIST, keyed by account + playlist id. Two different
// playlists still run concurrently — globally serializing would make the app
// feel broken for an unrelated correctness problem.
//
// This is deliberately NOT the same mechanism as PlaylistSyncService's
// single-flight. That one guards the whole REPLAY PASS (one worker); this one
// orders individual MUTATIONS. Conflating them would either serialize
// everything or serialize nothing.

import 'dart:async';

/// Serializes mutations per (account, playlist) and carries the authoritative
/// version between them.
class PlaylistMutationLane {
  /// Tail of each lane's chain. A new mutation appends itself to the tail, so
  /// mutations run strictly in submission order.
  final Map<String, Future<void>> _tails = {};

  /// Last server-confirmed version per lane key. This is the value a queued
  /// mutation should use, NOT whatever the UI happened to be showing.
  final Map<String, int> _versions = {};

  /// Diagnostics: lanes that have ever run, and how many mutations each ran.
  final Map<String, int> runCounts = {};

  /// The serialization key. Includes the account so two signed-in identities
  /// can never share a lane, and the playlist so unrelated playlists stay
  /// independent.
  static String laneKey(String accountId, String playlistId) =>
      '$accountId::$playlistId';

  /// The authoritative version for this lane, if a mutation has confirmed one.
  int? versionFor(String accountId, String playlistId) =>
      _versions[laneKey(accountId, playlistId)];

  /// Records a server-confirmed version. Called after every successful
  /// mutation, BEFORE the next one in the lane starts.
  void recordVersion(String accountId, String playlistId, int version) {
    final key = laneKey(accountId, playlistId);
    final current = _versions[key];
    // Versions only move forward. A late response from an earlier mutation must
    // never roll the lane back onto a stale version.
    if (current == null || version > current) _versions[key] = version;
  }

  /// Clears a lane's cached version — after a conflict, or when authoritative
  /// state is refetched.
  void invalidateVersion(String accountId, String playlistId) =>
      _versions.remove(laneKey(accountId, playlistId));

  /// Runs [action] with exclusive access to this playlist's lane.
  ///
  /// [action] receives the lane's current authoritative version (null if
  /// unknown) and returns the version the server reported, which becomes the
  /// input for the next mutation in the same lane.
  ///
  /// A failing action does NOT break the lane: the chain continues so one bad
  /// mutation cannot deadlock every later mutation for that playlist.
  Future<T> run<T>(
    String accountId,
    String playlistId,
    Future<({T result, int? version})> Function(int? expectedVersion) action,
  ) {
    final key = laneKey(accountId, playlistId);
    final previous = _tails[key] ?? Future<void>.value();

    final completer = Completer<T>();
    final chained = previous.then((_) async {
      runCounts[key] = (runCounts[key] ?? 0) + 1;
      try {
        final out = await action(_versions[key]);
        if (out.version != null) recordVersion(accountId, playlistId, out.version!);
        completer.complete(out.result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });

    // The tail swallows errors so a failed mutation cannot poison the lane for
    // every subsequent one; the caller still sees the error via `completer`.
    _tails[key] = chained.catchError((Object _) {});
    // ignore: discarded_futures
    chained.whenComplete(() {
      if (identical(_tails[key], chained)) _tails.remove(key);
    });
    return completer.future;
  }

  /// True when a mutation is currently queued or running for this playlist.
  bool isBusy(String accountId, String playlistId) =>
      _tails.containsKey(laneKey(accountId, playlistId));

  /// Drops all lanes for an account (sign-out / account switch).
  void clearAccount(String accountId) {
    final prefix = '$accountId::';
    _tails.removeWhere((k, _) => k.startsWith(prefix));
    _versions.removeWhere((k, _) => k.startsWith(prefix));
  }

  void resetForTest() {
    _tails.clear();
    _versions.clear();
    runCounts.clear();
  }
}
