// ============================================================================
// Media Session — Mobile (audio_service Foreground Service)
// ============================================================================
// On Android, this delegates to PaaxAudioHandler to update the notification
// with track metadata and playback state. The handler keeps the Foreground
// Service alive so the WebView can continue playing in the background.
// ============================================================================

import '../../domain/entities/track.dart';
import 'paax_audio_handler.dart';

void setMediaSession({
  required Track track,
  required void Function() onPlay,
  required void Function() onPause,
  required void Function() onNext,
  required void Function() onPrevious,
}) {
  final handler = globalAudioHandler;
  if (handler == null) return;

  // Wire the notification controls to the PlaybackController callbacks
  handler.onPlay = onPlay;
  handler.onPause = onPause;
  handler.onNext = onNext;
  handler.onPrevious = onPrevious;

  // Update the notification with track info
  handler.updateNotificationMetadata(
    title: track.title,
    artist: track.displayArtist,
    artworkUrl: track.artworkUrl,
    duration: Duration(seconds: track.duration),
  );
}

void updateMediaSessionPlaybackState({
  required bool isPlaying,
  Duration position = Duration.zero,
}) {
  globalAudioHandler?.updatePlaybackState(
    isPlaying: isPlaying,
    position: position,
  );
}

/// Updates the notification's MediaItem duration dynamically when the
/// WebView reports the real duration (e.g. from YouTube metadata).
void updateMediaSessionDuration(Duration duration) {
  final handler = globalAudioHandler;
  if (handler == null) return;

  final current = handler.mediaItem.valueOrNull;
  if (current != null && duration > Duration.zero) {
    handler.mediaItem.add(current.copyWith(duration: duration));
  }
}

void clearMediaSession() {
  // Keep the service alive but clear metadata
}
