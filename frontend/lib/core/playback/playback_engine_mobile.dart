import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:beaty/core/config/api_config.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'playback_engine.dart';

/// Typed exception thrown when the backend cannot resolve a playable stream URL.
/// The [message] is already a safe, user-friendly string — never contains raw
/// yt-dlp output, YouTube anti-bot text, or HTTP error codes.
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

  /// Friendly messages shown to the user for each backend error code.
  /// Never shows raw HTTP errors, yt-dlp text, or YouTube bot messages.
  static const _kErrorMessages = {
    'BOT_CHECK':      'This track is temporarily unavailable.',
    'GEO_BLOCKED':    'This track is not available in your region.',
    'UNAVAILABLE':    'This track is no longer available.',
    'RESOLVE_FAILED': 'Playback is not available right now.',
    'NETWORK_ERROR':  'Check your connection and try again.',
  };

  /// Resolves a YouTube videoId to a playable stream URL via the centralized
  /// backend endpoint `/playback/resolve`.
  ///
  /// The backend owns all caching (Redis + in-memory) and all retry logic.
  /// On failure, throws a [_PlaybackResolveException] with a safe user-facing
  /// message — the raw YouTube / yt-dlp error never reaches the client.
  Future<String> _resolveStreamUrl(String videoId) async {
    final uri = Uri.parse(
        '${ApiConfig.baseUrl}/playback/resolve?videoId=${Uri.encodeComponent(videoId)}');
    debugPrint('[PlaybackEngine] → /playback/resolve?videoId=$videoId');

    // 95 s: backend retries 3× with backoff (up to ~50 s) before responding.
    late final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 95));
    } on Exception catch (e) {
      debugPrint('[PlaybackEngine] Network error for $videoId: $e');
      throw _PlaybackResolveException(
          _kErrorMessages['NETWORK_ERROR']!);
    }

    // Always 200 — backend returns ok:false instead of 4xx/5xx for resolve errors.
    late final Map<String, dynamic> body;
    try {
      body = json.decode(response.body) as Map<String, dynamic>;
    } catch (_) {
      debugPrint('[PlaybackEngine] Malformed JSON from /playback/resolve for $videoId');
      throw _PlaybackResolveException(
          _kErrorMessages['RESOLVE_FAILED']!);
    }

    final ok = body['ok'] as bool? ?? false;
    if (!ok) {
      final code = (body['errorCode'] as String?) ?? 'RESOLVE_FAILED';
      final msg = _kErrorMessages[code] ?? _kErrorMessages['RESOLVE_FAILED']!;
      debugPrint('[PlaybackEngine] Resolve failed [$videoId]: code=$code');
      throw _PlaybackResolveException(msg);
    }

    final streamUrl = body['streamUrl'] as String?;
    if (streamUrl == null || streamUrl.isEmpty) {
      debugPrint('[PlaybackEngine] ok=true but empty streamUrl for $videoId');
      throw _PlaybackResolveException(_kErrorMessages['RESOLVE_FAILED']!);
    }

    final cached = body['cached'] as bool? ?? false;
    debugPrint('[PlaybackEngine] Resolved $videoId (cached=$cached)');
    return streamUrl;
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
