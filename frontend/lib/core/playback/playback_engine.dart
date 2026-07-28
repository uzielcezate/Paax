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

  /// Raw player-state stream using YouTube IFrame semantics:
  /// -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
  /// Used by the play transaction to confirm the newly-loaded video actually
  /// started (buffering/playing/cued) before committing it as the current track.
  Stream<int> get playerStateStream;

  /// Player-error stream (YouTube onError codes: 2, 5, 100, 101, 150). Emitted
  /// when the loaded video is invalid/unavailable/embedding-disabled.
  Stream<int> get errorStream;

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
  
  /// Prefetch the next track's stream URL in the background (fire-and-forget).
  /// Errors are silently ignored — this is a best-effort optimisation only.
  void prefetchNext(String videoId);

  /// Dispose resources
  void dispose();
  
  /// Build the platform specific player view
  Widget buildPlayerView(BuildContext context);
}
