import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'stream_api_service.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — Hybrid Architecture (Phase 8)
// ---------------------------------------------------------------------------
//
// Extraction: Client-side (youtube_explode_dart on residential IP)
// Streaming:  Server-side (IPv6 proxy with UA rotation + Range support)
//
// Flow:
//   load(videoId)
//     → StreamApiService.resolveStream(videoId)
//         1. youtube_explode_dart extracts stream manifest (on device)
//         2. Selects itag 140 (128kbps M4A) CDN URL
//         3. Wraps in proxy: /stream?url=<encoded_cdn_url>
//         ← { streamUrl: proxy_url, mimeType, provider, bitrate }
//     → just_audio: AudioSource.uri(proxy_url)
//     → 3-sec stall guard → 1 retry (fresh resolve, no cache)
//     → stall again → retryFailed
//
//   PlayerException 403/400 → same path as stall (1 retry)

// Headers for talking to our OWN proxy (not YouTube directly)
const Map<String, String> _kHeaders = {
  'User-Agent': 'PaaxMusicApp/4.0',
  'Accept': '*/*',
};

const int _kMaxAttempts = 2;

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({StreamApiService? streamApi})
      : _streamApi = streamApi ?? StreamApiService(),
        super();

  final StreamApiService _streamApi;
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

    // ── Resolve via backend ──────────────────────────────────────────────────
    debugPrint('[ENGINE] Resolving: $videoId (attempt $attempt)');
    StreamResult resolved;
    try {
      resolved = await _streamApi.resolveStream(videoId);
    } catch (e) {
      debugPrint('[ENGINE] Resolve failed (attempt $attempt): $e');
      if (kDebugMode) {
        final httpStatus = e is StreamResolveException ? e.httpStatus : 0;
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedResolve,
          videoId:           videoId,
          attempt:           attempt,
          failureSource:     FailureSource.resolve,
          resolveStartedAt:  resolveStart,
          resolveFinishedAt: DateTime.now(),
          lastError:         e.toString(),
          workerHttpStatus:  httpStatus,
        );
      }
      if (attempt == 1) rethrow;
      return;
    }

    if (_loadId != myId) return;

    final resolveEnd = DateTime.now();
    final uri  = Uri.parse(resolved.streamUrl);
    final host = uri.host;

    debugPrint('[ENGINE] Resolved: videoId=$videoId provider=${resolved.provider} '
        'mime=${resolved.mimeType} bitrate=${resolved.bitrate ~/ 1000}kbps '
        'host=$host attempt=$attempt');

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.resolved,
        videoId:           videoId,
        attempt:           attempt,
        resolveSource:     'backend',
        sourceType:        'audioOnly',
        mimeType:          resolved.mimeType,
        bitrate:           resolved.bitrate,
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

    debugPrint('[ENGINE] setAudioSource: $host attempt=$attempt');

    try {
      await _player.setAudioSource(source, preload: false);
    } on PlayerException catch (e) {
      final errMsg = 'PlayerException code=${e.code}: ${e.message}';
      final is4xx  = e.code.toString().contains('40') ||
                     (e.message ?? '').contains('403') ||
                     (e.message ?? '').contains('400');
      debugPrint('[ENGINE] setAudioSource failed ($errMsg is4xx=$is4xx)');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, attempt: attempt,
          mimeType: resolved.mimeType, urlHost: host,
          resolveStartedAt: resolveStart, resolveFinishedAt: resolveEnd,
          setSourceCalled: true, setSourceError: errMsg,
          failureSource: FailureSource.playback, lastError: errMsg,
        );
      }
      await _handleStall(
        videoId: videoId, myId: myId, attempt: attempt, reason: errMsg,
      );
      return;
    } catch (e) {
      debugPrint('[ENGINE] setAudioSource generic error: $e');
      await _handleStall(
        videoId: videoId, myId: myId, attempt: attempt, reason: '$e',
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
      debugPrint('[ENGINE] play() called: state=${_player.processingState.name}');
    } catch (e) {
      debugPrint('[ENGINE] play() threw: $e');
      await _handleStall(
        videoId: videoId, myId: myId, attempt: attempt, reason: 'play(): $e',
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

    Future.delayed(const Duration(seconds: 3), () async {
      if (_isDisposed || _loadId != guardId) return;

      final pos         = _player.position;
      final buf         = _player.bufferedPosition;
      final state       = _player.processingState;
      final playing     = _player.playing;
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      debugPrint('[STALL GUARD] $guardVideoId attempt=$guardAttempt '
          'pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms '
          'state=${state.name} bytesMoving=$bytesMoving');

      if (bytesMoving) return;

      final elapsed = DateTime.now().difference(playCallTime).inSeconds;
      final isFalse = kDebugMode &&
          PlaybackDiagnosticsNotifier.value?.stage == PlaybackStage.playing;

      if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId: guardVideoId, attempt: guardAttempt,
        )).copyWith(
          stage:           isFalse ? PlaybackStage.falsePlayingDetected
                                   : PlaybackStage.failedBuffering,
          stageEnteredAt:  DateTime.now(),
          failureSource:   FailureSource.playback,
          processingState: state.name, isPlaying: playing,
          position: pos, buffered: buf,
          lastError: '${state.name} after ${elapsed}s: pos=0 buf=0',
        );
      }

      await _handleStall(
        videoId: guardVideoId, myId: guardId, attempt: guardAttempt,
        reason: 'no bytes after ${elapsed}s (${state.name})',
      );
    });
  }

  // ── _handleStall ───────────────────────────────────────────────────────────
  Future<void> _handleStall({
    required String videoId,
    required int    myId,
    required int    attempt,
    required String reason,
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

    debugPrint('[ENGINE] Stall detected — retrying: $videoId '
        'attempt ${attempt + 1}/$_kMaxAttempts reason=$reason');

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

  // ── _maybeConfirmPlaying ───────────────────────────────────────────────────
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

    debugPrint('[ENGINE] ✓ Playback confirmed: ${prev.videoId} '
        'attempt=${prev.attempt} pos=${pos.inMilliseconds}ms');

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

  // ── prefetchNext ───────────────────────────────────────────────────────────
  @override
  void prefetchNext(String videoId) {
    // Fire-and-forget background resolve. The backend response is stateless
    // so there is nothing to cache client-side; this is a no-op placeholder
    // until server-side caching is implemented on the stream backend.
    debugPrint('[ENGINE PREFETCH] $videoId — no-op (server handles caching)');
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
