// ============================================================================
// PaaxAudioHandler — Foreground Service Proxy
// ============================================================================
// This handler does NOT play audio itself. It acts as a proxy that:
//   1. Keeps a Foreground Service alive so Android won't kill the WebView.
//   2. Shows a persistent notification with track info + controls.
//   3. Delegates all control actions back to PlaybackController.
// ============================================================================

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

/// Global reference set during AudioService.init() in main.dart.
/// Accessible from PlaybackController and media_session_stub.
PaaxAudioHandler? globalAudioHandler;

class PaaxAudioHandler extends BaseAudioHandler with SeekHandler {
  // ── Callbacks wired by PlaybackController ─────────────────────────────────

  VoidCallback? onPlay;
  VoidCallback? onPause;
  VoidCallback? onNext;
  VoidCallback? onPrevious;
  void Function(Duration)? onSeek;

  // ── AudioHandler overrides ────────────────────────────────────────────────

  @override
  Future<void> play() async {
    debugPrint('[AudioHandler] play()');
    onPlay?.call();
  }

  @override
  Future<void> pause() async {
    debugPrint('[AudioHandler] pause()');
    onPause?.call();
  }

  @override
  Future<void> stop() async {
    debugPrint('[AudioHandler] stop()');
    onPause?.call();
    // Don't call super.stop() — we want the service to persist.
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[AudioHandler] seek(${position.inSeconds}s)');
    onSeek?.call(position);
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('[AudioHandler] skipToNext()');
    onNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('[AudioHandler] skipToPrevious()');
    onPrevious?.call();
  }

  // ── Notification Updates (called by PlaybackController) ───────────────────

  /// Updates the notification with the current track's metadata.
  void updateNotificationMetadata({
    required String title,
    required String artist,
    required String artworkUrl,
    required Duration duration,
  }) {
    final item = MediaItem(
      id: title, // unique-enough for notification purposes
      title: title,
      artist: artist,
      artUri: artworkUrl.isNotEmpty ? Uri.tryParse(artworkUrl) : null,
      duration: duration > Duration.zero ? duration : null,
    );
    mediaItem.add(item);
  }

  /// Updates the notification's play/pause state and position.
  void updatePlaybackState({
    required bool isPlaying,
    Duration position = Duration.zero,
  }) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        isPlaying ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: isPlaying,
      updatePosition: position,
      updateTime: DateTime.now(),
    ));
  }
}
