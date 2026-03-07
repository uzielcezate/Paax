import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'playback_engine.dart';

/// Typed exception thrown when on-device stream resolution fails.
/// [message] is already a safe, user-friendly string — never exposes raw errors.
class _PlaybackResolveException implements Exception {
  final String message;
  const _PlaybackResolveException(this.message);
  @override
  String toString() => message;
}

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

  @override
  Stream<Duration> get durationStream =>
      _player.durationStream.map((d) => d ?? Duration.zero);

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

  /// Resolves a YouTube [videoId] to a playable audio stream URL **on-device**
  /// using [youtube_explode_dart] — no backend call is made.
  ///
  /// Stream selection priority (best Android ExoPlayer / iOS AVPlayer compat):
  ///   1. Audio-only m4a/AAC  — most compatible, lowest bot-detection risk
  ///   2. Audio-only webm/Opus — widely available fallback
  ///   3. Any audio-only stream — last resort before failing
  ///
  /// Within each tier the highest-bitrate stream is chosen.
  /// Throws [_PlaybackResolveException] with a safe user-facing message on any failure.
  Future<String> _resolveStreamUrl(String videoId) async {
    final yt = YoutubeExplode();
    try {
      debugPrint('[PlaybackEngine] Resolving stream on-device for $videoId');

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final audioStreams = manifest.audioOnly;

      if (audioStreams.isEmpty) {
        debugPrint('[PlaybackEngine] No audio-only streams for $videoId');
        throw Exception('no audio streams');
      }

      // ── Tier 1: m4a / AAC ──────────────────────────────────────────────
      final m4aStreams = audioStreams
          .where((s) => s.codec.mimeType.contains('mp4') ||
                        s.codec.mimeType.contains('m4a'))
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      // ── Tier 2: webm / Opus ────────────────────────────────────────────
      final webmStreams = audioStreams
          .where((s) => s.codec.mimeType.contains('webm') ||
                        s.codec.mimeType.contains('opus'))
          .toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      // ── Tier 3: any audio-only ─────────────────────────────────────────
      final allSorted = audioStreams.toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

      final chosen = m4aStreams.isNotEmpty
          ? m4aStreams.first
          : webmStreams.isNotEmpty
              ? webmStreams.first
              : allSorted.first;

      if (kDebugMode) {
        debugPrint(
          '[PlaybackEngine] Resolved $videoId → '
          'codec=${chosen.codec.mimeType} '
          'bitrate=${chosen.bitrate} '
          'container=${chosen.container.name}',
        );
      }

      return chosen.url.toString();
    } catch (e) {
      debugPrint('[PlaybackEngine] Resolution failed for $videoId: $e');
      throw const _PlaybackResolveException('This track is temporarily unavailable.');
    } finally {
      yt.close();
    }
  }


  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;

    final streamUrl = await _resolveStreamUrl(videoId);

    // Stop any existing playback before loading new track
    await _player.stop();
    await _player.setAudioSource(AudioSource.uri(Uri.parse(streamUrl)));
    await _player.play();
  }

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
