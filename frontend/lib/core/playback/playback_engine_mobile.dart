import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'media_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — truthful state machine
// ---------------------------------------------------------------------------
//
// load(videoId)
//   → MediaResolver.resolve()          → Worker JSON (or cache) → CDN URL
//   → setAudioSource(directCdnUrl)     → stage = settingSource / sourceReady / failedSetSource
//   → seek(0) + play()                 → stage = buffering
//   → playerStateStream confirms ready → stage = playing   ← ONLY REAL SIGNAL
//   → 3s stall guard                   → stage = failedBuffering / falsePlayingDetected
//
// "playing" is NEVER set by calling play().
// It is ONLY set when playerStateStream emits ProcessingState.ready
// AND either position > 0 OR buffered > 0 confirms actual bytes are moving.
// ---------------------------------------------------------------------------

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({MediaResolver? resolver})
      : _resolver = resolver ?? MediaResolver();

  final MediaResolver _resolver;
  final _player              = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

  int _loadId = 0;

  // ── PlaybackEngine streams ─────────────────────────────────────────────────
  @override Stream<Duration> get positionStream   => _player.positionStream;
  @override Stream<Duration> get durationStream   => _player.durationStream
      .where((d) => d != null && d > Duration.zero).map((d) => d!);
  @override Stream<bool>     get playingStream    => _player.playingStream;
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

    // ── Completion ────────────────────────────────────────────────────────────
    _subscriptions.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      debugPrint('[PLAYER STATE] playing=${state.playing} state=${state.processingState.name}');

      if (state.processingState == ProcessingState.completed) {
        _completionController.add(null);
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              stage:           PlaybackStage.completed,
              processingState: 'completed',
              isPlaying:       false,
              stageEnteredAt:  DateTime.now(),
            );
          }
        }
      } else if (kDebugMode) {
        // Always push live processingState + isPlaying changes
        final prev = PlaybackDiagnosticsNotifier.value;
        if (prev != null) {
          PlaybackDiagnosticsNotifier.value = prev.copyWith(
            processingState: state.processingState.name,
            isPlaying:       state.playing,
          );
        }
        // Check if this state update warrants upgrading buffering → playing
        _maybeUpgradePlaying(state.processingState, state.playing);
      }
    }));

    // ── Live position/buffered push (only during confirmed playback) ──────────
    _subscriptions.add(_player.positionStream.listen((pos) {
      if (_isDisposed) return;
      if (!kDebugMode) return;
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev == null) return;
      // Always push position/buffered regardless of stage so overlay is live
      PlaybackDiagnosticsNotifier.value = prev.copyWith(
        position:  pos,
        buffered:  _player.bufferedPosition,
        duration:  _player.duration ?? Duration.zero,
        isPlaying: _player.playing,
      );
    }));
  }

  // ── load ───────────────────────────────────────────────────────────────────
  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;
    final myId = ++_loadId;


    debugPrint('[PLAYER STOP] >>> $videoId');
    await _player.stop();
    if (_loadId != myId) return;

    final resolveStart = DateTime.now();

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(
        videoId,
        resolveStartedAt: resolveStart,
      );
    }

    // ── Step 1: Resolve ──────────────────────────────────────────────────────
    debugPrint('[MEDIA RESOLVE START] $videoId');
    ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId);
    } catch (e) {
      final elapsed = DateTime.now().difference(resolveStart);
      debugPrint('[MEDIA RESOLVE FAIL] $videoId +${elapsed.inMilliseconds}ms err=$e');
      final isTimeout = e.toString().toLowerCase().contains('timeout');
      final stage = isTimeout
          ? PlaybackStage.failedResolveTimeout
          : PlaybackStage.failedResolveHttp;
      final resolveEx = e is MediaResolveException ? e : null;
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          stage,
          videoId:           videoId,
          resolveStartedAt:  resolveStart,
          resolveFinishedAt: DateTime.now(),
          workerHttpStatus:  resolveEx?.httpStatus ?? 0,
          workerErrorBody:   resolveEx?.errorBody,
          lastError:         e.toString(),
        );
      }
      throw _MediaEngineException(e.toString());
    }

    final resolveEnd = DateTime.now();
    final resolveMs  = resolveEnd.difference(resolveStart).inMilliseconds;
    debugPrint('[MEDIA RESOLVE OK] $videoId +${resolveMs}ms '
        '→ ${resolved.sourceType} mime=${resolved.mimeType}');

    if (_loadId != myId) return;

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.resolved,
        videoId:           videoId,
        sourceType:        resolved.sourceType,
        mimeType:          resolved.mimeType,
        expiresAt:         resolved.expiresAt,
        urlHost:           Uri.parse(resolved.url).host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
      );
    }

    // ── Step 2: setAudioSource ────────────────────────────────────────────────
    await _loadAndPlay(videoId, resolved, myId, resolveStart, resolveEnd, isRetry: false);
  }

  Future<void> _loadAndPlay(
    String videoId,
    ResolvedStream resolved,
    int myId,
    DateTime resolveStart,
    DateTime resolveEnd, {
    required bool isRetry,
  }) async {
    final uri = Uri.parse(resolved.url);
    final source = AudioSource.uri(uri, headers: const {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
      'Referer': 'https://www.youtube.com/',
      'Origin':  'https://www.youtube.com',
    });

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.settingSource,
        videoId:           videoId,
        sourceType:        resolved.sourceType,
        mimeType:          resolved.mimeType,
        expiresAt:         resolved.expiresAt,
        urlHost:           uri.host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
        setSourceCalled:   true,
      );
    }

    debugPrint('[PLAYER SET SOURCE] $videoId → ${uri.host}');
    try {
      await _player.setAudioSource(source, preload: false);
      debugPrint('[PLAYER SET SOURCE OK] $videoId state=${_player.processingState.name}');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.sourceReady,
          videoId:            videoId,
          sourceType:         resolved.sourceType,
          mimeType:           resolved.mimeType,
          expiresAt:          resolved.expiresAt,
          urlHost:            uri.host,
          resolveStartedAt:   resolveStart,
          resolveFinishedAt:  resolveEnd,
          setSourceCalled:    true,
          setSourceSucceeded: true,
          processingState:    _player.processingState.name,
        );
      }
    } on PlayerException catch (e) {
      final errMsg = 'PlayerException code=${e.code} msg=${e.message ?? 'unknown'}';
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId $errMsg');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId:          videoId,
          sourceType:       resolved.sourceType,
          mimeType:         resolved.mimeType,
          urlHost:          uri.host,
          resolveStartedAt: resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled:  true,  setSourceSucceeded: false,
          setSourceError:   errMsg,
          lastError:        errMsg,
        );
      }
      if (!isRetry) {
        await _resolver.invalidate(videoId);
        debugPrint('[MEDIA RE-RESOLVE] $videoId after setAudioSource failure');
        ResolvedStream fresh;
        try {
          fresh = await _resolver.resolve(videoId);
        } catch (e2) {
          throw _MediaEngineException('Re-resolve failed: $e2');
        }
        if (_loadId == myId) {
          return _loadAndPlay(videoId, fresh, myId, resolveStart, DateTime.now(), isRetry: true);
        }
        return;
      }
      throw _MediaEngineException('Source rejected (${e.code}): ${e.message ?? 'unknown'}');
    } catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId generic: $e');
      await _resolver.invalidate(videoId);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId:         videoId,
          urlHost:         uri.host,
          setSourceCalled: true,
          lastError:       'setAudioSource error: $e',
        );
      }
      throw _MediaEngineException('Source setup failed: $e');
    }

    if (_loadId != myId) return;

    // ── Step 3: play() — mark buffering, NOT playing ──────────────────────────
    debugPrint('[PLAYER PLAY] $videoId — calling play()');
    final playCallTime = DateTime.now();

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.buffering,
        videoId:            videoId,
        sourceType:         resolved.sourceType,
        mimeType:           resolved.mimeType,
        expiresAt:          resolved.expiresAt,
        urlHost:            uri.host,
        resolveStartedAt:   resolveStart,
        resolveFinishedAt:  resolveEnd,
        setSourceCalled:    true,
        setSourceSucceeded: true,
        playCalled:         true,
        processingState:    _player.processingState.name,
      );
    }

    bool playOk = false;
    try {
      await _player.seek(Duration.zero);
      await _player.play();
      playOk = true;
      debugPrint('[PLAYER PLAY] $videoId play() returned — '
          'state=${_player.processingState.name} playing=${_player.playing}');
    } catch (e) {
      debugPrint('[PLAYER PLAY ERROR] $videoId: $e');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId:           videoId,
          sourceType:        resolved.sourceType,
          mimeType:          resolved.mimeType,
          urlHost:           uri.host,
          resolveStartedAt:  resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled:   true, setSourceSucceeded: true,
          playCalled:        true, playSucceeded: false,
          playError:         'play() threw: $e',
          lastError:         'play() threw: $e',
        );
      }
      throw _MediaEngineException('Playback failed to start: $e');
    }

    if (_loadId != myId) return;

    // After play() returns, we do NOT mark stage = playing yet.
    // We install a 3-second stall guard.
    // playerStateStream (in initialize()) will upgrade us to "playing"
    // IF ProcessingState.ready is observed. The guard downgrades otherwise.
    final guardId = myId;
    final videoIdGuard = videoId;
    final resolveCapture  = resolved;
    final resolveStartCap = resolveStart;
    final resolveEndCap   = resolveEnd;
    final playCallTimeCap = playCallTime;

    Future.delayed(const Duration(seconds: 3), () {
      if (_isDisposed || _loadId != guardId) return;
      final d = PlaybackDiagnosticsNotifier.value;
      if (d == null || d.videoId != videoIdGuard) return;

      // Check if we're still in buffering (play() didn't produce real playback)
      final pos     = _player.position;
      final buf     = _player.bufferedPosition;
      final state   = _player.processingState;
      final playing = _player.playing;

      debugPrint('[STALL GUARD] $videoIdGuard pos=${pos.inMilliseconds}ms '
          'buf=${buf.inMilliseconds}ms state=${state.name} playing=$playing');

      // Truthful playing: processingState must be ready/buffering AND bytes moved
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      if (!kDebugMode) return;

      if (d.stage == PlaybackStage.playing && !bytesMoving) {
        // Stage was already promoted to playing (by playerStateStream) but no bytes
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.falsePlayingDetected,
          videoId:            videoIdGuard,
          sourceType:         resolveCapture.sourceType,
          mimeType:           resolveCapture.mimeType,
          expiresAt:          resolveCapture.expiresAt,
          urlHost:            uri.host,
          resolveStartedAt:   resolveStartCap,
          resolveFinishedAt:  resolveEndCap,
          setSourceCalled:    true, setSourceSucceeded: true,
          playCalled:         true, playSucceeded:      playOk,
          processingState:    state.name,
          isPlaying:          playing,
          position:           pos,
          buffered:           buf,
          lastError:          'play() returned but ExoPlayer idle/pos=0/buf=0 after 3s '
                              '(processingState=${state.name})',
        );
      } else if ((d.stage == PlaybackStage.buffering ||
                  d.stage == PlaybackStage.stalledAfterResolved) &&
                 !bytesMoving) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId:            videoIdGuard,
          sourceType:         resolveCapture.sourceType,
          mimeType:           resolveCapture.mimeType,
          expiresAt:          resolveCapture.expiresAt,
          urlHost:            uri.host,
          resolveStartedAt:   resolveStartCap,
          resolveFinishedAt:  resolveEndCap,
          setSourceCalled:    true, setSourceSucceeded: true,
          playCalled:         true, playSucceeded:      playOk,
          processingState:    state.name,
          isPlaying:          playing,
          position:           pos,
          buffered:           buf,
          lastError:          'Buffering stall: ${DateTime.now().difference(playCallTimeCap).inSeconds}s '
                              'with zero bytes (state=${state.name})',
        );
      }
      // If bytes are moving but stage is still buffering, let playerStateStream
      // promote it to playing via the listener in initialize().
    });

    // Update buffering snapshot with confirmed play() result
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = (PlaybackDiagnosticsNotifier.value ?? 
          PlaybackDiagnostics.atStage(PlaybackStage.buffering, videoId: videoId))
          .copyWith(
            playSucceeded:   true,
            processingState: _player.processingState.name,
            isPlaying:       _player.playing,
            position:        _player.position,
            buffered:        _player.bufferedPosition,
            duration:        _player.duration ?? Duration.zero,
          );
    }
  }

  // ── playerStateStream promotes buffering → playing truthfully ─────────────
  // This replaces the old "mark playing right after play()" logic.
  // Called from initialize()'s listener — upgrade stage when ExoPlayer
  // confirms actual readiness + bytes are moving.
  void _maybeUpgradePlaying(ProcessingState state, bool isPlaying) {
    if (!kDebugMode) return;
    final prev = PlaybackDiagnosticsNotifier.value;
    if (prev == null) return;
    if (prev.stage != PlaybackStage.buffering &&
        prev.stage != PlaybackStage.stalledAfterResolved) return;

    final pos = _player.position;
    final buf = _player.bufferedPosition;
    final bytesMoving = pos > Duration.zero || buf > Duration.zero;

    if ((state == ProcessingState.ready || state == ProcessingState.buffering) &&
        isPlaying &&
        bytesMoving) {
      debugPrint('[PLAYER PLAYING CONFIRMED] ${prev.videoId} pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms');
      PlaybackDiagnosticsNotifier.value = prev.copyWith(
        stage:           PlaybackStage.playing,
        stageEnteredAt:  DateTime.now(),
        processingState: state.name,
        isPlaying:       true,
        position:        pos,
        buffered:        buf,
        duration:        _player.duration ?? Duration.zero,
        playSucceeded:   true,
      );
    }
  }

  // ── controls ───────────────────────────────────────────────────────────────
  @override Future<void> play()  async { debugPrint('[MEDIA PLAY] resume'); await _player.play(); }
  @override Future<void> pause() async { debugPrint('[PLAYER PAUSE]'); await _player.pause(); }
  @override Future<void> seek(Duration position) async {
    debugPrint('[MEDIA SEEK] ${position.inSeconds}s');
    await _player.seek(position);
  }
  @override void prefetchNext(String videoId) { /* handled by PrefetchManager */ }

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
  @override String toString() => message;
}
