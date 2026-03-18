import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// ResolvedStream — value object returned by MediaResolver
// ---------------------------------------------------------------------------

/// The result of successfully resolving a track's playback source.
///
/// [url]          — The audio URL ready for just_audio.
///                 V1: always the Worker proxy URL (stream.paaxmusic.app/{id}).
/// [sourceType]   — Where the URL came from ('workerProxy' | 'cache').
/// [resolvedAt]   — Timestamp, used by StreamCache for TTL.
class ResolvedStream {
  final String url;
  final String sourceType;
  final DateTime resolvedAt;

  const ResolvedStream({
    required this.url,
    required this.sourceType,
    required this.resolvedAt,
  });

  @override
  String toString() =>
      'ResolvedStream(source=$sourceType url=${url.substring(0, url.length.clamp(0, 60))}…)';
}

// ---------------------------------------------------------------------------
// MediaResolver
// ---------------------------------------------------------------------------

/// Resolves a playable stream URL for a given YouTube video ID.
///
/// Resolution strategy (V1):
///   1. Check [StreamCache] — if a non-expired entry exists, return it as-is.
///      The Worker URL is stable; only the underlying signed CDN URL expires.
///      Since the Worker handles re-resolution transparently, the Worker URL
///      itself never "expires" from the app's perspective.
///   2. Verify the Worker is reachable via a low-cost HEAD request.
///      If HEAD returns 200/206/303 → URL is valid, write to cache.
///   3. On any error: return null — callers decide the fallback.
///
/// Why HEAD and not GET?
///   A HEAD probe is < 1 KB on the wire and confirms the Worker can resolve
///   this videoId without streaming the full audio body to check availability.
class MediaResolver {
  MediaResolver({StreamCache? cache}) : _cache = cache ?? StreamCache.instance;

  final StreamCache _cache;

  static const String _workerBase = 'https://stream.paaxmusic.app';
  static const Duration _probeTimeout = Duration(seconds: 8);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns a [ResolvedStream] for [videoId], or null on failure.
  Future<ResolvedStream?> resolve(String videoId) async {
    assert(videoId.isNotEmpty);

    // --- 1. Cache hit ---------------------------------------------------------
    final cached = await _cache.get(videoId);
    if (cached != null) {
      debugPrint('[MEDIA CACHE HIT] $videoId → ${cached.sourceType}');
      return cached;
    }
    debugPrint('[MEDIA CACHE MISS] $videoId — resolving via Worker');

    // --- 2. Resolve via Worker ------------------------------------------------
    final workerUrl = Uri.parse('$_workerBase/$videoId');
    debugPrint('[MEDIA RESOLVE] $videoId — calling Worker: $workerUrl');

    try {
      // HEAD probe: confirms the Worker can resolve this videoId.
      // The Worker's Innertube waterfall runs, and if it succeeds the HEAD
      // would return 200. If the track is unavailable, we get 404/503.
      final probeResp = await http.head(workerUrl).timeout(_probeTimeout);
      final status = probeResp.statusCode;

      debugPrint('[MEDIA RESOLVE] $videoId — Worker probe status=$status');

      if (status >= 200 && status < 400) {
        // Worker confirmed playable — use the Worker URL directly as the stream.
        // just_audio will GET this URL; the Worker will stream audio bytes.
        final resolved = ResolvedStream(
          url: workerUrl.toString(),
          sourceType: 'workerProxy',
          resolvedAt: DateTime.now(),
        );
        debugPrint('[MEDIA FORMAT PICK] $videoId → workerProxy ${resolved.url}');
        await _cache.put(videoId, resolved);
        return resolved;
      }

      debugPrint('[MEDIA ERROR] $videoId — Worker probe rejected: $status');
      return null;
    } catch (e) {
      debugPrint('[MEDIA ERROR] $videoId — resolve failed: $e');
      return null;
    }
  }

  /// Resolve without cache check — always hits the Worker.
  /// Used by [PrefetchManager] to warm the cache for upcoming tracks.
  Future<ResolvedStream?> resolveForPrefetch(String videoId) async {
    assert(videoId.isNotEmpty);
    debugPrint('[MEDIA PREFETCH] Resolving $videoId in background');

    final workerUrl = Uri.parse('$_workerBase/$videoId');
    try {
      final probeResp = await http
          .head(workerUrl)
          .timeout(const Duration(seconds: 12));
      if (probeResp.statusCode >= 200 && probeResp.statusCode < 400) {
        final resolved = ResolvedStream(
          url: workerUrl.toString(),
          sourceType: 'workerProxy',
          resolvedAt: DateTime.now(),
        );
        await _cache.put(videoId, resolved);
        debugPrint('[MEDIA PREFETCH] $videoId — cached successfully');
        return resolved;
      }
    } catch (e) {
      debugPrint('[MEDIA PREFETCH] $videoId — failed: $e');
    }
    return null;
  }
}
