import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../config/api_config.dart';

// ===========================================================================
// StreamApiService — Hybrid Architecture (Phase 8)
// ===========================================================================
//
// Extraction:  Client-side via youtube_explode_dart (residential IP)
// Streaming:   Server-side via IPv6 proxy (datacenter, 16 IPv6 addresses)
//
// Flow:
//   1. youtube_explode_dart extracts the stream manifest on the user's device
//      (residential IP — bypasses YouTube's datacenter IP blocks)
//   2. Selects the best audio-only stream (itag 140 preferred: 128kbps M4A)
//   3. URL-encodes the raw googlevideo.com CDN URL
//   4. Constructs the proxy URL:
//        https://resolver.paaxmusic.app/stream?url=<encoded_cdn_url>
//   5. Returns this proxy URL to the playback engine
//
// The proxy handles IPv6 rotation, User-Agent spoofing, and Range requests.
// ===========================================================================

class StreamResult {
  final String streamUrl;     // The proxy URL (not the raw CDN URL)
  final String rawCdnUrl;     // The raw googlevideo.com URL (for debug)
  final String mimeType;      // e.g. 'audio/mp4'
  final String container;     // e.g. 'mp4'
  final String provider;      // 'youtube_explode_dart'
  final int    bitrate;       // bits per second

  const StreamResult({
    required this.streamUrl,
    required this.rawCdnUrl,
    required this.mimeType,
    required this.container,
    required this.provider,
    this.bitrate = 0,
  });

  @override
  String toString() =>
      'StreamResult(provider=$provider mimeType=$mimeType '
      'bitrate=${bitrate ~/ 1000}kbps)';
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
  StreamApiService();

  final YoutubeExplode _yt = YoutubeExplode();

  // ── Target itag: 140 = 128kbps AAC M4A (gold standard for music) ──────────
  static const int _kTargetItag = 140;

  // ---------------------------------------------------------------------------
  // resolveStream
  // ---------------------------------------------------------------------------

  /// Extract the audio stream URL for [videoId] locally using
  /// youtube_explode_dart, then wrap it in the IPv6 proxy URL.
  ///
  /// Throws [StreamResolveException] on any failure.
  Future<StreamResult> resolveStream(String videoId) async {
    assert(videoId.isNotEmpty);

    debugPrint('[STREAM API] Extracting manifest for videoId=$videoId '
        '(client-side, youtube_explode_dart)');

    // ── 1. Get stream manifest ──────────────────────────────────────────────
    StreamManifest manifest;
    try {
      manifest = await _yt.videos.streamsClient.getManifest(videoId);
    } catch (e) {
      debugPrint('[STREAM API] Manifest extraction failed: $e');
      throw StreamResolveException(
        'Failed to extract stream manifest: $e',
        isRetriable: true,
      );
    }

    // ── 2. Filter to audio-only streams ─────────────────────────────────────
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) {
      debugPrint('[STREAM API] No audio-only streams found for $videoId');
      throw StreamResolveException(
        'No audio-only streams found for videoId=$videoId',
      );
    }

    debugPrint('[STREAM API] Found ${audioStreams.length} audio streams');

    // ── 3. Select best stream (prefer itag 140) ─────────────────────────────
    AudioOnlyStreamInfo? selected;

    // Priority 1: itag 140 (128kbps AAC M4A)
    for (final stream in audioStreams) {
      if (stream.tag == _kTargetItag) {
        selected = stream;
        debugPrint('[STREAM API] itag 140 found — using it directly');
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
        debugPrint('[STREAM API] itag 140 absent — chose best M4A '
            '(itag=${selected.tag} bitrate=${selected.bitrate})');
      }
    }

    // Priority 3: Any audio (highest bitrate)
    if (selected == null) {
      final sorted = List<AudioOnlyStreamInfo>.from(audioStreams)
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      selected = sorted.first;
      debugPrint('[STREAM API] No M4A — fell back to '
          'itag=${selected.tag} container=${selected.container.name}');
    }

    // ── 4. Build the proxy URL ──────────────────────────────────────────────
    final rawCdnUrl = selected.url.toString();
    final encodedUrl = Uri.encodeComponent(rawCdnUrl);
    final proxyUrl = '${ApiConfig.streamBaseUrl}/stream?url=$encodedUrl';

    final bitrateKbps = selected.bitrate.kiloBitsPerSecond.round();
    final mimeType = 'audio/${selected.container.name.toLowerCase()}';

    debugPrint('[STREAM API] Resolved: videoId=$videoId '
        'itag=${selected.tag} bitrate=${bitrateKbps}kbps '
        'container=${selected.container.name} '
        'cdn_host=${selected.url.host}');
    debugPrint('[STREAM API] Proxy URL: ${proxyUrl.substring(0, 80)}...');

    return StreamResult(
      streamUrl: proxyUrl,
      rawCdnUrl: rawCdnUrl,
      mimeType:  mimeType,
      container: selected.container.name.toLowerCase(),
      provider:  'youtube_explode_dart',
      bitrate:   (bitrateKbps * 1000),
    );
  }

  /// Dispose the youtube_explode client.
  void dispose() {
    _yt.close();
  }
}
