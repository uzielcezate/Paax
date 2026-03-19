import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// ResolvedStream — value object returned by MediaResolver
// ---------------------------------------------------------------------------

/// The result of a stream resolution from the Worker.
///
/// [url]        — Direct googlevideo.com CDN URL for ExoPlayer.
/// [mimeType]   — e.g. 'audio/mp4' or 'video/mp4'.
/// [sourceType] — 'audioOnly' | 'muxed' (from Worker).
/// [expiresAt]  — Unix seconds when the CDN URL expires; 0 if unknown.
/// [clientUsed] — Which Innertube client the Worker used (e.g. 'ANDROID').
/// [itag]       — YouTube format itag (e.g. 140 = 128kbps AAC).
class ResolvedStream {
  final String url;
  final String mimeType;
  final String sourceType;
  final DateTime resolvedAt;
  final int    expiresAt;   // Unix epoch seconds; 0 = unknown
  final String clientUsed;  // e.g. 'ANDROID', 'ANDROID_VR', 'IOS', …
  final int    itag;        // 140 = audio/mp4 128kbps; 251 = opus; etc.

  const ResolvedStream({
    required this.url,
    required this.mimeType,
    required this.sourceType,
    required this.resolvedAt,
    this.expiresAt  = 0,
    this.clientUsed = '?',
    this.itag       = 0,
  });

  /// True when the CDN URL has definitely expired.
  bool get isExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  @override
  String toString() =>
      'ResolvedStream(client=$clientUsed itag=$itag source=$sourceType '
      'mime=$mimeType expires=$expiresAt '
      'url=${url.substring(0, url.length.clamp(0, 60))}…)';
}

// ---------------------------------------------------------------------------
// MediaResolver
// ---------------------------------------------------------------------------

/// Resolves a direct playable stream URL by calling the Worker JSON API.
///
/// Flow:
///   1. StreamCache hit → return immediately.
///   2. Cache miss      → GET https://stream.paaxmusic.app/{videoId}[?client=X]
///                        Response: { url, mimeType, sourceType, expiresAt,
///                                    clientUsed, itag }
///   3. Cache the result.
///   4. Return to engine → ExoPlayer fetches bytes directly from CDN.
///
/// On failedBuffering (detected by engine stall guard):
///   Engine calls [invalidate] + [resolve] with a fresh client hint.
class MediaResolver {
  MediaResolver({StreamCache? cache}) : _cache = cache ?? StreamCache.instance;

  final StreamCache _cache;

  static const String _workerBase    = 'https://stream.paaxmusic.app';
  static const Duration _httpTimeout = Duration(seconds: 15);

  static const Map<String, String> _workerHeaders = {
    'Accept': 'application/json',
  };

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Resolves the direct CDN stream URL for [videoId].
  ///
  /// If [preferredClient] is set, the Worker tries that client first
  /// (bypasses CF cache, so we always get a fresh URL from the preferred client).
  ///
  /// Throws [MediaResolveException] on Worker error, network failure, or
  /// malformed response.
  Future<ResolvedStream> resolve(String videoId, {String? preferredClient}) async {
    assert(videoId.isNotEmpty);

    // --- 1. Cache hit (only when no client preference is forced) ────────────
    if (preferredClient == null) {
      debugPrint('[MEDIA CACHE READ] $videoId');
      final cached = await _cache.get(videoId);
      if (cached != null) {
        if (!cached.isExpired) {
          debugPrint('[MEDIA CACHE HIT] $videoId → ${cached.sourceType} client=${cached.clientUsed}');
          return cached;
        }
        debugPrint('[MEDIA CACHE EXPIRED] $videoId — re-resolving');
        await _cache.invalidate(videoId);
      }
      debugPrint('[MEDIA CACHE MISS] $videoId');
    } else {
      debugPrint('[MEDIA RESOLVE FORCED] $videoId preferredClient=$preferredClient');
    }

    // --- 2. Build request URL ────────────────────────────────────────────────
    final Uri endpoint;
    if (preferredClient != null) {
      endpoint = Uri.parse('$_workerBase/$videoId').replace(
        queryParameters: {'client': preferredClient},
      );
    } else {
      endpoint = Uri.parse('$_workerBase/$videoId');
    }

    // --- 3. Call Worker JSON resolver ────────────────────────────────────────
    debugPrint('[MEDIA RESOLVE START] $videoId endpoint=$endpoint');
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
      String code = 'WORKER_ERROR';
      String? errorBody;
      try {
        final b = jsonDecode(response.body) as Map<String, dynamic>;
        code      = (b['code']    as String?) ?? code;
        errorBody = (b['message'] as String?) ?? (b['error'] as String?);
      } catch (_) {
        errorBody = response.body.length > 120
            ? '${response.body.substring(0, 120)}…'
            : response.body;
      }
      debugPrint('[MEDIA RESOLVE FAIL] $videoId — HTTP ${response.statusCode} code=$code');
      throw MediaResolveException(
        _workerErrorMessage(code, response.statusCode),
        code:       code,
        httpStatus: response.statusCode,
        errorBody:  errorBody,
      );
    }

    // --- 4. Parse JSON payload ───────────────────────────────────────────────
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[MEDIA RESOLVE ERROR] $videoId — malformed JSON: $e');
      throw const MediaResolveException('Stream resolver returned malformed response');
    }

    final cdnUrl     = body['url']        as String?;
    final mimeType   = body['mimeType']   as String? ?? 'audio/mp4';
    final srcType    = body['sourceType'] as String? ?? 'audioOnly';
    final expiresAt  = (body['expiresAt'] as num?)?.toInt() ?? 0;
    final clientUsed = body['clientUsed'] as String? ?? '?';
    final itag       = (body['itag']      as num?)?.toInt() ?? 0;

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
      clientUsed: clientUsed,
      itag:       itag,
    );

    debugPrint('[MEDIA RESOLVE OK] $videoId → client=$clientUsed itag=$itag '
        'sourceType=$srcType mime=$mimeType expiresAt=$expiresAt');

    // --- 5. Cache (skip if client-pinned — we want next play to re-use normal waterfall) ──
    if (preferredClient == null) {
      await _cache.put(videoId, resolved);
    }

    return resolved;
  }

  /// Pre-warm the cache for an upcoming track (used by PrefetchManager).
  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    assert(videoId.isNotEmpty);
    debugPrint('[MEDIA PREFETCH] Resolving $videoId');

    final cached = await _cache.get(videoId);
    if (cached != null && !cached.isExpired) {
      debugPrint('[MEDIA PREFETCH] $videoId already cached — skip');
      return cached;
    }
    try {
      final resolved = await resolve(videoId);
      debugPrint('[MEDIA PREFETCH] $videoId — cached successfully');
      return resolved;
    } catch (e) {
      debugPrint('[MEDIA PREFETCH] $videoId — failed: $e');
      rethrow;
    }
  }

  /// Invalidate the StreamCache entry for [videoId].
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

class MediaResolveException implements Exception {
  final String  message;
  final String? code;
  final int     httpStatus;
  final String? errorBody;

  const MediaResolveException(
    this.message, {
    this.code,
    this.httpStatus = 0,
    this.errorBody,
  });

  @override String toString() => message;
}
