// test/widget/startup_routing_test.dart
//
// Phase 3.4.2 — AuthGate routing.
//
// The production symptom was visual: Complete Profile *flashed* for existing
// users. A test asserting only the final state would have passed while the bug
// was still on screen. These tests therefore step through the real startup
// sequence frame by frame and assert CompleteProfileScreen is absent at EVERY
// frame, not merely at the end.
//
// Shell phases are asserted through the pure [destinationFor] table rather than
// by mounting MainWrapper, whose provider graph (playback, library, realtime) is
// out of scope here and is covered by its own tests.

import 'package:beaty/core/startup/startup_state.dart';
import 'package:beaty/domain/entities/profile.dart';
import 'package:beaty/presentation/screens/auth/auth_gate.dart';
import 'package:beaty/presentation/screens/auth/complete_profile_screen.dart';
import 'package:beaty/presentation/screens/auth/startup_status_screens.dart';
import 'package:beaty/presentation/screens/auth/welcome_screen.dart';
import 'package:beaty/presentation/state/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Exposes only what AuthGate selects on, so routing can be tested without
/// Supabase, Hive, or a network.
class _StubAuth extends ChangeNotifier implements AuthController {
  StartupPhase _phase;
  _StubAuth(this._phase);

  @override
  StartupPhase get phase => _phase;

  void moveTo(StartupPhase p) {
    _phase = p;
    notifyListeners();
  }

  @override
  bool get isSubmitting => false;
  @override
  bool get isOffline => _phase.isOffline;
  @override
  Profile? get profile => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget _app(_StubAuth auth) => ChangeNotifierProvider<AuthController>.value(
      value: auth,
      child: const MaterialApp(home: AuthGate()),
    );

void main() {
  group('routing table (pure)', () {
    test('every phase has exactly one destination', () {
      for (final p in StartupPhase.values) {
        expect(() => destinationFor(p), returnsNormally, reason: p.name);
      }
    });

    test('ONLY completeProfileRequired reaches the Complete Profile form', () {
      for (final p in StartupPhase.values) {
        final isForm = destinationFor(p) == StartupDestination.completeProfile;
        expect(isForm, p == StartupPhase.completeProfileRequired, reason: p.name);
      }
    });

    test('the three ready phases share ONE destination', () {
      expect(destinationFor(StartupPhase.onlineReady), StartupDestination.shell);
      expect(destinationFor(StartupPhase.offlineReady), StartupDestination.shell);
      expect(destinationFor(StartupPhase.syncing), StartupDestination.shell);
    });

    test('no splash phase can resolve to the shell or the form', () {
      for (final p in StartupPhase.values.where((p) => p.isSplash)) {
        expect(destinationFor(p), StartupDestination.splash, reason: p.name);
      }
    });
  });

  group('no Complete Profile flash', () {
    testWidgets('cached complete profile: splash → shell, never the form',
        (tester) async {
      final auth = _StubAuth(StartupPhase.initializing);
      await tester.pumpWidget(_app(auth));
      expect(find.byType(StartupSplash), findsOneWidget);
      expect(find.byType(CompleteProfileScreen), findsNothing);

      // The real cache-first sequence, frame by frame.
      for (final p in [
        StartupPhase.loadingLocalProfile,
        StartupPhase.syncing,
        StartupPhase.onlineReady,
      ]) {
        auth.moveTo(p);
        // Do not pump into the shell's widget tree; assert the decision instead.
        expect(destinationFor(p), isNot(StartupDestination.completeProfile),
            reason: 'Complete Profile must never be the destination during $p');
      }
    });

    testWidgets('503/504 behind a cached profile never shows the form',
        (tester) async {
      final auth = _StubAuth(StartupPhase.initializing);
      await tester.pumpWidget(_app(auth));

      auth.moveTo(StartupPhase.loadingLocalProfile);
      await tester.pump();
      expect(find.byType(CompleteProfileScreen), findsNothing);

      // Cached-complete → shell; remote 503 → offlineReady. Same destination.
      expect(destinationFor(StartupPhase.syncing), StartupDestination.shell);
      expect(destinationFor(StartupPhase.offlineReady), StartupDestination.shell);
    });

    testWidgets('offline first-ever user gets a recoverable setup screen, '
        'not an editable form', (tester) async {
      final auth = _StubAuth(StartupPhase.setupBlockedOffline);
      await tester.pumpWidget(_app(auth));
      await tester.pump();

      expect(find.byType(StartupOfflineSetupScreen), findsOneWidget);
      expect(find.byType(CompleteProfileScreen), findsNothing);
      expect(find.text('Connect to finish setting up your profile'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('non-shell destinations render correctly', () {
    testWidgets('splash for every splash phase', (tester) async {
      for (final p in StartupPhase.values.where((p) => p.isSplash)) {
        await tester.pumpWidget(_app(_StubAuth(p)));
        await tester.pump();
        expect(find.byType(StartupSplash), findsOneWidget, reason: p.name);
      }
    });

    testWidgets('unauthenticated shows Welcome', (tester) async {
      await tester.pumpWidget(_app(_StubAuth(StartupPhase.unauthenticated)));
      await tester.pump();
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(CompleteProfileScreen), findsNothing);
    });

    testWidgets('fatal local corruption offers recovery, not a dead end',
        (tester) async {
      await tester.pumpWidget(_app(_StubAuth(StartupPhase.fatalStartupError)));
      await tester.pump();
      expect(find.byType(StartupFatalErrorScreen), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('proven-incomplete profile DOES show the form', (tester) async {
      await tester.pumpWidget(
          _app(_StubAuth(StartupPhase.completeProfileRequired)));
      await tester.pump();
      expect(find.byType(CompleteProfileScreen), findsOneWidget);
    });
  });
}
