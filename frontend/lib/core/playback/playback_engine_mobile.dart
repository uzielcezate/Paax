import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'playback_engine.dart';

/// Typed exception thrown when on-device stream resolution or player setup fails.
/// [message] is already a safe, user-friendly string — never exposes raw errors.
class _PlaybackResolveException implements Exception {
  final String message;
  const _PlaybackResolveException(this.message);
  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// HTTP headers sent with every CDN audio request.
//
// WHY: YouTube CDN streams require a valid browser-like User-Agent and a
// recognized Referer/Origin to serve the audio bytes. Without them the CDN
// responds with 403 / connection-reset.
// ---------------------------------------------------------------------------
const _kYouTubeHeaders = {
  'User-Agent':
      'com.google.android.youtube/17.36.4 (Linux; U; Android 12) gzip',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

// ---------------------------------------------------------------------------
// YtStreamAudioSource
// ---------------------------------------------------------------------------
// WHY WE NEED THIS:
//
// youtube_explode_dart stream URLs are signed DASH-mode CDN URLs. When handed
// directly to AudioSource.uri(), ExoPlayer (Android) tries to open them as a
// seekable progressive HTTP stream. The CDN serves the bytes in DASH-segment
// mode and does NOT respond to ExoPlayer's byte-range negotiation in the way
// ExoPlayer expects. This surfaces as:
//   "(0) Source error" on Android ExoPlayer
//   "Connection aborted" on iOS AVPlayer
//
// This affects all tracks — it is a transport-level issue, not a codec issue.
//
// FIX: Implement StreamAudioSource ourselves. just_audio calls our request()
// method with a [start, end] byte range whenever it needs data (initial load,
// seeks, buffer refills). We satisfy each request by making a standard HTTP
// GET with a Range header against the YouTube CDN URL, using our own
// http.Client — which sends the correct User-Agent + Referer headers that the
// CDN accepts. The response stream is then fed directly to just_audio.
//
// This completely sidesteps ExoPlayer's HTTP stack for CDN access while still
// letting ExoPlayer handle all decoding, buffering, and state management.
// ---------------------------------------------------------------------------
class _YtStreamAudioSource extends StreamAudioSource {
  final AudioOnlyStreamInfo _info;

  // One http.Client per source — reused across Range requests for the same
  // track to benefit from keep-alive connections. Closed via close() when
  // the track is replaced or the engine is disposed.
  final _client = http.Client();

  _YtStreamAudioSource(this._info);

  void close() {
    try {
      _client.close();
    } catch (_) {}
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final headers = Map<String, String>.from(_kYouTubeHeaders);

    // Build Range header when just_audio requests a specific byte slice
    // (initial buffering, seeks, preloading). HTTP Range is inclusive on
    // both ends; just_audio's [end] is exclusive, so subtract 1.
    if (start != null) {
      final last = end != null ? '${end - 1}' : '';
      headers['Range'] = 'bytes=$start-$last';
    }

    if (kDebugMode) {
      debugPrint(
        '[YtStreamAudioSource] request '
        'range=${start ?? 0}-${end ?? "end"} '
        'url=${_info.url.toString().substring(0, 60)}…',
      );
    }

    final req = http.Request('GET', _info.url)..headers.addAll(headers);
    final res = await _client.send(req);

    final totalBytes = _info.size.totalBytes;
    // res.contentLength is the size of this range slice, not the total.
    final rangeLength = res.contentLength ?? (totalBytes - (start ?? 0));

    if (kDebugMode) {
      debugPrint(
        '[YtStreamAudioSource] CDN responded '
        'status=${res.statusCode} '
        'rangeLen=$rangeLength '
        'total=$totalBytes',
      );
    }

    return StreamAudioResponse(
      sourceLength: totalBytes,
      contentLength: rangeLength,
      offset: start ?? 0,
      stream: res.stream,
      contentType: _info.codec.mimeType,
    );
  }
}

/// Native-platform playback engine shared by **Android and iOS**.
///
/// Selected by [playback_factory.dart] when `dart.library.io` is available,
/// which is true on both Android and iOS (false only on web).
///
/// Uses:
/// - `just_audio` for audio playback (supports Android/iOS/macOS natively)
/// - `audio_session` for AVAudioSession management on iOS and
///   AudioFocus management on Android
class PlaybackEngineImpl implements PlaybackEngine {
  final _player = AudioPlayer();

  // Broadcast controllers to match interface contract
  final _completionController = StreamController<void>.broadcast();
  bool _isDisposed = false;

  // Subscriptions managed during lifecycle
  final _subscriptions = <StreamSubscription>[];

  // Current stream source — kept so we can close it when loading a new track.
  _YtStreamAudioSource? _currentSource;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  // Only emit when the player has determined a real (positive) duration.
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

    // iOS interruption handling (phone calls, Siri, alarms)
    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (_isDisposed) return;
        if (event.begin) {
          _player.pause();
        } else {
          if (event.type == AudioInterruptionType.pause ||
              event.type == AudioInterruptionType.duck) {
            _player.play();
          }
        }
      }),
    );

    // Becoming noisy: headphone unplug / Bluetooth disconnect
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        if (_isDisposed) return;
        _player.pause();
      }),
    );

    // Track completion
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

  // ── Playable container whitelist ─────────────────────────────────────────
  // Only mp4/m4a/AAC containers. webm/Opus excluded — even though ExoPlayer
  // supports Opus in theory, the CDN delivery mode causes source errors.
  static bool _isMp4Compatible(AudioOnlyStreamInfo s) {
    final mime = s.codec.mimeType.toLowerCase();
    final container = s.container.name.toLowerCase();
    return mime.contains('mp4') ||
        mime.contains('m4a') ||
        mime.contains('aac') ||
        container == 'mp4';
  }

  /// Resolves a YouTube [videoId] to a compatible [AudioOnlyStreamInfo].
  ///
  /// Only mp4/m4a/AAC streams pass the whitelist filter — see [_isMp4Compatible].
  /// The highest-bitrate compatible stream is selected.
  /// Throws [_PlaybackResolveException] on any failure.
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
          '[PlaybackEngine] Found ${audioStreams.length} audio-only streams for $videoId',
        );
        for (final s in audioStreams) {
          final compat = _isMp4Compatible(s) ? '✓' : '✗ skip';
          debugPrint(
            '  $compat  ${s.codec.mimeType} | ${s.container.name} | '
            '${(s.bitrate.bitsPerSecond / 1000).round()} kbps | '
            '${s.size.totalBytes} bytes',
          );
        }
      }

      if (audioStreams.isEmpty) {
        throw Exception('no audio streams found');
      }

      final compatibleStreams = audioStreams
          .where(_isMp4Compatible)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (compatibleStreams.isEmpty) {
        debugPrint(
          '[PlaybackEngine] ✗ No mp4-compatible stream for $videoId. '
          'Available: ${audioStreams.map((s) => s.codec.mimeType).join(', ')}',
        );
        throw Exception('no compatible audio format available');
      }

      final chosen = compatibleStreams.first;
      final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();

      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine] ✓ Chose stream for $videoId\n'
          '  codec    : ${chosen.codec.mimeType}\n'
          '  container: ${chosen.container.name}\n'
          '  bitrate  : $bitrateKbps kbps\n'
          '  size     : ${chosen.size.totalBytes} bytes\n'
          '  url      : ${chosen.url.toString().substring(0, 60)}…',
        );
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
      // Manifest fetch is done — close the yt instance.
      // The AudioOnlyStreamInfo already holds the URL; we no longer need yt.
      yt.close();
    }
  }

  // -------------------------------------------------------------------------
  // Load & play
  // -------------------------------------------------------------------------

  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;

    // ── Step 1: Resolve — get AudioOnlyStreamInfo (not a raw URL) ───────────
    final resolved = await _resolveStream(videoId);

    // ── Step 2: Stop current playback & release previous source ─────────────
    await _player.stop();
    _currentSource?.close();
    _currentSource = null;

    // ── Step 3: Create the byte-pipe source ─────────────────────────────────
    // _YtStreamAudioSource satisfies just_audio's byte-range requests using
    // our own http.Client with YouTube CDN headers — bypasses ExoPlayer HTTP.
    final source = _YtStreamAudioSource(resolved.info);
    _currentSource = source;

    if (kDebugMode) {
      debugPrint(
        '[PlaybackEngine] setAudioSource (StreamAudioSource) → $videoId\n'
        '  type     : YtStreamAudioSource (byte-pipe, NOT AudioSource.uri)\n'
        '  codec    : ${resolved.codec}\n'
        '  container: ${resolved.container}\n'
        '  bitrate  : ${resolved.bitrateKbps} kbps\n'
        '  size     : ${resolved.info.size.totalBytes} bytes',
      );
    }

    // ── Step 4: Load into player ─────────────────────────────────────────────
    try {
      await _player.setAudioSource(source);
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ✓ setAudioSource OK for $videoId');
      }
    } catch (e) {
      _currentSource?.close();
      _currentSource = null;
      debugPrint(
        '[PlaybackEngine] ✗ setAudioSource FAILED for $videoId: $e '
        '(type: ${e.runtimeType})',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][DEBUG SUMMARY] videoId=$videoId '
          'ext=${resolved.container} codec=${resolved.codec} source=REJECTED at setAudioSource',
        );
      }
      throw _PlaybackResolveException(
        'Playback source rejected by player: ${_friendlyPlayerError(e)}',
      );
    }

    // ── Step 5: Start playback ────────────────────────────────────────────────
    if (kDebugMode) {
      debugPrint('[PlaybackEngine] play() → $videoId …');
    }
    try {
      await _player.play();
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ✓ play() OK for $videoId');
        debugPrint(
          '[PlaybackEngine][DEBUG SUMMARY] videoId=$videoId | '
          'ext=${resolved.container} | codec=${resolved.codec} | '
          'bitrate=${resolved.bitrateKbps} kbps | source=ACCEPTED',
        );
      }
    } catch (e) {
      debugPrint(
        '[PlaybackEngine] ✗ play() FAILED for $videoId: '
        '$e (type: ${e.runtimeType})',
      );
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][DEBUG SUMMARY] videoId=$videoId '
          'ext=${resolved.container} source=REJECTED at play()',
        );
      }
      throw _PlaybackResolveException(
        'Playback failed to start: ${_friendlyPlayerError(e)}',
      );
    }
  }

  /// Converts a raw just_audio / platform exception into a short friendly string.
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

  /// just_audio is headless on Android and iOS — no widget needed.
  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}
