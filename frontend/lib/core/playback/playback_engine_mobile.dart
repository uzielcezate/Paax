import 'dart:async';
import 'package:flutter/material.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'playback_engine.dart';

class PlaybackEngineImpl implements PlaybackEngine {
  late YoutubePlayerController _controller;
  
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completionController = StreamController<void>.broadcast();
  
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
      initialVideoId: '', 
      flags: const YoutubePlayerFlags(
        autoPlay: false,
        mute: false,
        hideControls: true,
        controlsVisibleAtStart: false,
        hideThumbnail: true,
      ),
    );
    
    _controller.addListener(_videoListener);
  }
  
  void _videoListener() {
      if (_isDisposed) return;
      
      final value = _controller.value;
      
      // Sync Position (Mobile player has it natively in value)
      _positionController.add(value.position);
      
      // Sync Duration
      _durationController.add(value.metaData.duration);
      
      // Sync Playing
      if (value.playerState == PlayerState.playing) {
          _playingController.add(true);
      } else if (value.playerState == PlayerState.paused || value.playerState == PlayerState.ended) {
           _playingController.add(false);
           if (value.playerState == PlayerState.ended) {
               _completionController.add(null);
           }
      }
  }

  // ... (rest of methods)

  @override
  void dispose() {
    _isDisposed = true;
    _controller.dispose();
    _positionController.close();
    _durationController.close();
    _playingController.close();
    _completionController.close();
  }

  @override
  Future<void> load(String videoId) async {
    _controller.load(videoId);
  }

  @override
  Future<void> pause() async {
    _controller.pause();
  }

  @override
  Future<void> play() async {
    _controller.play();
  }

  @override
  Future<void> seek(Duration position) async {
    _controller.seekTo(position);
  }
  
  @override
  Widget buildPlayerView(BuildContext context) {
    return YoutubePlayer(
      controller: _controller,
      width: 1, 
    );
  }
}
