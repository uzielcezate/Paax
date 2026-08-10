// lib/core/network/offline_status.dart
//
// One app-scoped source of truth for "are we offline?" (Phase 3.4.5).
//
// TWO SIGNALS, ONE TRUTH (revised Phase 3.4.8)
// --------------------------------------------
// Offline status combines two sources, because neither alone is sufficient:
//
//   1. REQUEST OUTCOMES (authoritative). The OS connectivity flag answers the
//      wrong question — it reports "an interface is up", which is true on a
//      captive portal, on a dead VPN, and while Supabase itself is unreachable.
//      During the 2026-08-08 incident the device had connectivity and the
//      backend refused everything. So what we actually believe about
//      reachability comes from real request results, via [reportOutcome].
//
//   2. OS CONNECTIVITY EVENTS (trigger only). Outcomes alone cannot detect
//      COMING BACK: while offline nothing calls the network, so nothing ever
//      reports success, so `offline → online` never fires. That was the
//      reconnect bug — the journal only replayed when the user happened to
//      perform some unrelated action that hit the network. The connectivity
//      stream supplies the missing edge. It is event-driven (never polled) and
//      only a hint; a wrong hint is corrected by the next request outcome.
//
// There is exactly ONE subscription, owned here and started by main(). Screens
// must never open their own — five screens × one listener each is five things
// to leak, and this codebase has already been bitten by duplicated listeners.
//
// This class also owns the single-flight reconnect registry, so a surface can
// ask to refresh exactly once when connectivity returns without each screen
// inventing its own guard.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class OfflineStatus extends ChangeNotifier {
  /// The single app-scoped instance, set by `main()`'s provider.
  ///
  /// A static sink is used deliberately. Reporting outcomes is a cross-cutting
  /// concern touched by every repository and data source; threading a
  /// dependency through all of them would be far more invasive than one
  /// well-documented registration, and the alternative (each layer owning its
  /// own connectivity notion) is exactly the duplication this class exists to
  /// prevent. Null in tests that never register one, so [report] is a no-op
  /// there rather than a crash.
  static OfflineStatus? instance;

  /// Records an outcome from anywhere without needing a BuildContext.
  static void report({required bool succeeded, bool wasNetworkFailure = false}) {
    instance?.reportOutcome(
        succeeded: succeeded, wasNetworkFailure: wasNetworkFailure);
  }

  /// THE MISSING RECONNECT SIGNAL (Phase 3.4.8).
  ///
  /// Until now this class was derived PURELY from request outcomes. That works
  /// for detecting we went offline (a mutation fails), but it cannot detect
  /// coming back: nothing calls the network while offline, so nothing ever
  /// reported success, so `offline → online` never fired and the journal was
  /// never replayed. The user had to perform some unrelated action that
  /// happened to hit the network — which is exactly what manual QA observed
  /// ("performing another server-interacting action can cause the pending
  /// operation to finally replay").
  ///
  /// So we now also observe the OS connectivity stream. It is event-driven —
  /// no polling — and it is only a HINT: a connectivity event means "an
  /// interface came up", not "the backend is reachable" (captive portals, VPNs,
  /// a down backend). We therefore treat it as a trigger to re-verify, and the
  /// authoritative online/offline decision still comes from real request
  /// outcomes via [reportOutcome].
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  /// Registers the single app-scoped connectivity observer. Idempotent — a
  /// second call is a no-op, so there can never be two subscriptions.
  void startObserving({Stream<List<ConnectivityResult>>? stream}) {
    if (_connectivitySub != null) return;
    final source = stream ?? Connectivity().onConnectivityChanged;
    _connectivitySub = source.listen(_onConnectivityEvent);
  }

  void _onConnectivityEvent(List<ConnectivityResult> results) {
    final hasInterface =
        results.any((r) => r != ConnectivityResult.none);
    if (!hasInterface) {
      _setOffline(true);
      return;
    }
    // An interface exists. If we believed we were offline, this is a candidate
    // reconnect — flip to online so listeners (journal replay, cached
    // surfaces) run exactly once. If the backend is still unreachable, the
    // very next failed request flips us back, and the refresh generation
    // guarantees the retry is bounded rather than a loop.
    if (_offline) _setOffline(false);
  }

  bool _offline = false;

  /// Monotonic counter, bumped on every offline→online transition. Surfaces
  /// compare it against the generation they last refreshed at, so a widget
  /// rebuild cannot trigger a second refresh for the same reconnect.
  int _onlineGeneration = 0;

  /// Keys already refreshed for the current [_onlineGeneration].
  final Set<String> _refreshedThisGeneration = {};

  /// In-flight refreshes, so concurrent callers join rather than duplicate.
  final Map<String, Future<void>> _inFlight = {};

  bool get isOffline => _offline;
  int get onlineGeneration => _onlineGeneration;

  /// Diagnostics: how many reconnect refreshes have actually executed.
  @visibleForTesting
  int refreshCount = 0;

  /// Records the outcome of a remote call. Call sites pass the classified
  /// result; this is the ONLY way status changes.
  void reportOutcome({required bool succeeded, bool wasNetworkFailure = false}) {
    if (succeeded) {
      _setOffline(false);
    } else if (wasNetworkFailure) {
      _setOffline(true);
    }
    // A non-network failure (validation, auth, conflict) says nothing about
    // connectivity and must not flip the indicator.
  }

  void _setOffline(bool value) {
    if (_offline == value) return;
    _offline = value;
    if (!value) {
      // Came back online — open a new refresh generation.
      _onlineGeneration++;
      _refreshedThisGeneration.clear();
    }
    notifyListeners();
  }

  /// Runs [refresh] AT MOST ONCE per reconnect, per [key].
  ///
  /// Rebuild-safe by construction: a widget may call this on every build and
  /// only the first call after an offline→online transition does work. This is
  /// what stops "reconnect + rebuild storm" from becoming a request storm.
  Future<void> refreshOnce(String key, Future<void> Function() refresh) {
    if (_offline) return Future<void>.value();
    if (_refreshedThisGeneration.contains(key)) return Future<void>.value();

    final existing = _inFlight[key];
    if (existing != null) return existing;

    _refreshedThisGeneration.add(key);
    refreshCount++;
    final future = refresh().catchError((Object _) {
      // A failed refresh must not wedge the key forever; allow the next
      // reconnect generation to try again.
      _refreshedThisGeneration.remove(key);
    });
    _inFlight[key] = future;
    // ignore: discarded_futures
    future.whenComplete(() {
      if (identical(_inFlight[key], future)) _inFlight.remove(key);
    });
    return future;
  }

  /// Drops per-account state on sign-out / account switch.
  void onUserSession(String? userId) {
    _refreshedThisGeneration.clear();
    _inFlight.clear();
  }

  @visibleForTesting
  void debugSetOffline(bool value) => _setOffline(value);

  @override
  void dispose() {
    // ignore: discarded_futures
    _connectivitySub?.cancel();
    _connectivitySub = null;
    super.dispose();
  }

  @visibleForTesting
  bool get isObserving => _connectivitySub != null;

  @visibleForTesting
  void resetForTest() {
    _offline = false;
    _onlineGeneration = 0;
    _refreshedThisGeneration.clear();
    _inFlight.clear();
    refreshCount = 0;
  }
}

/// True when [error] means "we could not reach the service", as opposed to
/// "the service answered and said no".
///
/// Shared by the offline UI so a single predicate decides whether the user sees
/// the offline copy or a real error. Deliberately conservative: anything not
/// recognised as a connectivity problem is NOT treated as offline, because
/// telling a user "you're offline" when they aren't is its own bug.
bool isKnownOfflineError(Object? error) {
  if (error == null) return false;
  final s = error.toString().toLowerCase();
  return s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('no address associated') ||
      s.contains('network is unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection closed') ||
      s.contains('connection reset') ||
      s.contains('no internet') ||
      s.contains('handshake') ||
      s.contains('timed out') ||
      s.contains('timeout') ||
      s.contains('clientexception') ||
      s.contains('503') ||
      s.contains('504') ||
      s.contains('service unavailable') ||
      s.contains('bad gateway');
}
