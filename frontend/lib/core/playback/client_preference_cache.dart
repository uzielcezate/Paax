// ---------------------------------------------------------------------------
// ClientPreferenceCache
// ---------------------------------------------------------------------------
//
// Remembers which Innertube client produced confirmed successful playback
// per videoId during this app session.
//
// Used by PlaybackEngineImpl to pass a ?client=X hint to the Worker,
// so repeat plays of the same track skip the waterfall and go straight
// to the client that last worked.
//
// In-memory only — intentionally not persisted. If the app restarts,
// we fall back to the waterfall afresh (no stale preference).
//
// TEMPORARY DEBUG-SUPPORT FILE — remove before shipping to production.
// ---------------------------------------------------------------------------

class ClientPreferenceCache {
  ClientPreferenceCache._();
  static final ClientPreferenceCache instance = ClientPreferenceCache._();

  final _prefs = <String, String>{}; // videoId → clientName

  /// Returns the preferred client name for [videoId], or null if unknown.
  String? preferred(String videoId) => _prefs[videoId];

  /// Record that [clientName] produced confirmed playback for [videoId].
  void markSuccess(String videoId, String clientName) {
    _prefs[videoId] = clientName;
  }

  /// Remove preference for [videoId] — called when that client later fails.
  void invalidate(String videoId) {
    _prefs.remove(videoId);
  }

  /// Remove all preferences.
  void clear() => _prefs.clear();
}
