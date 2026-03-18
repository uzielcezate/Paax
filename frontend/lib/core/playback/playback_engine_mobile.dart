import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'media_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — Media Engine V1
// ---------------------------------------------------------------------------
//
// Architecture:
//   load(videoId)
//     → MediaResolver.resolve()            ← calls Worker JSON API (or cache)
//     → AudioSource.uri(directCdnUrl,
//            headers: {Referer, Origin})   ← ExoPlayer fetches bytes directly
//     → _player.play()                     ← [MEDIA PLAY]
//
// On PlayerException (e.g. expired CDN URL):
//   → resolver.invalidate(videoId)         ← clears StreamCache
//   → resolver.resolve(videoId)            ← fresh Worker call → new CDN URL
//   → AudioSource.uri(newUrl) + play()     ← retry once
// ────────────────────────────────────────────────────────────────────────────

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({MediaResolver? resolver})
      : _resolver = resolver ?? MediaResolver();

  final MediaResolver _resolver;
  final _player       = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

  // Load-lock: generation counter. Bumped at every load() call.
  // Any in-flight load() that finds _loadId changed after an await bails out.
  int _loadId = 0;

  // ── PlaybackEngine streams ─────────────────────────────────────────────────
  @override Stream<Duration> get positionStream  => _player.positionStream;
  @override Stream<Duration> get durationStream  => _player.durationStream
      .where((d) => d != null && d > Duration.zero)
      .map((d) => d!);
  @override Stream<bool>     get playingStream   => _player.playingStream;
  @override Stream<void>     get completionStream => _completionController.stream;

  // ── initialize ─────────────────────────────────────────────────────────────
  @override
  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(session.interruptionEventStream.listen((event) {
      if (_isDisposed) return;
      if (event.begin) {
        _player.pause();
      } else if (event.type == AudioInterruptionType.pause ||
                 event.type == AudioInterruptionType.duck) {
        _player.play();
      }
    }));

    _subscriptions.add(session.becomingNoisyEventStream.listen((_) {
      if (_isDisposed) return;
      _player.pause();
    }));

    _subscriptions.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      debugPrint(
        '[PLAYER STATE] playing=${state.playing}  '
        'processingState=${state.processingState.name}',
      );
      if (state.processingState == ProcessingState.completed) {
        _completionController.add(null);
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              stage:          PlaybackStage.completed,
              processingState: 'completed',
              isPlaying:      false,
              stageEnteredAt: DateTime.now(),
            );
          }
        }
      } else if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        if (prev != null) {
          PlaybackDiagnosticsNotifier.value = prev.copyWith(
            processingState: state.processingState.name,
            isPlaying:       state.playing,
          );
        }
      }
    }));

    _subscriptions.add(_player.positionStream.listen((pos) {
      if (_isDisposed) return;
      if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        if (prev != null && prev.stage == PlaybackStage.playing) {
          PlaybackDiagnosticsNotifier.value = prev.copyWith(
            position: pos,
            buffered: _player.bufferedPosition,
            duration: _player.duration ?? Duration.zero,
            isPlaying: _player.playing,
          );
        }
      }
    }));
  }

  // ── load ───────────────────────────────────────────────────────────────────
  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;
    final myId = ++_loadId;

    // Step 1: Stop previous playback immediately
    debugPrint('[PLAYER STOP] >>> videoId=$videoId');
    await _player.stop();
    if (_loadId != myId) return;

    // Publish resolving state to debug panel
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value =
          PlaybackDiagnostics.atStage(PlaybackStage.resolving, videoId: videoId);
    }

    // Step 2: Resolve — check cache then call Worker for direct CDN URL
    debugPrint('[MEDIA RESOLVE START] $videoId');
    ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId);
    } catch (e) {
      debugPrint('[MEDIA ERROR] $videoId — resolve threw: $e');
      throw _MediaEngineException(e.toString());
    }
    if (_loadId != myId) {
      debugPrint('[MEDIA RESOLVE RESULT DIRECT] Superseded — bailing ($videoId)');
      return;
    }
    debugPrint('[MEDIA RESOLVE RESULT DIRECT] $videoId → ${resolved.sourceType} url=${resolved.url.substring(0, resolved.url.length.clamp(0, 70))}…');
    debugPrint('[MEDIA FORMAT PICK] $videoId → ${resolved.sourceType} mime=${resolved.mimeType}');

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.resolved,
        videoId:    videoId,
        sourceType: resolved.sourceType,
        mimeType:   resolved.mimeType,
        expiresAt:  resolved.expiresAt,
        urlHost:    Uri.parse(resolved.url).host,
      );
    }

    // Step 3: Set source + play (with re-resolve on failure)
    await _loadAndPlay(videoId, resolved, myId, isRetry: false);
  }

  /// Inner helper: setAudioSource → seek → play.
  /// On PlayerException, re-resolves once via [MediaResolver] and retries.
  Future<void> _loadAndPlay(
    String videoId,
    ResolvedStream resolved,
    int myId, {
    required bool isRetry,
  }) async {
    // Direct CDN URL — googlevideo.com
    // YouTube headers increase CDN acceptance rate.
    final uri = Uri.parse(resolved.url);
    final source = AudioSource.uri(
      uri,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
        'Referer':  'https://www.youtube.com/',
        'Origin':   'https://www.youtube.com',
      },
    );

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.settingSource,
        videoId:    videoId,
        sourceType: resolved.sourceType,
        mimeType:   resolved.mimeType,
        expiresAt:  resolved.expiresAt,
        urlHost:    uri.host,
      );
    }

    debugPrint('[PLAYER SET SOURCE DIRECT] $videoId → ${uri.host}${uri.path.substring(0, uri.path.length.clamp(0, 40))}…');
    try {
      await _player.setAudioSource(source, preload: false);
      debugPrint('[PLAYER SET SOURCE] OK  state=${_player.processingState.name}  videoId=$videoId');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.sourceReady,
          videoId:        videoId,
          sourceType:     resolved.sourceType,
          mimeType:       resolved.mimeType,
          expiresAt:      resolved.expiresAt,
          urlHost:        uri.host,
          processingState: _player.processingState.name,
        );
      }
    } on PlayerException catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId PlayerException: code=${e.code} msg=${e.message}');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedPlayer,
          videoId:   videoId,
          sourceType: resolved.sourceType,
          mimeType:  resolved.mimeType,
          urlHost:   uri.host,
          lastError:  'setAudioSource failed: code=${e.code} msg=${e.message ?? 'unknown'}',
        );
      }
      if (!isRetry) {
        // Invalidate stale cache entry and retry with a fresh resolve
        await _resolver.invalidate(videoId);
        debugPrint('[MEDIA RESOLVE RESULT DIRECT] $videoId — re-resolving after setAudioSource failure');
        final fresh = await _resolver.resolve(videoId);
        if (_loadId == myId) return _loadAndPlay(videoId, fresh, myId, isRetry: true);
        return;
      }
      throw _MediaEngineException(
        'Playback source rejected (${e.code}): ${e.message ?? 'unknown'}',
      );
    } catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId: $e');
      await _resolver.invalidate(videoId);
      throw _MediaEngineException('Playback setup failed: $e');
    }

    if (_loadId != myId) return;

    debugPrint('[PLAYER PLAY DIRECT] $videoId — starting playback');
    try {
      await _player.seek(Duration.zero);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.buffering,
          videoId:        videoId,
          sourceType:     resolved.sourceType,
          mimeType:       resolved.mimeType,
          expiresAt:      resolved.expiresAt,
          urlHost:        uri.host,
          processingState: _player.processingState.name,
        );
      }
      await _player.play();
      debugPrint('[MEDIA PLAY] $videoId OK  playing=${_player.playing}  '
          'state=${_player.processingState.name}');

      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.playing,
          videoId:        videoId,
          sourceType:     resolved.sourceType,
          mimeType:       resolved.mimeType,
          expiresAt:      resolved.expiresAt,
          urlHost:        uri.host,
          processingState: _player.processingState.name,
          isPlaying:      _player.playing,
          position:       _player.position,
          duration:       _player.duration ?? Duration.zero,
        );
      }
    } catch (e) {
      debugPrint('[PLAYER PLAY ERROR] $videoId: $e');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedPlayer,
          videoId:   videoId,
          sourceType: resolved.sourceType,
          mimeType:  resolved.mimeType,
          urlHost:   uri.host,
          lastError:  'play() failed: $e',
        );
      }
      throw _MediaEngineException('Playback failed to start: $e');
    }
  }

  // ── controls ───────────────────────────────────────────────────────────────
  @override
  Future<void> play() async {
    debugPrint('[MEDIA PLAY] resume');
    await _player.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[PLAYER PAUSE]');
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[MEDIA SEEK] ${position.inSeconds}s');
    await _player.seek(position);
  }

  @override
  void prefetchNext(String videoId) {
    // Legacy call-site in PlaybackController; no-op here —
    // prefetching is now handled by PrefetchManager directly.
    // This stub preserves interface compatibility.
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) { sub.cancel(); }
    _subscriptions.clear();
    _player.dispose();
    _completionController.close();
  }

  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// Internal exception
// ---------------------------------------------------------------------------
class _MediaEngineException implements Exception {
  final String message;
  const _MediaEngineException(this.message);
  @override
  String toString() => message;
}
