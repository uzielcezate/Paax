// ---------------------------------------------------------------------------
// CandidateBlacklist — session-level playback failure memory
// ---------------------------------------------------------------------------
//
// Tracks which (client, itag) pairs failed to produce byte flow for a videoId
// during the current app session. Used by PlaybackEngineImpl to:
//   1. Skip locally cached candidates that already failed
//   2. Build the ?exclude=CLIENT,CLIENT list sent to the Worker when all
//      local candidates from a client are exhausted
//
// In-memory only — intentionally not persisted.
// TEMPORARY DEBUG-SUPPORT FILE — remove before shipping to production.
// ---------------------------------------------------------------------------

class CandidateBlacklist {
  CandidateBlacklist._();
  static final CandidateBlacklist instance = CandidateBlacklist._();

  // videoId → Set of candidateKey strings ("CLIENT:itag")
  final _map = <String, Set<String>>{};

  /// Unique key for a (client, itag) pair.
  static String key(String client, int itag) => '$client:$itag';

  /// Returns true if this (client, itag) combo failed for [videoId].
  bool isBlacklisted(String videoId, String client, int itag) =>
      _map[videoId]?.contains(key(client, itag)) ?? false;

  /// Record a failed (client, itag) pair for [videoId].
  void blacklist(String videoId, String client, int itag) {
    (_map[videoId] ??= {}).add(key(client, itag));
  }

  /// How many distinct (client, itag) pairs have failed for [videoId].
  int count(String videoId) => _map[videoId]?.length ?? 0;

  /// Distinct client names that appear in the blacklist for [videoId].
  /// Used to build the ?exclude= query param for the Worker.
  Set<String> failedClients(String videoId) =>
      (_map[videoId] ?? {})
          .map((k) => k.split(':').first)
          .toSet();

  /// Remove all blacklist entries for [videoId] (called at start of new load).
  void clearForVideo(String videoId) => _map.remove(videoId);

  /// Wipe all entries.
  void clear() => _map.clear();
}
