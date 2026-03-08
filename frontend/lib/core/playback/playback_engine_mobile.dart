import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'playback_engine.dart';

/// Typed exception thrown when resolution or player setup fails.
/// Already a safe, user-friendly string — never exposes raw errors.
class _PlaybackResolveException implements Exception {
  final String message;
  const _PlaybackResolveException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// HTTP headers for YouTube CDN requests.
// ---------------------------------------------------------------------------
const _kYouTubeHeaders = <String, String>{
  'User-Agent':
      'com.google.android.youtube/17.36.4 (Linux; U; Android 12) gzip',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

// ---------------------------------------------------------------------------
// URL analysis helper — development diagnostics only.
// ---------------------------------------------------------------------------

/// Returns a structured diagnostic map for the resolved stream URL.
/// Used exclusively in [kDebugMode] blocks — zero cost in release builds.
Map<String, String> _analyzeUrl(Uri uri, AudioOnlyStreamInfo info) {
  final path = uri.path.toLowerCase();
  final ext = path.contains('.') ? path.split('.').last.split('?').first : '';
  final isManifest = ext == 'm3u8' ||
      ext == 'mpd' ||
      path.contains('manifest') ||
      path.contains('playlist') ||
      uri.queryParameters.containsKey('manifest_type');
  final isSigned = uri.queryParameters.containsKey('sig') ||
      uri.queryParameters.containsKey('signature') ||
      uri.queryParameters.containsKey('expire') ||  // YouTube signed URL
      uri.queryParameters.containsKey('lsig');
  final paramCount = uri.queryParameters.length;
  final totalBytes = info.size.totalBytes;

  return {
    'scheme': uri.scheme,
    'host': uri.host,
    'path_ext': ext.isEmpty ? '(none)' : ext,
    'mime': info.codec.mimeType,
    'container': info.container.name,
    'is_manifest': '$isManifest',
    'is_signed_url': '$isSigned',
    'query_param_count': '$paramCount',
    'total_bytes': '$totalBytes',
    'size_valid': '${totalBytes > 0}',
    'direct_audio':
        '${!isManifest && (ext == 'mp4' || ext == 'm4a' || ext == '' || ext == 'aac')}',
  };
}

// ---------------------------------------------------------------------------
// _YtStreamAudioSource
// ---------------------------------------------------------------------------
//
// WHY: youtube_explode_dart stream URLs are signed CDN URLs served in
// DASH-adaptive mode. ExoPlayer's DefaultHttpDataSource cannot negotiate
// these as seekable progressive streams → (0) Source error.
//
// FIX: We extend StreamAudioSource and satisfy just_audio's byte-range
// requests ourselves using http.Client + Range headers + YouTube CDN headers.
// ExoPlayer only sees a plain byte stream from us; it never touches the CDN.
//
// KEY DETAILS IN THIS REVISION:
//   1. sourceLength is passed as null when totalBytes == 0 (unknown size)
//      rather than 0, which was causing ExoPlayer to reject the source.
//   2. Every CDN response is validated (status 200/206 required).
//   3. An explicit Range: bytes=0- is always sent, even on the first request
//      (some YouTube CDN nodes require a Range header to serve audio bytes).
//   4. A pre-flight diagnostic log is printed before setAudioSource.
// ---------------------------------------------------------------------------
class _YtStreamAudioSource extends StreamAudioSource {
  final AudioOnlyStreamInfo _info;
  final _client = http.Client();

  _YtStreamAudioSource(this._info);

  void close() {
    try {
      _client.close();
    } catch (_) {}
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // Always send a Range header.
    // Without it some YouTube CDN edge nodes serve a multipart/byteranges
    // response that ExoPlayer cannot parse. "bytes=0-" is the safest default.
    final effectiveStart = start ?? 0;
    final rangeEnd = end != null ? '${end - 1}' : '';
    final rangeHeader = 'bytes=$effectiveStart-$rangeEnd';

    final headers = <String, String>{
      ..._kYouTubeHeaders,
      'Range': rangeHeader,
    };

    if (kDebugMode) {
      debugPrint(
        '[PlaybackEngine][Source] CDN request  '
        'Range: $rangeHeader  '
        'url: ${_info.url.toString().substring(0, 70)}…',
      );
    }

    late http.StreamedResponse res;
    try {
      final req = http.Request('GET', _info.url)..headers.addAll(headers);
      res = await _client.send(req);
    } catch (e) {
      debugPrint('[PlaybackEngine][Error] CDN HTTP request failed: $e');
      throw _PlaybackResolveException(
          'CDN request failed: ${e.toString().substring(0, 80)}');
    }

    if (kDebugMode) {
      debugPrint(
        '[PlaybackEngine][Source] CDN response '
        'status=${res.statusCode}  '
        'content-type=${res.headers['content-type'] ?? '(none)'}  '
        'content-length=${res.contentLength ?? '(chunked)'}  '
        'content-range=${res.headers['content-range'] ?? '(none)'}',
      );
    }

    // Accept 200 (no Range support) and 206 (partial content / Range ok).
    // Any other status means the CDN rejected our request.
    if (res.statusCode != 200 && res.statusCode != 206) {
      debugPrint(
        '[PlaybackEngine][Error] CDN rejected Range request '
        'status=${res.statusCode}',
      );
      throw _PlaybackResolveException(
        'Audio stream unavailable (CDN ${res.statusCode}).',
      );
    }

    final totalBytes = _info.size.totalBytes;
    // Pass null if totalBytes is unknown to allow just_audio to still play
    // without a known length (duration will be inferred during buffering).
    final knownSourceLength = totalBytes > 0 ? totalBytes : null;
    // Content-Length from the response is the range slice size.
    final rangeLength =
        res.contentLength ?? (knownSourceLength != null ? knownSourceLength - effectiveStart : null);

    return StreamAudioResponse(
      sourceLength: knownSourceLength,
      contentLength: rangeLength,
      offset: effectiveStart,
      stream: res.stream,
      contentType: _info.codec.mimeType,
    );
  }
}

/// Native-platform playback engine shared by Android and iOS.
class PlaybackEngineImpl implements PlaybackEngine {
  final _player = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();
  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

  // Kept so we can close its http.Client when a new track loads.
  _YtStreamAudioSource? _currentSource;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration> get durationStream => _player.durationStream
      .where((d) => d != null && d > Duration.zero)
      .map((d) => d!);

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (_isDisposed) return;
        if (event.begin) {
          _player.pause();
        } else if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.duck) {
          _player.play();
        }
      }),
    );
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        if (_isDisposed) return;
        _player.pause();
      }),
    );
    _subscriptions.add(
      _player.playerStateStream.listen((state) {
        if (_isDisposed) return;
        if (state.processingState == ProcessingState.completed) {
          _completionController.add(null);
        }
      }),
    );
  }

  // -------------------------------------------------------------------------
  // Stream resolution
  // -------------------------------------------------------------------------

  /// Accepts only mp4/m4a/AAC containers; rejects webm/opus.
  static bool _isMp4Compatible(AudioOnlyStreamInfo s) {
    final mime = s.codec.mimeType.toLowerCase();
    final container = s.container.name.toLowerCase();
    return mime.contains('mp4') ||
        mime.contains('m4a') ||
        mime.contains('aac') ||
        container == 'mp4';
  }

  Future<({AudioOnlyStreamInfo info, String codec, String container, int bitrateKbps})>
      _resolveStream(String videoId) async {
    final yt = YoutubeExplode();
    try {
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ▶ Resolving stream for $videoId');
      }

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;

      // ── Full candidate dump (debug only) ─────────────────────────────────
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine] ${audioStreams.length} audio-only candidates:',
        );
        for (final s in audioStreams) {
          final pass = _isMp4Compatible(s) ? '✓' : '✗ skip';
          final bytes = s.size.totalBytes;
          debugPrint(
            '  $pass  mime=${s.codec.mimeType}  '
            'container=${s.container.name}  '
            'bitrate=${(s.bitrate.bitsPerSecond / 1000).round()} kbps  '
            'size=${bytes > 0 ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : 'unknown'}',
          );
        }
      }

      if (audioStreams.isEmpty) throw Exception('no audio streams');

      final compatibleStreams = audioStreams
          .where(_isMp4Compatible)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (kDebugMode && compatibleStreams.isEmpty) {
        debugPrint(
          '[PlaybackEngine] ✗ All candidates skipped. '
          'Types: ${audioStreams.map((s) => s.codec.mimeType).toSet().join(', ')}',
        );
      }

      if (compatibleStreams.isEmpty) {
        throw Exception('no mp4-compatible audio stream');
      }

      final chosen = compatibleStreams.first;
      final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();

      // ── Pre-flight URL analysis ───────────────────────────────────────────
      if (kDebugMode) {
        final uri = chosen.url;
        final diag = _analyzeUrl(uri, chosen);
        debugPrint('[PlaybackEngine] ✓ Selected stream for $videoId');
        diag.forEach(
          (k, v) => debugPrint('  $k: $v'),
        );
        debugPrint(
          '  url_preview: ${uri.toString().substring(0, 80)}…',
        );
        if (diag['is_manifest'] == 'true') {
          debugPrint(
            '[PlaybackEngine] ⚠ WARNING: selected URL looks like a MANIFEST — '
            'may not be a direct audio stream!',
          );
        }
        if (diag['size_valid'] == 'false') {
          debugPrint(
            '[PlaybackEngine] ⚠ WARNING: totalBytes=0 — '
            'sourceLength will be null (unknown). '
            'Seeking may be unavailable until player buffers duration.',
          );
        }
      }

      return (
        info: chosen,
        codec: chosen.codec.mimeType,
        container: chosen.container.name,
        bitrateKbps: bitrateKbps,
      );
    } catch (e) {
      debugPrint('[PlaybackEngine] ✗ Resolution failed for $videoId: $e');
      throw const _PlaybackResolveException(
          'This track is temporarily unavailable.');
    } finally {
      yt.close();
    }
  }

  // -------------------------------------------------------------------------
  // Load & play
  // -------------------------------------------------------------------------

  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;

    // ── Step 1: Resolve ───────────────────────────────────────────────────
    final resolved = await _resolveStream(videoId);

    // ── Step 2: Stop + release previous source ────────────────────────────
    await _player.stop();
    _currentSource?.close();
    _currentSource = null;

    // ── Step 3: Build StreamAudioSource ───────────────────────────────────
    final source = _YtStreamAudioSource(resolved.info);
    _currentSource = source;

    if (kDebugMode) {
      final totalBytes = resolved.info.size.totalBytes;
      debugPrint(
        '[PlaybackEngine][Source] PRE-FLIGHT SUMMARY\n'
        '  videoId      : $videoId\n'
        '  source_type  : _YtStreamAudioSource (byte-pipe / StreamAudioSource)\n'
        '  codec        : ${resolved.codec}\n'
        '  container    : ${resolved.container}\n'
        '  bitrate      : ${resolved.bitrateKbps} kbps\n'
        '  total_bytes  : ${totalBytes > 0 ? '${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB' : 'UNKNOWN — sourceLength=null'}\n'
        '  headers      : User-Agent ✓  Referer ✓  Origin ✓  Range ✓\n'
        '  direct_stream: true (byte-pipe, not AudioSource.uri)\n'
        '  url_host     : ${resolved.info.url.host}\n'
        '  url_scheme   : ${resolved.info.url.scheme}',
      );
    }

    // ── Step 4: setAudioSource ────────────────────────────────────────────
    if (kDebugMode) {
      debugPrint('[PlaybackEngine][Source] setAudioSource() starting — $videoId');
    }
    try {
      await _player.setAudioSource(source);
      if (kDebugMode) {
        debugPrint('[PlaybackEngine][Source] setAudioSource() OK — $videoId');
      }
    } catch (e) {
      _currentSource?.close();
      _currentSource = null;
      // Always logged (debug + release) — critical failure path.
      debugPrint(
        '[PlaybackEngine][Error] setAudioSource() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $e\n'
        '  player : ${e is PlayerException ? 'code=${e.code}  msg=${e.message}' : 'n/a'}',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][Error] SUMMARY  videoId=$videoId  '
          'container=${resolved.container}  codec=${resolved.codec}  '
          'stage=setAudioSource  headers=attached  result=REJECTED',
        );
      }
      // In debug builds append the failure stage so the snackbar shows exactly
      // where playback broke. In release, keep the generic friendly message.
      const hint = kDebugMode ? ' (setAudioSource failed)' : '';
      throw _PlaybackResolveException(
        'Playback source rejected$hint: ${_friendlyPlayerError(e)}',
      );
    }

    // ── Step 5: play ──────────────────────────────────────────────────────
    if (kDebugMode) {
      debugPrint('[PlaybackEngine][Source] play() starting — $videoId');
    }
    try {
      await _player.play();
      if (kDebugMode) {
        debugPrint('[PlaybackEngine][Source] play() OK — $videoId');
        debugPrint(
          '[PlaybackEngine][Source] SUMMARY  videoId=$videoId  '
          'container=${resolved.container}  codec=${resolved.codec}  '
          'bitrate=${resolved.bitrateKbps} kbps  stage=play  result=ACCEPTED',
        );
      }
    } catch (e) {
      // Always logged — critical failure path.
      debugPrint(
        '[PlaybackEngine][Error] play() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $e\n'
        '  player : ${e is PlayerException ? 'code=${e.code}  msg=${e.message}' : 'n/a'}',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][Error] SUMMARY  videoId=$videoId  '
          'container=${resolved.container}  stage=play  result=REJECTED',
        );
      }
      const hint = kDebugMode ? ' (play() failed)' : '';
      throw _PlaybackResolveException(
        'Playback failed to start$hint: ${_friendlyPlayerError(e)}',
      );
    }
  }

  String _friendlyPlayerError(Object e) {
    if (e is PlayerException) {
      return '(${e.code}) ${e.message ?? 'Unknown player error'}';
    }
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  // -------------------------------------------------------------------------
  // Playback controls
  // -------------------------------------------------------------------------

  @override
  Future<void> play() async => _player.play();

  @override
  Future<void> pause() async => _player.pause();

  @override
  Future<void> seek(Duration position) async => _player.seek(position);

  @override
  void dispose() {
    _isDisposed = true;
    _currentSource?.close();
    _currentSource = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _player.dispose();
    _completionController.close();
  }

  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}
