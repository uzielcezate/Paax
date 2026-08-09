// lib/domain/entities/playlist_mutation_result.dart
//
// The canonical outcome of a user-initiated playlist mutation (Phase 3.4.4).
//
// Before this, mutations were fire-and-forget: `_pushCloud` swallowed every
// error, so the UI showed "Removed from playlist" whether the server had
// applied it, queued it, or flatly refused. That is how a client drifts out of
// sync with the server without anyone noticing.
//
// Every value here is a DISTINCT user-visible situation with a distinct
// message. Notably `queuedOffline` is a success (the offline journal will
// replay it) while `conflict` and `forbidden` are refusals that also roll the
// optimistic local change back.
enum PlaylistMutationResult {
  /// Applied on the server (or on a local-only playlist).
  applied,

  /// Network unavailable; durably journalled and will replay on reconnect.
  queuedOffline,

  /// The server refused: the playlist changed elsewhere. Local change rolled
  /// back; the user should reopen to see authoritative state.
  conflict,

  /// The server refused: permission lost or never held. Local change rolled back.
  forbidden,

  /// Anything else. Local change rolled back.
  failed,
}

extension PlaylistMutationResultX on PlaylistMutationResult {
  /// True when the user's intent will eventually reach the server.
  bool get isSuccess =>
      this == PlaylistMutationResult.applied ||
      this == PlaylistMutationResult.queuedOffline;

  /// True when the local optimistic change was reverted.
  bool get wasRolledBack => !isSuccess;
}
