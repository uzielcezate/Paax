// lib/core/network/offline_status.dart
//
// One app-scoped source of truth for "are we offline?" (Phase 3.4.5).
//
// WHY NOT A CONNECTIVITY PLUGIN, AND WHY NOT PER-SCREEN
// -----------------------------------------------------
// Two constraints shaped this:
//
//   1. Screens must not each open their own connectivity subscription. Five
//      screens × one listener each is five things to leak, and this codebase
//      has already been bitten by duplicated listeners.
//   2. The OS connectivity flag answers the wrong question. It reports "an
//      interface is up", which is true on a captive portal, on a VPN that is
//      down, and while Supabase itself is unreachable — all of which are
//      offline from the user's point of view. During the 2026-08-08 incident
//      the device had connectivity and the backend still refused everything.
//
// So offline status is DERIVED FROM ACTUAL REQUEST OUTCOMES, reusing the
// failure taxonomy from Phase 3.4.4: a `transientNetwork` failure marks us
// offline, any success marks us online. That is both cheaper and more truthful
// than asking the platform, and it adds no new subscription anywhere.
//
// This class also owns the single-flight reconnect registry, so a surface can
// ask to refresh exactly once when connectivity returns without each screen
// inventing its own guard.

import 'package:flutter/foundation.dart';

class OfflineStatus extends ChangeNotifier {
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
