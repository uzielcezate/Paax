import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

// ===========================================================================
// StreamApiService — single HTTP client for the stream resolution backend
// ===========================================================================
//
// All stream resolution happens server-side (Invidious via your own backend).
// The Flutter client never touches YouTube/Invidious directly.
//
// Endpoint:
//   GET {streamBaseUrl}/resolve/stream/{videoId}
//
// Expected response shape:
//   {
//     "success":   true,
//     "videoId":   "...",
//     "provider":  "invidious-nerdvpn",
//     "streamUrl": "https://...",
//     "mimeType":  "audio/mp4",
//     "container": "mp4",
//     "bitrate":   131550
//   }
// ===========================================================================

class StreamResult {
  final String streamUrl;
  final String mimeType;    // e.g. 'audio/mp4'
  final String container;   // e.g. 'mp4'
  final String provider;    // e.g. 'invidious-nerdvpn'
  final int    bitrate;     // bits per second

  const StreamResult({
    required this.streamUrl,
    required this.mimeType,
    required this.container,
    required this.provider,
    this.bitrate = 0,
  });

  @override
  String toString() =>
      'StreamResult(provider=$provider mimeType=$mimeType bitrate=${bitrate ~/ 1000}kbps)';
}

class StreamResolveException implements Exception {
  final String message;
  final int    httpStatus; // 0 = network/parse error
  final bool   isRetriable;

  const StreamResolveException(
    this.message, {
    this.httpStatus    = 0,
    this.isRetriable   = false,
  });

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// StreamApiService
// ---------------------------------------------------------------------------

class StreamApiService {
  StreamApiService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 15);

  // ---------------------------------------------------------------------------
  // resolveStream
  // ---------------------------------------------------------------------------

  /// Resolve the audio stream URL for [videoId] by calling your stream backend.
  ///
  /// Throws [StreamResolveException] on any failure (network, HTTP error, or
  /// unexpected response shape).
  Future<StreamResult> resolveStream(String videoId) async {
    assert(videoId.isNotEmpty);

    final endpoint = '${ApiConfig.streamBaseUrl}/resolve/stream/$videoId';
    debugPrint('[STREAM API] → GET $endpoint');

    http.Response response;
    try {
      response = await _client
          .get(Uri.parse(endpoint))
          .timeout(_timeout);
    } on Exception catch (e) {
      debugPrint('[STREAM API] Network error: $e');
      throw StreamResolveException(
        'Network error reaching stream backend: $e',
        isRetriable: true,
      );
    }

    debugPrint('[STREAM API] ← HTTP ${response.statusCode} '
        '(${response.body.length} bytes)');

    if (response.statusCode != 200) {
      final retriable = response.statusCode >= 500 || response.statusCode == 429;
      debugPrint('[STREAM API] Error body: ${_truncate(response.body)}');
      throw StreamResolveException(
        'Backend returned HTTP ${response.statusCode}',
        httpStatus:  response.statusCode,
        isRetriable: retriable,
      );
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[STREAM API] JSON parse error: $e');
      throw const StreamResolveException('Invalid JSON from stream backend');
    }

    final success   = json['success'] as bool? ?? false;
    final streamUrl = json['streamUrl'] as String?;

    if (!success || streamUrl == null || streamUrl.isEmpty) {
      final reason = json['error'] ?? json['message'] ?? 'unknown';
      debugPrint('[STREAM API] Backend failure: $reason');
      throw StreamResolveException('Backend could not resolve stream: $reason');
    }

    final result = StreamResult(
      streamUrl: streamUrl,
      mimeType:  (json['mimeType']  as String?) ?? 'audio/mp4',
      container: (json['container'] as String?) ?? 'mp4',
      provider:  (json['provider']  as String?) ?? 'unknown',
      bitrate:   (json['bitrate']   as num?)?.toInt() ?? 0,
    );

    debugPrint('[STREAM API] Resolved: videoId=$videoId '
        'provider=${result.provider} mimeType=${result.mimeType} '
        'bitrate=${result.bitrate ~/ 1000}kbps '
        'host=${Uri.parse(streamUrl).host}');

    return result;
  }

  static String _truncate(String s, [int max = 200]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
