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
// PlaybackEngineImpl — diverse retry, truthful state machine
// ---------------------------------------------------------------------------
//
// RETRY POLICY (max 4 total attempts):
// ─────────────────────────────────────────────────────────────────────────────
//   Attempt 1 — Initial resolve (uses ClientPreferenceCache hint)
//     plays: candidates[0] from initial resolve (e.g. ANDROID:140)
//     on stall:  blacklist ANDROID:140 → move to Attempt 2
//
//   Attempt 2 — ONE local same-client format fallback
//     picks: next non-blacklisted candidate from same local list (ANDROID:139)
//     on stall:  blacklist ANDROID:139 → move to Attempt 3
//     *** THIS IS THE LAST LOCAL PICK ***  After attempt 2, we ALWAYS force
//     a new-client re-resolve regardless of remaining local candidates.
//
//   Attempt 3 — Guaranteed new Innertube client
//     calls: resolve(videoId, excludeClients: [ANDROID])
//     → Worker skips ANDROID, picks ANDROID_VR / IOS / etc.
//     plays: new candidate (e.g. ANDROID_VR:140)
//     on stall:  blacklist → move to Attempt 4
//
//   Attempt 4 — Final new-client attempt
//     (same pattern, excludes more clients)
//     on stall:  fallbackRetryFailed (exhausted)
//
// KEY INVARIANT: _tryNextCandidate("force new client") is triggered when
//   attempt >= 2, regardless of whether the local candidates list still has
//   entries from the same client.  This guarantees attempt 3 is ALWAYS a
//   different Innertube client.
//
// "playing" stage set ONLY when ExoPlayer confirms bytes are moving:
//   ProcessingState.ready/buffering + isPlaying + (pos>0 OR buf>0)
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

// Total attempts allowed: 1 initial + 1 same-client local + 2 new-client resolves
const int _kMaxAttempts = 4;

// After this many consecutive stalls, stop picking local candidates and force
// a new-client re-resolve. Set to 1 = only attempt 1 uses local; attempt 2+ always new-client.
const int _kLocalFallbackLimit = 1;

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
  int  _loadId     = 0;

  // Candidates from initial resolve only — cleared on each new load
  List<StreamCandidate> _candidates = [];

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

    _blacklist.clearForVideo(videoId);
    _candidates = [];

    await _player.stop();
    if (_loadId != myId) return;

    final resolveStart = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value =
          PlaybackDiagnostics.resolving(videoId, resolveStartedAt: resolveStart, attempt: 1);
    }

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

    final primary = _pickLocalCandidate(videoId);
    if (primary == null) {
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId: videoId, lastError: 'Worker returned no playable candidates',
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
        videoId: videoId, attempt: attempt,
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
          videoId: videoId, attempt: attempt,
          candidateKey:       candidate.key, blacklistCount: _blacklist.count(videoId),
          sourceType:         candidate.sourceType, mimeType: candidate.mimeType,
          clientUsed:         candidate.clientUsed, itag: candidate.itag,
          urlHost:            uri.host, resolveStartedAt: resolveStart,
          resolveFinishedAt:  resolveEnd, setSourceCalled: true,
          setSourceSucceeded: true, processingState: _player.processingState.name,
        );
      }
    } on PlayerException catch (e) {
      final errMsg = 'PlayerException code=${e.code} msg=${e.message ?? 'unknown'}';
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId $errMsg');
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, attempt: attempt,
          candidateKey: candidate.key, blacklistCount: _blacklist.count(videoId),
          clientUsed: candidate.clientUsed, itag: candidate.itag, urlHost: uri.host,
          setSourceCalled: true, setSourceError: errMsg, lastError: errMsg,
          failureSource: FailureSource.playback,
        );
      }
      await _handleStall(videoId: videoId, myId: myId,
          resolveStart: resolveStart, resolveEnd: resolveEnd,
          attempt: attempt, candidate: candidate,
          reason: errMsg, source: FailureSource.playback);
      return;
    } catch (e) {
      final errMsg = 'setAudioSource error: $e';
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedSetSource,
          videoId: videoId, attempt: attempt,
          candidateKey: candidate.key, blacklistCount: _blacklist.count(videoId),
          setSourceCalled: true, lastError: errMsg, failureSource: FailureSource.playback,
        );
      }
      await _handleStall(videoId: videoId, myId: myId,
          resolveStart: resolveStart, resolveEnd: resolveEnd,
          attempt: attempt, candidate: candidate,
          reason: errMsg, source: FailureSource.playback);
      return;
    }

    if (_loadId != myId) return;

    // ── play() ─────────────────────────────────────────────────────────────────
    final playCallTime = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.buffering,
        videoId: videoId, attempt: attempt,
        candidateKey:       candidate.key, blacklistCount: _blacklist.count(videoId),
        sourceType:         candidate.sourceType, mimeType: candidate.mimeType,
        clientUsed:         candidate.clientUsed, itag: candidate.itag,
        urlHost:            uri.host, resolveStartedAt: resolveStart,
        resolveFinishedAt:  resolveEnd, setSourceCalled: true,
        setSourceSucceeded: true, playCalled: true,
        processingState:    _player.processingState.name,
      );
    }

    bool playOk = false;
    try {
      await _player.seek(Duration.zero);
      await _player.play();
      playOk = true;
      debugPrint('[PLAYER PLAY] $videoId attempt=$attempt candidate=${candidate.key} '
          'state=${_player.processingState.name} playing=${_player.playing}');
    } catch (e) {
      _blacklist.blacklist(videoId, candidate.clientUsed, candidate.itag);
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          PlaybackStage.failedBuffering,
          videoId: videoId, attempt: attempt,
          candidateKey: candidate.key, blacklistCount: _blacklist.count(videoId),
          clientUsed: candidate.clientUsed, itag: candidate.itag, urlHost: uri.host,
          setSourceCalled: true, setSourceSucceeded: true,
          playCalled: true, lastError: 'play() threw: $e',
          failureSource: FailureSource.playback,
        );
      }
      await _handleStall(videoId: videoId, myId: myId,
          resolveStart: resolveStart, resolveEnd: resolveEnd,
          attempt: attempt, candidate: candidate,
          reason: 'play() threw: $e', source: FailureSource.playback);
      return;
    }

    if (_loadId != myId) return;

    if (kDebugMode) {
      final prev = PlaybackDiagnosticsNotifier.value;
      if (prev != null) {
        PlaybackDiagnosticsNotifier.value = prev.copyWith(
          playSucceeded: true, processingState: _player.processingState.name,
          isPlaying: _player.playing, position: _player.position,
          buffered: _player.bufferedPosition, duration: _player.duration ?? Duration.zero,
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
      if (kDebugMode) {
        final d = PlaybackDiagnosticsNotifier.value;
        if (d == null || d.videoId != guardVideoId) return;
      }

      final pos     = _player.position;
      final buf     = _player.bufferedPosition;
      final state   = _player.processingState;
      final playing = _player.playing;
      final bytesMoving = pos > Duration.zero || buf > Duration.zero;

      debugPrint('[STALL GUARD] $guardVideoId attempt=$guardAttempt '
          'candidate=${guardCandidate.key} pos=${pos.inMilliseconds}ms '
          'buf=${buf.inMilliseconds}ms state=${state.name} bytes=$bytesMoving');

      if (bytesMoving) return;

      _blacklist.blacklist(guardVideoId, guardCandidate.clientUsed, guardCandidate.itag);
      final elapsed = DateTime.now().difference(playCallTime).inSeconds;
      final isFalsePlaying = kDebugMode &&
          PlaybackDiagnosticsNotifier.value?.stage == PlaybackStage.playing;

      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
          isFalsePlaying ? PlaybackStage.falsePlayingDetected : PlaybackStage.failedBuffering,
          videoId:        guardVideoId, attempt: guardAttempt,
          candidateKey:   guardCandidate.key, blacklistCount: _blacklist.count(guardVideoId),
          clientUsed:     guardCandidate.clientUsed, itag: guardCandidate.itag,
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

      await _handleStall(
        videoId: guardVideoId, myId: guardId,
        resolveStart: guardRStart, resolveEnd: guardREnd,
        attempt: guardAttempt, candidate: guardCandidate,
        reason: 'no bytes after ${elapsed}s (state=${state.name})',
        source: FailureSource.playback,
      );
    });
  }

  // ── _handleStall ────────────────────────────────────────────────────────────
  // Decides whether to pick another local candidate or force a new-client resolve.
  //
  // LOCAL PICK:  only for attempt 1 → attempt 2  (attempt < 1 + _kLocalFallbackLimit)
  // CLIENT SWITCH: attempt 2 onwards always forces new-client re-resolve
  //
  // This is the critical fix: prevents attempt 3 from picking ANDROID:599 locally.
  Future<void> _handleStall({
    required String          videoId,
    required int             myId,
    required DateTime        resolveStart,
    required DateTime        resolveEnd,
    required int             attempt,
    required StreamCandidate candidate,
    required String          reason,
    required FailureSource   source,
  }) async {
    if (_loadId != myId || _isDisposed) return;
    if (attempt >= _kMaxAttempts) {
      debugPrint('[PLAYER RETRY] $videoId max attempts ($attempt/$_kMaxAttempts) reached');
      if (kDebugMode) {
        // Preserve existing diagnostic snapshot — just flip stage and error.
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId: videoId, attempt: attempt,
          blacklistCount: _blacklist.count(videoId),
        )).copyWith(
          stage:          PlaybackStage.fallbackRetryFailed,
          stageEnteredAt: DateTime.now(),
          failureSource:  source,
          blacklistCount: _blacklist.count(videoId),
          lastError: 'All $_kMaxAttempts attempts exhausted. Last: $reason',
        );
      }
      return;
    }

    final nextAttempt = attempt + 1;
    debugPrint('[PLAYER RETRY] $videoId attempt=$nextAttempt reason=$reason '
        'localAllowed=${attempt <= _kLocalFallbackLimit}');

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
        PlaybackStage.fallbackRetryStarted,
        videoId:        videoId, attempt: nextAttempt,
        blacklistCount: _blacklist.count(videoId),
        failureSource:  source, lastError: reason,
      );
    }

    await _player.stop();
    if (_loadId != myId) return;

    // ── Option A: ONE local format fallback (only transition 1→2) ──────────
    // Uses local candidates so we avoid a Worker round-trip for a cheap second try.
    if (attempt <= _kLocalFallbackLimit) {
      final local = _pickLocalCandidate(videoId);
      if (local != null) {
        debugPrint('[PLAYER RETRY] $videoId → local candidate=${local.key} (same client, diff format)');
        await _playCandidate(
          videoId: videoId, candidate: local, myId: myId,
          resolveStart: resolveStart, resolveEnd: resolveEnd, attempt: nextAttempt,
        );
        return;
      }
      // No local candidate available — fall through to new-client resolve
      debugPrint('[PLAYER RETRY] $videoId no local candidate found — going to new-client resolve');
    }
    // ── Option B: New Innertube client (always for attempt 2+ stalls) ───────
    await _resolveWithNewClient(
      videoId: videoId, myId: myId,
      resolveStart: resolveStart, attempt: nextAttempt,
      source: source,
    );
  }

  // ── _resolveWithNewClient ─────────────────────────────────────────────────
  Future<void> _resolveWithNewClient({
    required String       videoId,
    required int          myId,
    required DateTime     resolveStart,
    required int          attempt,
    required FailureSource source,
  }) async {
    if (_loadId != myId || _isDisposed) return;

    final failedClients = _blacklist.failedClients(videoId).toList();
    debugPrint('[PLAYER RETRY] $videoId → new-client resolve '
        'exclude=[${failedClients.join(',')}]');

    final freshStart = DateTime.now();
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(
        videoId, resolveStartedAt: freshStart, attempt: attempt,
        excludedClients: failedClients,
      ).copyWith(blacklistCount: _blacklist.count(videoId));
    }

    _clientPrefs.invalidate(videoId);
    await _resolver.invalidate(videoId);

    ResolvedStream freshResolved;
    try {
      freshResolved = await _resolver.resolve(videoId, excludeClients: failedClients);
    } catch (e) {
      debugPrint('[PLAYER RETRY FAIL] $videoId re-resolve failed: $e');
      // _emitResolveFailure sets all worker metadata (httpStatus, attemptedClients,
      // clientErrors, excludedClients). We then upgrade the stage to fallbackRetryFailed
      // using copyWith so none of that data is lost.
      _emitResolveFailure(videoId, e, freshStart,
          attempt: attempt, excludedClients: failedClients);
      if (kDebugMode) {
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId: videoId, attempt: attempt,
          blacklistCount: _blacklist.count(videoId),
        )).copyWith(
          stage:          PlaybackStage.fallbackRetryFailed,
          stageEnteredAt: DateTime.now(),
          failureSource:  FailureSource.resolve,
          blacklistCount: _blacklist.count(videoId),
          lastError: 'Re-resolve failed exclude=[${failedClients.join(',')}]: $e',
        );
      }
      return;
    }

    if (_loadId != myId) return;

    // Merge new-client candidates into list
    for (final c in freshResolved.candidates) {
      if (!_candidates.any((x) => x.key == c.key)) _candidates.add(c);
    }

    _emitResolved(videoId, freshResolved, freshStart, attempt: attempt);

    final nextCandidate = _pickLocalCandidate(videoId);
    if (nextCandidate == null) {
      debugPrint('[PLAYER RETRY FAIL] $videoId re-resolve returned only blacklisted candidates');
      if (kDebugMode) {
        // Preserve the resolved metadata (attemptedClients, chosen, candidates) —
        // just upgrade the stage so the overlay keeps all the Worker response info.
        final prev = PlaybackDiagnosticsNotifier.value;
        PlaybackDiagnosticsNotifier.value = (prev ?? PlaybackDiagnostics.atStage(
          PlaybackStage.fallbackRetryFailed,
          videoId: videoId, attempt: attempt,
          blacklistCount: _blacklist.count(videoId),
        )).copyWith(
          stage:          PlaybackStage.fallbackRetryFailed,
          stageEnteredAt: DateTime.now(),
          failureSource:  FailureSource.resolve,
          blacklistCount: _blacklist.count(videoId),
          lastError: 'No new candidate after re-resolve — all from same blacklisted client',
        );
      }
      return;
    }

    debugPrint('[PLAYER RETRY] $videoId attempt=$attempt NEW client=${nextCandidate.key}');
    await _playCandidate(
      videoId: videoId, candidate: nextCandidate, myId: myId,
      resolveStart: freshStart, resolveEnd: DateTime.now(), attempt: attempt,
    );
  }

  // ── _pickLocalCandidate ────────────────────────────────────────────────────
  // Returns first non-blacklisted candidate. Prefers audioOnly over muxed.
  StreamCandidate? _pickLocalCandidate(String videoId) {
    for (final c in _candidates) {
      if (c.sourceType == 'audioOnly' &&
          !_blacklist.isBlacklisted(videoId, c.clientUsed, c.itag)) return c;
    }
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
  void _emitResolved(String videoId, ResolvedStream r, DateTime resolveStart,
      {required int attempt}) {
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
      attemptedClients:  r.attemptedClients,
      excludedClients:   r.excludedClients,
      resolvePath:       r.resolvePath,
      candidateCount:    r.candidateCount,
      clientErrors:      r.clientErrors,
      resolveStartedAt:  resolveStart,
      resolveFinishedAt: DateTime.now(),
    );
  }

  void _emitResolveFailure(
    String   videoId,
    Object   e,
    DateTime resolveStart, {
    required int          attempt,
    List<String>          excludedClients = const [],
  }) {
    if (!kDebugMode) return;
    final isTimeout = e.toString().toLowerCase().contains('timeout');
    final re    = e is MediaResolveException ? e : null;
    final stage = isTimeout
        ? PlaybackStage.failedResolveTimeout
        : PlaybackStage.failedResolveHttp;
    final clientErrors = re?.clientErrors ?? [];
    // Build compact per-client error string for workerErrorBody
    final clientErrorStr = clientErrors.isNotEmpty
        ? clientErrors.map((e) => '${e['client']}: ${e['code']}').join(' | ')
        : null;
    PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.atStage(
      stage,
      videoId:            videoId,
      attempt:            attempt,
      blacklistCount:     _blacklist.count(videoId),
      resolveStartedAt:   resolveStart,
      resolveFinishedAt:  DateTime.now(),
      workerHttpStatus:   re?.httpStatus ?? 0,
      workerErrorBody:    clientErrorStr ?? re?.errorBody,
      // Prefer fields from Worker response; fallback to empty list
      attemptedClients:   (re != null && re.attemptedClients.isNotEmpty)
                              ? re.attemptedClients
                              : [],
      excludedClients:    excludedClients,
      clientErrors:       clientErrors,
      lastError:          e.toString(),
      failureSource:      FailureSource.resolve,
    );
  }

  // ── Controls ────────────────────────────────────────────────────────────────
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

class _EngineException implements Exception {
  final String message;
  const _EngineException(this.message);
  @override String toString() => message;
}
