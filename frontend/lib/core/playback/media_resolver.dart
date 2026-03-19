import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// StreamCandidate — one playable format URL from a resolved client
// ---------------------------------------------------------------------------

/// A single playable stream candidate returned by the Worker.
/// Multiple candidates can come from the same Innertube client.
class StreamCandidate {
  final String url;
  final int    itag;       // e.g. 140 (audio/mp4), 18 (muxed)
  final String mimeType;  // e.g. 'audio/mp4', 'video/mp4'
  final String sourceType; // 'audioOnly' | 'muxed'
  final String clientUsed; // e.g. 'ANDROID'
  final int    bitrate;

  const StreamCandidate({
    required this.url,
    required this.itag,
    required this.mimeType,
    required this.sourceType,
    required this.clientUsed,
    this.bitrate = 0,
  });

  /// Unique key used by [CandidateBlacklist] to track failures.
  String get key => '$clientUsed:$itag';

  Map<String, dynamic> toJson() => {
    'url':        url,
    'itag':       itag,
    'mimeType':   mimeType,
    'sourceType': sourceType,
    'clientUsed': clientUsed,
    'bitrate':    bitrate,
  };

  factory StreamCandidate.fromJson(Map<String, dynamic> j, String clientUsed) =>
      StreamCandidate(
        url:        j['url']        as String,
        itag:       (j['itag']      as num).toInt(),
        mimeType:   j['mimeType']   as String? ?? 'audio/mp4',
        sourceType: j['sourceType'] as String? ?? 'audioOnly',
        clientUsed: clientUsed,
        bitrate:    (j['bitrate']   as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'StreamCandidate(key=$key sourceType=$sourceType mime=$mimeType)';
}

// ---------------------------------------------------------------------------
// ResolvedStream — value object returned by MediaResolver
// ---------------------------------------------------------------------------

class ResolvedStream {
  final String url;
  final String mimeType;
  final String sourceType;
  final DateTime resolvedAt;
  final int    expiresAt;
  final String clientUsed;
  final int    itag;
  /// All playable candidates from the winning client (includes primary).
  final List<StreamCandidate> candidates;

  const ResolvedStream({
    required this.url,
    required this.mimeType,
    required this.sourceType,
    required this.resolvedAt,
    this.expiresAt  = 0,
    this.clientUsed = '?',
    this.itag       = 0,
    this.candidates = const [],
  });

  bool get isExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  @override
  String toString() =>
      'ResolvedStream(client=$clientUsed itag=$itag source=$sourceType '
      'candidates=${candidates.length} expires=$expiresAt)';
}

// ---------------------------------------------------------------------------
// MediaResolver
// ---------------------------------------------------------------------------

class MediaResolver {
  MediaResolver({StreamCache? cache}) : _cache = cache ?? StreamCache.instance;

  final StreamCache _cache;

  static const String _workerBase    = 'https://stream.paaxmusic.app';
  static const Duration _httpTimeout = Duration(seconds: 15);
  static const Map<String, String> _workerHeaders = {'Accept': 'application/json'};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Resolves a direct CDN stream URL for [videoId].
  ///
  /// [preferredClient] — Worker will try this client first (bypasses CF cache)
  /// [excludeClients]  — Worker will skip these clients entirely
  ///
  /// On failedBuffering the engine calls this again with [excludeClients] set
  /// to the set of clients that produced no bytes, forcing a genuinely new
  /// Innertube client to be tried.
  Future<ResolvedStream> resolve(
    String videoId, {
    String?       preferredClient,
    List<String>? excludeClients,
  }) async {
    assert(videoId.isNotEmpty);

    final forceResolve = preferredClient != null ||
        (excludeClients != null && excludeClients.isNotEmpty);

    // --- 1. Cache hit (skip for forced resolves) ─────────────────────────────
    if (!forceResolve) {
      final cached = await _cache.get(videoId);
      if (cached != null) {
        if (!cached.isExpired) {
          debugPrint('[MEDIA CACHE HIT] $videoId client=${cached.clientUsed} '
              'itag=${cached.itag} candidates=${cached.candidates.length}');
          return cached;
        }
        await _cache.invalidate(videoId);
      }
    }

    // --- 2. Build Worker URL ─────────────────────────────────────────────────
    final qp = <String, String>{};
    if (preferredClient != null) qp['client'] = preferredClient;
    if (excludeClients != null && excludeClients.isNotEmpty) {
      qp['exclude'] = excludeClients.join(',');
    }

    final endpoint = Uri.parse('$_workerBase/$videoId')
        .replace(queryParameters: qp.isNotEmpty ? qp : null);

    debugPrint('[MEDIA RESOLVE START] $videoId → $endpoint');

    // --- 3. HTTP request ─────────────────────────────────────────────────────
    final http.Response response;
    try {
      response = await http
          .get(endpoint, headers: _workerHeaders)
          .timeout(_httpTimeout);
    } catch (e) {
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
      debugPrint('[MEDIA RESOLVE FAIL] $videoId HTTP=${response.statusCode} code=$code');
      throw MediaResolveException(
        _workerErrorMessage(code, response.statusCode),
        code: code, httpStatus: response.statusCode, errorBody: errorBody,
      );
    }

    // --- 4. Parse JSON ───────────────────────────────────────────────────────
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw const MediaResolveException('Stream resolver returned malformed response');
    }

    final cdnUrl     = body['url']        as String?;
    final mimeType   = body['mimeType']   as String? ?? 'audio/mp4';
    final srcType    = body['sourceType'] as String? ?? 'audioOnly';
    final expiresAt  = (body['expiresAt'] as num?)?.toInt() ?? 0;
    final clientUsed = body['clientUsed'] as String? ?? '?';
    final itag       = (body['itag']      as num?)?.toInt() ?? 0;

    if (cdnUrl == null || cdnUrl.isEmpty) {
      throw const MediaResolveException('Stream resolver returned an empty URL');
    }

    // Parse candidates array from Worker v5
    final rawCandidates = body['candidates'] as List<dynamic>? ?? [];
    final candidates = rawCandidates.map((c) {
      final m = c as Map<String, dynamic>;
      return StreamCandidate.fromJson(m, clientUsed);
    }).toList();

    // If Worker didn't return candidates (old Worker version), synthesize one
    if (candidates.isEmpty) {
      candidates.add(StreamCandidate(
        url: cdnUrl, itag: itag, mimeType: mimeType,
        sourceType: srcType, clientUsed: clientUsed,
      ));
    }

    final resolved = ResolvedStream(
      url:        cdnUrl,
      mimeType:   mimeType,
      sourceType: srcType,
      resolvedAt: DateTime.now(),
      expiresAt:  expiresAt,
      clientUsed: clientUsed,
      itag:       itag,
      candidates: candidates,
    );

    debugPrint('[MEDIA RESOLVE OK] $videoId client=$clientUsed itag=$itag '
        'candidates=${candidates.length} expiresAt=$expiresAt');

    // --- 5. Cache (only for non-forced resolves) ─────────────────────────────
    if (!forceResolve) {
      await _cache.put(videoId, resolved);
    }

    return resolved;
  }

  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    final cached = await _cache.get(videoId);
    if (cached != null && !cached.isExpired) return cached;
    try {
      final r = await resolve(videoId);
      debugPrint('[MEDIA PREFETCH] $videoId — cached');
      return r;
    } catch (e) {
      debugPrint('[MEDIA PREFETCH] $videoId — failed: $e');
      rethrow;
    }
  }

  Future<void> invalidate(String videoId) => _cache.invalidate(videoId);

  // ---------------------------------------------------------------------------
  String _workerErrorMessage(String code, int status) {
    const msgs = {
      'PLAYABILITY_UNAVAILABLE': 'This track is no longer available.',
      'PLAYABILITY_FAILED':      'This track is no longer available.',
      'NO_AUDIO_FORMAT':         'No compatible audio stream found.',
      'ALL_CLIENTS_BLOCKED':     'Stream temporarily unavailable. Please try again.',
      'ALL_CLIENTS_EXCLUDED':    'Stream temporarily unavailable. Please try again.',
      'NO_STREAMING_DATA':       'Playback is not available right now.',
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
