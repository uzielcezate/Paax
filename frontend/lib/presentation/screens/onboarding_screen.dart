import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/auth_controller.dart';
import 'auth_screen.dart';
import '../../core/theme/app_colors.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  
  final List<Map<String, String>> _pages = [
    {
      "title": "Discover music you’ll love",
      "subtitle": "Explore millions of tracks tailored just for your taste.",
      "icon": "library_music_rounded"
    },
    {
      "title": "Save favorites & Playlists",
      "subtitle": "Build your personal collection and listen anytime.",
      "icon": "favorite_rounded"
    },
    {
      "title": "Smart Library, Premium UI",
      "subtitle": "Experience music with a stunning, polished interface.",
      "icon": "graphic_eq_rounded"
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _pages.length,
            onPageChanged: (index) => setState(() => _currentPage = index),
            itemBuilder: (context, index) {
              return _buildPage(
                _pages[index]["title"]!,
                _pages[index]["subtitle"]!,
                _getIconData(_pages[index]["icon"]!),
              );
            },
          ),
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _pages.length,
                    (index) => Container(
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: _currentPage == index ? 24 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _currentPage == index
                            ? AppColors.primaryStart
                            : Colors.grey.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: () {
                    if (_currentPage < _pages.length - 1) {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeIn,
                      );
                    } else {
                      _finishOnboarding();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.zero, // Important for Ink
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(56),
                    ),
                  ),
                  child: Ink(
                    decoration: BoxDecoration(
                      gradient: AppColors.primaryGradient,
                      borderRadius: BorderRadius.circular(56),
                    ),
                    child: Container(
                         alignment: Alignment.center,
                         height: 56, // constraint
                         child: Text(
                            _currentPage == _pages.length - 1 ? "Get Started" : "Next",
                         ),
                    ),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildPage(String title, String subtitle, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceLight.withOpacity(0.5),
            ),
            child: Icon(icon, size: 80, color: AppColors.primaryStart),
          ),
          const SizedBox(height: 48),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }

  IconData _getIconData(String name) {
    switch (name) {
      case "library_music_rounded":
        return Icons.library_music_rounded;
      case "favorite_rounded":
        return Icons.favorite_rounded;
      case "graphic_eq_rounded":
        return Icons.graphic_eq_rounded;
      default:
        return Icons.music_note;
    }
  }

  void _finishOnboarding() {
    context.read<AuthController>().completeOnboarding();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }
}
