import 'dart:async';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:beaty/core/config/api_config.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'playback_engine.dart';

/// In-memory cache entry: stream URL + expiry
class _CacheEntry {
  final String url;
  final DateTime expiresAt;
  _CacheEntry(this.url, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
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

  // 10-minute TTL cache: videoId -> stream URL
  final _urlCache = <String, _CacheEntry>{};

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

  /// Resolves a YouTube videoId to a direct streaming URL via the backend.
  /// Results are cached for 10 minutes to avoid redundant fetches.
  Future<String> _resolveStreamUrl(String videoId) async {
    final cached = _urlCache[videoId];
    if (cached != null && !cached.isExpired) {
      return cached.url;
    }

    final uri = Uri.parse('${ApiConfig.baseUrl}/stream/$videoId');
    // yt-dlp cold-start can take ~10-15 s; 30 s is safe.
    final response = await http.get(uri).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Stream resolve failed [${response.statusCode}]: ${response.body}');
    }

    final body = json.decode(response.body);
    final url = body['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('Backend returned empty stream URL for $videoId');
    }

    _urlCache[videoId] = _CacheEntry(url, DateTime.now().add(const Duration(minutes: 10)));
    return url;
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
