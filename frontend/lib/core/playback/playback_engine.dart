import 'package:flutter/material.dart';

abstract class PlaybackEngine {
  /// Stream of current playback position
  Stream<Duration> get positionStream;
  
  /// Stream of current media duration
  Stream<Duration> get durationStream;
  
  /// Stream of playback status (playing/paused/ended)
  Stream<bool> get playingStream; // Simple Playing status
  
  /// Stream of completion events (track ended)
  Stream<void> get completionStream;
  
  /// Initialize the engine (if needed)
  Future<void> initialize();
  
  /// Load and play a video by ID
  Future<void> load(String videoId);
  
  /// Play
  Future<void> play();
  
  /// Pause
  Future<void> pause();
  
  /// Seek
  Future<void> seek(Duration position);
  
  /// Dispose resources
  void dispose();
  
  /// Build the platform specific player view
  Widget buildPlayerView(BuildContext context);
}
