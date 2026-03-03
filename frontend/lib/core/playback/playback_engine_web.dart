import 'dart:async';
import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
import 'playback_engine.dart';

class PlaybackEngineImpl implements PlaybackEngine {
  late YoutubePlayerController _controller;
  
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  
  Timer? _positionTimer;
  bool _isDisposed = false;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;
  
  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Future<void> initialize() async {
    _controller = YoutubePlayerController(
      params: const YoutubePlayerParams(
         showControls: false,
         showFullscreenButton: false,
         mute: false,
         loop: false,
      ),
    );
    
    // Listen to iframe events
    _controller.listen((event) {
        if (_isDisposed) return;
        
        // Sync Duration
        _durationController.add(event.metaData.duration);
        
        // Sync Playing State & Timer
        if (event.playerState == PlayerState.playing) {
            _playingController.add(true);
            _startPositionTimer();
        } else if (event.playerState == PlayerState.paused || event.playerState == PlayerState.ended) {
            _playingController.add(false);
            _stopPositionTimer();
            if (event.playerState == PlayerState.ended) {
               _completionController.add(null);
            }
        } else {
           // buffer, etc.
        }
    });
  }

  // ... (rest of methods)

  @override
  void dispose() {
    _isDisposed = true;
    _stopPositionTimer();
    _positionController.close();
    _durationController.close();
    _playingController.close();
    _completionController.close();
    // _controller.close(); // iframe controller might not need explicit close or it disposes with widget
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
        if (_isDisposed) {
           _stopPositionTimer();
           return;
        }
        try {
           final pos = await _controller.currentTime;
           _positionController.add(Duration(milliseconds: (pos * 1000).toInt()));
        } catch (_) {}
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  @override
  Future<void> load(String videoId) async {
    _controller.loadVideoById(videoId: videoId);
  }

  @override
  Future<void> pause() async {
    _controller.pauseVideo();
  }

  @override
  Future<void> play() async {
    _controller.playVideo();
  }

  @override
  Future<void> seek(Duration position) async {
    // allowSeekAhead = true for smoother scrubbing
    _controller.seekTo(seconds: position.inSeconds.toDouble(), allowSeekAhead: true);
  }
  

  
  @override
  Widget buildPlayerView(BuildContext context) {
    return YoutubePlayer(
       controller: _controller,
       aspectRatio: 16/9,
    );
  }
}
