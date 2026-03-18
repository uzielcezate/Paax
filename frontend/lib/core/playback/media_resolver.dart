import 'package:flutter/foundation.dart';
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
/// ── V1 strategy ─────────────────────────────────────────────────────────────
///   The Worker URL (stream.paaxmusic.app/{videoId}) is always deterministic
///   and never needs a probe. The Worker handles Innertube resolution,
///   CDN proxy, and CF caching transparently.
///
///   DO NOT HEAD-probe the Worker before use. Reasoning:
///   1. The Worker is a proxy — a HEAD forces a full Innertube waterfall +
///      CDN fetch just to answer a status code. This easily hits 8–12s,
///      causing the resolver to time out and return null.
///   2. The actual availability check is done naturally by ExoPlayer when it
///      calls setAudioSource → play(). If the Worker returns 4xx/5xx,
///      ExoPlayer throws PlayerException, which the engine catches to
///      invalidate the cache and surface a user-friendly error.
///   3. The Worker URL itself never "expires" — only the underlying signed CDN
///      URL expires, but the Worker re-resolves that transparently.
///
///   Resolution order:
///     1. StreamCache hit → instant return, no network call.
///     2. Cache miss      → construct Worker URL, write to cache, return.
///     ExoPlayer then makes the first GET when play() is called.
// ────────────────────────────────────────────────────────────────────────────
class MediaResolver {
  MediaResolver({StreamCache? cache}) : _cache = cache ?? StreamCache.instance;

  final StreamCache _cache;

  static const String _workerBase = 'https://stream.paaxmusic.app';

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns a [ResolvedStream] for [videoId].
  ///
  /// Always succeeds — the Worker URL is deterministic. If the Worker itself
  /// cannot serve the track, ExoPlayer will propagate a [PlayerException]
  /// and the engine will invalidate the cache entry.
  Future<ResolvedStream> resolve(String videoId) async {
    assert(videoId.isNotEmpty);

    // --- 1. Cache hit: instant, no network ──────────────────────────────────
    debugPrint('[MEDIA CACHE READ] $videoId');
    final cached = await _cache.get(videoId);
    if (cached != null) {
      debugPrint('[MEDIA CACHE HIT] $videoId → ${cached.sourceType}');
      return cached;
    }
    debugPrint('[MEDIA CACHE MISS] $videoId');

    // --- 2. Construct Worker URL — no probe needed ───────────────────────────
    debugPrint('[MEDIA RESOLVE START] $videoId');
    final workerUrl = '$_workerBase/$videoId';
    final resolved = ResolvedStream(
      url:        workerUrl,
      sourceType: 'workerProxy',
      resolvedAt: DateTime.now(),
    );

    debugPrint('[MEDIA RESOLVE RESULT] $videoId → $workerUrl');
    debugPrint('[MEDIA FORMAT PICK] $videoId → workerProxy (ExoPlayer streams bytes from Worker)');

    // Write to cache before returning so repeat plays are instant
    debugPrint('[MEDIA CACHE WRITE] $videoId');
    await _cache.put(videoId, resolved);

    return resolved;
  }

  /// Pre-warm the cache for an upcoming track (used by PrefetchManager).
  ///
  /// Same logic as [resolve] — just constructs the URL and writes to cache.
  /// The actual Worker call happens when ExoPlayer plays the track.
  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    assert(videoId.isNotEmpty);

    // Check cache first — no need to prefetch if already warm
    final cached = await _cache.get(videoId);
    if (cached != null) {
      debugPrint('[MEDIA PREFETCH] $videoId already cached — skip');
      return cached;
    }

    debugPrint('[MEDIA PREFETCH] $videoId — warming cache with Worker URL');
    final resolved = ResolvedStream(
      url:        '$_workerBase/$videoId',
      sourceType: 'workerProxy',
      resolvedAt: DateTime.now(),
    );
    await _cache.put(videoId, resolved);
    debugPrint('[MEDIA PREFETCH] $videoId — cached successfully');
    return resolved;
  }
}
