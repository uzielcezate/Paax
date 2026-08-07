// lib/presentation/screens/auth/auth_gate.dart
//
// Deterministic startup router (Phase 3.1 → 3.4.2).
//
// Reacts to [StartupPhase] and shows exactly one destination. A Selector keeps
// the rebuild scoped to the phase, so background reconciliation (onlineReady ⇄
// syncing) never re-creates the shell and never thrashes routes.
//
// Phase 3.4.2: routing is driven by the explicit startup state machine rather
// than by a nullable profile plus a try/catch. Notably, `offlineReady` and
// `syncing` both render the SAME `MainWrapper` instance (same key) as
// `onlineReady` — going offline changes an indicator, never the route.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/startup/startup_state.dart';
import '../../state/auth_controller.dart';
import '../../state/onboarding_controller.dart';
import '../main_wrapper.dart';
import '../onboarding/artist_onboarding_screen.dart';
import 'complete_profile_screen.dart';
import 'reset_password_screen.dart';
import 'startup_status_screens.dart';
import 'verify_email_screen.dart';
import 'welcome_screen.dart';

/// The one destination a [StartupPhase] resolves to.
///
/// Separating the DECISION from the WIDGET keeps the routing table exhaustively
/// testable without mounting the shell's full provider graph, and makes the
/// "which phases share a destination" question answerable at a glance.
enum StartupDestination {
  splash,
  welcome,
  verifyEmail,
  resetPassword,
  completeProfile,
  artistOnboarding,
  offlineSetup,
  fatalError,
  shell,
}

/// Pure phase → destination mapping. Exhaustive by construction.
StartupDestination destinationFor(StartupPhase phase) {
  switch (phase) {
    case StartupPhase.initializing:
    case StartupPhase.authenticating:
    case StartupPhase.loadingLocalProfile:
    case StartupPhase.loadingRemoteProfile:
      return StartupDestination.splash;
    case StartupPhase.unauthenticated:
      return StartupDestination.welcome;
    case StartupPhase.unverified:
      return StartupDestination.verifyEmail;
    case StartupPhase.recovery:
      return StartupDestination.resetPassword;
    case StartupPhase.completeProfileRequired:
      return StartupDestination.completeProfile;
    case StartupPhase.onboardingRequired:
      return StartupDestination.artistOnboarding;
    case StartupPhase.setupBlockedOffline:
      return StartupDestination.offlineSetup;
    case StartupPhase.fatalStartupError:
      return StartupDestination.fatalError;
    // One destination for all three ⇒ connectivity changes never switch routes.
    case StartupPhase.onlineReady:
    case StartupPhase.offlineReady:
    case StartupPhase.syncing:
      return StartupDestination.shell;
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // Selecting on the DESTINATION (not the phase) means onlineReady ⇄ syncing ⇄
    // offlineReady does not even rebuild this widget — the shell is untouched.
    return Selector<AuthController, StartupDestination>(
      selector: (_, c) => destinationFor(c.phase),
      builder: (context, destination, _) {
        switch (destination) {
          // Bounded splash. Every phase mapping here has a hard deadline
          // enforced by RetryPolicy.totalBudget, so none can hang forever.
          case StartupDestination.splash:
            return const StartupSplash();

          case StartupDestination.welcome:
            return const WelcomeScreen();

          case StartupDestination.verifyEmail:
            return const VerifyEmailScreen();

          case StartupDestination.resetPassword:
            return const ResetPasswordScreen();

          // Reachable ONLY from an authoritative server answer proving required
          // fields are missing. See core/startup/startup_state.dart.
          case StartupDestination.completeProfile:
            return const CompleteProfileScreen();

          case StartupDestination.artistOnboarding:
            return ChangeNotifierProvider(
              create: (_) => OnboardingController(),
              child: const ArtistOnboardingScreen(),
            );

          // First-ever account, no cache, server unreachable. Recoverable and
          // honest — deliberately NOT an editable profile form, which would
          // imply the server had confirmed an absence it never confirmed.
          case StartupDestination.offlineSetup:
            return const StartupOfflineSetupScreen();

          case StartupDestination.fatalError:
            return const StartupFatalErrorScreen();

          // Shared by onlineReady / offlineReady / syncing. Identical widget +
          // key ⇒ Flutter reuses the element, so connectivity changes cannot
          // remount Home/Library, lose scroll position, or interrupt playback.
          case StartupDestination.shell:
            return MainWrapper(key: MainWrapper.shellKey);
        }
      },
    );
  }
}

/// Helper to push auth sub-routes on the root navigator without breaking the
/// gate's single-destination model (these are pushed ON TOP of the gate).
class AuthRoutes {
  static Future<T?> push<T>(BuildContext context, Widget screen) =>
      Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
}
