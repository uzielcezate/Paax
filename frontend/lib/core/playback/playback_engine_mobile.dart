import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'client_preference_cache.dart';
import 'media_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — reliable, truthful state machine
// ---------------------------------------------------------------------------
//
// Load pipeline:
//   load(videoId)
//     1. MediaResolver.resolve() → Worker JSON → direct CDN URL
//        ↳ Uses ClientPreferenceCache.preferred() to hint preferred client
//     2. setAudioSource(directCdnUrl, headers: hardened-mobile-UA)
//     3. seek(0) + play()  → stage = buffering
//     4. playerStateStream → _maybeUpgradePlaying()
//        → stage = playing  ONLY if ProcessingState.ready + bytes moving
//     5. 3s stall guard → if pos=0 AND buf=0 → trigger fallback retry
//
// Fallback retry (max 2 attempts total):
//   On failedBuffering/falsePlayingDetected after initial play:
//     a. Emit fallbackRetryStarted
//     b. ClientPreferenceCache.invalidate(videoId)  ← forget old client
//     c. MediaResolver.invalidate(videoId)           ← clear StreamCache
//     d. Re-resolve with no preferred-client hint    ← Worker picks next client
//     e. Retry _loadAndPlay() with fresh URL
//     f. Emit fallbackRetrySucceeded | fallbackRetryFailed
//   After confirmed success:
//     ClientPreferenceCache.markSuccess(videoId, clientUsed)
//
// ExoPlayer headers:
//   Android YouTube app UA + Referer + Origin + Accept + Range support.
//   These are the minimum headers for direct googlevideo.com byte fetching
//   without triggering bot-detection on the CDN side.
// ---------------------------------------------------------------------------

// Hardened headers — mobile Android YouTube client fingerprint
const _kMobileHeaders = {
  'User-Agent':
      'com.google.android.youtube/20.10.38 (Linux; U; Android 12; GB) gzip',
  'Accept':          '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Origin':          'https://www.youtube.com',
  'Referer':         'https://www.youtube.com/',
  'Connection':      'keep-alive',
};

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({MediaResolver? resolver})
      : _resolver = resolver ?? MediaResolver();

  final MediaResolver _resolver;
  final _clientPrefs      = ClientPreferenceCache.instance;
  final _player           = AudioPlayer();
  final _completionCtrl   = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subs      = <StreamSubscription>[];

  // Load-lock — bumped at every load(). Async continuations bail if changed.
  int _loadId = 0;

  // ── PlaybackEngine streams ─────────────────────────────────────────────────
  @override Stream<Duration> get positionStream   => _player.positionStream;
  @override Stream<Duration> get durationStream   => _player.durationStream
      .where((d) => d != null && d > Duration.zero).map((d) => d!);
  @override Stream<bool>     get playingStream    => _player.playingStream;
  @override Stream<void>     get completionStream => _completionCtrl.stream;

  // ── initialize ─────────────────────────────────────────────────────────────
  @override
  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subs.add(session.interruptionEventStream.listen((event) {
      if (_isDisposed) return;
      if (event.begin) {
        _player.pause();
      } else if (event.type == AudioInterruptionType.pause ||
                 event.type == AudioInterruptionType.duck) {
        _player.play();
      }
    }));

    _subs.add(session.becomingNoisyEventStream.listen((_) {
      if (_isDisposed) return;
      _player.pause();
    }));

    // ── PlayerStateStream: completion + live diagnostics updates ─────────────
    _subs.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      debugPrint('[PLAYER STATE] playing=${state.playing} state=${state.processingState.name}');

      if (state.processingState == ProcessingState.completed) {
        _completionCtrl.add(null);
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
      } else {
        // Always push live processingState + isPlaying, then try to confirm playing
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              processingState: state.processingState.name,
              isPlaying:       state.playing,
            );
          }
        }
        _maybeUpgradePlaying(state.processingState, state.playing);
      }
    }));

    // ── Position stream: push live pos/buf/dur during active playback ─────────
    _subs.add(_player.positionStream.listen((pos) {
      if (_isDisposed || !kDebugMode) return;
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev == null) return;
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
        videoId, resolveStartedAt: resolveStart,
      );
    }

    // ── Step 1: Resolve (with preferred-client hint) ──────────────────────────
    final preferred = _clientPrefs.preferred(videoId);
    debugPrint('[MEDIA RESOLVE START] $videoId preferredClient=${preferred ?? 'none'}');

    ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId, preferredClient: preferred);
    } catch (e) {
      final elapsed = DateTime.now().difference(resolveStart);
      debugPrint('[MEDIA RESOLVE FAIL] $videoId +${elapsed.inMilliseconds}ms err=$e');
      final isTimeout = e.toString().toLowerCase().contains('timeout');
      final stage = isTimeout
          ? PlaybackStage.failedResolveTimeout
          : PlaybackStage.failedResolveHttp;
      final re = e is MediaResolveException ? e : null;
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          stage,
          videoId:           videoId,
          resolveStartedAt:  resolveStart,
          resolveFinishedAt: DateTime.now(),
          workerHttpStatus:  re?.httpStatus ?? 0,
          workerErrorBody:   re?.errorBody,
          lastError:         e.toString(),
        );
      }
      throw _EngineException(e.toString());
    }

    final resolveEnd = DateTime.now();
    debugPrint('[MEDIA RESOLVE OK] $videoId +${resolveEnd.difference(resolveStart).inMilliseconds}ms '
        'client=${resolved.clientUsed} itag=${resolved.itag} sourceType=${resolved.sourceType}');

    if (_loadId != myId) return;

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.resolved,
        videoId:           videoId,
        sourceType:        resolved.sourceType,
        mimeType:          resolved.mimeType,
        clientUsed:        resolved.clientUsed,
        itag:              resolved.itag,
        expiresAt:         resolved.expiresAt,
        urlHost:           Uri.parse(resolved.url).host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
      );
    }

    // ── Step 2: setAudioSource + play ─────────────────────────────────────────
    await _loadAndPlay(
      videoId: videoId, resolved: resolved, myId: myId,
      resolveStart: resolveStart, resolveEnd: resolveEnd,
      retryCount: 0,
    );
  }

  // ── _loadAndPlay ────────────────────────────────────────────────────────────
  Future<void> _loadAndPlay({
    required String         videoId,
    required ResolvedStream resolved,
    required int            myId,
    required DateTime       resolveStart,
    required DateTime       resolveEnd,
    required int            retryCount,
  }) async {
    final uri     = Uri.parse(resolved.url);
    final source  = AudioSource.uri(uri, headers: _kMobileHeaders);

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.settingSource,
        videoId:           videoId,
        sourceType:        resolved.sourceType,
        mimeType:          resolved.mimeType,
        clientUsed:        resolved.clientUsed,
        itag:              resolved.itag,
        expiresAt:         resolved.expiresAt,
        urlHost:           uri.host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
        setSourceCalled:   true,
        retryCount:        retryCount,
      );
    }

    // ── setAudioSource ────────────────────────────────────────────────────────
    debugPrint('[PLAYER SET SOURCE] $videoId → ${uri.host} itag=${resolved.itag}');
    try {
      await _player.setAudioSource(source, preload: false);
      debugPrint('[PLAYER SET SOURCE OK] $videoId state=${_player.processingState.name}');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.sourceReady,
          videoId:            videoId,
          sourceType:         resolved.sourceType,
          mimeType:           resolved.mimeType,
          clientUsed:         resolved.clientUsed,
          itag:               resolved.itag,
          expiresAt:          resolved.expiresAt,
          urlHost:            uri.host,
          resolveStartedAt:   resolveStart,
          resolveFinishedAt:  resolveEnd,
          setSourceCalled:    true,
          setSourceSucceeded: true,
          processingState:    _player.processingState.name,
          retryCount:         retryCount,
        );
      }
    } on PlayerException catch (e) {
      final errMsg = 'PlayerException code=${e.code} msg=${e.message ?? 'unknown'}';
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId $errMsg');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId:         videoId, sourceType: resolved.sourceType,
          mimeType:        resolved.mimeType, clientUsed: resolved.clientUsed,
          urlHost:         uri.host,
          resolveStartedAt: resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled: true, setSourceSucceeded: false,
          setSourceError:  errMsg, lastError: errMsg,
          retryCount:      retryCount,
        );
      }
      // Retry once with a fresh resolve if not already retrying
      if (retryCount < 2) {
        await _retryWithFreshClient(
          videoId: videoId, myId: myId,
          resolveStart: resolveStart, resolveEnd: resolveEnd,
          retryCount: retryCount,
          reason: errMsg,
        );
        return;
      }
      throw _EngineException('Source rejected (${e.code}): ${e.message ?? 'unknown'}');
    } catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId generic: $e');
      await _resolver.invalidate(videoId);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, urlHost: uri.host,
          setSourceCalled: true, lastError: 'setAudioSource: $e',
          retryCount: retryCount,
        );
      }
      throw _EngineException('Source setup failed: $e');
    }

    if (_loadId != myId) return;

    // ── play() — mark buffering, NOT playing ──────────────────────────────────
    debugPrint('[PLAYER PLAY] $videoId — calling play()');
    final playCallTime = DateTime.now();

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.buffering,
        videoId:            videoId,
        sourceType:         resolved.sourceType,
        mimeType:           resolved.mimeType,
        clientUsed:         resolved.clientUsed,
        itag:               resolved.itag,
        expiresAt:          resolved.expiresAt,
        urlHost:            uri.host,
        resolveStartedAt:   resolveStart,
        resolveFinishedAt:  resolveEnd,
        setSourceCalled:    true,
        setSourceSucceeded: true,
        playCalled:         true,
        processingState:    _player.processingState.name,
        retryCount:         retryCount,
      );
    }

    bool playOk = false;
    try {
      await _player.seek(Duration.zero);
      await _player.play();
      playOk = true;
      debugPrint('[PLAYER PLAY] $videoId returned — state=${_player.processingState.name} playing=${_player.playing}');
    } catch (e) {
      debugPrint('[PLAYER PLAY ERROR] $videoId: $e');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId:           videoId, sourceType: resolved.sourceType,
          mimeType:          resolved.mimeType, clientUsed: resolved.clientUsed,
          urlHost:           uri.host,
          resolveStartedAt:  resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled:   true, setSourceSucceeded: true,
          playCalled:        true, playSucceeded: false,
          playError:         'play() threw: $e',
          lastError:         'play() threw: $e',
          retryCount:        retryCount,
        );
      }
      throw _EngineException('Playback failed to start: $e');
    }

    if (_loadId != myId) return;

    // Update buffering snapshot with play() result
    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          playSucceeded:   true,
          processingState: _player.processingState.name,
          isPlaying:       _player.playing,
          position:        _player.position,
          buffered:        _player.bufferedPosition,
          duration:        _player.duration ?? Duration.zero,
        );
      }
    }

    // ── 3-second stall guard ──────────────────────────────────────────────────
    // If bytes don't move within 3s, trigger a fallback retry (if retries remain).
    // _maybeUpgradePlaying() will promote to "playing" once confirmed.
    final guardId        = myId;
    final guardVideoId   = videoId;
    final guardResolved  = resolved;
    final guardRStart    = resolveStart;
    final guardREnd      = resolveEnd;
    final guardRetry     = retryCount;
    final guardPlayOk    = playOk;
    final guardPlayCall  = playCallTime;

    Future.delayed(const Duration(seconds: 3), () async {
      if (_isDisposed || _loadId != guardId) return;
      final d = PlaybackDiagnosticsNotifier.value;
      if (d == null || d.videoId != guardVideoId) return;

      final pos     = _player.position;
      final buf     = _player.bufferedPosition;
      final state   = _player.processingState;
      final playing = _player.playing;
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      debugPrint('[STALL GUARD] $guardVideoId pos=${pos.inMilliseconds}ms '
          'buf=${buf.inMilliseconds}ms state=${state.name} playing=$playing '
          'retry=$guardRetry');

      // If bytes are already moving, everything is fine
      if (bytesMoving) return;

      // Trigger fallback retry if we haven't hit the limit
      if (guardRetry < 2 && kDebugMode) {
        final isFalsePlaying = d.stage == PlaybackStage.playing;
        final failStage = isFalsePlaying
            ? PlaybackStage.falsePlayingDetected
            : PlaybackStage.failedBuffering;

        final elapsed = DateTime.now().difference(guardPlayCall).inSeconds;
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          failStage,
          videoId:            guardVideoId,
          sourceType:         guardResolved.sourceType,
          mimeType:           guardResolved.mimeType,
          clientUsed:         guardResolved.clientUsed,
          itag:               guardResolved.itag,
          urlHost:            Uri.parse(guardResolved.url).host,
          resolveStartedAt:   guardRStart, resolveFinishedAt: guardREnd,
          setSourceCalled:    true, setSourceSucceeded: true,
          playCalled:         true, playSucceeded: guardPlayOk,
          processingState:    state.name, isPlaying: playing,
          position:           pos, buffered: buf,
          lastError:          '${state.name} after ${elapsed}s: pos=0 buf=0',
          retryCount:         guardRetry,
        );
      }

      if (guardRetry < 2) {
        await _retryWithFreshClient(
          videoId: guardVideoId, myId: guardId,
          resolveStart: guardRStart, resolveEnd: guardREnd,
          retryCount: guardRetry,
          reason: 'no bytes after 3s (processingState=${state.name})',
        );
      } else if (kDebugMode) {
        // Max retries exhausted
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId:        guardVideoId,
          clientUsed:     guardResolved.clientUsed,
          retryCount:     guardRetry,
          lastError:      'All ${guardRetry + 1} attempts produced no bytes',
        );
      }
    });
  }

  // ── _retryWithFreshClient ──────────────────────────────────────────────────
  Future<void> _retryWithFreshClient({
    required String   videoId,
    required int      myId,
    required DateTime resolveStart,
    required DateTime resolveEnd,
    required int      retryCount,
    required String   reason,
  }) async {
    if (_loadId != myId || _isDisposed) return;

    debugPrint('[PLAYER RETRY] $videoId attempt=${retryCount + 1} reason=$reason');

    // Forget old client — Worker will pick the next one in its waterfall
    _clientPrefs.invalidate(videoId);
    await _resolver.invalidate(videoId);

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.fallbackRetryStarted,
        videoId:     videoId,
        retryCount:  retryCount + 1,
        clientUsed:  prev?.clientUsed ?? '…',
        lastError:   reason,
      );
    }

    // Stop current playback before retry
    await _player.stop();
    if (_loadId != myId) return;

    final freshResolveStart = DateTime.now();
    ResolvedStream freshResolved;
    try {
      // No preferred client — Worker waterfall picks the next candidate
      freshResolved = await _resolver.resolve(videoId);
    } catch (e) {
      debugPrint('[PLAYER RETRY FAIL] $videoId resolve failed: $e');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId:    videoId,
          retryCount: retryCount + 1,
          lastError:  'Re-resolve failed: $e',
        );
      }
      return;
    }

    if (_loadId != myId) return;

    debugPrint('[PLAYER RETRY] $videoId got fresh client=${freshResolved.clientUsed} itag=${freshResolved.itag}');

    await _loadAndPlay(
      videoId:      videoId,
      resolved:     freshResolved,
      myId:         myId,
      resolveStart: freshResolveStart,
      resolveEnd:   DateTime.now(),
      retryCount:   retryCount + 1,
    );
  }

  // ── _maybeUpgradePlaying ───────────────────────────────────────────────────
  // Only called from playerStateStream listener.
  // Upgrades stage from buffering → playing ONLY when bytes are confirmed.
  // Also records the successful client in ClientPreferenceCache.
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
        isPlaying && bytesMoving) {
      debugPrint('[PLAYER PLAYING CONFIRMED] ${prev.videoId} '
          'client=${prev.clientUsed} pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms');

      // Record which client succeeded for future plays of this track
      if (prev.clientUsed != '…' && prev.clientUsed.isNotEmpty) {
        _clientPrefs.markSuccess(prev.videoId, prev.clientUsed);
      }

      PlaybackDiagnosticsNotifier.value = prev.copyWith(
        stage:           prev.retryCount > 0
            ? PlaybackStage.fallbackRetrySucceeded
            : PlaybackStage.playing,
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
    for (final sub in _subs) { sub.cancel(); }
    _subs.clear();
    _player.dispose();
    _completionCtrl.close();
  }

  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
class _EngineException implements Exception {
  final String message;
  const _EngineException(this.message);
  @override String toString() => message;
}
