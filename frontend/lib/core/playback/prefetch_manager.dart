import 'dart:async';
import 'package:flutter/foundation.dart';
import 'media_resolver.dart';

// ---------------------------------------------------------------------------
// PrefetchManager
// ---------------------------------------------------------------------------

/// Proactively resolves stream URLs for upcoming tracks in the background.
///
/// When a track starts playing, [PlaybackController] calls [prefetchList]
/// with the IDs of the next 1–2 tracks. The manager fires off background
/// HEAD probes via [MediaResolver.resolveForPrefetch], which writes results
/// into [StreamCache]. When that track's [load()] is eventually called,
/// [StreamCache.get()] returns immediately — the network round-trip is gone.
///
/// Design rules:
///   - Fire-and-forget: callers never await prefetch results.
///   - Silent failures: errors are logged but never surfaced to the UI.
///   - Deduplication: a second prefetch for the same videoId is ignored
///     while a prior one is still in-flight.
///   - Cancellation: [cancel] drops in-flight work when the queue changes.
class PrefetchManager {
  PrefetchManager({MediaResolver? resolver})
      : _resolver = resolver ?? MediaResolver();

  final MediaResolver _resolver;

  // Track in-flight prefetch operations by videoId.
  final _inFlight = <String, Future<void>>{};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Pre-resolve [videoId] in the background.
  ///
  /// Safe to call multiple times — de-duplicates automatically.
  void prefetch(String videoId) {
    if (videoId.isEmpty) return;
    if (_inFlight.containsKey(videoId)) {
      debugPrint('[MEDIA PREFETCH] $videoId already in-flight — skipping');
      return;
    }

    debugPrint('[MEDIA PREFETCH] Queuing $videoId');
    final future = _resolver
        .resolveForPrefetch(videoId)
        .catchError((Object e) {
          debugPrint('[MEDIA PREFETCH] $videoId error: $e');
          return null;
        })
        .whenComplete(() => _inFlight.remove(videoId));

    _inFlight[videoId] = future;
  }

  /// Pre-resolve a list of tracks (e.g. next 2 in queue).
  ///
  /// Resolves in priority order — first ID resolves before the second starts.
  void prefetchList(List<String> videoIds) {
    for (final id in videoIds) {
      if (id.isNotEmpty) prefetch(id);
    }
  }

  /// Cancel an in-flight prefetch. The future runs to completion but its
  /// result is discarded (Dart futures cannot be hard-cancelled).
  void cancel(String videoId) {
    _inFlight.remove(videoId);
    debugPrint('[MEDIA PREFETCH] Cancelled $videoId');
  }

  /// Cancel all pending prefetch work. Useful when the queue is replaced.
  void cancelAll() {
    final ids = List<String>.from(_inFlight.keys);
    _inFlight.clear();
    debugPrint('[MEDIA PREFETCH] Cancelled all (${ids.length} entries)');
  }

  /// Returns true if [videoId] is currently being prefetched.
  bool isInFlight(String videoId) => _inFlight.containsKey(videoId);
}
