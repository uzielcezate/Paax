// ============================================================================
// Media Session — Stub (non-web platforms)
// ============================================================================
// On Android/iOS the native audio_session / just_audio package handles media
// notifications. This stub silently no-ops so the rest of the code compiles
// on all platforms.
// ============================================================================

import '../../domain/entities/track.dart';

void setMediaSession({
  required Track track,
  required void Function() onPlay,
  required void Function() onPause,
  required void Function() onNext,
  required void Function() onPrevious,
}) {
  // No-op on non-web platforms.
}

void updateMediaSessionPlaybackState({required bool isPlaying}) {
  // No-op on non-web platforms.
}

void clearMediaSession() {
  // No-op on non-web platforms.
}
