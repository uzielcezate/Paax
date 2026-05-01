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

  PlaybackController() {
    _engine = getPlaybackEngine();
    _initEngine();
  }

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
      if (_isPlaying != playing) {
        _isPlaying = playing;
        // Pass current position so the notification doesn't reset to 00:00 on pause
        updateMediaSessionPlaybackState(isPlaying: playing, position: _position);
        notifyListeners();
      }
    });
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

  Future<void> _playCurrent() async {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;

    final track = _queue[_currentIndex];

    // Immediately notify so UI shows title/artwork/track info
    _errorMessage    = null;
    _isLoadingTrack  = true;
    _position        = Duration.zero;
    _duration        = Duration.zero;
    positionNotifier.value = Duration.zero;
    durationNotifier.value = Duration.zero;
    notifyListeners();

    bool loadFailed = false;
    try {
      await _engine.load(track.id);
      // Kick off background prefetch for the next track (best-effort,
      // fire-and-forget via the engine — no-op if backend handles caching).
      final upcoming = _upcomingTrackIds(count: 1);
      for (final id in upcoming) {
        _engine.prefetchNext(id);
      }
    } catch (e) {
      loadFailed = true;
      _errorMessage   = 'Playback unavailable: ${e.toString().replaceFirst('Exception: ', '')}';
      _isLoadingTrack = false;
      _isPlaying      = false;
      notifyListeners();
    } finally {
      if (!loadFailed) {
        _isLoadingTrack = false;
        // Don't call notifyListeners — playingStream/durationStream will

        // Update the Web Media Session with track metadata + wire up
        // lock-screen / notification controls.
        setMediaSession(
          track: track,
          onPlay: () => _engine.play(),
          onPause: () => _engine.pause(),
          onNext: () => playNext(),
          onPrevious: () => playPrevious(),
        );
      }
    }
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

