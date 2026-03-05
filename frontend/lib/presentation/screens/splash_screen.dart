import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/auth_controller.dart';
import 'onboarding_screen.dart';
import 'auth_screen.dart';
import 'main_wrapper.dart';
import '../../core/theme/app_colors.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // Reduced from 2 s → 600 ms: polished but never makes the user wait
      duration: const Duration(milliseconds: 600),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    // Start animation and navigation check in parallel.
    // Auth state is read from Hive (synchronous), so _checkNavigation
    // is ready before the animation finishes — we navigate as soon as
    // the animation completes (max 600 ms wait).
    _controller.forward().whenComplete(_checkNavigation);
  }

  void _checkNavigation() {
    if (!mounted) return;
    final auth = context.read<AuthController>();

    Widget nextScreen;
    if (!auth.onboardingCompleted) {
      nextScreen = const OnboardingScreen();
    } else if (!auth.isAuthenticated) {
      nextScreen = const AuthScreen();
    } else {
      nextScreen = MainWrapper(key: MainWrapper.shellKey);
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => nextScreen),
    );
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: ScaleTransition(
            scale: _scaleAnimation,
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.primaryGradient,
                boxShadow: [
                   BoxShadow(
                     color: AppColors.primaryStart,
                     blurRadius: 30,
                     spreadRadius: 5,
                     blurStyle: BlurStyle.normal,
                   )
                ]
              ),
              child: const Icon(
                Icons.music_note_rounded,
                size: 80,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
