// lib/presentation/screens/auth/auth_gate.dart
//
// Deterministic auth router. Reacts to AuthController.state and shows exactly
// one destination. Uses a Selector so auth-event storms don't cause duplicate
// route pushes (single widget swap, no Navigator loops).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../state/onboarding_controller.dart';
import '../main_wrapper.dart';
import '../onboarding/artist_onboarding_screen.dart';
import 'complete_profile_screen.dart';
import 'reset_password_screen.dart';
import 'verify_email_screen.dart';
import 'welcome_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<AuthController, AppAuthState>(
      selector: (_, c) => c.state,
      builder: (context, state, _) {
        switch (state) {
          case AppAuthState.initializing:
          case AppAuthState.profileLoading:
            return const _AuthSplash();
          case AppAuthState.unauthenticated:
            return const WelcomeScreen();
          case AppAuthState.unverified:
            return const VerifyEmailScreen();
          case AppAuthState.recovery:
            return const ResetPasswordScreen();
          case AppAuthState.completeProfile:
            return const CompleteProfileScreen();
          case AppAuthState.onboarding:
            return ChangeNotifierProvider(
              create: (_) => OnboardingController(),
              child: const ArtistOnboardingScreen(),
            );
          case AppAuthState.ready:
            return MainWrapper(key: MainWrapper.shellKey);
        }
      },
    );
  }
}

/// Initialization/loading splash — shown while the session is restored so the
/// Login screen never flashes for an already-signed-in user.
class _AuthSplash extends StatelessWidget {
  const _AuthSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Paax',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5)),
            SizedBox(height: 24),
            SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

/// Helper to push auth sub-routes on the root navigator without breaking the
/// gate's single-destination model (these are pushed ON TOP of the gate).
class AuthRoutes {
  static Future<T?> push<T>(BuildContext context, Widget screen) =>
      Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
}
