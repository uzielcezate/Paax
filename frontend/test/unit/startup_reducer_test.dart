// test/unit/startup_reducer_test.dart
//
// Phase 3.4.2 — startup state machine.
//
// The headline test is `NEVER routes to completeProfileRequired on failure`,
// which enumerates every failure kind × cache state × source phase. That is the
// production defect (Supabase 503/504 → "Complete profile") expressed as an
// exhaustive property rather than a single regression case.

import 'package:beaty/core/network/remote_result.dart';
import 'package:beaty/core/startup/startup_diagnostics.dart';
import 'package:beaty/core/startup/startup_state.dart';
import 'package:beaty/domain/entities/profile.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _complete({
  String id = 'u1',
  bool onboarded = true,
}) =>
    Profile(
      id: id,
      username: 'iamleizu',
      displayName: 'Uziel',
      firstName: 'Uziel',
      birthDate: DateTime(1998, 4, 12),
      countryCode: 'MX',
      onboardingCompleted: onboarded,
    );

Profile _incomplete({String id = 'u1'}) => Profile(id: id, username: 'x');

void main() {
  setUp(StartupDiagnostics.reset);

  group('safety invariant — failure never means "profile incomplete"', () {
    test('exhaustive: no failure kind, from any phase, reaches completeProfileRequired',
        () {
      // Throws with a precise counter-example if the invariant is ever broken.
      expect(assertNeverFromFailure, returnsNormally);
    });

    test('each failure kind individually, with a cached profile → offlineReady', () {
      for (final kind in RemoteFailureKind.values) {
        if (kind == RemoteFailureKind.unauthorized) continue; // asserted below
        final s = StartupState(
          phase: StartupPhase.syncing,
          userId: 'u1',
          profile: _complete(),
        );
        final out = startupReducer(
          s,
          RemoteProfileResolved(
            RemoteUnavailable<Profile?>(kind),
            hasCachedProfile: true,
          ),
        );
        expect(out.phase, StartupPhase.offlineReady, reason: 'kind=${kind.name}');
        expect(out.failureKind, kind);
        expect(out.isStale, isTrue);
      }
    });

    test('each failure kind individually, no cache → setupBlockedOffline', () {
      for (final kind in RemoteFailureKind.values) {
        if (kind == RemoteFailureKind.unauthorized) continue;
        final out = startupReducer(
          const StartupState(
              phase: StartupPhase.loadingRemoteProfile, userId: 'u1'),
          RemoteProfileResolved(
            RemoteUnavailable<Profile?>(kind),
            hasCachedProfile: false,
          ),
        );
        expect(out.phase, StartupPhase.setupBlockedOffline,
            reason: 'kind=${kind.name}');
        expect(out.phase, isNot(StartupPhase.completeProfileRequired));
      }
    });

    test('503/504 server-unavailable — the exact production failure', () {
      final out = startupReducer(
        StartupState(
            phase: StartupPhase.syncing, userId: 'u1', profile: _complete()),
        const RemoteProfileResolved(
          RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable),
          hasCachedProfile: true,
        ),
      );
      expect(out.phase, StartupPhase.offlineReady);
    });

    test('unauthorized is the ONLY failure that changes auth state', () {
      final out = startupReducer(
        StartupState(
            phase: StartupPhase.syncing, userId: 'u1', profile: _complete()),
        const RemoteProfileResolved(
          RemoteUnavailable<Profile?>(RemoteFailureKind.unauthorized),
          hasCachedProfile: true,
        ),
      );
      expect(out.phase, StartupPhase.unauthenticated);
      expect(out.phase, isNot(StartupPhase.completeProfileRequired));
    });
  });

  group('completeProfileRequired is reachable only from authority', () {
    test('authoritative null (no row) → completeProfileRequired', () {
      final out = startupReducer(
        const StartupState(
            phase: StartupPhase.loadingRemoteProfile, userId: 'u1'),
        const RemoteProfileResolved(
          RemoteSuccess<Profile?>(null),
          hasCachedProfile: false,
        ),
      );
      expect(out.phase, StartupPhase.completeProfileRequired);
      expect(out.profile, isNull);
    });

    test('authoritative incomplete row → completeProfileRequired', () {
      final out = startupReducer(
        const StartupState(
            phase: StartupPhase.loadingRemoteProfile, userId: 'u1'),
        RemoteProfileResolved(
          RemoteSuccess<Profile?>(_incomplete()),
          hasCachedProfile: false,
        ),
      );
      expect(out.phase, StartupPhase.completeProfileRequired);
    });

    test('authoritative complete + onboarded → onlineReady, not stale', () {
      final out = startupReducer(
        const StartupState(
            phase: StartupPhase.loadingRemoteProfile, userId: 'u1'),
        RemoteProfileResolved(
          RemoteSuccess<Profile?>(_complete()),
          hasCachedProfile: false,
        ),
      );
      expect(out.phase, StartupPhase.onlineReady);
      expect(out.isStale, isFalse);
      expect(out.failureKind, isNull);
    });

    test('authoritative complete but onboarding pending → onboardingRequired', () {
      final out = startupReducer(
        const StartupState(
            phase: StartupPhase.loadingRemoteProfile, userId: 'u1'),
        RemoteProfileResolved(
          RemoteSuccess<Profile?>(_complete(onboarded: false)),
          hasCachedProfile: false,
        ),
      );
      expect(out.phase, StartupPhase.onboardingRequired);
    });

    test('a later authoritative "incomplete" DOES correct an offline shell', () {
      // Cached-complete opened the shell; the server later disagrees.
      // Routing must follow authority — this is the one legitimate way to
      // leave a ready shell for Complete Profile.
      var s = StartupState(
          phase: StartupPhase.offlineReady, userId: 'u1', profile: _complete());
      s = startupReducer(
        s,
        RemoteProfileResolved(
          RemoteSuccess<Profile?>(_incomplete()),
          hasCachedProfile: true,
        ),
      );
      expect(s.phase, StartupPhase.completeProfileRequired);
    });
  });

  group('cache-first startup', () {
    test('complete cached profile opens the shell without waiting for remote', () {
      var s = const StartupState(phase: StartupPhase.initializing);
      s = startupReducer(s, const SessionRestored('u1', emailVerified: true));
      expect(s.phase, StartupPhase.loadingLocalProfile);

      s = startupReducer(s, LocalProfileLoaded(_complete()));
      expect(s.phase, StartupPhase.syncing);
      expect(s.phase.isShellVisible, isTrue,
          reason: 'shell must be visible before any remote call');
      expect(s.isStale, isTrue);
    });

    test('empty cache does NOT claim incomplete — it asks the server', () {
      var s = const StartupState(phase: StartupPhase.loadingLocalProfile, userId: 'u1');
      s = startupReducer(s, const LocalProfileLoaded(null));
      expect(s.phase, StartupPhase.loadingRemoteProfile);
      expect(s.phase, isNot(StartupPhase.completeProfileRequired));
    });

    test('cached profile mid-onboarding must not skip the onboarding gate', () {
      var s = const StartupState(phase: StartupPhase.loadingLocalProfile, userId: 'u1');
      s = startupReducer(s, LocalProfileLoaded(_complete(onboarded: false)));
      expect(s.phase, StartupPhase.loadingRemoteProfile);
      expect(s.phase.isShellVisible, isFalse);
    });

    test('cached-complete + remote failure = uninterrupted offline shell', () {
      var s = const StartupState(phase: StartupPhase.initializing);
      s = startupReducer(s, const SessionRestored('u1', emailVerified: true));
      s = startupReducer(s, LocalProfileLoaded(_complete()));
      final beforeShell = s.phase.isShellVisible;
      s = startupReducer(
        s,
        const RemoteProfileResolved(
          RemoteUnavailable<Profile?>(RemoteFailureKind.offline),
          hasCachedProfile: true,
        ),
      );
      expect(beforeShell, isTrue);
      expect(s.phase, StartupPhase.offlineReady);
      expect(s.phase.isShellVisible, isTrue,
          reason: 'the shell must never be torn down by going offline');
    });
  });

  group('account isolation + session lifecycle', () {
    test('switching account drops the previous profile', () {
      var s = StartupState(
          phase: StartupPhase.onlineReady, userId: 'A', profile: _complete(id: 'A'));
      s = startupReducer(s, const SessionRestored('B', emailVerified: true));
      expect(s.userId, 'B');
      expect(s.profile, isNull, reason: 'account A data must not leak into B');
    });

    test('same account re-restore keeps the profile (no flicker)', () {
      var s = StartupState(
          phase: StartupPhase.onlineReady, userId: 'A', profile: _complete(id: 'A'));
      s = startupReducer(s, const SessionRestored('A', emailVerified: true));
      expect(s.profile, isNotNull);
    });

    test('explicit sign-out wins from every phase, including offline', () {
      for (final phase in StartupPhase.values) {
        final out = startupReducer(
          StartupState(phase: phase, userId: 'u1', profile: _complete()),
          const SignedOut(),
        );
        expect(out.phase, StartupPhase.unauthenticated, reason: phase.name);
        expect(out.profile, isNull, reason: 'sign-out must clear cached profile');
        expect(out.userId, isNull);
      }
    });

    test('unverified email routes to verification, never to the shell', () {
      final out = startupReducer(
        const StartupState(phase: StartupPhase.initializing),
        const SessionRestored('u1', emailVerified: false),
      );
      expect(out.phase, StartupPhase.unverified);
    });

    test('no session → unauthenticated', () {
      final out = startupReducer(
          const StartupState(phase: StartupPhase.initializing), const NoSessionFound());
      expect(out.phase, StartupPhase.unauthenticated);
    });
  });

  group('no route thrash', () {
    test('BackgroundSyncStarted is ignored unless the shell is visible', () {
      for (final phase in StartupPhase.values) {
        final s = StartupState(phase: phase, userId: 'u1');
        final out = startupReducer(s, const BackgroundSyncStarted());
        if (phase.isShellVisible) {
          expect(out.phase, StartupPhase.syncing, reason: phase.name);
        } else {
          expect(out.phase, phase,
              reason: 'background sync must not move $phase');
        }
      }
    });

    test('ConnectivityRestored only lifts offlineReady', () {
      expect(
        startupReducer(
          const StartupState(phase: StartupPhase.offlineReady, userId: 'u'),
          const ConnectivityRestored(),
        ).phase,
        StartupPhase.syncing,
      );
      expect(
        startupReducer(
          const StartupState(phase: StartupPhase.completeProfileRequired, userId: 'u'),
          const ConnectivityRestored(),
        ).phase,
        StartupPhase.completeProfileRequired,
      );
    });

    test('all three ready phases render the same shell', () {
      expect(StartupPhase.onlineReady.isShellVisible, isTrue);
      expect(StartupPhase.offlineReady.isShellVisible, isTrue);
      expect(StartupPhase.syncing.isShellVisible, isTrue);
    });

    test('every splash phase is a splash, and none is a shell', () {
      for (final p in StartupPhase.values) {
        expect(p.isSplash && p.isShellVisible, isFalse, reason: p.name);
      }
    });
  });

  group('fatal local corruption', () {
    test('LocalStorageFailed → fatalStartupError, from any phase', () {
      for (final phase in StartupPhase.values) {
        final out = startupReducer(
          StartupState(phase: phase, userId: 'u1'),
          const LocalStorageFailed('boom'),
        );
        expect(out.phase, StartupPhase.fatalStartupError, reason: phase.name);
      }
    });
  });

  group('diagnostics', () {
    test('transitions are recorded for debugging', () {
      var s = const StartupState(phase: StartupPhase.initializing);
      s = startupReducer(s, const SessionRestored('u1', emailVerified: true));
      s = startupReducer(s, LocalProfileLoaded(_complete()));
      expect(StartupDiagnostics.stateTransitions, greaterThanOrEqualTo(2));
      expect(StartupDiagnostics.transitionLog.join('\n'), contains('syncing'));
    });

    test('identical phase produces no recorded transition', () {
      final before = StartupDiagnostics.stateTransitions;
      startupReducer(
        const StartupState(phase: StartupPhase.onlineReady, userId: 'u'),
        const ConnectivityRestored(), // no-op from onlineReady
      );
      expect(StartupDiagnostics.stateTransitions, before);
    });
  });
}
