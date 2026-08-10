// lib/data/sync/playlist_sync_service.dart
//
// Offline-first replay engine for queued playlist mutations (Phase 3.4.1 →
// 3.4.3 incident hardening).
//
// WHY THIS FILE IS DEFENSIVE
// -------------------------
// On 2026-08-08 a stale playlist reorder produced ~2,565 executions/sec against
// production for hours. The multiplication was server-side (SQLSTATE 40001 made
// PostgREST retry a deterministic conflict forever), and this replay engine was
// NOT the cause. But it is the component best placed to make a recurrence
// impossible from the client, so it now enforces four hard invariants:
//
//   1. SINGLE FLIGHT — at most one replay pass runs per process, ever.
//      Concurrent callers join the in-flight pass instead of starting another.
//   2. CONFLICTS ARE TERMINAL — a version conflict is quarantined, never
//      retried, and never re-enqueued. It is an authoritative answer.
//   3. PER-PLAYLIST PAUSE — after a conflict, remaining ops for that SAME
//      playlist are quarantined too: they were computed against a base state
//      the server has already moved past, so replaying them would corrupt.
//   4. HARD RETRY CAP — transient network retries are bounded and the count is
//      persisted, so a queue can never cycle indefinitely.

import '../local/playlist_ops_journal.dart';
import 'playlist_op.dart';
import 'playlist_op_failure.dart';

/// Outcome of executing one queued op.
///
/// `conflict` and `forbidden` are TERMINAL — the server gave an authoritative
/// answer. `retry` is the only outcome that may be re-attempted, and only
/// within [PlaylistSyncService.maxRetries].
enum OpOutcome {
  success,

  /// Version conflict. Authoritative and deterministic — MUST NOT be retried.
  conflict,

  /// Permission lost/never held. Authoritative — MUST NOT be retried.
  forbidden,

  /// Transient (network/timeout). Bounded retry allowed.
  retry,

  /// Permanent non-conflict failure (NOT_FOUND / validation) that can never
  /// succeed. Dropped without blocking the queue.
  drop,
}

/// Why an op was quarantined, for UI and diagnostics.
enum QuarantineReason {
  conflict,
  forbidden,
  blockedByConflict,
  retriesExhausted,

  /// An unrecognised failure hit its conservative attempt cap. Phase 3.4.4:
  /// we refuse to keep repeating a request whose failure we cannot explain.
  unclassified,
}

class QuarantinedOp {
  final PlaylistOp op;
  final QuarantineReason reason;

  /// Authoritative server version when known (conflict only) — lets the UI
  /// offer a deterministic rebase without another round trip.
  final int? actualVersion;

  const QuarantinedOp(this.op, this.reason, {this.actualVersion});
}

class PlaylistFlushResult {
  final List<PlaylistOp> conflicts;
  final List<PlaylistOp> forbidden;
  final List<PlaylistOp> dropped;
  final List<QuarantinedOp> quarantined;
  final int remaining;

  /// True when this call joined an already-running pass instead of replaying.
  final bool skippedInFlight;

  const PlaylistFlushResult({
    this.conflicts = const [],
    this.forbidden = const [],
    this.dropped = const [],
    this.quarantined = const [],
    this.remaining = 0,
    this.skippedInFlight = false,
  });

  bool get hadConflicts => conflicts.isNotEmpty;
  bool get hadForbidden => forbidden.isNotEmpty;
}

class PlaylistSyncService {
  final PlaylistOpsJournal _journal;

  /// After this many transient failures an op is quarantined so it can never
  /// block later ops — or cycle forever.
  static const int maxRetries = 8;

  /// Single-flight guard. Static because there is one journal per device and
  /// one logical replay worker per process; making it an instance field would
  /// let two accidentally-constructed services replay the same queue
  /// concurrently (exactly the duplicate-worker failure mode this prevents).
  static Future<PlaylistFlushResult>? _inFlight;

  /// Diagnostics: how many replay passes have actually executed.
  static int passCount = 0;

  PlaylistSyncService(this._journal);

  bool hasPending(String userId) => _journal.hasPending(userId);
  List<PlaylistOp> pending(String userId) => _journal.pending(userId);
  List<QuarantinedOp> quarantined(String userId) => _journal.quarantined(userId);

  Future<void> enqueue(PlaylistOp op) => _journal.enqueue(op);

  /// True when a replay pass is currently running.
  static bool get isFlushing => _inFlight != null;

  /// Replay [userId]'s pending ops in order.
  ///
  /// SINGLE FLIGHT: if a pass is already running, this returns that pass's
  /// result rather than starting a second one. Reconnect events, controller
  /// rebuilds, resume callbacks and account restores can therefore all call
  /// this freely — the work happens once.
  Future<PlaylistFlushResult> flush(
    String userId,
    Future<OpOutcome> Function(PlaylistOp op) execute, {
    /// Called after a `create` commits, with (localId, cloudId, version).
    /// MUST atomically rewrite every account-scoped reference before returning;
    /// dependents are only released once it completes.
    Future<void> Function(String localId, String cloudId, int? version)?
        onAdopted,

    /// Reports the authoritative version returned by a successful mutation, so
    /// the next mutation for that playlist uses it.
    Future<void> Function(String playlistId, int version)? onVersion,
  }) {
    final existing = _inFlight;
    if (existing != null) {
      return existing.then((r) => PlaylistFlushResult(
            conflicts: r.conflicts,
            forbidden: r.forbidden,
            dropped: r.dropped,
            quarantined: r.quarantined,
            remaining: r.remaining,
            skippedInFlight: true,
          ));
    }
    final future =
        _flushOnce(userId, execute, onAdopted: onAdopted, onVersion: onVersion);
    _inFlight = future;
    // ignore: discarded_futures
    future.whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  Future<PlaylistFlushResult> _flushOnce(
    String userId,
    Future<OpOutcome> Function(PlaylistOp op) execute, {
    Future<void> Function(String localId, String cloudId, int? version)?
        onAdopted,
    Future<void> Function(String playlistId, int version)? onVersion,
  }) async {
    passCount++;
    final ops = _journal.pending(userId);
    final remaining = <PlaylistOp>[];
    final conflicts = <PlaylistOp>[];
    final forbidden = <PlaylistOp>[];
    final dropped = <PlaylistOp>[];
    final quarantine = <QuarantinedOp>[];

    /// Playlists whose server state has moved past our queued base state. Every
    /// later op for such a playlist was computed against a stale base, so
    /// replaying it would push wrong data. They are quarantined for the user to
    /// resolve, never silently applied and never retried.
    final poisonedPlaylists = <String>{};

    /// local playlist UUID → authoritative cloud UUID, for creates adopted in
    /// THIS pass. Persisted by [onAdopted] before dependents are released.
    // Seeded from the DURABLE map so an adoption recorded in a previous pass
    // still releases its dependents in this one.
    final adoptions = <String, String>{..._journal.adoptions(userId)};

    /// opIds of creates that failed terminally this pass.
    final failedCreates = <String>{};

    var stopped = false;

    for (var op in ops) {
      if (stopped) {
        remaining.add(op); // preserve strict FIFO after a network stall
        continue;
      }
      if (poisonedPlaylists.contains(op.playlistId)) {
        quarantine.add(QuarantinedOp(op, QuarantineReason.blockedByConflict));
        continue;
      }

      // ── dependency gate (Phase 3.4.7) ──────────────────────────────────
      // An op queued against a LOCAL playlist UUID must never be sent: the
      // server cannot resolve that id. It waits until its create is adopted,
      // at which point `adoptions` holds local→cloud and we rewrite it.
      final dep = op.dependsOnOpId;
      if (dep != null && !op.adopted) {
        final cloudId = adoptions[op.playlistId];
        if (cloudId == null) {
          if (failedCreates.contains(dep)) {
            // The create will never land — the dependent op is meaningless.
            dropped.add(op);
            continue;
          }
          remaining.add(op); // create still pending; preserve order
          continue;
        }
        // Adoption happened earlier in THIS pass — rewrite and proceed.
        op = op.adoptCloudId(cloudId);
      } else if (adoptions.containsKey(op.playlistId)) {
        // Defensive: an op that still names a local id after adoption.
        op = op.adoptCloudId(adoptions[op.playlistId]!);
      }
      if (op.retryCount >= maxRetries) {
        dropped.add(op);
        quarantine.add(QuarantinedOp(op, QuarantineReason.retriesExhausted));
        continue;
      }

      OpOutcome outcome;
      int? actualVersion;
      PlaylistFailureKind? failureKind;
      _ExecResult? exec;
      try {
        exec = await _run(execute, op);
        outcome = exec.outcome;
      } on _ConflictSignal catch (s) {
        outcome = OpOutcome.conflict;
        actualVersion = s.actualVersion;
        failureKind = PlaylistFailureKind.versionConflict;
      } on PlaylistOpFailure catch (f) {
        // Phase 3.4.4 — explicit taxonomy. No failure reaches a retry path
        // unless its kind was reviewed and assigned that policy.
        failureKind = f.kind;
        actualVersion = f.actualVersion;
        switch (f.policy) {
          case FailurePolicy.retryBounded:
            outcome = OpOutcome.retry;
          case FailurePolicy.terminal:
            outcome = f.kind == PlaylistFailureKind.versionConflict
                ? OpOutcome.conflict
                : OpOutcome.forbidden;
          case FailurePolicy.discard:
            outcome = OpOutcome.drop;
          case FailurePolicy.retryOnceThenQuarantine:
            // Tolerate a single blip, then stop. Uses the persisted retryCount
            // so the cap survives process restarts — an unknown failure can
            // never be retried indefinitely across sessions.
            if (op.retryCount + 1 >= PlaylistOpFailure.unknownAttemptCap) {
              outcome = OpOutcome.drop;
              quarantine.add(
                  QuarantinedOp(op, QuarantineReason.unclassified));
              dropped.add(op);
              continue; // already recorded — skip the switch below
            }
            outcome = OpOutcome.retry;
        }
      } catch (e) {
        // Anything that reached here was NOT classified upstream. Treat it as
        // `unknown`, which is deliberately NOT "transient". This is the default
        // that used to silently mean "safe to repeat".
        failureKind = PlaylistFailureKind.unknown;
        if (op.retryCount + 1 >= PlaylistOpFailure.unknownAttemptCap) {
          dropped.add(op);
          quarantine.add(QuarantinedOp(op, QuarantineReason.unclassified));
          continue;
        }
        outcome = OpOutcome.retry;
      }

      switch (outcome) {
        case OpOutcome.success:
          // ── UUID adoption transaction (Phase 3.4.7) ───────────────────
          // Order matters and is the whole point: persist the mapping FIRST,
          // then release dependents. If the app dies between the RPC and
          // onAdopted, the create is replayed — which is safe because
          // playlist_create is called with the client id, so the server
          // upserts the same row rather than creating a second one.
          if (op.type == PlaylistOpType.create) {
            final cloudId = exec?.cloudPlaylistId ?? op.playlistId;
            adoptions[op.playlistId] = cloudId;
            // Durable FIRST: if the process dies here, the next pass still
            // knows local→cloud and dependents are not stranded.
            await _journal.recordAdoption(userId, op.playlistId, cloudId);
            if (onAdopted != null) {
              await onAdopted(op.playlistId, cloudId, exec?.version);
            }
          }
          if (exec?.version != null && onVersion != null) {
            // Persist the authoritative version BEFORE the next op for this
            // playlist is dequeued, so mutation N+1 uses version N.
            await onVersion(op.playlistId, exec!.version!);
          }
          break; // applied on the cloud — drop from the queue

        case OpOutcome.conflict:
          // TERMINAL. Not re-enqueued, not retried, not counted toward
          // retryCount. The server has spoken; the local intent is preserved in
          // quarantine for the user to keep or discard.
          conflicts.add(op);
          quarantine.add(QuarantinedOp(op, QuarantineReason.conflict,
              actualVersion: actualVersion));
          poisonedPlaylists.add(op.playlistId); // pause this playlist
          break;

        case OpOutcome.forbidden:
          if (op.type == PlaylistOpType.create) failedCreates.add(op.opId);
          forbidden.add(op);
          quarantine.add(QuarantinedOp(op, QuarantineReason.forbidden));
          poisonedPlaylists.add(op.playlistId);
          break;

        case OpOutcome.drop when failureKind?.poisonsPlaylist == true:
          // e.g. NOT_FOUND: the playlist is gone, so every later op for it is
          // meaningless. Drop them together instead of failing one per pass.
          dropped.add(op);
          poisonedPlaylists.add(op.playlistId);
          break;

        case OpOutcome.drop:
          if (op.type == PlaylistOpType.create) failedCreates.add(op.opId);
          dropped.add(op); // permanent, non-conflict — remove and keep going
          break;

        case OpOutcome.retry:
          op.retryCount += 1;
          if (op.retryCount >= maxRetries) {
            dropped.add(op);
            quarantine.add(QuarantinedOp(op, QuarantineReason.retriesExhausted));
          } else {
            remaining.add(op);
          }
          stopped = true; // stop so later ops for this playlist keep order
          break;
      }
    }

    await _journal.replaceAll(userId, remaining);
    await _journal.pruneAdoptions(userId);
    if (quarantine.isNotEmpty) {
      await _journal.quarantineAll(userId, quarantine);
    }
    return PlaylistFlushResult(
      conflicts: conflicts,
      forbidden: forbidden,
      dropped: dropped,
      quarantined: quarantine,
      remaining: remaining.length,
    );
  }

  /// Discards a quarantined op (user chose "discard my change").
  Future<void> discardQuarantined(String userId, String opId) =>
      _journal.removeQuarantined(userId, opId);

  Future<void> clearQuarantine(String userId) => _journal.clearQuarantine(userId);

  /// On account switch / sign-out. The journal is keyed by userId so ops can
  /// never replay under another account; this also drops the single-flight
  /// guard so the next account can replay its own queue immediately.
  Future<void> onUserSession(String? userId) async {
    _inFlight = null;
  }

  /// Test hook — resets process-wide single-flight state.
  static void resetForTest() {
    _inFlight = null;
    passCount = 0;
  }
}

/// What one executed operation reported back.
class _ExecResult {
  final OpOutcome outcome;

  /// Authoritative cloud playlist id (create only).
  final String? cloudPlaylistId;

  /// Authoritative playlist version returned by the mutation.
  final int? version;

  const _ExecResult(this.outcome, {this.cloudPlaylistId, this.version});
}

/// Adapts the caller's `execute` callback, which returns a plain [OpOutcome],
/// to the richer [_ExecResult] the adoption/version logic needs.
///
/// The extra facts arrive out-of-band via [signalApplied] so the public
/// callback signature stays a simple `Future<OpOutcome> Function(PlaylistOp)`
/// — existing callers and every test keep compiling unchanged.
Future<_ExecResult> _run(
  Future<OpOutcome> Function(PlaylistOp op) execute,
  PlaylistOp op,
) async {
  _lastApplied = null;
  final outcome = await execute(op);
  final applied = _lastApplied;
  _lastApplied = null;
  return _ExecResult(
    outcome,
    cloudPlaylistId: applied?.cloudPlaylistId,
    version: applied?.version,
  );
}

class _AppliedFacts {
  final String? cloudPlaylistId;
  final int? version;
  const _AppliedFacts({this.cloudPlaylistId, this.version});
}

_AppliedFacts? _lastApplied;

/// Called by an `execute` implementation immediately after a successful
/// mutation to report the authoritative cloud id and version.
void signalApplied({String? cloudPlaylistId, int? version}) {
  _lastApplied =
      _AppliedFacts(cloudPlaylistId: cloudPlaylistId, version: version);
}

/// Internal carrier so `execute` can report the authoritative version alongside
/// a conflict without widening the public callback signature.
class _ConflictSignal implements Exception {
  final int? actualVersion;
  const _ConflictSignal(this.actualVersion);
}

/// Thrown by an `execute` implementation to report a conflict WITH the
/// authoritative server version attached.
Never signalConflict(int? actualVersion) => throw _ConflictSignal(actualVersion);
