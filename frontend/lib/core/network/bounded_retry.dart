// lib/core/network/bounded_retry.dart
//
// Bounded exponential backoff with jitter (Phase 3.4.2).
//
// DESIGN CONSTRAINT
// -----------------
// This phase exists partly because production sustained ~2,344 req/s against a
// wedged backend. Adding retries to fix "transient 503/504" is therefore a
// hazard: a naive retry makes exactly that failure worse. Every property below
// is chosen so a retry policy cannot degenerate into a storm:
//
//   • attempts are hard-capped (maxAttempts), not "until success";
//   • the TOTAL wall-clock budget is capped independently (totalBudget), so
//     slow failures cannot stack into an unbounded splash wait;
//   • only transient kinds retry — `unauthorized` and `unknown` fail fast;
//   • full jitter, so N clients recovering from an outage do not synchronise
//     into a thundering herd;
//   • each in-flight job registers with StartupDiagnostics, so a duplicate or
//     leaked retry job trips an assertion in development.
//
// There is intentionally no "retry forever in the background" mode. Background
// refresh after a failure is driven by explicit lifecycle events (app resume,
// connectivity regained, user pull-to-refresh) — never by a self-perpetuating
// timer.

import 'dart:async';
import 'dart:math';

import '../startup/startup_diagnostics.dart';
import 'remote_result.dart';

/// Retry policy. Const-constructible so call sites document their own budget.
class RetryPolicy {
  /// Total attempts including the first. `1` disables retrying.
  final int maxAttempts;

  /// Deadline for a single attempt.
  final Duration attemptTimeout;

  /// Ceiling on total elapsed time across all attempts and waits.
  final Duration totalBudget;

  /// Base delay; attempt N waits a random value in [0, base * 2^(N-1)].
  final Duration baseDelay;

  /// Upper bound on any single backoff wait.
  final Duration maxDelay;

  const RetryPolicy({
    this.maxAttempts = 3,
    this.attemptTimeout = const Duration(seconds: 6),
    this.totalBudget = const Duration(seconds: 15),
    this.baseDelay = const Duration(milliseconds: 400),
    this.maxDelay = const Duration(seconds: 4),
  })  : assert(maxAttempts >= 1, 'maxAttempts must be >= 1'),
        assert(maxAttempts <= 5, 'A startup read must never attempt more than 5 times');

  /// Startup profile read: fast, shallow, strictly bounded. The splash cannot
  /// outlive [totalBudget] because of this policy.
  static const startupProfile = RetryPolicy(
    maxAttempts: 3,
    attemptTimeout: Duration(seconds: 5),
    totalBudget: Duration(seconds: 12),
    baseDelay: Duration(milliseconds: 350),
    maxDelay: Duration(seconds: 3),
  );

  /// Background refresh behind an already-usable UI. May be slower and more
  /// patient because nothing is blocked on it.
  static const backgroundRefresh = RetryPolicy(
    maxAttempts: 3,
    attemptTimeout: Duration(seconds: 8),
    totalBudget: Duration(seconds: 30),
    baseDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 8),
  );

  /// No retry — a single bounded attempt.
  static const single = RetryPolicy(
    maxAttempts: 1,
    attemptTimeout: Duration(seconds: 6),
    totalBudget: Duration(seconds: 8),
  );
}

/// Runs [operation] under [policy], converting throws into [RemoteUnavailable].
///
/// Returns as soon as the operation yields an authoritative answer. Retries ONLY
/// transient failures, and never exceeds either the attempt cap or the total
/// time budget. Never throws.
///
/// [random] is injectable so tests can assert exact backoff sequences instead of
/// sleeping on real jitter.
Future<RemoteResult<T>> runBounded<T>(
  Future<T> Function() operation, {
  RetryPolicy policy = RetryPolicy.startupProfile,
  Random? random,
  String? label,
  void Function(int attempt)? onAttempt,
}) async {
  final rng = random ?? Random();
  final started = DateTime.now();
  StartupDiagnostics.register(StartupResource.retryJob, max: 4, owner: label);

  try {
    RemoteUnavailable<T> last =
        const RemoteUnavailable(RemoteFailureKind.unknown, 'not attempted');

    for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
      // Budget check BEFORE spending an attempt, so the caller's deadline holds
      // even when individual attempts run long.
      final elapsed = DateTime.now().difference(started);
      if (elapsed >= policy.totalBudget) {
        return RemoteUnavailable<T>(
          last.kind == RemoteFailureKind.unknown
              ? RemoteFailureKind.timeout
              : last.kind,
          'retry budget exhausted after $elapsed',
        );
      }

      onAttempt?.call(attempt);
      try {
        final value = await operation().timeout(policy.attemptTimeout);
        return RemoteSuccess<T>(value);
      } catch (e) {
        final kind = classifyRemoteError(e);
        last = RemoteUnavailable<T>(kind, e);

        // Non-transient (unauthorized, malformed request, unknown) → stop now.
        // Retrying these cannot help and only adds load.
        if (!kind.isTransient) return last;
        if (attempt == policy.maxAttempts) return last;

        final delay = _backoffDelay(policy, attempt, rng);
        final remaining = policy.totalBudget - DateTime.now().difference(started);
        if (remaining <= Duration.zero) return last;
        await Future<void>.delayed(delay < remaining ? delay : remaining);
      }
    }
    return last;
  } finally {
    StartupDiagnostics.unregister(StartupResource.retryJob);
  }
}

/// Full-jitter exponential backoff: `uniform(0, min(maxDelay, base * 2^(n-1)))`.
///
/// Full jitter (rather than exponential-plus-small-jitter) is chosen because it
/// minimises client synchronisation when many devices recover from a shared
/// outage — the exact scenario that produced this phase.
Duration _backoffDelay(RetryPolicy policy, int attempt, Random rng) {
  final expMicros = policy.baseDelay.inMicroseconds * (1 << (attempt - 1));
  final capped = min(expMicros, policy.maxDelay.inMicroseconds);
  if (capped <= 0) return Duration.zero;
  return Duration(microseconds: rng.nextInt(capped + 1));
}
