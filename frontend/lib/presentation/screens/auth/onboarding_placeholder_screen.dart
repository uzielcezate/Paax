// lib/presentation/screens/auth/onboarding_placeholder_screen.dart
//
// PREPARED route for the 5-artist onboarding (Phase 3.2). Reached when a user is
// verified with a complete profile but onboarding_completed is still false.
// It deliberately does NOT let the user into Home and does NOT mark onboarding
// complete (that is Phase 3.2). This proves routing only.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class OnboardingPlaceholderScreen extends StatelessWidget {
  const OnboardingPlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final name = context.select<AuthController, String>(
        (c) => c.profile?.greetingName ?? 'there');
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.tune, color: AppColors.textPrimary, size: 56),
              const SizedBox(height: 20),
              Text('Almost there, $name',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              const Text(
                "Next, you'll pick a few artists you love so Paax can tune your "
                'experience. This step is coming soon.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4),
              ),
              const Spacer(),
              // No "continue to Home" — onboarding must be completed first (Phase 3.2).
              Center(
                child: PaaxTextLink(
                  label: 'Log out',
                  onPressed: () => context.read<AuthController>().logout(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
