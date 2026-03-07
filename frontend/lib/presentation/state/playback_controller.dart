import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import '../../domain/entities/track.dart';
import '../../core/playback/playback_engine.dart';
import '../../core/playback/playback_factory.dart';

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
  /// UI should show '--:--' and disable seeking while this is false.
  bool get durationKnown => _duration > Duration.zero;
  bool get isShuffle => _isShuffle;
  LoopMode get loopMode => _loopMode;
  bool get isLoadingTrack => _isLoadingTrack;
  String? get errorMessage => _errorMessage;

  // Notifiers for high-frequency updates (to avoid full rebuilds)
  final positionNotifier = ValueNotifier<Duration>(Duration.zero);
  final durationNotifier = ValueNotifier<Duration>(Duration.zero);

  PlaybackController() {
    _engine = getPlaybackEngine();
    _initEngine();
  }

  // Scrubbing state to prevent UI jitter
  bool _isScrubbing = false;

  Future<void> seek(Duration position) async {
    // Optimistic update
    positionNotifier.value = position;
    _position = position;
    await _engine.seek(position);
  }

  Future<void> endScrubbing(Duration position) async {
    _position = position;
    positionNotifier.value = position;
    await _engine.seek(position);
    await Future.delayed(const Duration(milliseconds: 200));
    _isScrubbing = false;
  }

  // Engine Listeners
  Future<void> _initEngine() async {
    await _engine.initialize();

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

      if (p < lastEmittedPosition && (lastEmittedPosition - p).inSeconds < 2) {
        return;
      }

      lastUpdate = now;
      lastEmittedPosition = p;

      positionNotifier.value = p;
      _position = p;
    });

    _engine.durationStream.listen((d) {
      if (_duration != d) {
        _duration = d;
        durationNotifier.value = d;
        notifyListeners();
      }
    });

    _engine.playingStream.listen((playing) {
      if (_isPlaying != playing) {
        _isPlaying = playing;
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
      _currentIndex = nextIndex;
      await _playCurrent();
    }
  }

  Future<void> playPrevious() async {
    if (_queue.isEmpty) return;

    // If more than 3 seconds in, restart track
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
    _errorMessage = null;
    _isLoadingTrack = true;
    // Reset position/duration for new track
    _position = Duration.zero;
    _duration = Duration.zero;
    positionNotifier.value = Duration.zero;
    durationNotifier.value = Duration.zero;
    notifyListeners();

    bool loadFailed = false;
    try {
      await _engine.load(track.id);
      // Success — isPlaying will be set via playingStream listener
    } catch (e) {
      loadFailed = true;
      _errorMessage = 'Playback unavailable: ${e.toString().replaceFirst('Exception: ', '')}';
      _isLoadingTrack = false;
      _isPlaying = false;
      notifyListeners();
    } finally {
      // Only clear loading flag here if the catch block didn't already do it.
      // This prevents a second notifyListeners() race when the error state
      // has already been published above.
      if (!loadFailed) {
        _isLoadingTrack = false;
        // Don't call notifyListeners here — playingStream/durationStream will do it
      }
    }
  }

  Future<void> playQueue(List<Track> tracks, {int index = 0}) async {
    if (tracks.isEmpty) return;
    _queue = List.from(tracks);
    _currentIndex = index;
    if (_currentIndex < 0 || _currentIndex >= _queue.length) {
      _currentIndex = 0;
    }
    await _playCurrent();
  }

  Future<void> playTrack(Track track) async {
    await playQueue([track]);
  }

  void addToQueue(Track track) {
    _queue.add(track);
    notifyListeners();
  }

  void startScrubbing() {
    _isScrubbing = true;
  }

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
    // No notifyListeners needed — caller handles after consuming
  }

  Widget buildPlayerView(BuildContext context) {
    return _engine.buildPlayerView(context);
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }
}
