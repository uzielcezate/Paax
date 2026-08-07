// lib/core/startup/startup_state.dart
//
// Explicit startup state machine (Phase 3.4.2).
//
// WHY A STATE MACHINE AND NOT A FIX
// ---------------------------------
// The previous implementation derived routing from a nullable `Profile?` plus a
// `try/catch`. That is exception-driven routing: the destination depended on
// which line threw, so every new failure mode silently acquired a default
// destination — and the default happened to be Complete Profile. Patching the
// `catch` would have fixed one symptom and left the shape intact.
//
// Here the destination is a value, not a control-flow accident. Every input is
// a named [StartupEvent]; the mapping is a pure function ([startupReducer]) that
// is exhaustive over both phase and event. A new failure mode cannot acquire a
// destination by accident — it must be added to the enum, and the switch stops
// compiling until every transition is decided deliberately.
//
// THE LOAD-BEARING INVARIANT
// --------------------------
//   completeProfileRequired is reachable from exactly ONE event:
//   RemoteProfileResolved, carrying an authoritative server answer that
//   positively proves required fields are missing.
//
// No timeout, 5xx, DNS failure, offline condition, cancellation, or unclassified
// error can reach it, because none of them can construct that event — only a
// `RemoteSuccess` can. [assertNeverFromFailure] pins this in tests.

import 'package:flutter/foundation.dart';

import '../../domain/entities/profile.dart';
import '../network/remote_result.dart';
import 'startup_diagnostics.dart';

/// Where the application is in its startup lifecycle.
enum StartupPhase {
  /// Nothing restored yet. The only legal initial phase.
  initializing,

  /// No session. Destination: Welcome/Login.
  unauthenticated,

  /// A credential exchange is in flight (login, registration, token refresh).
  authenticating,

  /// Reading the account-scoped local cache. Bounded by disk I/O only.
  loadingLocalProfile,

  /// Blocking remote lookup. Entered ONLY when there is no usable cached
  /// profile — i.e. a genuinely first-ever account on this device. An existing
  /// user never blocks here, which is what removes the splash hang.
  loadingRemoteProfile,

  /// Cached profile is complete and remote confirmed it. Full functionality.
  onlineReady,

  /// Cached profile is complete but remote is unreachable. The app is fully
  /// usable against local data; writes queue to the offline journal.
  offlineReady,

  /// Usable UI is already on screen and a background refresh is in flight.
  /// Never blocks navigation.
  syncing,

  /// PROVEN incomplete profile. Reachable only from an authoritative answer.
  completeProfileRequired,

  /// Authoritative answer proved onboarding (5-artist selection) is pending.
  onboardingRequired,

  /// First-ever account with no cache, and remote is unreachable. Recoverable:
  /// shows "Connect to finish setting up your profile", never an editable form
  /// that would imply the server had confirmed an absence.
  setupBlockedOffline,

  /// Session exists but the email is unverified.
  unverified,

  /// Password-recovery deep link is active.
  recovery,

  /// Local storage is unreadable/corrupt. Terminal until user action.
  fatalStartupError,
}

extension StartupPhaseX on StartupPhase {
  /// Phases in which the main application shell is on screen.
  bool get isShellVisible =>
      this == StartupPhase.onlineReady ||
      this == StartupPhase.offlineReady ||
      this == StartupPhase.syncing;

  /// Phases that render the splash. All are bounded — see [StartupState.deadline].
  bool get isSplash =>
      this == StartupPhase.initializing ||
      this == StartupPhase.authenticating ||
      this == StartupPhase.loadingLocalProfile ||
      this == StartupPhase.loadingRemoteProfile;

  /// True when remote data is known to be stale or absent.
  bool get isOffline =>
      this == StartupPhase.offlineReady ||
      this == StartupPhase.setupBlockedOffline;
}

/// Inputs to the state machine. One per real-world occurrence.
@immutable
sealed class StartupEvent {
  const StartupEvent();
}

/// Startup began. Emitted exactly once per session.
final class StartupRequested extends StartupEvent {
  const StartupRequested();
}

/// No session was restored.
final class NoSessionFound extends StartupEvent {
  const NoSessionFound();
}

/// A session exists. [emailVerified] gates the verification screen.
final class SessionRestored extends StartupEvent {
  final String userId;
  final bool emailVerified;
  const SessionRestored(this.userId, {required this.emailVerified});
}

/// Local cache read finished. [profile] is null when nothing was cached.
final class LocalProfileLoaded extends StartupEvent {
  final Profile? profile;
  const LocalProfileLoaded(this.profile);

  bool get hasUsableProfile => isShellReady(profile);
}

/// A profile good enough to open the shell without asking the server.
///
/// Requires BOTH gates: required fields present AND artist onboarding done.
/// Checking only [Profile.isComplete] would let a cached mid-onboarding account
/// skip the 5-artist step, so onboarding must be part of the same predicate.
bool isShellReady(Profile? p) =>
    p != null && p.isComplete && p.onboardingCompleted;

/// The remote lookup produced a result — authoritative or not.
///
/// This is the ONLY event that can reach [StartupPhase.completeProfileRequired],
/// and only when [result] is a [RemoteSuccess].
final class RemoteProfileResolved extends StartupEvent {
  final RemoteResult<Profile?> result;

  /// True when a usable cached profile exists, so a failure degrades to
  /// offlineReady rather than blocking.
  final bool hasCachedProfile;

  const RemoteProfileResolved(this.result, {required this.hasCachedProfile});
}

/// A background refresh started behind an already-visible shell.
final class BackgroundSyncStarted extends StartupEvent {
  const BackgroundSyncStarted();
}

/// Connectivity or a successful remote call restored online status.
final class ConnectivityRestored extends StartupEvent {
  const ConnectivityRestored();
}

/// The user signed out explicitly, or the session was proven invalid.
final class SignedOut extends StartupEvent {
  const SignedOut();
}

/// A password-recovery deep link arrived.
final class RecoveryRequested extends StartupEvent {
  const RecoveryRequested();
}

/// A credential exchange began.
final class AuthenticationStarted extends StartupEvent {
  const AuthenticationStarted();
}

/// Local storage is unusable.
final class LocalStorageFailed extends StartupEvent {
  final Object error;
  const LocalStorageFailed(this.error);
}

/// Immutable startup state. [phase] drives routing; the rest is context.
@immutable
class StartupState {
  final StartupPhase phase;

  /// The account this state belongs to. Guards against a stale async response
  /// from a previous account being applied after a switch.
  final String? userId;

  /// Best known profile — cached or remote. Never used to decide completeness;
  /// [StartupPhase] already encodes that decision.
  final Profile? profile;

  /// Why remote data is unavailable, when it is.
  final RemoteFailureKind? failureKind;

  /// True when [profile] came from cache and has not yet been confirmed.
  final bool isStale;

  const StartupState({
    required this.phase,
    this.userId,
    this.profile,
    this.failureKind,
    this.isStale = false,
  });

  static const initial = StartupState(phase: StartupPhase.initializing);

  StartupState copyWith({
    StartupPhase? phase,
    String? userId,
    Profile? profile,
    RemoteFailureKind? failureKind,
    bool? isStale,
    bool clearFailure = false,
    bool clearProfile = false,
    bool clearUser = false,
  }) {
    return StartupState(
      phase: phase ?? this.phase,
      userId: clearUser ? null : (userId ?? this.userId),
      profile: clearProfile ? null : (profile ?? this.profile),
      failureKind: clearFailure ? null : (failureKind ?? this.failureKind),
      isStale: isStale ?? this.isStale,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StartupState &&
      other.phase == phase &&
      other.userId == userId &&
      other.profile?.id == profile?.id &&
      other.failureKind == failureKind &&
      other.isStale == isStale;

  @override
  int get hashCode => Object.hash(phase, userId, profile?.id, failureKind, isStale);

  @override
  String toString() =>
      'StartupState(${phase.name}${userId == null ? '' : ', u=${userId!.substring(0, userId!.length.clamp(0, 8))}'}'
      '${failureKind == null ? '' : ', ${failureKind!.name}'}${isStale ? ', stale' : ''})';
}

/// The startup state machine. Pure: no I/O, no clock, no globals.
///
/// Purity is what makes the safety property testable — every (phase, event) pair
/// can be enumerated in a unit test without a network, a device, or a fake clock.
StartupState startupReducer(StartupState s, StartupEvent e) {
  final next = _reduce(s, e);
  if (next.phase != s.phase) {
    StartupDiagnostics.recordTransition(s.phase.name, next.phase.name, e.runtimeType.toString());
  }
  return next;
}

StartupState _reduce(StartupState s, StartupEvent e) {
  switch (e) {
    // ── terminal / global events ────────────────────────────────────────────
    // Handled first: they are valid from ANY phase.
    case SignedOut():
      // Explicit sign-out always wins, including while offline. Returning to
      // the cached Home after an intentional logout would be a data leak.
      return const StartupState(phase: StartupPhase.unauthenticated);

    case RecoveryRequested():
      return s.copyWith(phase: StartupPhase.recovery);

    case LocalStorageFailed():
      return s.copyWith(phase: StartupPhase.fatalStartupError);

    case AuthenticationStarted():
      return s.copyWith(phase: StartupPhase.authenticating);

    // ── startup sequence ────────────────────────────────────────────────────
    case StartupRequested():
      return s.copyWith(phase: StartupPhase.initializing);

    case NoSessionFound():
      return const StartupState(phase: StartupPhase.unauthenticated);

    case SessionRestored(userId: final uid, emailVerified: final verified):
      if (!verified) {
        return StartupState(phase: StartupPhase.unverified, userId: uid);
      }
      // A different account → drop all prior context so nothing bleeds across.
      final switched = s.userId != null && s.userId != uid;
      return StartupState(
        phase: StartupPhase.loadingLocalProfile,
        userId: uid,
        profile: switched ? null : s.profile,
      );

    case LocalProfileLoaded(profile: final p):
      // Cache-first: a complete cached profile opens the shell IMMEDIATELY.
      // Remote confirmation happens behind the visible UI. This single branch is
      // what removes both the splash hang and the Complete-Profile flash.
      if (isShellReady(p)) {
        return s.copyWith(
          phase: StartupPhase.syncing,
          profile: p,
          isStale: true,
          clearFailure: true,
        );
      }
      // No usable cache → we must ask the server before claiming anything about
      // this profile. Note we do NOT route to completeProfileRequired here: an
      // empty cache is not evidence about the server's state.
      return s.copyWith(
        phase: StartupPhase.loadingRemoteProfile,
        profile: p,
        isStale: p != null,
      );

    case RemoteProfileResolved(result: final r, hasCachedProfile: final cached):
      switch (r) {
        // ── the ONLY authoritative branch ──────────────────────────────────
        case RemoteSuccess<Profile?>(value: final p):
          if (p == null || !p.isComplete) {
            // Server was reached, RLS applied, required fields proven missing.
            return s.copyWith(
              phase: StartupPhase.completeProfileRequired,
              profile: p,
              isStale: false,
              clearFailure: true,
              clearProfile: p == null,
            );
          }
          if (!p.onboardingCompleted) {
            return s.copyWith(
              phase: StartupPhase.onboardingRequired,
              profile: p,
              isStale: false,
              clearFailure: true,
            );
          }
          return s.copyWith(
            phase: StartupPhase.onlineReady,
            profile: p,
            isStale: false,
            clearFailure: true,
          );

        // ── no authoritative answer: NEVER a claim about the profile ───────
        case RemoteUnavailable<Profile?>(kind: final kind):
          // A revoked/expired session is the one failure that legitimately
          // changes auth state — but it routes to sign-in, never to onboarding.
          if (kind == RemoteFailureKind.unauthorized) {
            return const StartupState(phase: StartupPhase.unauthenticated);
          }
          if (cached || isShellReady(s.profile)) {
            // Usable cache → full offline app. This is the happy degraded path.
            return s.copyWith(
              phase: StartupPhase.offlineReady,
              failureKind: kind,
              isStale: true,
            );
          }
          // First-ever account, no cache, no server: recoverable, and honest
          // about the fact that nothing has been confirmed.
          return s.copyWith(
            phase: StartupPhase.setupBlockedOffline,
            failureKind: kind,
            isStale: false,
          );
      }

    case BackgroundSyncStarted():
      // Only meaningful behind a visible shell; never pulls the UI backwards.
      return s.phase.isShellVisible ? s.copyWith(phase: StartupPhase.syncing) : s;

    case ConnectivityRestored():
      return s.phase == StartupPhase.offlineReady
          ? s.copyWith(phase: StartupPhase.syncing, clearFailure: true)
          : s;
  }
}

/// Test-facing statement of the safety property.
///
/// Asserts that no failed remote result, for any failure kind and either cache
/// state, can produce [StartupPhase.completeProfileRequired]. Exported (rather
/// than living in the test file) so the guarantee travels with the machine it
/// constrains.
@visibleForTesting
void assertNeverFromFailure() {
  for (final kind in RemoteFailureKind.values) {
    for (final cached in [true, false]) {
      for (final phase in StartupPhase.values) {
        final s = StartupState(phase: phase, userId: 'u1');
        final out = startupReducer(
          s,
          RemoteProfileResolved(
            RemoteUnavailable<Profile?>(kind),
            hasCachedProfile: cached,
          ),
        );
        if (out.phase == StartupPhase.completeProfileRequired) {
          throw StateError(
            'INVARIANT VIOLATED: ${kind.name} with cached=$cached from '
            '${phase.name} produced completeProfileRequired',
          );
        }
      }
    }
  }
}
