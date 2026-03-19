import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// ResolvedStream — value object returned by MediaResolver
// ---------------------------------------------------------------------------

/// The result of a stream resolution from the Worker.
///
/// [url]          — The direct googlevideo.com CDN URL for ExoPlayer.
/// [mimeType]     — e.g. 'audio/mp4' or 'video/mp4'.
/// [sourceType]   — 'audioOnly' | 'muxed' (from Worker).
/// [resolvedAt]   — When this was resolved (for StreamCache TTL).
/// [expiresAt]    — Unix seconds when the CDN URL expires (from expire= param).
///                 0 if unknown.
class ResolvedStream {
  final String url;
  final String mimeType;
  final String sourceType;
  final DateTime resolvedAt;
  final int expiresAt; // Unix epoch seconds; 0 = unknown

  const ResolvedStream({
    required this.url,
    required this.mimeType,
    required this.sourceType,
    required this.resolvedAt,
    this.expiresAt = 0,
  });

  /// True when the CDN URL has definitely expired.
  bool get isExpired {
    if (expiresAt == 0) return false; // unknown — assume valid
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  @override
  String toString() =>
      'ResolvedStream(source=$sourceType mime=$mimeType expires=$expiresAt '
      'url=${url.substring(0, url.length.clamp(0, 60))}…)';
}

// ---------------------------------------------------------------------------
// MediaResolver
// ---------------------------------------------------------------------------

/// Resolves a direct playable stream URL by calling the Worker JSON API.
///
/// Flow:
///   1. StreamCache hit → return immediately, no network call.
///   2. Cache miss      → GET https://stream.paaxmusic.app/{videoId}
///                        Worker resolves via Innertube and returns JSON:
///                        { url, mimeType, sourceType, expiresAt }
///   3. Cache the result with TTL = min(4 min, expiresAt - now).
///   4. Return the direct CDN URL to the engine.
///      ExoPlayer fetches bytes from googlevideo.com directly — no proxying.
///
/// On CDN 403 during playback (detected in engine via PlayerException):
///   The engine calls [invalidate] to remove the stale entry, then re-resolves.
class MediaResolver {
  MediaResolver({StreamCache? cache}) : _cache = cache ?? StreamCache.instance;

  final StreamCache _cache;

  static const String _workerBase    = 'https://stream.paaxmusic.app';
  static const Duration _httpTimeout = Duration(seconds: 15);

  // Headers sent with every Worker resolve request
  static const Map<String, String> _workerHeaders = {
    'Accept': 'application/json',
  };

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Resolves the direct CDN stream URL for [videoId].
  ///
  /// Throws [MediaResolveException] on Worker error, network failure, or
  /// malformed response. The engine surface this as "Playback unavailable".
  Future<ResolvedStream> resolve(String videoId) async {
    assert(videoId.isNotEmpty);

    // --- 1. Cache hit: instant, no network ──────────────────────────────────
    debugPrint('[MEDIA CACHE READ] $videoId');
    final cached = await _cache.get(videoId);
    if (cached != null) {
      if (!cached.isExpired) {
        debugPrint('[MEDIA CACHE HIT] $videoId → ${cached.sourceType} url=${cached.url.substring(0, 50)}…');
        return cached;
      }
      // URL has expired according to expiresAt — discard and re-resolve
      debugPrint('[MEDIA CACHE HIT] $videoId — CDN URL expired (expiresAt=${cached.expiresAt}), re-resolving');
      await _cache.invalidate(videoId);
    }
    debugPrint('[MEDIA CACHE MISS] $videoId');

    // --- 2. Call Worker JSON resolver ────────────────────────────────────────
    debugPrint('[MEDIA RESOLVE START] $videoId');
    final endpoint = Uri.parse('$_workerBase/$videoId');

    final http.Response response;
    try {
      response = await http
          .get(endpoint, headers: _workerHeaders)
          .timeout(_httpTimeout);
    } catch (e) {
      debugPrint('[MEDIA RESOLVE ERROR] $videoId — network: $e');
      throw MediaResolveException('Network error resolving stream: $e');
    }

    if (response.statusCode != 200) {
      // Worker returned an error — try to parse the code from JSON
      String code = 'WORKER_ERROR';
      String? errorBody;
      try {
        final b = jsonDecode(response.body) as Map<String, dynamic>;
        code      = (b['code']    as String?) ?? code;
        errorBody = (b['message'] as String?) ?? (b['error'] as String?);
      } catch (_) {
        // Body may be HTML (rate-limit page) — capture first 120 chars
        errorBody = response.body.length > 120
            ? '${response.body.substring(0, 120)}…'
            : response.body;
      }
      debugPrint('[MEDIA RESOLVE FAIL] $videoId — HTTP ${response.statusCode} code=$code body=${errorBody ?? '—'}');
      throw MediaResolveException(
        _workerErrorMessage(code, response.statusCode),
        code:      code,
        httpStatus: response.statusCode,
        errorBody: errorBody,
      );
    }

    // --- 3. Parse JSON payload ───────────────────────────────────────────────
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MEDIA RESOLVE ERROR] $videoId — malformed JSON: $e');
      throw const MediaResolveException('Stream resolver returned malformed response');
    }

    final cdnUrl    = body['url']        as String?;
    final mimeType  = body['mimeType']   as String? ?? 'audio/mp4';
    final srcType   = body['sourceType'] as String? ?? 'audioOnly';
    final expiresAt = (body['expiresAt'] as num?)?.toInt() ?? 0;

    if (cdnUrl == null || cdnUrl.isEmpty) {
      debugPrint('[MEDIA RESOLVE ERROR] $videoId — Worker returned empty url');
      throw const MediaResolveException('Stream resolver returned an empty URL');
    }

    final resolved = ResolvedStream(
      url:        cdnUrl,
      mimeType:   mimeType,
      sourceType: srcType,
      resolvedAt: DateTime.now(),
      expiresAt:  expiresAt,
    );

    debugPrint('[MEDIA RESOLVE RESULT DIRECT] $videoId → $srcType expiresAt=$expiresAt');
    debugPrint('[MEDIA DIRECT URL] $videoId → ${cdnUrl.substring(0, cdnUrl.length.clamp(0, 80))}…');
    debugPrint('[MEDIA FORMAT PICK] $videoId → $srcType mime=$mimeType');

    // --- 4. Cache with TTL based on expiresAt ───────────────────────────────
    debugPrint('[MEDIA CACHE WRITE] $videoId (expiresAt=$expiresAt)');
    await _cache.put(videoId, resolved);

    return resolved;
  }

  /// Pre-warm the cache for an upcoming track (used by PrefetchManager).
  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    assert(videoId.isNotEmpty);
    debugPrint('[MEDIA PREFETCH] Resolving $videoId');

    // Check cache first — skip if already warm and not expired
    final cached = await _cache.get(videoId);
    if (cached != null && !cached.isExpired) {
      debugPrint('[MEDIA PREFETCH] $videoId already cached — skip');
      return cached;
    }

    // Full resolve — same path as [resolve]
    try {
      final resolved = await resolve(videoId);
      debugPrint('[MEDIA PREFETCH] $videoId — cached successfully');
      return resolved;
    } catch (e) {
      debugPrint('[MEDIA PREFETCH] $videoId — failed: $e');
      rethrow;
    }
  }

  /// Invalidate the cache for [videoId] — called by the engine on PlayerException.
  Future<void> invalidate(String videoId) => _cache.invalidate(videoId);

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _workerErrorMessage(String code, int status) {
    const msgs = {
      'PLAYABILITY_FAILED':  'This track is no longer available.',
      'NO_AUDIO_FORMAT':     'No compatible audio stream found.',
      'ALL_CLIENTS_BLOCKED': 'Stream temporarily unavailable. Please try again.',
      'NO_STREAMING_DATA':   'Playback is not available right now.',
    };
    return msgs[code] ?? 'Stream unavailable (HTTP $status). Please try again.';
  }
}

// ---------------------------------------------------------------------------
// MediaResolveException
// ---------------------------------------------------------------------------

/// Thrown by [MediaResolver.resolve] on any failure.
class MediaResolveException implements Exception {
  final String  message;
  final String? code;
  /// HTTP status code from the Worker (non-200), or 0 on network error.
  final int     httpStatus;
  /// Short excerpt from the Worker error body.
  final String? errorBody;

  const MediaResolveException(
    this.message, {
    this.code,
    this.httpStatus = 0,
    this.errorBody,
  });

  @override
  String toString() => message;
}
