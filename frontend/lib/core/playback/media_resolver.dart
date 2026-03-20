import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// StreamCandidate
// ---------------------------------------------------------------------------
class StreamCandidate {
  final String url;
  final int    itag;
  final String mimeType;
  final String sourceType;
  final String clientUsed;
  final int    bitrate;

  const StreamCandidate({
    required this.url,
    required this.itag,
    required this.mimeType,
    required this.sourceType,
    required this.clientUsed,
    this.bitrate = 0,
  });

  String get key => '$clientUsed:$itag';

  Map<String, dynamic> toJson() => {
    'url': url, 'itag': itag, 'mimeType': mimeType,
    'sourceType': sourceType, 'clientUsed': clientUsed, 'bitrate': bitrate,
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
// ResolvedStream
// ---------------------------------------------------------------------------
class ResolvedStream {
  final String url;
  final String mimeType;
  final String sourceType;
  final DateTime resolvedAt;
  final int    expiresAt;
  final String clientUsed;
  final int    itag;
  final List<StreamCandidate> candidates;

  // Worker v6 debug fields
  final List<String> attemptedClients;
  final List<String> excludedClients;
  final String       resolvePath;    // 'fresh' | 'cache'
  final int          candidateCount;
  final List<Map<String, String>> clientErrors;

  const ResolvedStream({
    required this.url,
    required this.mimeType,
    required this.sourceType,
    required this.resolvedAt,
    this.expiresAt  = 0,
    this.clientUsed = '?',
    this.itag       = 0,
    this.candidates = const [],
    this.attemptedClients = const [],
    this.excludedClients  = const [],
    this.resolvePath      = '',
    this.candidateCount   = 0,
    this.clientErrors     = const [],
  });

  bool get isExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  @override
  String toString() =>
      'ResolvedStream(client=$clientUsed itag=$itag candidates=${candidates.length} '
      'attempted=${attemptedClients.join(",")} path=$resolvePath)';
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

  Future<ResolvedStream> resolve(
    String videoId, {
    String?       preferredClient,
    List<String>? excludeClients,
  }) async {
    assert(videoId.isNotEmpty);

    final forceResolve = preferredClient != null ||
        (excludeClients != null && excludeClients.isNotEmpty);

    // Cache hit
    if (!forceResolve) {
      final cached = await _cache.get(videoId);
      if (cached != null) {
        if (!cached.isExpired) {
          debugPrint('[MEDIA CACHE HIT] $videoId client=${cached.clientUsed} itag=${cached.itag}');
          return cached;
        }
        await _cache.invalidate(videoId);
      }
    }

    // Build URL
    final qp = <String, String>{};
    if (preferredClient != null)                                qp['client']  = preferredClient;
    if (excludeClients != null && excludeClients.isNotEmpty)   qp['exclude'] = excludeClients.join(',');
    final endpoint = Uri.parse('$_workerBase/$videoId')
        .replace(queryParameters: qp.isNotEmpty ? qp : null);

    debugPrint('[MEDIA RESOLVE START] $videoId → $endpoint');

    // HTTP
    final http.Response response;
    try {
      response = await http.get(endpoint, headers: _workerHeaders).timeout(_httpTimeout);
    } catch (e) {
      throw MediaResolveException('Network error resolving stream: $e');
    }

    if (response.statusCode != 200) {
      String code = 'WORKER_ERROR';
      String? errorBody;
      List<String>            attemptedClients = [];
      List<Map<String, String>> clientErrors  = [];
      try {
        final b = jsonDecode(response.body) as Map<String, dynamic>;
        code             = (b['code']             as String?) ?? code;
        errorBody        = (b['error']             as String?);
        attemptedClients = (b['attemptedClients']  as List?)?.cast<String>() ?? [];
        final rawErrs    =  b['clientErrors']      as List? ?? [];
        clientErrors     = rawErrs.map((e) {
          final m = e as Map;
          return {'client': m['client']?.toString() ?? '', 'code': m['code']?.toString() ?? '', 'msg': m['msg']?.toString() ?? ''};
        }).toList();
      } catch (_) {
        errorBody = response.body.length > 120
            ? '${response.body.substring(0, 120)}…'
            : response.body;
      }
      final clientErrorStr = clientErrors.map((e) => '${e['client']}:${e['code']}').join(', ');
      debugPrint('[MEDIA RESOLVE FAIL] $videoId HTTP=${response.statusCode} code=$code '
          'attempted=[${attemptedClients.join(',')}] clientErrors={$clientErrorStr}');
      throw MediaResolveException(
        _workerErrorMessage(code, response.statusCode),
        code: code, httpStatus: response.statusCode,
        errorBody: errorBody,
        attemptedClients: attemptedClients,
        clientErrors: clientErrors,
      );
    }

    // Parse JSON
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

    // Parse candidates
    final rawCandidates = body['candidates'] as List<dynamic>? ?? [];
    final candidates = rawCandidates
        .map((c) => StreamCandidate.fromJson(c as Map<String, dynamic>, clientUsed))
        .toList();
    if (candidates.isEmpty) {
      candidates.add(StreamCandidate(url: cdnUrl, itag: itag, mimeType: mimeType,
          sourceType: srcType, clientUsed: clientUsed));
    }

    // Parse Worker v6 debug fields
    final attemptedClients = (body['attemptedClients'] as List?)?.cast<String>() ?? [];
    final excludedClients  = (body['excludedClients']  as List?)?.cast<String>() ?? [];
    final resolvePath      = body['resolvePath']     as String? ?? '';
    final candidateCount   = (body['candidateCount'] as num?)?.toInt() ?? candidates.length;
    final rawClientErrors  = body['clientErrors'] as List? ?? [];
    final clientErrors     = rawClientErrors.map((e) {
      final m = e as Map;
      return {'client': m['client']?.toString() ?? '', 'code': m['code']?.toString() ?? '', 'msg': m['msg']?.toString() ?? ''};
    }).toList();

    final resolved = ResolvedStream(
      url: cdnUrl, mimeType: mimeType, sourceType: srcType,
      resolvedAt: DateTime.now(), expiresAt: expiresAt,
      clientUsed: clientUsed, itag: itag, candidates: candidates,
      attemptedClients: attemptedClients, excludedClients: excludedClients,
      resolvePath: resolvePath, candidateCount: candidateCount,
      clientErrors: clientErrors,
    );

    debugPrint('[MEDIA RESOLVE OK] $videoId client=$clientUsed itag=$itag '
        'candidates=${candidates.length} attempted=${attemptedClients.join(",")} path=$resolvePath');

    if (!forceResolve) await _cache.put(videoId, resolved);
    return resolved;
  }

  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    final cached = await _cache.get(videoId);
    if (cached != null && !cached.isExpired) return cached;
    return resolve(videoId);
  }

  Future<void> invalidate(String videoId) => _cache.invalidate(videoId);

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
  final List<String>              attemptedClients;
  final List<Map<String, String>> clientErrors;

  const MediaResolveException(
    this.message, {
    this.code,
    this.httpStatus       = 0,
    this.errorBody,
    this.attemptedClients = const [],
    this.clientErrors     = const [],
  });

  @override String toString() => message;
}
