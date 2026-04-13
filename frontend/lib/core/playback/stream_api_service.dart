import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'identity_service.dart';

// ===========================================================================
// StreamApiService — WebView-Authenticated Extraction (Phase 10)
// ===========================================================================
//
// Flow:
//   1. IdentityService provides real browser cookies + visitorData
//      (extracted from a hidden WebView that loaded m.youtube.com)
//   2. We inject these into youtube_explode_dart's HTTP client
//   3. YouTube sees a "real browser" session, not a bot
//   4. Extraction succeeds, returns raw CDN URL for direct playback
//
// Fallback:
//   If IdentityService fails (timeout, no WebView), we try extraction
//   without cookies. It may or may not work, but we don't crash.
// ===========================================================================

class StreamResult {
  final String streamUrl;     // Raw CDN URL (fed directly to just_audio)
  final String mimeType;      // e.g. 'audio/mp4'
  final String container;     // e.g. 'mp4'
  final String provider;      // 'youtube_explode_dart'
  final int    bitrate;       // bits per second
  final bool   authenticated; // true if WebView cookies were used

  const StreamResult({
    required this.streamUrl,
    required this.mimeType,
    required this.container,
    required this.provider,
    this.bitrate = 0,
    this.authenticated = false,
  });

  @override
  String toString() =>
      'StreamResult(provider=$provider mimeType=$mimeType '
      'bitrate=${bitrate ~/ 1000}kbps auth=$authenticated)';
}

class StreamResolveException implements Exception {
  final String message;
  final int    httpStatus;
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
// Authenticated HTTP client that injects WebView cookies
// ---------------------------------------------------------------------------

/// Wraps a standard [http.Client] to add YouTube session cookies
/// and visitor identity to every outgoing request.
class _CookieInjectedClient extends http.BaseClient {
  final http.Client _inner;
  final String cookieHeader;
  final String? visitorData;

  _CookieInjectedClient({
    required this.cookieHeader,
    this.visitorData,
    http.Client? inner,
  }) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (cookieHeader.isNotEmpty) {
      request.headers['Cookie'] = cookieHeader;
    }
    if (visitorData != null && visitorData!.isNotEmpty) {
      request.headers['X-Goog-Visitor-Id'] = visitorData!;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

// ---------------------------------------------------------------------------
// StreamApiService
// ---------------------------------------------------------------------------

class StreamApiService {
  StreamApiService();

  static const int _kTargetItag = 140; // 128kbps AAC M4A
  static const Duration _kIdentityTimeout = Duration(seconds: 12);

  // ---------------------------------------------------------------------------
  // resolveStream
  // ---------------------------------------------------------------------------

  /// Extract the audio stream URL for [videoId] using youtube_explode_dart,
  /// authenticated with real browser cookies from the hidden WebView.
  ///
  /// Returns the raw CDN URL for direct playback by just_audio.
  Future<StreamResult> resolveStream(String videoId) async {
    assert(videoId.isNotEmpty);

    // ── 1. Get browser identity (cookies + visitor data) ─────────────────
    YouTubeIdentity? identity;
    try {
      identity = await IdentityService.instance
          .getIdentity()
          .timeout(_kIdentityTimeout);
      debugPrint('[STREAM] Identity OK: '
          '${identity.cookies.length} cookies, '
          'visitor=${identity.visitorData != null ? "YES" : "NO"}');
    } catch (e) {
      debugPrint('[STREAM] Identity unavailable: $e -- trying without cookies');
    }

    // ── 2. Create youtube_explode with authenticated HTTP client ─────────
    final bool authenticated = identity != null &&
        identity.cookieHeader.isNotEmpty;

    final YoutubeExplode yt;
    if (authenticated) {
      final authClient = _CookieInjectedClient(
        cookieHeader: identity.cookieHeader,
        visitorData: identity.visitorData,
      );
      yt = YoutubeExplode(YoutubeHttpClient(authClient));
      debugPrint('[STREAM] Using AUTHENTICATED client');
    } else {
      yt = YoutubeExplode();
      debugPrint('[STREAM] Using DEFAULT client (no cookies)');
    }

    // ── 3. Extract stream manifest ───────────────────────────────────────
    debugPrint('[STREAM] Extracting manifest for videoId=$videoId');

    StreamManifest manifest;
    try {
      manifest = await yt.videos.streamsClient.getManifest(videoId);
    } catch (e) {
      debugPrint('[STREAM] Manifest extraction failed: $e');
      yt.close();

      // If authenticated extraction failed, invalidate identity
      // so next attempt gets fresh cookies
      if (authenticated) {
        IdentityService.instance.invalidate();
        debugPrint('[STREAM] Identity invalidated due to extraction failure');
      }

      throw StreamResolveException(
        'Failed to extract stream manifest: $e',
        isRetriable: true,
      );
    }

    // ── 4. Filter to audio-only streams ──────────────────────────────────
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) {
      yt.close();
      debugPrint('[STREAM] No audio-only streams found for $videoId');
      throw StreamResolveException(
        'No audio-only streams found for videoId=$videoId',
      );
    }

    debugPrint('[STREAM] Found ${audioStreams.length} audio streams');

    // ── 5. Select best stream (prefer itag 140) ──────────────────────────
    AudioOnlyStreamInfo? selected;

    // Priority 1: itag 140 (128kbps AAC M4A)
    for (final stream in audioStreams) {
      if (stream.tag == _kTargetItag) {
        selected = stream;
        debugPrint('[STREAM] itag 140 found');
        break;
      }
    }

    // Priority 2: Best M4A by bitrate
    if (selected == null) {
      final m4aStreams = audioStreams
          .where((s) => s.container.name.toLowerCase() == 'mp4'
                     || s.container.name.toLowerCase() == 'm4a')
          .toList();
      if (m4aStreams.isNotEmpty) {
        m4aStreams.sort((a, b) => b.bitrate.compareTo(a.bitrate));
        selected = m4aStreams.first;
        debugPrint('[STREAM] itag 140 absent -- best M4A: '
            'itag=${selected.tag} bitrate=${selected.bitrate}');
      }
    }

    // Priority 3: Any audio (highest bitrate)
    if (selected == null) {
      final sorted = List<AudioOnlyStreamInfo>.from(audioStreams)
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      selected = sorted.first;
      debugPrint('[STREAM] No M4A -- fallback: '
          'itag=${selected.tag} container=${selected.container.name}');
    }

    yt.close();

    // ── 6. Return raw CDN URL for direct playback ────────────────────────
    final cdnUrl = selected.url.toString();
    final bitrateKbps = selected.bitrate.kiloBitsPerSecond.round();
    final mimeType = 'audio/${selected.container.name.toLowerCase()}';

    debugPrint('[STREAM] Resolved: videoId=$videoId '
        'itag=${selected.tag} ${bitrateKbps}kbps '
        '${selected.container.name} '
        'host=${selected.url.host} '
        'auth=$authenticated');

    return StreamResult(
      streamUrl: cdnUrl,
      mimeType:  mimeType,
      container: selected.container.name.toLowerCase(),
      provider:  'youtube_explode_dart',
      bitrate:   (bitrateKbps * 1000),
      authenticated: authenticated,
    );
  }
}
