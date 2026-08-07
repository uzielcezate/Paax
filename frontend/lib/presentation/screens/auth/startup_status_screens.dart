// lib/presentation/screens/auth/startup_status_screens.dart
//
// Startup splash + recoverable startup states (Phase 3.4.2).
//
// Every screen here is a DEAD END ONLY IF the user has no recourse — so none of
// them are. Each offers an explicit action, per the UX rule that no error state
// may be a dead end.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/startup/startup_diagnostics.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';

/// Initialization splash — shown while the session and local cache are
/// restored, so the Login screen never flashes for an already-signed-in user.
///
/// Bounded by construction: the phases that render it are all governed by
/// `RetryPolicy.totalBudget`, so this cannot spin indefinitely the way the
/// pre-3.4.2 `profileLoading` state could.
class StartupSplash extends StatelessWidget {
  const StartupSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Center(
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
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white54)),
              ],
            ),
          ),
          // Debug-only startup counters. Compile-time constant ⇒ absent from
          // release builds entirely.
          if (StartupDiagnostics.enabled) const _DiagnosticsFooter(),
        ],
      ),
    );
  }
}

/// First-ever account, no local cache, remote unreachable.
///
/// Deliberately NOT the Complete Profile form: nothing has been confirmed about
/// this account yet, and showing an editable form would imply otherwise.
class StartupOfflineSetupScreen extends StatelessWidget {
  const StartupOfflineSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded,
                    size: 56, color: Colors.white38),
                const SizedBox(height: 20),
                const Text(
                  'Connect to finish setting up your profile',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Text(
                  'You\'re signed in, but we haven\'t been able to reach Paax '
                  'to load your profile yet. Check your connection and try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  onPressed: auth.isSubmitting
                      ? null
                      // ignore: discarded_futures
                      : () => auth.retryStartup(),
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  // ignore: discarded_futures
                  onPressed: () => auth.logout(),
                  child: const Text('Sign out',
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Local storage is unreadable. The only terminal startup state, and even this
/// offers a retry plus a sign-out escape hatch.
class StartupFatalErrorScreen extends StatelessWidget {
  const StartupFatalErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 56, color: Colors.white38),
                const SizedBox(height: 20),
                const Text(
                  'Couldn\'t start Paax',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Some local data on this device couldn\'t be read. Try again, '
                  'or sign out to start fresh.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 28),
                FilledButton(
                  // ignore: discarded_futures
                  onPressed: () => auth.retryStartup(),
                  child: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  // ignore: discarded_futures
                  onPressed: () => auth.logout(),
                  child: const Text('Sign out',
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Debug-only counter strip. Never present in release builds.
class _DiagnosticsFooter extends StatelessWidget {
  const _DiagnosticsFooter();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 8,
      child: IgnorePointer(
        child: Text(
          StartupDiagnostics.snapshot(),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white24, fontSize: 9),
        ),
      ),
    );
  }
}
