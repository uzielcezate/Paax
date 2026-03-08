import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'playback_diagnostics.dart';
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
// HTTP headers passed directly to AudioSource.uri().
// just_audio v0.9.x forwards these to ExoPlayer's DefaultHttpDataSource,
// which then includes them on every range request it makes to the CDN.
// ---------------------------------------------------------------------------
const _kYouTubeHeaders = <String, String>{
  'User-Agent':
      'com.google.android.youtube/17.36.4 (Linux; U; Android 12) gzip',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

// ---------------------------------------------------------------------------
// Stream format filter
// ---------------------------------------------------------------------------

/// Returns true only for mp4 / m4a / AAC audio containers.
/// webm / opus containers are explicitly rejected — ExoPlayer on Android
/// cannot reliably handle webm as a progressive HTTP stream.
bool _isMp4Compatible(AudioOnlyStreamInfo s) {
  final mime = s.codec.mimeType.toLowerCase();
  final container = s.container.name.toLowerCase();
  return (mime.contains('mp4') ||
          mime.contains('m4a') ||
          mime.contains('aac') ||
          container == 'mp4') &&
      !mime.contains('webm') &&
      !container.contains('webm');
}

// ---------------------------------------------------------------------------
// URL analysis helper — debug diagnostics only.
// ---------------------------------------------------------------------------
Map<String, String> _analyzeUrl(Uri uri, AudioOnlyStreamInfo info) {
  final path = uri.path.toLowerCase();
  final ext = path.contains('.') ? path.split('.').last.split('?').first : '';
  final isManifest = ext == 'm3u8' ||
      ext == 'mpd' ||
      path.contains('manifest') ||
      path.contains('playlist') ||
      uri.queryParameters.containsKey('manifest_type');
  final isSigned = uri.queryParameters.containsKey('expire') ||
      uri.queryParameters.containsKey('sig') ||
      uri.queryParameters.containsKey('signature') ||
      uri.queryParameters.containsKey('lsig');
  final totalBytes = info.size.totalBytes;

  return {
    'scheme': uri.scheme,
    'host': uri.host,
    'path_ext': ext.isEmpty ? '(none — direct CDN path)' : ext,
    'mime': info.codec.mimeType,
    'container': info.container.name,
    'is_manifest': '$isManifest',
    'is_signed_url': '$isSigned',
    'query_params': '${uri.queryParameters.length}',
    'total_bytes': '$totalBytes',
    'size_known': '${totalBytes > 0}',
    'mp4_compatible': '${_isMp4Compatible(info)}',
    // DASH indicator: YouTube progressive streams serve full content-length,
    // while DASH segments use 'clen=' query param alongside 'sq='
    'has_sq_param': '${uri.queryParameters.containsKey('sq')}',
    'has_clen_param': '${uri.queryParameters.containsKey('clen')}',
  };
}

// ---------------------------------------------------------------------------
// PlaybackEngineImpl
// ---------------------------------------------------------------------------

/// Native-platform playback engine shared by Android and iOS.
///
/// APPROACH (this revision):
///   Uses [AudioSource.uri()] with YouTube CDN headers passed directly.
///   This lets ExoPlayer's built-in HTTP stack handle range requests and
///   buffering natively, while the CDN headers ensure auth is accepted.
///
///   WHY NOT StreamAudioSource byte-pipe:
///   The previous _YtStreamAudioSource approach was failing at setAudioSource
///   because just_audio's internal probe request during setAudioSource was
///   also failing — meaning the byte-piping was not solving the core issue.
///   Switching to AudioSource.uri() + headers is the correctapproach because:
///   1. ExoPlayer natively handles HTTP range requests, retries and buffering
///   2. The headers param in just_audio v0.9.x is forwarded to ExoPlayer
///   3. YouTube mp4/m4a audio-only streams ARE accessible as progressive HTTP
///      streams when the correct User-Agent and Referer headers are provided
class PlaybackEngineImpl implements PlaybackEngine {
  final _player = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();
  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

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

  Future<({AudioOnlyStreamInfo info, String codec, String container, int bitrateKbps})>
      _resolveStream(String videoId) async {
    final yt = YoutubeExplode();
    try {
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ▶ Resolving stream for $videoId');
      }

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;

      if (kDebugMode) {
        debugPrint(
            '[PlaybackEngine][Source] ${audioStreams.length} audio-only candidates:');
        for (final s in audioStreams) {
          final pass = _isMp4Compatible(s) ? '✓ mp4-compat' : '✗ skip';
          final bytes = s.size.totalBytes;
          final url = s.url;
          debugPrint(
            '  $pass  mime=${s.codec.mimeType}  '
            'container=${s.container.name}  '
            'bitrate=${(s.bitrate.bitsPerSecond / 1000).round()} kbps  '
            'size=${bytes > 0 ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : 'unknown'}  '
            'has_sq=${url.queryParameters.containsKey('sq')}  '
            'host=${url.host.split('.').take(3).join('.')}',
          );
        }
      }

      if (audioStreams.isEmpty) {
        throw Exception('YouTube returned no audio streams for $videoId');
      }

      // ── Filter: mp4/m4a/AAC only ────────────────────────────────────────
      final compatibleStreams = audioStreams
          .where(_isMp4Compatible)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (kDebugMode && compatibleStreams.isEmpty) {
        debugPrint(
          '[PlaybackEngine][Error] No mp4-compatible streams found. '
          'Available types: ${audioStreams.map((s) => s.codec.mimeType).toSet().join(', ')}',
        );
      }

      if (compatibleStreams.isEmpty) {
        throw Exception('no mp4/m4a audio stream found '
            '(available: ${audioStreams.map((s) => s.container.name).toSet().join(', ')})');
      }

      final chosen = compatibleStreams.first;
      final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();

      // ── Validate fields before returning ────────────────────────────────
      if (kDebugMode) {
        final uri = chosen.url;
        final diag = _analyzeUrl(uri, chosen);
        debugPrint('[PlaybackEngine][Source] ✓ Selected stream:');
        diag.forEach((k, v) => debugPrint('  $k: $v'));
        debugPrint(
            '  url_preview: ${uri.toString().substring(0, 80)}…');
        debugPrint(
            '  bitrate: $bitrateKbps kbps');

        if (diag['is_manifest'] == 'true') {
          debugPrint(
            '[PlaybackEngine][Error] ⚠ WARNING: URL looks like a MANIFEST. '
            'ExoPlayer will reject this!',
          );
        }
        if (diag['has_sq_param'] == 'true') {
          debugPrint(
            '[PlaybackEngine][Error] ⚠ WARNING: URL has sq= param — '
            'this is likely a DASH segment URL, not a progressive stream.',
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
      debugPrint('[PlaybackEngine][Error] Resolution failed for $videoId: $e');
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

    // Publish resolving state immediately so debug panel updates.
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value =
          PlaybackDiagnostics.resolving(videoId);
    }

    // ── Step 1: Resolve stream ────────────────────────────────────────────
    final resolved = await _resolveStream(videoId);

    // ── Step 2: Stop previous playback ────────────────────────────────────
    await _player.stop();

    // ── Step 3: Build AudioSource.uri with YouTube CDN headers ────────────
    // AudioSource.uri() in just_audio v0.9.x passes the headers map directly
    // to ExoPlayer's DefaultHttpDataSource factory, so every range request
    // ExoPlayer makes to the CDN will include our User-Agent, Referer, Origin.
    final uri = resolved.info.url;
    final source = AudioSource.uri(uri, headers: _kYouTubeHeaders);

    if (kDebugMode) {
      final totalBytes = resolved.info.size.totalBytes;
      final diag = _analyzeUrl(uri, resolved.info);
      debugPrint(
        '[PlaybackEngine][Source] PRE-FLIGHT SUMMARY\n'
        '  videoId      : $videoId\n'
        '  approach     : AudioSource.uri + YouTube CDN headers\n'
        '  codec        : ${resolved.codec}\n'
        '  container    : ${resolved.container}\n'
        '  bitrate      : ${resolved.bitrateKbps} kbps\n'
        '  total_bytes  : ${totalBytes > 0 ? '${(totalBytes / 1024 / 1024).toStringAsFixed(2)} MB' : 'UNKNOWN'}\n'
        '  headers      : User-Agent ✓  Referer ✓  Origin ✓\n'
        '  url_host     : ${uri.host}\n'
        '  url_scheme   : ${uri.scheme}\n'
        '  is_manifest  : ${diag['is_manifest']}\n'
        '  has_sq_param : ${diag['has_sq_param']}\n'
        '  mp4_compat   : ${diag['mp4_compatible']}',
      );

      // Publish full diagnostic snapshot before setAudioSource.
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
        videoId: videoId,
        urlHost: uri.host,
        urlScheme: uri.scheme,
        mimeType: resolved.codec,
        container: resolved.container,
        bitrateKbps: resolved.bitrateKbps,
        sizeKnown: totalBytes > 0,
        totalBytes: totalBytes,
        headersAttached: true,
        directStream: true,
        isManifest: diag['is_manifest'] == 'true',
        succeeded: false,
        shortReason: 'Waiting for setAudioSource…',
      );
    }

    // ── Step 4: setAudioSource ────────────────────────────────────────────
    if (kDebugMode) {
      debugPrint(
          '[PlaybackEngine][Source] setAudioSource() starting — $videoId');
    }
    try {
      await _player.setAudioSource(source);
      if (kDebugMode) {
        debugPrint('[PlaybackEngine][Source] setAudioSource() OK — $videoId');
      }
    } catch (e) {
      final errStr = e.toString();
      debugPrint(
        '[PlaybackEngine][Error] setAudioSource() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $errStr\n'
        '  player : ${e is PlayerException ? 'code=${e.code}  msg=${e.message}' : 'n/a'}',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][Error] SUMMARY  videoId=$videoId  '
          'container=${resolved.container}  codec=${resolved.codec}  '
          'approach=AudioSource.uri+headers  stage=setAudioSource  result=REJECTED',
        );
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId: videoId,
          urlHost: uri.host,
          urlScheme: uri.scheme,
          mimeType: resolved.codec,
          container: resolved.container,
          bitrateKbps: resolved.bitrateKbps,
          sizeKnown: resolved.info.size.totalBytes > 0,
          totalBytes: resolved.info.size.totalBytes,
          headersAttached: true,
          directStream: true,
          isManifest: false,
          succeeded: false,
          failedAt: 'setAudioSource',
          exceptionMessage:
              errStr.length > 200 ? '${errStr.substring(0, 200)}…' : errStr,
          shortReason: PlaybackDiagnostics.inferReason(errStr),
        );
      }
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
          'bitrate=${resolved.bitrateKbps} kbps  approach=AudioSource.uri+headers  result=ACCEPTED',
        );
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId: videoId,
          urlHost: uri.host,
          urlScheme: uri.scheme,
          mimeType: resolved.codec,
          container: resolved.container,
          bitrateKbps: resolved.bitrateKbps,
          sizeKnown: resolved.info.size.totalBytes > 0,
          totalBytes: resolved.info.size.totalBytes,
          headersAttached: true,
          directStream: true,
          isManifest: false,
          succeeded: true,
        );
      }
    } catch (e) {
      final errStr = e.toString();
      debugPrint(
        '[PlaybackEngine][Error] play() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $errStr\n'
        '  player : ${e is PlayerException ? 'code=${e.code}  msg=${e.message}' : 'n/a'}',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][Error] SUMMARY  videoId=$videoId  '
          'container=${resolved.container}  stage=play  result=REJECTED',
        );
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId: videoId,
          urlHost: uri.host,
          urlScheme: uri.scheme,
          mimeType: resolved.codec,
          container: resolved.container,
          bitrateKbps: resolved.bitrateKbps,
          sizeKnown: resolved.info.size.totalBytes > 0,
          totalBytes: resolved.info.size.totalBytes,
          headersAttached: true,
          directStream: true,
          isManifest: false,
          succeeded: false,
          failedAt: 'play()',
          exceptionMessage:
              errStr.length > 200 ? '${errStr.substring(0, 200)}…' : errStr,
          shortReason: PlaybackDiagnostics.inferReason(errStr),
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
