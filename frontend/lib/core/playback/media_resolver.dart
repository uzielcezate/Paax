import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'stream_cache.dart';

// ---------------------------------------------------------------------------
// Anti-Bot: Override YoutubeHttpClient headers so every Innertube call uses
// the Android YouTube Music UA instead of the default Chrome/desktop UA.
// The library's send() method injects these on every request automatically.
// ---------------------------------------------------------------------------
class _MusicHttpClient extends YoutubeHttpClient {
  static const _kHeaders = {
    'user-agent':
        'com.google.android.apps.youtube.music/6.47.53 '
        '(Linux; U; Android 14; es_MX) gzip',
    'accept-language': 'es-MX,es;q=0.9,en-US;q=0.8,en;q=0.7',
    'accept': '*/*',
    'cookie': 'CONSENT=YES+cb',
  };

  @override
  Map<String, String> get headers => _kHeaders;
}

// ===========================================================================
// LocalStreamResolver — on-device YouTube audio stream extractor
// ===========================================================================
//
// Uses a single, shared YoutubeExplode instance across the app's lifetime to
// avoid memory leaks and excessive initialisation overhead.
//
// Stream selection priority:
//   1. AudioOnly itag=140  (audio/mp4, ~128 kbps AAC — most stable)
//   2. AudioOnly, any mp4/m4a, highest bitrate
//   3. AudioOnly, any container, highest bitrate
//   4. Muxed mp4, lowest bitrate (last resort)
// ===========================================================================

// ---------------------------------------------------------------------------
// ResolvedStream — minimal value object
// ---------------------------------------------------------------------------

class ResolvedStream {
  final String   url;
  final String   mimeType;   // e.g. 'audio/mp4'
  final String   sourceType; // 'audioOnly' | 'muxed'
  final DateTime resolvedAt;
  final int      expiresAt;  // Unix epoch seconds, 0 = unknown
  final int      itag;
  final int      bitrate;    // bits per second

  const ResolvedStream({
    required this.url,
    required this.mimeType,
    required this.sourceType,
    required this.resolvedAt,
    this.expiresAt = 0,
    this.itag      = 0,
    this.bitrate   = 0,
  });

  bool get isExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  @override
  String toString() =>
      'ResolvedStream(itag=$itag mimeType=$mimeType sourceType=$sourceType)';
}

// ---------------------------------------------------------------------------
// LocalResolveException
// ---------------------------------------------------------------------------

class LocalResolveException implements Exception {
  final String  message;
  final bool    is403;
  final bool    is429; // rate-limited — back off and retry
  final String? videoId;

  const LocalResolveException(
    this.message, {
    this.is403  = false,
    this.is429  = false,
    this.videoId,
  });

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// LocalStreamResolver
// ---------------------------------------------------------------------------

class LocalStreamResolver {
  LocalStreamResolver._();

  /// Shared singleton — one YoutubeExplode for the app's entire lifecycle.
  static final LocalStreamResolver instance = LocalStreamResolver._();

  /// Never call dispose() on this — it must survive the entire app lifecycle.
  ///
  /// The inner HTTP client is configured with Android YouTube Music headers so
  /// Innertube treats our player requests as a real phone app, not a bot.
  static YoutubeExplode _buildYt() => YoutubeExplode(_MusicHttpClient());

  final _yt    = _buildYt();
  final _cache = StreamCache.instance;

  // ---------------------------------------------------------------------------
  // resolve
  // ---------------------------------------------------------------------------

  /// Extract and return the best audio stream for [videoId].
  ///
  /// Results are cached in [StreamCache] with a fixed TTL. Callers should call
  /// [invalidate] before retrying after a 403 or playback failure.
  Future<ResolvedStream> resolve(String videoId) async {
    assert(videoId.isNotEmpty);

    // Cache hit
    final cached = await _cache.get(videoId);
    if (cached != null) {
      if (!cached.isExpired) {
        debugPrint('[LOCAL RESOLVE] Cache hit: $videoId itag=${cached.itag}');
        return cached;
      }
      await _cache.invalidate(videoId);
    }

    debugPrint('[LOCAL RESOLVE] Fetching manifest: $videoId');
    final resolveStart = DateTime.now();

    StreamManifest manifest;
    try {
      manifest = await _yt.videos.streamsClient.getManifest(videoId);
    } on YoutubeExplodeException catch (e) {
      final msg = e.message.toLowerCase();
      final is429 = msg.contains('429') ||
                    msg.contains('rate') ||
                    msg.contains('too many requests') ||
                    msg.contains('bot') ||
                    msg.contains('sign in') ||
                    msg.contains('confirm');
      debugPrint('[LOCAL RESOLVE] ${is429 ? '429/RATE-LIMIT' : 'ERROR'}: ${e.message}');
      throw LocalResolveException(
        is429 ? 'Rate-limited by YouTube — retrying with fresh extract'
              : 'Stream unavailable: ${e.message}',
        is429:   is429,
        videoId: videoId,
      );
    } catch (e) {
      debugPrint('[LOCAL RESOLVE] Error: $e');
      throw LocalResolveException('Failed to resolve stream: $e', videoId: videoId);
    }

    final elapsed = DateTime.now().difference(resolveStart).inMilliseconds;
    debugPrint('[LOCAL RESOLVE] Manifest in ${elapsed}ms: $videoId');

    final resolved = _selectBest(manifest, videoId);
    debugPrint('[LOCAL RESOLVE] Selected itag=${resolved.itag} '
        'mime=${resolved.mimeType} src=${resolved.sourceType} '
        'bitrate=${resolved.bitrate ~/ 1000}kbps expiresAt=${resolved.expiresAt}');

    await _cache.put(videoId, resolved);
    return resolved;
  }

  // ---------------------------------------------------------------------------
  // resolveForPrefetch — used by PrefetchManager (best-effort, fire-and-forget)
  // ---------------------------------------------------------------------------

  Future<ResolvedStream> resolveForPrefetch(String videoId) async {
    final cached = await _cache.get(videoId);
    if (cached != null && !cached.isExpired) return cached;
    return resolve(videoId);
  }

  // ---------------------------------------------------------------------------
  // invalidate
  // ---------------------------------------------------------------------------

  Future<void> invalidate(String videoId) {
    debugPrint('[LOCAL RESOLVE] Invalidating cache: $videoId');
    return _cache.invalidate(videoId);
  }

  // ---------------------------------------------------------------------------
  // _selectBest
  // ---------------------------------------------------------------------------

  ResolvedStream _selectBest(StreamManifest manifest, String videoId) {
    final audioStreams = manifest.audioOnly.toList();

    // Priority 1: itag 140  (audio/mp4 128kbps AAC — most reliable)
    for (final s in audioStreams) {
      if (s.tag == 140) {
        return _fromAudio(s);
      }
    }

    // Priority 2: any mp4/m4a audio stream, highest bitrate
    final mp4Audio = audioStreams
        .where((s) => s.container.name.toLowerCase() == 'mp4')
        .toList()
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    if (mp4Audio.isNotEmpty) return _fromAudio(mp4Audio.first);

    // Priority 3: any audio stream, highest bitrate
    audioStreams.sort(
        (a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    if (audioStreams.isNotEmpty) return _fromAudio(audioStreams.first);

    // Priority 4: muxed mp4 (last resort — video + audio, pick lowest bitrate)
    final muxed = manifest.muxed
        .where((s) => s.container.name.toLowerCase() == 'mp4')
        .toList()
      ..sort((a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond));
    if (muxed.isNotEmpty) {
      final m = muxed.first;
      return ResolvedStream(
        url:        m.url.toString(),
        mimeType:   'video/mp4',
        sourceType: 'muxed',
        resolvedAt: DateTime.now(),
        expiresAt:  _extractExpiry(m.url),
        itag:       m.tag,
        bitrate:    m.bitrate.bitsPerSecond,
      );
    }

    throw LocalResolveException(
      'No playable stream found for $videoId',
      videoId: videoId,
    );
  }

  ResolvedStream _fromAudio(AudioOnlyStreamInfo s) => ResolvedStream(
    url:        s.url.toString(),
    mimeType:   'audio/${s.container.name.toLowerCase()}',
    sourceType: 'audioOnly',
    resolvedAt: DateTime.now(),
    expiresAt:  _extractExpiry(s.url),
    itag:       s.tag,
    bitrate:    s.bitrate.bitsPerSecond,
  );

  int _extractExpiry(Uri uri) {
    try {
      final v = uri.queryParameters['expire'];
      return v != null ? (int.tryParse(v) ?? 0) : 0;
    } catch (_) {
      return 0;
    }
  }
}
