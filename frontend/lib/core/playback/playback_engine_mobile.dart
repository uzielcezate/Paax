import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'media_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — local-first, youtube_explode_dart powered
// ---------------------------------------------------------------------------
//
// Stream resolution is fully on-device via [LocalStreamResolver].
// No Cloudflare Worker, no remote proxy.
//
// Retry policy (max 2 attempts):
//   Attempt 1: LocalStreamResolver.resolve(videoId) → cached or fresh extract
//              play via AudioSource.uri + YouTube headers
//              3-sec stall guard fires → invalidate cache → retry
//
//   Attempt 2: LocalStreamResolver.resolve(videoId) → guaranteed fresh URL
//              3-sec stall guard fires → retryFailed
//
//   403 PlayerException: same path as stall — invalidate + re-resolve

// Headers injected into every ExoPlayer CDN request via AudioSource.uri.
// Must match the web-browser UA used by youtube_explode_dart's default client
// so the googlevideo.com CDN accepts the web-signed stream URL without dropping
// the connection.
const Map<String, String> _kHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Safari/537.36',
  'Accept':          '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Origin':          'https://www.youtube.com',
  'Referer':         'https://www.youtube.com/',
};

const int _kMaxAttempts = 2;

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({LocalStreamResolver? resolver})
      : _resolver = resolver ?? LocalStreamResolver.instance;

  final LocalStreamResolver _resolver;
  final _player         = AudioPlayer();
  final _completionCtrl = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subs      = <StreamSubscription>[];
  int  _loadId     = 0;

  // ── Streams ────────────────────────────────────────────────────────────────
  @override Stream<Duration> get positionStream  => _player.positionStream;
  @override Stream<Duration> get durationStream  => _player.durationStream
      .where((d) => d != null && d > Duration.zero).map((d) => d!);
  @override Stream<bool>     get playingStream   => _player.playingStream;
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

    _subs.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      if (state.processingState == ProcessingState.completed) {
        _completionCtrl.add(null);
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              stage: PlaybackStage.completed,
              processingState: 'completed', isPlaying: false,
              stageEnteredAt: DateTime.now(),
            );
          }
        }
      } else {
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              processingState: state.processingState.name,
              isPlaying:       state.playing,
            );
          }
        }
        _maybeConfirmPlaying(state.processingState, state.playing);
      }
    }));

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

    await _player.stop();
    if (_loadId != myId) return;

    await _playAttempt(videoId: videoId, myId: myId, attempt: 1);
  }

  // ── _playAttempt ───────────────────────────────────────────────────────────
  Future<void> _playAttempt({
    required String videoId,
    required int    myId,
    required int    attempt,
  }) async {
    if (_isDisposed || _loadId != myId) return;

    final resolveStart = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(
        videoId, resolveStartedAt: resolveStart, attempt: attempt,
      );
    }

    // ── Resolve ─────────────────────────────────────────────────────────────
    ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId);
    } catch (e) {
      debugPrint('[ENGINE] Resolve failed ($attempt): $e');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedResolve,
          videoId:           videoId,
          attempt:           attempt,
          failureSource:     FailureSource.resolve,
          resolveStartedAt:  resolveStart,
          resolveFinishedAt: DateTime.now(),
          lastError:         e.toString(),
        );
      }
      // Propagate only on attempt 1 — caller (load) should surface the error
      if (attempt == 1) rethrow;
      return;
    }

    if (_loadId != myId) return;

    final resolveEnd = DateTime.now();
    final uri  = Uri.parse(resolved.url);
    final host = uri.host;

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.resolved,
        videoId:           videoId,
        attempt:           attempt,
        resolveSource:     'local',
        sourceType:        resolved.sourceType,
        mimeType:          resolved.mimeType,
        itag:              resolved.itag,
        bitrate:           resolved.bitrate,
        expiresAt:         resolved.expiresAt,
        urlHost:           host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
      );
    }

    // ── setAudioSource ───────────────────────────────────────────────────────
    final source = AudioSource.uri(uri, headers: _kHeaders);

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          stage: PlaybackStage.settingSource, stageEnteredAt: DateTime.now(),
          setSourceCalled: true,
        );
      }
    }

    debugPrint('[ENGINE] setAudioSource attempt=$attempt itag=${resolved.itag} host=$host');

    try {
      await _player.setAudioSource(source, preload: false);
    } on PlayerException catch (e) {
      final errMsg = 'PlayerException code=${e.code}';
      final is403  = (e.message ?? '').contains('403') ||
                     e.code.toString().contains('403');
      debugPrint('[ENGINE] setAudioSource failed: $errMsg is403=$is403');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, attempt: attempt,
          sourceType: resolved.sourceType, mimeType: resolved.mimeType,
          itag: resolved.itag, urlHost: host,
          resolveStartedAt: resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled: true, setSourceError: errMsg,
          failureSource: FailureSource.playback, lastError: errMsg,
        );
      }
      await _handlePlayerFailure(
        videoId: videoId, myId: myId, attempt: attempt,
        reason: errMsg, force403: is403,
      );
      return;
    } catch (e) {
      debugPrint('[ENGINE] setAudioSource generic error: $e');
      await _handlePlayerFailure(
        videoId: videoId, myId: myId, attempt: attempt,
        reason: 'setAudioSource: $e',
      );
      return;
    }

    if (_loadId != myId) return;

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          stage: PlaybackStage.sourceReady, stageEnteredAt: DateTime.now(),
          setSourceSucceeded: true,
          processingState: _player.processingState.name,
        );
      }
    }

    // ── play() ───────────────────────────────────────────────────────────────
    final playCallTime = DateTime.now();
    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          stage: PlaybackStage.buffering, stageEnteredAt: DateTime.now(),
          playCalled: true,
        );
      }
    }

    try {
      await _player.seek(Duration.zero);
      await _player.play();
      debugPrint('[ENGINE] play() called attempt=$attempt state=${_player.processingState.name}');
    } catch (e) {
      debugPrint('[ENGINE] play() threw: $e');
      await _handlePlayerFailure(
        videoId: videoId, myId: myId, attempt: attempt,
        reason: 'play() threw: $e',
      );
      return;
    }

    if (_loadId != myId) return;

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          playSucceeded:   true,
          processingState: _player.processingState.name,
          isPlaying:       _player.playing,
        );
      }
    }

    // ── 3-second stall guard ─────────────────────────────────────────────────
    final guardId      = myId;
    final guardVideoId = videoId;
    final guardAttempt = attempt;
    final guardItag    = resolved.itag;

    Future.delayed(const Duration(seconds: 3), () async {
      if (_isDisposed || _loadId != guardId) return;

      final pos         = _player.position;
      final buf         = _player.bufferedPosition;
      final state       = _player.processingState;
      final playing     = _player.playing;
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      debugPrint('[STALL GUARD] $guardVideoId attempt=$guardAttempt '
          'itag=$guardItag pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms '
          'state=${state.name} moving=$bytesMoving');

      if (bytesMoving) return; // bytes flowing — all good

      final elapsed  = DateTime.now().difference(playCallTime).inSeconds;
      final isFalse  = kDebugMode &&
          (PlaybackDiagnosticsNotifier.value?.stage == PlaybackStage.playing);

      if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId: guardVideoId, attempt: guardAttempt,
        )).copyWith(
          stage:          isFalse ? PlaybackStage.falsePlayingDetected : PlaybackStage.failedBuffering,
          stageEnteredAt: DateTime.now(),
          failureSource:  FailureSource.playback,
          processingState: state.name, isPlaying: playing,
          position: pos, buffered: buf,
          lastError: '${state.name} after ${elapsed}s: pos=0 buf=0',
        );
      }

      await _handlePlayerFailure(
        videoId: guardVideoId, myId: guardId, attempt: guardAttempt,
        reason: 'no bytes after ${elapsed}s (${state.name})',
      );
    });
  }

  // ── _handlePlayerFailure ───────────────────────────────────────────────────
  // Shared path for stall guard, 403, and play() errors.
  Future<void> _handlePlayerFailure({
    required String videoId,
    required int    myId,
    required int    attempt,
    required String reason,
    bool            force403 = false,
  }) async {
    if (_isDisposed || _loadId != myId) return;

    if (attempt >= _kMaxAttempts) {
      debugPrint('[ENGINE] All $attempt attempts exhausted: $videoId');
      if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.retryFailed,
          videoId: videoId, attempt: attempt,
        )).copyWith(
          stage:          PlaybackStage.retryFailed,
          stageEnteredAt: DateTime.now(),
          failureSource:  FailureSource.playback,
          lastError:      'All $attempt attempts exhausted. Last: $reason',
        );
      }
      return;
    }

    // Always invalidate cache before re-resolve — ensures fresh URL
    await _resolver.invalidate(videoId);
    debugPrint('[ENGINE] Retrying: $videoId attempt=${attempt + 1} reason=$reason');

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
        PlaybackStage.retryResolving,
        videoId: videoId, attempt: attempt + 1,
      )).copyWith(
        stage:          PlaybackStage.retryResolving,
        stageEnteredAt: DateTime.now(),
        attempt:        attempt + 1,
        lastError:      reason,
      );
    }

    await _player.stop();
    if (_loadId != myId) return;

    await _playAttempt(videoId: videoId, myId: myId, attempt: attempt + 1);
  }

  // ── _maybeConfirmPlaying ─────────────────────────────────────────────────
  void _maybeConfirmPlaying(ProcessingState state, bool isPlaying) {
    if (!kDebugMode) return;
    final prev = PlaybackDiagnosticsNotifier.value;
    if (prev == null) return;
    if (prev.stage != PlaybackStage.buffering &&
        prev.stage != PlaybackStage.retryResolving) return;

    final pos = _player.position;
    final buf = _player.bufferedPosition;
    if (!((state == ProcessingState.ready || state == ProcessingState.buffering) &&
        isPlaying && (pos > Duration.zero || buf > Duration.zero))) return;

    debugPrint('[ENGINE] Playback confirmed: ${prev.videoId} '
        'itag=${prev.itag} attempt=${prev.attempt} '
        'pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms');

    PlaybackDiagnosticsNotifier.value = prev.copyWith(
      stage:           prev.attempt > 1
          ? PlaybackStage.retrySucceeded
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

  // ── prefetchNext ─────────────────────────────────────────────────────────
  @override
  void prefetchNext(String videoId) {
    if (videoId.isEmpty) return;
    _resolver.resolveForPrefetch(videoId).then((_) {
      debugPrint('[ENGINE PREFETCH] $videoId — cached');
    }).catchError((Object e) {
      debugPrint('[ENGINE PREFETCH] $videoId — failed: $e');
    });
  }

  // ── Controls ──────────────────────────────────────────────────────────────
  @override Future<void> play()  async { await _player.play(); }
  @override Future<void> pause() async { await _player.pause(); }
  @override Future<void> seek(Duration position) async { await _player.seek(position); }

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
