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
      if (_loopMode == LoopMode.one) {
        seek(Duration.zero);
        _engine.play();
      } else {
        playNext();
      }
    });

    _engine.positionStream.listen((p) {
      if (_isScrubbing) return;
      final now = DateTime.now();
      if (now.difference(lastUpdate).inMilliseconds < 250) return;
      if (p < lastEmittedPosition && (lastEmittedPosition - p).inSeconds < 2) return;
      lastUpdate = now;
      lastEmittedPosition = p;
      positionNotifier.value = p;
      _position = p;
    });

    _engine.durationStream.listen((d) {
      if (_duration != d) {
        _duration = d;
        durationNotifier.value = d;
        // Dynamically update the notification's MediaItem with the real duration
        // reported by the WebView (fixes static progress bar when track.duration was 0)
        if (d > Duration.zero) {
          updateMediaSessionDuration(d);
        }
        notifyListeners();
      }
    });

    _engine.playingStream.listen((playing) {
      // While a new track is loading, ignore a stale "playing" event from the
      // previous video so we never show the not-yet-confirmed track as playing.
      if (playing && _isLoadingTrack) return;
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

  Future<void> playNext() async {
    if (_queue.isEmpty) return;

    int nextIndex = -1;

    if (_isShuffle) {
      if (_queue.length > 1) {
        final r = Random();
        do {
          nextIndex = r.nextInt(_queue.length);
        } while (nextIndex == _currentIndex);
      } else {
        nextIndex = 0;
      }
    } else {
      if (_currentIndex < _queue.length - 1) {
        nextIndex = _currentIndex + 1;
      } else if (_loopMode == LoopMode.all) {
        nextIndex = 0;
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

    if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrent();
    } else if (_loopMode == LoopMode.all) {
      _currentIndex = _queue.length - 1;
      await _playCurrent();
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

    _errorMessage    = null;
    _position        = Duration.zero;
    _duration        = Duration.zero;
    positionNotifier.value = Duration.zero;
    durationNotifier.value = Duration.zero;

    // Eager legacy path: Track.id IS the videoId. An empty id means this track
    // has no playable match — do NOT switch to it (the previous track's audio
    // is still playing); restore the confirmed track and surface the error.
    if (videoId.isEmpty) {
      _failPlayback(myGen, track);
      return;
    }

    // Show the pending track as LOADING (not playing) — responsive but truthful.
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
      _failPlayback(myGen, track);
      return;
    }

    // Confirmed: the iframe accepted and started the new video. Commit it.
    _confirmedQueue = List.from(_queue);
    _confirmedIndex = _currentIndex;
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

  /// Playback failed for [track]: never present it as playing; restore the last
  /// confirmed track state (its audio may still be running) and show the safe
  /// retryable message. Best-effort failure report.
  void _failPlayback(int myGen, Track track) {
    if (myGen != _playGeneration) return;
    _isLoadingTrack = false;
    _isPlaying      = false;
    _errorMessage   = 'Unable to play this track';
    if (_confirmedIndex >= 0 && _confirmedIndex < _confirmedQueue.length) {
      _queue        = List.from(_confirmedQueue);
      _currentIndex = _confirmedIndex;
    }
    notifyListeners();
    _reportPlaybackFailure(track);
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

