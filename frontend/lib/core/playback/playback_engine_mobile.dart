import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'candidate_blacklist.dart';
import 'client_preference_cache.dart';
import 'media_resolver.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — diverse-retry, truthful state machine
// ---------------------------------------------------------------------------
//
// Retry strategy (max 3 total attempts = initial + 2 retries):
//
//   Attempt 1 (initial):
//     resolve(videoId, preferredClient: ClientPreferenceCache.preferred)
//     → ResolvedStream{ url, clientUsed, itag, candidates: [...] }
//     play(candidates[0])   ← primary candidate
//     3s stall guard fires → blacklist("CLIENT:itag")
//
//   Attempt 2 (local fallback — same client, different format):
//     pick next non-blacklisted candidate from candidates[]
//     → if found: play(nextCandidate) without a Worker call
//     → if not found: go to Attempt 3
//
//   Attempt 3 (new client — different Innertube client):
//     resolve(videoId, excludeClients: blacklist.failedClients(videoId))
//     → Worker skips blacklisted clients → returns different client's URL
//     play(newCandidate)
//     3s stall guard → fallbackRetryFailed (exhausted)
//
// "playing" stage set ONLY when playerStateStream confirms:
//   ProcessingState.ready + isPlaying + (pos > 0 OR buf > 0)
//
// ExoPlayer headers: Android YouTube app fingerprint for direct CDN access.
// ---------------------------------------------------------------------------

const _kMobileHeaders = {
  'User-Agent':
      'com.google.android.youtube/20.10.38 (Linux; U; Android 12; GB) gzip',
  'Accept':          '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Origin':          'https://www.youtube.com',
  'Referer':         'https://www.youtube.com/',
  'Connection':      'keep-alive',
};

const int _kMaxAttempts = 3;

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({MediaResolver? resolver})
      : _resolver = resolver ?? MediaResolver();

  final MediaResolver _resolver;
  final _clientPrefs  = ClientPreferenceCache.instance;
  final _blacklist    = CandidateBlacklist.instance;
  final _player       = AudioPlayer();
  final _completionCtrl = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subs      = <StreamSubscription>[];

  // Load-lock
  int _loadId = 0;

  // Candidate list from the most recent resolve — shared across retries
  List<StreamCandidate> _candidates = [];

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

    _subs.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      debugPrint('[PLAYER STATE] playing=${state.playing} state=${state.processingState.name}');
      if (state.processingState == ProcessingState.completed) {
        _completionCtrl.add(null);
        if (kDebugMode) {
          final prev = PlaybackDiagnosticsNotifier.value;
          if (prev != null) {
            PlaybackDiagnosticsNotifier.value = prev.copyWith(
              stage: PlaybackStage.completed, processingState: 'completed',
              isPlaying: false, stageEnteredAt: DateTime.now(),
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
        _maybeUpgradePlaying(state.processingState, state.playing);
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

    // Clear blacklist from any previous playback of this track
    _blacklist.clearForVideo(videoId);
    _candidates = [];

    debugPrint('[PLAYER STOP] >>> $videoId');
    await _player.stop();
    if (_loadId != myId) return;

    final resolveStart = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(
        videoId, resolveStartedAt: resolveStart, attempt: 1,
      );
    }

    // ── Resolve (attempt 1) ────────────────────────────────────────────────
    final preferred = _clientPrefs.preferred(videoId);
    ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId, preferredClient: preferred);
    } catch (e) {
      _emitResolveFailure(videoId, e, resolveStart, attempt: 1);
      throw _EngineException(e.toString());
    }

    if (_loadId != myId) return;
    _candidates = List.of(resolved.candidates);

    _emitResolved(videoId, resolved, resolveStart, attempt: 1);

    // Take first non-blacklisted candidate from list
    final primary = _pickCandidate(videoId);
    if (primary == null) {
      // No candidates — extremely unlikely but safe
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId: videoId, lastError: 'No playable candidates returned by Worker',
        );
      }
      throw const _EngineException('No playable candidates returned by Worker');
    }

    await _playCandidate(
      videoId: videoId, candidate: primary, myId: myId,
      resolveStart: resolveStart, resolveEnd: DateTime.now(), attempt: 1,
    );
  }

  // ── _playCandidate ─────────────────────────────────────────────────────────
  // Plays a specific (client, itag) candidate. On stall triggers either
  // local format fallback or a new-client re-resolve.
  Future<void> _playCandidate({
    required String          videoId,
    required StreamCandidate candidate,
    required int             myId,
    required DateTime        resolveStart,
    required DateTime        resolveEnd,
    required int             attempt,
  }) async {
    final uri    = Uri.parse(candidate.url);
    final source = AudioSource.uri(uri, headers: _kMobileHeaders);

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.settingSource,
        videoId:           videoId,
        attempt:           attempt,
        candidateKey:      candidate.key,
        blacklistCount:    _blacklist.count(videoId),
        sourceType:        candidate.sourceType,
        mimeType:          candidate.mimeType,
        clientUsed:        candidate.clientUsed,
        itag:              candidate.itag,
        urlHost:           uri.host,
        resolveStartedAt:  resolveStart,
        resolveFinishedAt: resolveEnd,
        setSourceCalled:   true,
      );
    }

    debugPrint('[PLAYER SET SOURCE] $videoId attempt=$attempt '
        'candidate=${candidate.key} host=${uri.host}');

    try {
      await _player.setAudioSource(source, preload: false);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.sourceReady,
          videoId:            videoId,
          attempt:            attempt,
          candidateKey:       candidate.key,
          blacklistCount:     _blacklist.count(videoId),
          sourceType:         candidate.sourceType,
          mimeType:           candidate.mimeType,
          clientUsed:         candidate.clientUsed,
          itag:               candidate.itag,
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
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId:       videoId, attempt: attempt,
          candidateKey:  candidate.key,
          blacklistCount: _blacklist.count(videoId),
          clientUsed:    candidate.clientUsed, itag: candidate.itag,
          urlHost:       uri.host,
          setSourceCalled: true, setSourceSucceeded: false,
          setSourceError: errMsg, lastError: errMsg,
          failureSource:  FailureSource.playback,
        );
      }
      await _tryNextCandidate(
        videoId: videoId, myId: myId,
        resolveStart: resolveStart, resolveEnd: resolveEnd,
        attempt: attempt, reason: errMsg, source: FailureSource.playback,
      );
      return;
    } catch (e) {
      final errMsg = 'setAudioSource error: $e';
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId generic: $e');
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, attempt: attempt,
          candidateKey: candidate.key, blacklistCount: _blacklist.count(videoId),
          setSourceCalled: true, lastError: errMsg,
          failureSource: FailureSource.playback,
        );
      }
      await _tryNextCandidate(
        videoId: videoId, myId: myId,
        resolveStart: resolveStart, resolveEnd: resolveEnd,
        attempt: attempt, reason: errMsg, source: FailureSource.playback,
      );
      return;
    }

    if (_loadId != myId) return;

    // ── play() — marks buffering, NOT playing ───────────────────────────────
    final playCallTime = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.buffering,
        videoId:            videoId,
        attempt:            attempt,
        candidateKey:       candidate.key,
        blacklistCount:     _blacklist.count(videoId),
        sourceType:         candidate.sourceType,
        mimeType:           candidate.mimeType,
        clientUsed:         candidate.clientUsed,
        itag:               candidate.itag,
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
      debugPrint('[PLAYER PLAY] $videoId attempt=$attempt candidate=${candidate.key} '
          'state=${_player.processingState.name}');
    } catch (e) {
      debugPrint('[PLAYER PLAY ERROR] $videoId: $e');
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId: videoId, attempt: attempt,
          candidateKey: candidate.key, blacklistCount: _blacklist.count(videoId),
          clientUsed: candidate.clientUsed, itag: candidate.itag,
          urlHost: uri.host, setSourceCalled: true, setSourceSucceeded: true,
          playCalled: true, playSucceeded: false,
          playError: 'play() threw: $e', lastError: 'play() threw: $e',
          failureSource: FailureSource.playback,
        );
      }
      await _tryNextCandidate(
        videoId: videoId, myId: myId,
        resolveStart: resolveStart, resolveEnd: resolveEnd,
        attempt: attempt,
        reason: 'play() threw: $e', source: FailureSource.playback,
      );
      return;
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

    // ── 3-second stall guard ─────────────────────────────────────────────────
    final guardId        = myId;
    final guardVideoId   = videoId;
    final guardCandidate = candidate;
    final guardRStart    = resolveStart;
    final guardREnd      = resolveEnd;
    final guardAttempt   = attempt;
    final guardUri       = uri;

    Future.delayed(const Duration(seconds: 3), () async {
      if (_isDisposed || _loadId != guardId) return;
      final d = PlaybackDiagnosticsNotifier.value;
      if (d == null || d.videoId != guardVideoId) return;

      final pos     = _player.position;
      final buf     = _player.bufferedPosition;
      final state   = _player.processingState;
      final playing = _player.playing;
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      debugPrint('[STALL GUARD] $guardVideoId attempt=$guardAttempt '
          'candidate=${guardCandidate.key} pos=${pos.inMilliseconds}ms '
          'buf=${buf.inMilliseconds}ms state=${state.name}');

      if (bytesMoving) return; // bytes flowing → all good

      // Blacklist this candidate
      _blacklist.blacklist(guardVideoId, guardCandidate.clientUsed, guardCandidate.itag);
      final elapsed = DateTime.now().difference(playCallTime).inSeconds;
      final isFalsePlaying = d.stage == PlaybackStage.playing;

      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          isFalsePlaying ? PlaybackStage.falsePlayingDetected : PlaybackStage.failedBuffering,
          videoId:        guardVideoId,
          attempt:        guardAttempt,
          candidateKey:   guardCandidate.key,
          blacklistCount: _blacklist.count(guardVideoId),
          clientUsed:     guardCandidate.clientUsed,
          itag:           guardCandidate.itag,
          urlHost:        guardUri.host,
          resolveStartedAt: guardRStart, resolveFinishedAt: guardREnd,
          setSourceCalled: true, setSourceSucceeded: true,
          playCalled: true, playSucceeded: playOk,
          processingState: state.name, isPlaying: playing,
          position: pos, buffered: buf,
          lastError: '${state.name} after ${elapsed}s: pos=0 buf=0',
          failureSource: FailureSource.playback,
        );
      }

      await _tryNextCandidate(
        videoId: guardVideoId, myId: guardId,
        resolveStart: guardRStart, resolveEnd: guardREnd,
        attempt: guardAttempt,
        reason: 'no bytes after ${elapsed}s (state=${state.name})',
        source: FailureSource.playback,
      );
    });
  }

  // ── _tryNextCandidate ──────────────────────────────────────────────────────
  // Picks next candidate: local first (same client, diff itag), then new-client resolve.
  Future<void> _tryNextCandidate({
    required String       videoId,
    required int          myId,
    required DateTime     resolveStart,
    required DateTime     resolveEnd,
    required int          attempt,
    required String       reason,
    required FailureSource source,
  }) async {
    if (_loadId != myId || _isDisposed) return;
    if (attempt >= _kMaxAttempts) {
      debugPrint('[PLAYER RETRY] $videoId exhausted max $_kMaxAttempts attempts');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId:        videoId,
          attempt:        attempt,
          blacklistCount: _blacklist.count(videoId),
          failureSource:  source,
          lastError:      'All $_kMaxAttempts attempts exhausted. Last: $reason',
        );
      }
      return;
    }

    final nextAttempt = attempt + 1;
    debugPrint('[PLAYER RETRY] $videoId attempt=$nextAttempt reason=$reason');

    // Emit retryStarted
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.fallbackRetryStarted,
        videoId:        videoId,
        attempt:        nextAttempt,
        blacklistCount: _blacklist.count(videoId),
        failureSource:  source,
        lastError:      reason,
      );
    }

    await _player.stop();
    if (_loadId != myId) return;

    // ── Option A: local candidate (no Worker call) ─────────────────────────
    final local = _pickCandidate(videoId);
    if (local != null) {
      debugPrint('[PLAYER RETRY] $videoId using local candidate=${local.key}');
      await _playCandidate(
        videoId: videoId, candidate: local, myId: myId,
        resolveStart: resolveStart, resolveEnd: resolveEnd,
        attempt: nextAttempt,
      );
      return;
    }

    // ── Option B: new-client resolve (Worker with exclude list) ────────────
    final failedClients = _blacklist.failedClients(videoId).toList();
    debugPrint('[PLAYER RETRY] $videoId all local candidates exhausted — '
        're-resolving exclude=${failedClients.join(',')}');

    final freshStart = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(
        videoId, resolveStartedAt: freshStart, attempt: nextAttempt,
      ).copyWith(blacklistCount: _blacklist.count(videoId));
    }

    ResolvedStream freshResolved;
    try {
      _clientPrefs.invalidate(videoId);
      freshResolved = await _resolver.resolve(
        videoId, excludeClients: failedClients,
      );
    } catch (e) {
      debugPrint('[PLAYER RETRY FAIL] $videoId re-resolve failed: $e');
      _emitResolveFailure(videoId, e, freshStart, attempt: nextAttempt);
      if (kDebugMode) {
        // Was a resolve failure — emit fallbackRetryFailed
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId:       videoId,
          attempt:       nextAttempt,
          blacklistCount: _blacklist.count(videoId),
          failureSource:  FailureSource.resolve,
          lastError:     'Re-resolve failed: $e',
        );
      }
      return;
    }

    if (_loadId != myId) return;

    // Merge new candidates into our list
    for (final c in freshResolved.candidates) {
      if (!_candidates.any((x) => x.key == c.key)) {
        _candidates.add(c);
      }
    }

    _emitResolved(videoId, freshResolved, freshStart, attempt: nextAttempt);

    final nextCandidate = _pickCandidate(videoId);
    if (nextCandidate == null) {
      debugPrint('[PLAYER RETRY FAIL] $videoId no non-blacklisted candidates after re-resolve');
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId:       videoId,
          attempt:       nextAttempt,
          blacklistCount: _blacklist.count(videoId),
          failureSource:  FailureSource.resolve,
          lastError:     'Re-resolve returned only already-blacklisted candidates',
        );
      }
      return;
    }

    await _playCandidate(
      videoId: videoId, candidate: nextCandidate, myId: myId,
      resolveStart: freshStart, resolveEnd: DateTime.now(),
      attempt: nextAttempt,
    );
  }

  // ── _pickCandidate ─────────────────────────────────────────────────────────
  // Returns the first candidate in _candidates not in the blacklist.
  // Prefers audioOnly over muxed.
  StreamCandidate? _pickCandidate(String videoId) {
    // Audio-only first
    for (final c in _candidates) {
      if (c.sourceType == 'audioOnly' &&
          !_blacklist.isBlacklisted(videoId, c.clientUsed, c.itag)) {
        return c;
      }
    }
    // Muxed as fallback
    for (final c in _candidates) {
      if (!_blacklist.isBlacklisted(videoId, c.clientUsed, c.itag)) return c;
    }
    return null;
  }

  // ── _maybeUpgradePlaying ────────────────────────────────────────────────────
  void _maybeUpgradePlaying(ProcessingState state, bool isPlaying) {
    if (!kDebugMode) return;
    final prev = PlaybackDiagnosticsNotifier.value;
    if (prev == null) return;
    if (prev.stage != PlaybackStage.buffering &&
        prev.stage != PlaybackStage.stalledAfterResolved) return;

    final pos = _player.position;
    final buf = _player.bufferedPosition;
    if (!((state == ProcessingState.ready || state == ProcessingState.buffering) &&
        isPlaying && (pos > Duration.zero || buf > Duration.zero))) return;

    debugPrint('[PLAYER PLAYING CONFIRMED] ${prev.videoId} '
        'client=${prev.clientUsed} attempt=${prev.attempt} '
        'pos=${pos.inMilliseconds}ms buf=${buf.inMilliseconds}ms');

    if (prev.clientUsed.isNotEmpty && prev.clientUsed != '…') {
      _clientPrefs.markSuccess(prev.videoId, prev.clientUsed);
    }

    PlaybackDiagnosticsNotifier.value = prev.copyWith(
      stage:           prev.attempt > 1
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

  // ── Diagnostic helpers ─────────────────────────────────────────────────────
  void _emitResolved(String videoId, ResolvedStream r, DateTime resolveStart, {required int attempt}) {
    if (!kDebugMode) return;
    PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
      PlaybackStage.resolved,
      videoId:           videoId,
      attempt:           attempt,
      candidateKey:      '${r.clientUsed}:${r.itag}',
      blacklistCount:    _blacklist.count(videoId),
      sourceType:        r.sourceType,
      mimeType:          r.mimeType,
      clientUsed:        r.clientUsed,
      itag:              r.itag,
      expiresAt:         r.expiresAt,
      urlHost:           Uri.parse(r.url).host,
      resolveStartedAt:  resolveStart,
      resolveFinishedAt: DateTime.now(),
    );
  }

  void _emitResolveFailure(String videoId, Object e, DateTime resolveStart, {required int attempt}) {
    if (!kDebugMode) return;
    final isTimeout = e.toString().toLowerCase().contains('timeout');
    final stage = isTimeout
        ? PlaybackStage.failedResolveTimeout
        : PlaybackStage.failedResolveHttp;
    final re = e is MediaResolveException ? e : null;
    PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
      stage,
      videoId:           videoId,
      attempt:           attempt,
      blacklistCount:    _blacklist.count(videoId),
      resolveStartedAt:  resolveStart,
      resolveFinishedAt: DateTime.now(),
      workerHttpStatus:  re?.httpStatus ?? 0,
      workerErrorBody:   re?.errorBody,
      lastError:         e.toString(),
      failureSource:     FailureSource.resolve,
    );
  }

  // ── Controls ───────────────────────────────────────────────────────────────
  @override Future<void> play()  async { await _player.play(); }
  @override Future<void> pause() async { await _player.pause(); }
  @override Future<void> seek(Duration position) async { await _player.seek(position); }
  @override void prefetchNext(String videoId) {}

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
