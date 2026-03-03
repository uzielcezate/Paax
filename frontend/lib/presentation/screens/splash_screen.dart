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
      duration: const Duration(seconds: 2),
    );
    
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _controller.forward().whenComplete(_checkNavigation);
  }

  void _checkNavigation() {
    final auth = context.read<AuthController>();
    
    Widget nextScreen;
    if (!auth.onboardingCompleted) {
      nextScreen = const OnboardingScreen();
    } else if (!auth.isAuthenticated) {
      nextScreen = const AuthScreen();
    } else {
      nextScreen = MainWrapper(key: MainWrapper.shellKey); // Home
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
