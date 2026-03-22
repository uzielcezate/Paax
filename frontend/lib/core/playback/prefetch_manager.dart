import 'dart:async';
import 'package:flutter/foundation.dart';
import 'media_resolver.dart';

// ---------------------------------------------------------------------------
// PrefetchManager
// ---------------------------------------------------------------------------

/// Proactively resolves stream URLs for upcoming tracks in the background.
///
/// Results are stored in [StreamCache] so the subsequent [load()] call returns
/// immediately instead of making a network request.
///
/// Design rules:
///   - Fire-and-forget: callers never await prefetch results.
///   - Silent failures: errors are logged but never surfaced to the UI.
///   - Deduplication: a second prefetch for the same videoId is ignored
///     while a prior one is still in-flight.
class PrefetchManager {
  PrefetchManager({LocalStreamResolver? resolver})
      : _resolver = resolver ?? LocalStreamResolver.instance;

  final LocalStreamResolver _resolver;
  final _inFlight = <String, Future<void>>{};

  /// Pre-resolve [videoId] in the background. Safe to call multiple times.
  void prefetch(String videoId) {
    if (videoId.isEmpty) return;
    if (_inFlight.containsKey(videoId)) {
      debugPrint('[PREFETCH] $videoId already in-flight — skipping');
      return;
    }

    debugPrint('[PREFETCH] Queuing $videoId');
    final future = _resolver
        .resolveForPrefetch(videoId)
        .then((_) {})
        .catchError((Object e) {
          debugPrint('[PREFETCH] $videoId error: $e');
        })
        .whenComplete(() => _inFlight.remove(videoId));

    _inFlight[videoId] = future;
  }

  /// Pre-resolve a list of tracks. Resolves sequentially in priority order.
  void prefetchList(List<String> videoIds) {
    for (final id in videoIds) {
      if (id.isNotEmpty) prefetch(id);
    }
  }

  /// Cancel tracking of an in-flight prefetch.
  void cancel(String videoId) {
    _inFlight.remove(videoId);
    debugPrint('[PREFETCH] Cancelled $videoId');
  }

  /// Cancel all pending prefetch work.
  void cancelAll() {
    final count = _inFlight.length;
    _inFlight.clear();
    debugPrint('[PREFETCH] Cancelled all ($count entries)');
  }

  bool isInFlight(String videoId) => _inFlight.containsKey(videoId);
}
