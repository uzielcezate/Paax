import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// ===========================================================================
// StreamApiService — Direct Playback (Phase 9)
// ===========================================================================
//
// The Flutter client handles EVERYTHING:
//   1. Extracts the stream manifest via youtube_explode_dart (residential IP)
//   2. Selects itag 140 (128kbps M4A) or best audio fallback
//   3. Returns the raw googlevideo.com CDN URL directly
//   4. just_audio plays it — same IP that extracted = no 403
//
// NO proxy involved. CDN URLs are IP-bound to the extracting client.
// ===========================================================================

class StreamResult {
  final String streamUrl;     // The raw CDN URL (fed directly to just_audio)
  final String mimeType;      // e.g. 'audio/mp4'
  final String container;     // e.g. 'mp4'
  final String provider;      // 'youtube_explode_dart'
  final int    bitrate;       // bits per second

  const StreamResult({
    required this.streamUrl,
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
  /// youtube_explode_dart.  Returns the raw CDN URL for direct playback.
  ///
  /// The URL is IP-bound to the device that called this method — it MUST
  /// be consumed by the same device (not proxied through a server).
  ///
  /// Throws [StreamResolveException] on any failure.
  Future<StreamResult> resolveStream(String videoId) async {
    assert(videoId.isNotEmpty);

    debugPrint('[STREAM] Extracting manifest for videoId=$videoId');

    // ── 1. Get stream manifest ──────────────────────────────────────────────
    StreamManifest manifest;
    try {
      manifest = await _yt.videos.streamsClient.getManifest(videoId);
    } catch (e) {
      debugPrint('[STREAM] Manifest extraction failed: $e');
      throw StreamResolveException(
        'Failed to extract stream manifest: $e',
        isRetriable: true,
      );
    }

    // ── 2. Filter to audio-only streams ─────────────────────────────────────
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) {
      debugPrint('[STREAM] No audio-only streams found for $videoId');
      throw StreamResolveException(
        'No audio-only streams found for videoId=$videoId',
      );
    }

    debugPrint('[STREAM] Found ${audioStreams.length} audio streams');

    // ── 3. Select best stream (prefer itag 140) ─────────────────────────────
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

    // ── 4. Return raw CDN URL (direct playback, no proxy) ───────────────────
    final cdnUrl = selected.url.toString();
    final bitrateKbps = selected.bitrate.kiloBitsPerSecond.round();
    final mimeType = 'audio/${selected.container.name.toLowerCase()}';

    debugPrint('[STREAM] Resolved: videoId=$videoId '
        'itag=${selected.tag} ${bitrateKbps}kbps '
        '${selected.container.name} '
        'host=${selected.url.host}');

    return StreamResult(
      streamUrl: cdnUrl,
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
