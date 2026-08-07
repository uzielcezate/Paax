// lib/core/startup/startup_diagnostics.dart
//
// Debug-only startup instrumentation (Phase 3.4.2).
//
// PURPOSE
// -------
// Phase 3.4.2 was triggered by two production faults that were invisible from
// inside the app: a wedged PostgREST instance issuing ~2,344 req/s, and a
// startup path that fired every request twice. Neither had any in-app signal.
// This file is the permanent countermeasure: every startup-scoped resource
// (bootstrap run, profile fetch, auth listener, realtime channel, timer, retry
// job) registers here, so a regression that silently creates a second listener
// or an unbounded retry loop trips an assertion in development instead of
// reaching production.
//
// COST IN RELEASE BUILDS
// ----------------------
// [enabled] is a compile-time constant. In a release build it is `false`, every
// call site folds to a no-op, and the tree shaker removes the counters. There is
// no runtime branch and no retained state.
//
// THE ONE FLAG
// ------------
//   flutter build apk --dart-define=STARTUP_DIAGNOSTICS=false
// disables it everywhere, including debug builds.

import 'package:flutter/foundation.dart';

/// Resource classes tracked for single-lifecycle enforcement.
enum StartupResource {
  authListener,
  realtimeSubscription,
  timer,
  retryJob,
}

/// Debug-only counters + invariant checks for the startup path.
///
/// All members are static: there is exactly one startup sequence per process,
/// so an instance would add ceremony without adding isolation. Tests reset via
/// [reset].
class StartupDiagnostics {
  StartupDiagnostics._();

  /// Master switch. Compile-time constant → fully tree-shaken in release.
  ///
  /// Disable in any build with `--dart-define=STARTUP_DIAGNOSTICS=false`.
  static const bool enabled = !kReleaseMode &&
      bool.fromEnvironment('STARTUP_DIAGNOSTICS', defaultValue: true);

  // ── counters ──────────────────────────────────────────────────────────────

  static int _bootstrapExecutions = 0;
  static int _profileFetches = 0;
  static int _stateTransitions = 0;
  static final Map<StartupResource, int> _live = {};
  static final List<String> _transitionLog = [];

  /// Number of times the startup resolution ran. MUST be 1 per session.
  static int get bootstrapExecutions => _bootstrapExecutions;

  /// Number of remote profile requests issued. Should be 1 per resolution.
  static int get profileFetches => _profileFetches;

  /// Number of startup state transitions recorded.
  static int get stateTransitions => _stateTransitions;

  /// Currently-registered resources of [r] (registered minus disposed).
  static int live(StartupResource r) => _live[r] ?? 0;

  /// Human-readable transition history — surfaced by the debug overlay and by
  /// failing tests, so a route-thrash regression is visible as a sequence.
  static List<String> get transitionLog => List.unmodifiable(_transitionLog);

  // ── recording ─────────────────────────────────────────────────────────────

  /// Records one startup resolution. Trips if a second one is attempted, which
  /// is exactly the duplicate-bootstrap defect this phase removes.
  static void recordBootstrap() {
    if (!enabled) return;
    _bootstrapExecutions++;
    assert(
      _bootstrapExecutions <= 1,
      'Startup resolved $_bootstrapExecutions times in one session. '
      'Exactly one resolution is allowed — a second one means the constructor '
      'and an auth event are both driving startup (the Phase 3.4.2 defect). '
      'Transitions so far:\n${_transitionLog.join('\n')}',
    );
  }

  /// Records a remote profile request.
  ///
  /// [limit] guards against a retry storm: bounded retry allows a few attempts,
  /// but a runaway loop trips long before it reaches the network in volume.
  static void recordProfileFetch({int limit = 12}) {
    if (!enabled) return;
    _profileFetches++;
    assert(
      _profileFetches <= limit,
      'Profile fetched $_profileFetches times this session (limit $limit). '
      'This is the signature of a retry loop or a rebuild storm. '
      'Transitions so far:\n${_transitionLog.join('\n')}',
    );
  }

  /// Records a startup state transition for the debug log.
  static void recordTransition(Object from, Object to, [String? cause]) {
    if (!enabled) return;
    _stateTransitions++;
    final line = cause == null ? '$from → $to' : '$from → $to  ($cause)';
    _transitionLog.add(line);
    // Bound the log so a pathological loop cannot exhaust memory before the
    // assertions below fire.
    if (_transitionLog.length > 200) _transitionLog.removeAt(0);
    debugPrint('[startup] $line');
  }

  /// Registers a live startup-scoped resource.
  ///
  /// [max] is the number that may legitimately exist at once. Exceeding it means
  /// something registered twice without disposing — the duplicate-listener and
  /// duplicate-subscription class of bug.
  static void register(StartupResource r, {int max = 1, String? owner}) {
    if (!enabled) return;
    final n = (_live[r] ?? 0) + 1;
    _live[r] = n;
    assert(
      n <= max,
      '$n live ${r.name}s (max $max)${owner == null ? '' : ' — registered by $owner'}. '
      'A startup resource was created twice without disposal. This is how a '
      'hidden loop or duplicate DB traffic starts.',
    );
  }

  /// Unregisters a resource previously passed to [register].
  static void unregister(StartupResource r) {
    if (!enabled) return;
    final n = (_live[r] ?? 0) - 1;
    _live[r] = n;
    assert(n >= 0, 'Disposed more ${r.name}s than were registered.');
  }

  /// One-line snapshot for logs, the debug overlay, and test failure messages.
  static String snapshot() {
    if (!enabled) return 'diagnostics disabled';
    return 'bootstraps=$_bootstrapExecutions '
        'profileFetches=$_profileFetches '
        'transitions=$_stateTransitions '
        'authListeners=${live(StartupResource.authListener)} '
        'realtimeSubs=${live(StartupResource.realtimeSubscription)} '
        'timers=${live(StartupResource.timer)} '
        'retryJobs=${live(StartupResource.retryJob)}';
  }

  /// Clears all counters. Tests call this in `setUp`; production never does.
  @visibleForTesting
  static void reset() {
    _bootstrapExecutions = 0;
    _profileFetches = 0;
    _stateTransitions = 0;
    _live.clear();
    _transitionLog.clear();
  }
}
