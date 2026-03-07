import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
// HTTP headers sent with every AudioSource.uri() request.
//
// WHY: YouTube CDN streams require a valid browser-like User-Agent and a
// recognized Referer/Origin to serve the audio bytes. Without them the CDN
// responds with 403 / connection-reset, which just_audio surfaces as:
//   Android ExoPlayer  → "Source error (0)"
//   iOS AVPlayer       → "Connection aborted"
//
// These headers mimic the official Android YouTube client.  They are the
// same headers that youtube_explode_dart uses internally when it fetches
// stream manifests, so the CDN treats the audio request as coming from the
// same session that obtained the manifest URL.
// ---------------------------------------------------------------------------
const _kYouTubeHeaders = {
  'User-Agent':
      'com.google.android.youtube/17.36.4 (Linux; U; Android 12) gzip',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

/// Native-platform playback engine shared by **Android and iOS**.
///
/// Selected by [playback_factory.dart] when `dart.library.io` is available,
/// which is true on both Android and iOS (false only on web).
///
/// Uses:
/// - `just_audio` for audio playback (supports Android/iOS/macOS natively)
/// - `audio_session` for AVAudioSession management on iOS and
///   AudioFocus management on Android — both called through the
///   same platform-agnostic `AudioSessionConfiguration.music()` API.
///
/// iOS-specific behaviour handled here:
/// - `UIBackgroundModes: audio` must be set in `ios/Runner/Info.plist` ✓
/// - Interruptions (phone calls, Siri, other apps) pause audio and
///   re-activate the audio session automatically via the listener below.
/// - Becoming-noisy events (headphone unplug) pause audio.
class PlaybackEngineImpl implements PlaybackEngine {
  final _player = AudioPlayer();

  // Broadcast controllers to match interface contract
  final _completionController = StreamController<void>.broadcast();
  bool _isDisposed = false;

  // Subscriptions managed during lifecycle
  final _subscriptions = <StreamSubscription>[];

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  // Only emit when the player has determined a real (positive) duration.
  // Callers that previously relied on the null→zero mapping should treat
  // Duration.zero (the controller's initial/reset value) as "unknown".
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
    // -----------------------------------------------------------------
    // Audio Session — works identically on Android and iOS:
    //   Android: requests AudioFocus, sets content type to MUSIC
    //   iOS:     configures AVAudioSession category to .playback
    //            (required for background audio and lock-screen controls)
    // -----------------------------------------------------------------
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // --- iOS interruption handling (phone calls, Siri, alarms) ---
    // On Android this stream emits nothing for interruptions — safe to listen on both platforms.
    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (_isDisposed) return;
        if (event.begin) {
          // Interrupted: pause so iOS doesn't kill us
          _player.pause();
        } else {
          // Interruption ended — resume only if we should
          if (event.type == AudioInterruptionType.pause ||
              event.type == AudioInterruptionType.duck) {
            _player.play();
          }
        }
      }),
    );

    // --- Becoming noisy: headphone unplug / Bluetooth disconnect ---
    // Standard behaviour on both platforms: pause when audio routing changes.
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        if (_isDisposed) return;
        _player.pause();
      }),
    );

    // --- Track completion ---
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
  // just_audio on Android (ExoPlayer) and iOS (AVPlayer) reliably handles
  // direct mp4/m4a AAC streams. webm/Opus containers are NOT reliably
  // supported via HttpAudioSource on either platform and cause:
  //   Android → PlayerException (0) Source error
  //   iOS     → Connection aborted / AVPlayer item failed
  //
  // We therefore apply a strict whitelist: only streams whose MIME type or
  // container name indicates an mp4/m4a/aac container are eligible.
  // webm, opus, and any unrecognised container are explicitly excluded.
  // If no whitelisted stream exists for a video, we fail fast with a clear
  // user-facing message rather than forwarding an incompatible source.
  static bool _isMp4Compatible(AudioOnlyStreamInfo s) {
    final mime = s.codec.mimeType.toLowerCase();
    final container = s.container.name.toLowerCase();
    // Accept: audio/mp4 · audio/m4a · audio/aac · container "mp4"
    // Reject: audio/webm · audio/opus · container "webm" · anything else
    return mime.contains('mp4') ||
        mime.contains('m4a') ||
        mime.contains('aac') ||
        container == 'mp4';
  }

  /// Resolves a YouTube [videoId] to a playable audio stream URL **on-device**
  /// using [youtube_explode_dart] — no backend call is made.
  ///
  /// Only mp4/m4a/AAC streams are considered (see [_isMp4Compatible]).
  /// webm/Opus streams are **never** selected — they are incompatible with
  /// just_audio's HttpAudioSource on Android ExoPlayer and iOS AVPlayer.
  ///
  /// Within the compatible set the highest-bitrate stream is chosen.
  /// Throws [_PlaybackResolveException] with a friendly message if:
  ///   - The manifest fetch fails
  ///   - No audio streams exist at all
  ///   - No *compatible* audio stream is found (all are webm/opus)
  Future<({String url, String codec, String container, int bitrateKbps})>
      _resolveStream(String videoId) async {
    final yt = YoutubeExplode();
    try {
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ▶ Resolving on-device stream for $videoId');
      }

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;

      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine] Found ${audioStreams.length} audio-only streams for $videoId',
        );
        for (final s in audioStreams) {
          final compat = _isMp4Compatible(s) ? '✓ mp4-compat' : '✗ skip';
          debugPrint(
            '  $compat  ${s.codec.mimeType} | ${s.container.name} | '
            '${(s.bitrate.bitsPerSecond / 1000).round()} kbps',
          );
        }
      }

      if (audioStreams.isEmpty) {
        debugPrint('[PlaybackEngine] ✗ No audio-only streams for $videoId');
        throw Exception('no audio streams');
      }

      // ── Whitelist: only mp4/m4a/AAC containers ────────────────────────
      // webm/Opus is intentionally excluded — see _isMp4Compatible().
      final compatibleStreams = audioStreams
          .where(_isMp4Compatible)
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      if (compatibleStreams.isEmpty) {
        // All available streams are webm/opus — unsupported by just_audio.
        // Log the formats found so developers know what YouTube returned.
        debugPrint(
          '[PlaybackEngine] ✗ No mp4-compatible stream for $videoId. '
          'Available: ${audioStreams.map((s) => s.codec.mimeType).join(', ')}',
        );
        throw Exception('no compatible audio format');
      }

      final chosen = compatibleStreams.first;

      final resolvedUrl = chosen.url.toString();
      final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();

      if (kDebugMode) {
        final shortUrl = resolvedUrl.length > 80
            ? '${resolvedUrl.substring(0, 80)}…'
            : resolvedUrl;
        debugPrint(
          '[PlaybackEngine] ✓ Chose stream for $videoId\n'
          '  codec    : ${chosen.codec.mimeType}\n'
          '  container: ${chosen.container.name}\n'
          '  bitrate  : $bitrateKbps kbps\n'
          '  scheme   : ${chosen.url.scheme}\n'
          '  url      : $shortUrl',
        );
      }

      return (
        url: resolvedUrl,
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

    // ── Step 1: Resolve stream URL ─────────────────────────────────────────
    final stream = await _resolveStream(videoId);

    // ── Step 2: Stop any existing playback ─────────────────────────────────
    await _player.stop();

    // ── Step 3: Set audio source with CDN-required headers ─────────────────
    // AudioSource.uri passes these as HTTP headers:
    //   • Android (ExoPlayer / OkHttp): via DefaultHttpDataSource
    //   • iOS (AVPlayer):               via AVURLAsset options dict
    // Without the User-Agent + Referer the YouTube CDN responds 403/reset.
    final source = AudioSource.uri(
      Uri.parse(stream.url),
      headers: _kYouTubeHeaders,
    );

    if (kDebugMode) {
      debugPrint('[PlaybackEngine] setAudioSource → $videoId …');
    }

    try {
      await _player.setAudioSource(source);
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ✓ setAudioSource OK for $videoId');
      }
    } catch (e) {
      debugPrint('[PlaybackEngine] ✗ setAudioSource FAILED for $videoId: $e '
          '(type: ${e.runtimeType})');
      throw _PlaybackResolveException(
        'Playback source rejected by player ($videoId): ${_friendlyPlayerError(e)}',
      );
    }

    // ── Step 4: Start playback ─────────────────────────────────────────────
    if (kDebugMode) {
      debugPrint('[PlaybackEngine] play() → $videoId …');
    }

    try {
      await _player.play();
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ✓ play() OK for $videoId');
        // Developer-only debug summary
        debugPrint(
          '[PlaybackEngine][DEBUG SUMMARY] '
          'videoId=$videoId | '
          'ext=${stream.container} | '
          'codec=${stream.codec} | '
          'bitrate=${stream.bitrateKbps} kbps | '
          'protocol=${Uri.parse(stream.url).scheme} | '
          'source=ACCEPTED',
        );
      }
    } catch (e) {
      debugPrint(
          '[PlaybackEngine] ✗ play() FAILED for $videoId: $e (type: ${e.runtimeType})');
      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine][DEBUG SUMMARY] '
          'videoId=$videoId | '
          'ext=${stream.container} | '
          'codec=${stream.codec} | '
          'source=REJECTED at play()',
        );
      }
      throw _PlaybackResolveException(
        'Playback failed to start: ${_friendlyPlayerError(e)}',
      );
    }
  }

  /// Converts a raw just_audio / platform exception into a short, friendly string.
  String _friendlyPlayerError(Object e) {
    if (e is PlayerException) {
      return '(${e.code}) ${e.message ?? 'Unknown player error'}';
    }
    final s = e.toString();
    if (s.length > 120) return '${s.substring(0, 120)}…';
    return s;
  }

  // -------------------------------------------------------------------------
  // Playback controls
  // -------------------------------------------------------------------------

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

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

  /// just_audio is headless on Android and iOS — no widget needed.
  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}
