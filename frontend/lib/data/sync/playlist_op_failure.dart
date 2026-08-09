// lib/data/sync/playlist_op_failure.dart
//
// Explicit failure taxonomy for queued playlist operations (Phase 3.4.4).
//
// WHY
// ---
// After the 2026-08-08 retry storm, PR #87 made version conflicts terminal but
// left one soft spot: `_execute`'s final `catch (_) => OpOutcome.retry`. Any
// error the code did not recognise was OPTIMISTICALLY assumed transient. That is
// the same shape of mistake that caused the incident — a default that silently
// classifies an unknown condition as "safe to repeat".
//
// The bug that produced the storm was not "we retried too many times". It was
// "we assumed a deterministic failure was transient". So the fix is not a
// smaller retry budget; it is refusing to guess. Every failure is now mapped to
// a named [PlaylistFailureKind] with an explicit, reviewed policy, and `unknown`
// gets the most conservative policy that still tolerates a genuine one-off blip.

/// What went wrong with one queued operation.
enum PlaylistFailureKind {
  /// Socket/DNS/timeout/5xx — the request never reached a verdict.
  transientNetwork,

  /// Session invalid, expired or revoked. Retrying burns requests and cannot
  /// help until the user re-authenticates.
  authentication,

  /// Authenticated but not permitted (RLS / ownership / collaborator role).
  /// Authoritative and stable.
  authorization,

  /// The server understood and rejected the payload (bad shape, bad enum,
  /// ORDER_SET_MISMATCH). Byte-identical replay produces byte-identical
  /// rejection.
  validation,

  /// Optimistic-concurrency conflict. Authoritative and deterministic.
  versionConflict,

  /// The target no longer exists (deleted elsewhere, or never created).
  notFound,

  /// Our own local state is inconsistent (unresolvable track ids, malformed
  /// journal payload). The network cannot fix this.
  localIntegrity,

  /// Genuinely unrecognised. Treated conservatively — see [policy].
  unknown,
}

/// How the replay engine may treat a failure kind.
enum FailurePolicy {
  /// Bounded retry against the normal cap.
  retryBounded,

  /// Terminal — quarantine immediately, never retry.
  terminal,

  /// Drop from the queue without quarantine (it can never succeed and carries
  /// no recoverable user intent).
  discard,

  /// At most [PlaylistOpFailure.unknownAttemptCap] attempts EVER, then
  /// quarantine. Tolerates a one-off blip without ever assuming an unknown
  /// condition is safe to repeat.
  retryOnceThenQuarantine,
}

extension PlaylistFailureKindX on PlaylistFailureKind {
  FailurePolicy get policy {
    switch (this) {
      case PlaylistFailureKind.transientNetwork:
        return FailurePolicy.retryBounded;

      // Authoritative answers. Replay cannot change them, and the user's intent
      // is worth preserving, so they are quarantined rather than discarded.
      case PlaylistFailureKind.versionConflict:
      case PlaylistFailureKind.authorization:
      case PlaylistFailureKind.authentication:
        return FailurePolicy.terminal;

      // Deterministic rejections with nothing for the user to resolve.
      case PlaylistFailureKind.validation:
      case PlaylistFailureKind.notFound:
      case PlaylistFailureKind.localIntegrity:
        return FailurePolicy.discard;

      // The conservative default. NOT retryBounded: an unrecognised error is
      // exactly the case where we must not assume repetition is harmless.
      case PlaylistFailureKind.unknown:
        return FailurePolicy.retryOnceThenQuarantine;
    }
  }

  /// True when this failure should pause remaining ops for the same playlist,
  /// because they were computed against a base the server has moved past.
  bool get poisonsPlaylist =>
      this == PlaylistFailureKind.versionConflict ||
      this == PlaylistFailureKind.authorization ||
      this == PlaylistFailureKind.notFound;
}

/// A classified operation failure.
class PlaylistOpFailure implements Exception {
  /// Hard ceiling on attempts for [PlaylistFailureKind.unknown], across the
  /// whole life of an op (persisted via `retryCount`).
  static const int unknownAttemptCap = 2;

  final PlaylistFailureKind kind;

  /// Authoritative server version, when the failure carried one.
  final int? actualVersion;

  final Object? cause;

  const PlaylistOpFailure(this.kind, {this.actualVersion, this.cause});

  FailurePolicy get policy => kind.policy;

  @override
  String toString() => 'PlaylistOpFailure(${kind.name}, cause=$cause)';
}
