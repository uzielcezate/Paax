import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import '../../domain/entities/track.dart';
import '../../core/playback/playback_engine.dart';
import '../../core/playback/playback_factory.dart';
import '../../core/playback/paax_audio_handler.dart';

// Platform-conditional import — web gets the real Media Session API interop,
// everything else gets a silent no-op stub.
import '../../core/playback/media_session_stub.dart'
    if (dart.library.html) '../../core/playback/media_session_web.dart';

/// Loop mode — kept local to avoid importing just_audio on web.
enum LoopMode { off, all, one }

class PlaybackController extends ChangeNotifier {
  late final PlaybackEngine _engine;

  List<Track> _queue = [];
  int _currentIndex = -1;

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.off;

  /// True while the stream URL is being resolved / audio source is loading.
  bool _isLoadingTrack = false;

  /// Non-null when the last load attempt failed. UI should show a snackbar.
  String? _errorMessage;

  // ── Play transaction (Phase 3.3.1 §4) ────────────────────────────────────
  // A monotonically increasing token identifies the current play request so a
  // late iframe callback or a superseded selection can never confirm the wrong
  // track. `_confirmed*` snapshots the last state that actually started playing,
  // so a failed load can restore truthful state instead of leaving new metadata
  // over the previous (still-playing) audio.
  int _playGeneration = 0;
  List<Track> _confirmedQueue = [];
  int _confirmedIndex = -1;
  // Confirmed playback state, updated by the engine listeners only while NOT in
  // a transaction, so the rollback snapshot never captures a loading track's
  // zeroed transient state (Phase 3.3.2 issue 1 / review H1).
  bool _confirmedIsPlaying = false;
  Duration _confirmedPosition = Duration.zero;
  Duration _confirmedDuration = Duration.zero;

  // Getters
  List<Track> get queue => _queue;
  int get currentIndex => _currentIndex;
  Track? get currentTrack =>
      _currentIndex >= 0 && _currentIndex < _queue.length ? _queue[_currentIndex] : null;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get duration => _duration;
  /// True only when the player has reported a real, positive duration.
  bool get durationKnown => _duration > Duration.zero;
  bool get isShuffle => _isShuffle;
  LoopMode get loopMode => _loopMode;
  bool get isLoadingTrack => _isLoadingTrack;
  String? get errorMessage => _errorMessage;

  /// Tracks coming after the currently playing track.
  List<Track> get upcomingQueue =>
      _currentIndex >= 0 && _currentIndex < _queue.length - 1
          ? _queue.sublist(_currentIndex + 1)
          : [];

  /// True if there are upcoming tracks in the queue.
  bool get hasUpcoming => upcomingQueue.isNotEmpty;

  // Notifiers for high-frequency updates (avoid full rebuilds)
  final positionNotifier = ValueNotifier<Duration>(Duration.zero);
  final durationNotifier = ValueNotifier<Duration>(Duration.zero);

  /// [engine] is injectable for tests; production uses the platform engine.
  PlaybackController({PlaybackEngine? engine}) {
    _engine = engine ?? getPlaybackEngine();
    _initialized = _initEngine();
  }

  /// Completes once engine init + stream wiring is done (test synchronization).
  late final Future<void> _initialized;
  Future<void> get initialized => _initialized;

  // Scrubbing state to prevent UI jitter
  bool _isScrubbing = false;

  Future<void> seek(Duration position) async {
    positionNotifier.value = position;
    _position = position;
    debugPrint('[MEDIA SEEK] ${position.inSeconds}s');
    await _engine.seek(position);
  }

  Future<void> endScrubbing(Duration position) async {
    _position = position;
    positionNotifier.value = position;
    await _engine.seek(position);
    await Future.delayed(const Duration(milliseconds: 200));
    _isScrubbing = false;
  }

  // ── Engine listeners ────────────────────────────────────────────────────────
  Future<void> _initEngine() async {
    await _engine.initialize();

    // Wire AudioHandler's seek callback to our engine
    globalAudioHandler?.onSeek = (position) => seek(position);

    DateTime lastUpdate = DateTime.now();
    Duration lastEmittedPosition = Duration.zero;

    _engine.completionStream.listen((_) {
      // Ignore completion while a new-track transaction is resolving — a failing
      // load's stray "ended" must not advance the queue (Phase 3.3.2 issue 1).
      if (_isLoadingTrack) return;
      if (_loopMode == LoopMode.one) {
        seek(Duration.zero);
        _engine.play();
      } else {
        playNext();
      }
    });

    _engine.positionStream.listen((p) {
      if (_isScrubbing) return;
      // During a transaction the engine is loading/failing a DIFFERENT video;
      // its position must not overwrite the confirmed track's (issue 1).
      if (_isLoadingTrack) return;
      final now = DateTime.now();
      if (now.difference(lastUpdate).inMilliseconds < 250) return;
      if (p < lastEmittedPosition && (lastEmittedPosition - p).inSeconds < 2) return;
      lastUpdate = now;
      lastEmittedPosition = p;
      positionNotifier.value = p;
      _position = p;
      _confirmedPosition = p; // keep the confirmed snapshot source current
    });

    _engine.durationStream.listen((d) {
      // NOT gated (review M2): duration is emitted once, on the playing state;
      // gating could drop it forever if it lands during a load. A duration for
      // the loading video is harmless (overwritten on confirm/rollback), but we
      // only advance the CONFIRMED store when not in a transaction.
      if (_duration != d) {
        _duration = d;
        durationNotifier.value = d;
        if (d > Duration.zero) {
          updateMediaSessionDuration(d);
        }
        notifyListeners();
      }
      if (!_isLoadingTrack) _confirmedDuration = d;
    });

    _engine.playingStream.listen((playing) {
      // While a new-track transaction is resolving, ignore ALL playing/paused
      // events — they belong to the loading/failing video, not the confirmed
      // track. Once the transaction confirms or rolls back, events flow again
      // and reflect the confirmed track (Phase 3.3.2 issue 1).
      if (_isLoadingTrack) return;
      _confirmedIsPlaying = playing; // keep the confirmed snapshot source current
      if (_isPlaying != playing) {
        _isPlaying = playing;
        // Pass current position so the notification doesn't reset to 00:00 on pause
        updateMediaSessionPlaybackState(isPlaying: playing, position: _position);
        notifyListeners();
      }
    });
  }

  // ── Remote media control handlers (notification / lockscreen) ──────────────
  // These are idempotent: play when already playing is a no-op, etc.
  // The engine's play() has its own health-check + rehydration logic.

  Future<void> _handleRemotePlay() async {
    debugPrint('[PlaybackCtrl] Remote PLAY (isPlaying=$_isPlaying)');
    if (_isPlaying) return; // Already playing — no-op
    if (currentTrack == null) return; // Nothing to play

    await _engine.play();
    // Update notification state immediately so the UI reflects the action
    // even if the playingStream callback is delayed
    updateMediaSessionPlaybackState(isPlaying: true, position: _position);
  }

  Future<void> _handleRemotePause() async {
    debugPrint('[PlaybackCtrl] Remote PAUSE (isPlaying=$_isPlaying)');
    if (!_isPlaying) return; // Already paused — no-op

    await _engine.pause();
    updateMediaSessionPlaybackState(isPlaying: false, position: _position);
  }

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  /// True when the track at [i] has a usable (non-empty) playable id.
  bool _isPlayableIndex(int i) =>
      i >= 0 && i < _queue.length && _queue[i].id.trim().isNotEmpty;

  Future<void> playNext() async {
    if (_queue.isEmpty) return;

    int nextIndex = -1;

    if (_isShuffle) {
      // Skip un-playable tracks: try a bounded number of random picks.
      if (_queue.length > 1) {
        final r = Random();
        for (var attempt = 0; attempt < _queue.length * 2; attempt++) {
          final candidate = r.nextInt(_queue.length);
          if (candidate != _currentIndex && _isPlayableIndex(candidate)) {
            nextIndex = candidate;
            break;
          }
        }
      } else if (_isPlayableIndex(0)) {
        nextIndex = 0;
      }
    } else {
      // Sequential: advance to the next PLAYABLE track (§4/M3) so an unplayable
      // (empty-id) track never stalls autoplay; honor loop-all wraparound once.
      var i = _currentIndex + 1;
      final end = _loopMode == LoopMode.all ? _currentIndex + _queue.length : _queue.length - 1;
      while (i <= end) {
        final idx = i % _queue.length;
        if (idx != _currentIndex && _isPlayableIndex(idx)) {
          nextIndex = idx;
          break;
        }
        i++;
      }
    }

    if (nextIndex >= 0) {
      debugPrint('[MEDIA NEXT TRACK] index=$nextIndex id=${_queue[nextIndex].id}');
      _currentIndex = nextIndex;
      await _playCurrent();
    }
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;

    if (_position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    // Step back to the previous PLAYABLE track (skip unplayable ones).
    var i = _currentIndex - 1;
    final floor = _loopMode == LoopMode.all ? _currentIndex - _queue.length : 0;
    while (i >= floor) {
      final idx = ((i % _queue.length) + _queue.length) % _queue.length;
      if (idx != _currentIndex && _isPlayableIndex(idx)) {
        _currentIndex = idx;
        await _playCurrent();
        return;
      }
      i--;
    }
  }

  /// Play-transaction state machine (Phase 3.3.1 §4).
  ///
  /// Truthfulness invariant: the visible current track is never presented as
  /// playing until we have a non-empty videoId AND the iframe accepts the new
  /// media (buffering/playing/cued). An empty/invalid id or a load
  /// failure/timeout keeps or restores the previously-confirmed track and shows
  /// the safe error — it never leaves new metadata over the prior audio.
  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;

    final myGen = ++_playGeneration;
    final track = _queue[_currentIndex];
    final videoId = track.id.trim();

    // Atomic snapshot of the CONFIRMED playback state (NOT the live fields — a
    // superseded in-flight transaction may have already zeroed those; review H1)
    // so a failed attempt restores the confirmed track exactly (issue 1).
    final snap = _PlaybackSnapshot(
      queue: List<Track>.from(_confirmedQueue),
      index: _confirmedIndex,
      isPlaying: _confirmedIsPlaying,
      position: _confirmedPosition,
      duration: _confirmedDuration,
    );

    _errorMessage = null;

    // Eager legacy path: Track.id IS the videoId. An empty id means this track
    // has no playable match — do NOT touch the engine or the confirmed track's
    // state (its audio keeps playing); restore the full snapshot and show error.
    if (videoId.isEmpty) {
      _failPlayback(myGen, track, snap, loadIssued: false);
      return;
    }

    // Non-empty: a new video will be loaded. Reset transient progress and show
    // the pending track as LOADING (not playing). While _isLoadingTrack is true
    // the persistent engine listeners are gated, so the failing video's events
    // can't corrupt the confirmed state.
    _position = Duration.zero;
    _duration = Duration.zero;
    positionNotifier.value = Duration.zero;
    durationNotifier.value = Duration.zero;
    _isLoadingTrack = true;
    _isPlaying      = false;
    notifyListeners();

    bool started;
    try {
      await _engine.load(videoId);
      started = await _awaitPlaybackStart(myGen);
    } catch (_) {
      started = false;
    }

    // A newer selection superseded this one — abandon; the newer call owns state.
    if (myGen != _playGeneration) return;

    if (!started) {
      // The load WAS issued (engine now holds this failed video), so restoring
      // must also re-cue the confirmed track's audio, not just its metadata.
      _failPlayback(myGen, track, snap, loadIssued: true);
      return;
    }

    // Confirmed: the iframe accepted and started the new video. Commit it and
    // seed the confirmed store (load() autoplays; duration fills in shortly).
    _confirmedQueue = List.from(_queue);
    _confirmedIndex = _currentIndex;
    _confirmedIsPlaying = true;
    _confirmedPosition = Duration.zero;
    _confirmedDuration = _duration;
    _isLoadingTrack = false;

    for (final id in _upcomingTrackIds(count: 1)) {
      _engine.prefetchNext(id);
    }
    // Media session (lock-screen / notification). Idempotent handlers.
    setMediaSession(
      track: track,
      onPlay: _handleRemotePlay,
      onPause: _handleRemotePause,
      onNext: () => playNext(),
      onPrevious: () => playPrevious(),
    );
    notifyListeners();
  }

  /// Waits for the iframe to accept the just-issued load: resolves true on the
  /// new video buffering/playing/cued, false on error/immediate-end/timeout.
  /// Guards against a stale "playing" from the PREVIOUS video by requiring a
  /// fresh load-begin (unstarted/buffering) before accepting a `playing` event.
  Future<bool> _awaitPlaybackStart(int gen) async {
    final completer = Completer<bool>();
    var loadBegan = false;
    StreamSubscription<int>? stateSub;
    StreamSubscription<int>? errorSub;
    Timer? timeout;

    void done(bool ok) {
      if (completer.isCompleted) return;
      stateSub?.cancel();
      errorSub?.cancel();
      timeout?.cancel();
      completer.complete(ok);
    }

    stateSub = _engine.playerStateStream.listen((st) {
      if (gen != _playGeneration) return done(false);
      switch (st) {
        case -1: // unstarted (a fresh load began)
          loadBegan = true;
          break;
        case 3: // buffering the new video → accepted
        case 5: // cued
          done(true);
          break;
        case 1: // playing — only trust it after a fresh load began
          if (loadBegan) done(true);
          break;
        case 0: // ended after a fresh load → treat as failure
          if (loadBegan) done(false);
          break;
      }
    });
    errorSub = _engine.errorStream.listen((_) {
      if (gen != _playGeneration) return done(false);
      done(false);
    });
    // Explicit bound — never rely on an upstream 40s timeout.
    timeout = Timer(const Duration(seconds: 12), () => done(false));

    return completer.future;
  }

  /// Playback failed for [failed]: never present it as playing. Restore the FULL
  /// confirmed playback snapshot ([snap]) — track identity, play/pause state,
  /// position and duration — so a failed attempt has no observable effect on the
  /// confirmed track except the error message (Phase 3.3.2 issue 1). Best-effort
  /// failure report.
  void _failPlayback(int myGen, Track failed, _PlaybackSnapshot snap,
      {required bool loadIssued}) {
    if (myGen != _playGeneration) return;
    _isLoadingTrack = false;
    _errorMessage   = 'Unable to play this track';

    if (snap.index >= 0 && snap.index < snap.queue.length) {
      // Atomic restore of the confirmed state (live + confirmed store).
      _queue         = List.from(snap.queue);
      _currentIndex  = snap.index;
      _confirmedQueue = List.from(snap.queue);
      _confirmedIndex = snap.index;
      _isPlaying     = snap.isPlaying;
      _position      = snap.position;
      _duration      = snap.duration;
      _confirmedIsPlaying = snap.isPlaying;
      _confirmedPosition  = snap.position;
      _confirmedDuration  = snap.duration;
      positionNotifier.value = snap.position;
      durationNotifier.value = snap.duration;

      if (loadIssued) {
        // A load was issued for the failed track, so the engine replaced the
        // confirmed track's video. Re-cue it and restore position + play state
        // so engine and controller agree (empty-id path never loaded, so the
        // confirmed track is still playing untouched and needs no reload).
        final restored = snap.queue[snap.index];
        final rid = restored.id.trim();
        if (rid.isNotEmpty) {
          // ignore: discarded_futures
          _recueConfirmed(rid, snap.position, snap.isPlaying);
        }
      }
    } else {
      // Nothing was ever confirmed — clear so only the error surfaces.
      _queue        = [];
      _currentIndex = -1;
      _confirmedQueue = [];
      _confirmedIndex = -1;
      _isPlaying    = false;
      _position     = Duration.zero;
      _duration     = Duration.zero;
      _confirmedIsPlaying = false;
      _confirmedPosition  = Duration.zero;
      _confirmedDuration  = Duration.zero;
      positionNotifier.value = Duration.zero;
      durationNotifier.value = Duration.zero;
    }
    notifyListeners();
    _reportPlaybackFailure(failed);
  }

  /// Re-cue the confirmed track after its video was interrupted by a failed
  /// load: reload, seek to the prior position, and restore the play/pause state.
  Future<void> _recueConfirmed(String videoId, Duration position, bool wasPlaying) async {
    try {
      await _engine.load(videoId);
      if (position > Duration.zero) {
        await _engine.seek(position);
      }
      if (!wasPlaying) {
        await _engine.pause();
      }
    } catch (_) {
      // Best-effort — the persistent listeners will reconcile from engine events.
    }
  }

  /// Best-effort playback-failure signal (existing reporting path). Safe no-op
  /// when there is nothing resolvable to report.
  void _reportPlaybackFailure(Track track) {
    debugPrint('[PlaybackCtrl] Playback failure for "${track.title}" '
        '(videoId="${track.id}", deezerTrackId=${track.deezerTrackId})');
    // Eager legacy tracks carry no catalog UUID here, so there is no normalized
    // report endpoint to call without a resolve; kept as a safe extension point.
  }

  Future<void> playQueue(List<Track> tracks, {int index = 0}) async {
    if (tracks.isEmpty) return;
    _queue = List.from(tracks);
    _currentIndex = index;
    if (_currentIndex < 0 || _currentIndex >= _queue.length) _currentIndex = 0;
    await _playCurrent();
  }

  Future<void> playTrack(Track track) async {
    await playQueue([track]);
  }

  /// Returns the IDs of the next [count] tracks in queue order,
  /// respecting loop. Skips shuffle (can't predict random picks).
  List<String> _upcomingTrackIds({int count = 2}) {
    if (_queue.isEmpty || _isShuffle) return [];
    final ids = <String>[];
    for (var i = 1; i <= count; i++) {
      final idx = _currentIndex + i;
      if (idx < _queue.length) {
        ids.add(_queue[idx].id);
      } else if (_loopMode == LoopMode.all && _queue.isNotEmpty) {
        ids.add(_queue[idx % _queue.length].id);
      }
    }
    return ids;
  }

  // ── Queue management ──────────────────────────────────────────────────────

  void addToQueue(Track track) {
    _queue.add(track);
    notifyListeners();
  }

  /// Jump to a specific absolute index in the queue and start playing.
  Future<void> playFromQueue(int absoluteIndex) async {
    if (absoluteIndex < 0 || absoluteIndex >= _queue.length) return;
    _currentIndex = absoluteIndex;
    await _playCurrent();
  }

  /// Remove a track at [absoluteIndex] from the queue.
  /// If removing the current track, play the next one.
  /// If removing before the current track, adjust _currentIndex.
  void removeFromQueue(int absoluteIndex) {
    if (absoluteIndex < 0 || absoluteIndex >= _queue.length) return;
    if (_queue.length <= 1) return; // Don't remove the last track

    if (absoluteIndex == _currentIndex) {
      // Removing the currently playing track — play next
      _queue.removeAt(absoluteIndex);
      if (_currentIndex >= _queue.length) _currentIndex = 0;
      _playCurrent();
    } else {
      if (absoluteIndex < _currentIndex) {
        _currentIndex--;
      }
      _queue.removeAt(absoluteIndex);
      notifyListeners();
    }
  }

  /// Reorder within the upcoming portion of the queue.
  /// [oldIndex] and [newIndex] are relative to the upcoming list
  /// (i.e., 0 = first track after current).
  void reorderQueue(int oldIndex, int newIndex) {
    final start = _currentIndex + 1;
    final absOld = start + oldIndex;
    var absNew = start + newIndex;

    if (absOld < 0 || absOld >= _queue.length) return;
    if (absNew < start) absNew = start;
    if (absNew > _queue.length) absNew = _queue.length;

    if (absOld == absNew) return;

    final track = _queue.removeAt(absOld);
    // After removal, adjust target if it was after the source
    if (absNew > absOld) absNew--;
    _queue.insert(absNew, track);
    notifyListeners();
  }

  /// Clear all upcoming tracks (everything after current).
  void clearUpcoming() {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
    if (_currentIndex < _queue.length - 1) {
      _queue.removeRange(_currentIndex + 1, _queue.length);
      notifyListeners();
    }
  }

  void startScrubbing() => _isScrubbing = true;

  void toggleShuffle() {
    _isShuffle = !_isShuffle;
    notifyListeners();
  }

  void toggleLoop() {
    if (_loopMode == LoopMode.off) {
      _loopMode = LoopMode.all;
    } else if (_loopMode == LoopMode.all) {
      _loopMode = LoopMode.one;
    } else {
      _loopMode = LoopMode.off;
    }
    notifyListeners();
  }

  /// Clears a previously shown error so the UI can dismiss the snackbar.
  void clearError() {
    _errorMessage = null;
  }

  Widget buildPlayerView(BuildContext context) => _engine.buildPlayerView(context);

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }
}

/// An atomic snapshot of the confirmed playback state, used to roll back after a
/// failed play attempt (Phase 3.3.2 issue 1).
class _PlaybackSnapshot {
  final List<Track> queue;
  final int index;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  const _PlaybackSnapshot({
    required this.queue,
    required this.index,
    required this.isPlaying,
    required this.position,
    required this.duration,
  });
}

