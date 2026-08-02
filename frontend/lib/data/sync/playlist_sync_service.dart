// lib/data/sync/playlist_sync_service.dart
//
// Phase 3.4.1 — offline-first replay engine for queued playlist mutations.
// Pure orchestration (the actual remote call is injected as `execute`), so it is
// fully unit-testable. Replays a user's pending ops IN ORDER; a network failure
// stops replay to preserve ordering; a version conflict or lost permission drops
// the stale op (the authoritative cloud state wins) and is surfaced so the caller
// can reconcile/roll back the optimistic local mirror.

import '../local/playlist_ops_journal.dart';
import 'playlist_op.dart';

/// `drop` = a PERMANENT non-conflict failure (NOT_FOUND / validation) that can
/// never succeed on retry — removed without blocking the queue (vs `retry`,
/// which is a transient network stall that stops replay to preserve order).
enum OpOutcome { success, conflict, forbidden, retry, drop }

class PlaylistFlushResult {
  final List<PlaylistOp> conflicts;
  final List<PlaylistOp> forbidden;
  final List<PlaylistOp> dropped; // permanent failures / gave-up poison pills
  final int remaining;

  const PlaylistFlushResult({
    this.conflicts = const [],
    this.forbidden = const [],
    this.dropped = const [],
    this.remaining = 0,
  });

  bool get hadConflicts => conflicts.isNotEmpty;
  bool get hadForbidden => forbidden.isNotEmpty;
}

class PlaylistSyncService {
  final PlaylistOpsJournal _journal;

  /// After this many failed network retries, a stuck op is dropped so it can
  /// never permanently block later ops for the same user.
  static const int maxRetries = 8;

  PlaylistSyncService(this._journal);

  bool hasPending(String userId) => _journal.hasPending(userId);
  List<PlaylistOp> pending(String userId) => _journal.pending(userId);

  Future<void> enqueue(PlaylistOp op) => _journal.enqueue(op);

  /// Replay [userId]'s pending ops in order. [execute] performs one op and
  /// returns its outcome (or throws → treated as a retryable network error).
  Future<PlaylistFlushResult> flush(
    String userId,
    Future<OpOutcome> Function(PlaylistOp op) execute,
  ) async {
    final ops = _journal.pending(userId);
    final remaining = <PlaylistOp>[];
    final conflicts = <PlaylistOp>[];
    final forbidden = <PlaylistOp>[];
    final dropped = <PlaylistOp>[];
    var stopped = false;

    for (final op in ops) {
      if (stopped) {
        remaining.add(op); // preserve strict FIFO order after a network stall
        continue;
      }
      // Give up on a poison pill so it can't block the queue forever.
      if (op.retryCount >= maxRetries) {
        dropped.add(op);
        continue;
      }
      OpOutcome outcome;
      try {
        outcome = await execute(op);
      } catch (_) {
        outcome = OpOutcome.retry;
      }
      switch (outcome) {
        case OpOutcome.success:
          break; // drop (applied on the cloud)
        case OpOutcome.conflict:
          conflicts.add(op); // drop — authoritative state supersedes it
          break;
        case OpOutcome.forbidden:
          forbidden.add(op); // drop — permission lost; caller rolls back
          break;
        case OpOutcome.drop:
          dropped.add(op); // permanent (NOT_FOUND/validation) — remove, keep going
          break;
        case OpOutcome.retry:
          op.retryCount += 1;
          remaining.add(op);
          stopped = true; // stop so later ops for this playlist keep order
          break;
      }
    }

    await _journal.replaceAll(userId, remaining);
    return PlaylistFlushResult(
      conflicts: conflicts,
      forbidden: forbidden,
      dropped: dropped,
      remaining: remaining.length,
    );
  }

  /// On account switch / sign-out, drop the previous user's queue reference
  /// (their ops remain namespaced under their own id and never replay for
  /// another account).
  Future<void> onUserSession(String? userId) async {
    // No global state to reset — the journal is keyed by userId. Provided for
    // symmetry with the other services and future use.
  }
}
