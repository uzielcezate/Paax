import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../widgets/mini_player.dart';
import '../widgets/hidden_video_player.dart';
import '../widgets/black_glass_blur_surface.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  static final GlobalKey<MainWrapperState> shellKey = GlobalKey<MainWrapperState>();

  @override
  State<MainWrapper> createState() => MainWrapperState();
}

class MainWrapperState extends State<MainWrapper> {
  int _currentIndex = 0;
  final List<int> _history = [];
  
  final List<GlobalKey<NavigatorState>> _navigatorKeys = [
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
    GlobalKey<NavigatorState>(),
  ];

  final List<Widget> _rootPages = [
    const HomeScreen(),
    const SearchScreen(),
    const LibraryScreen(),
    const ProfileScreen(),
  ];

  Future<bool> _onWillPop() async {
    // We can reuse the logic, but _onWillPop expects a bool return for system back.
    // simple wrapper:
    final handled = onBackPressed();
    return !handled; // If handled (true), return false (don't exit). If not handled (false), return true (exit).
  }

  /// Returns true if the back action was handled internally (pop or tab switch).
  /// Returns false if the app should probably exit or do default behavior.
  bool onBackPressed() {
    final NavigatorState? currentNavigator = _navigatorKeys[_currentIndex].currentState;
    
    // 1. Try to pop internal route in current tab
    if (currentNavigator != null && currentNavigator.canPop()) {
      currentNavigator.pop();
      return true;
    }
    
    // 2. Try to go back to previous tab
    if (_history.isNotEmpty) {
      setState(() {
        _currentIndex = _history.removeLast();
      });
      return true;
    }
    
    // 3. If no history, but not on Home, go to Home
    if (_currentIndex != 0) {
       setState(() => _currentIndex = 0);
       return true;
    }
    
    // 4. Not handled (at Home root, no history)
    return false;
  }

  void _onTabTapped(int index) {
    if (_currentIndex == index) {
      // Pop to root if tapping same tab
      _navigatorKeys[index].currentState?.popUntil((route) => route.isFirst);
    } else {
      setState(() {
        _history.add(_currentIndex);
        _currentIndex = index;
      });
    }
  }

  void navigateTo(Route route) {
     if (_navigatorKeys[_currentIndex].currentState != null) {
       _navigatorKeys[_currentIndex].currentState!.push(route);
     }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to playback state to adjust padding
    final currentTrack = context.select<PlaybackController, dynamic>((c) => c.currentTrack);
    final bool hasTrack = currentTrack != null;
    
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        extendBody: true, 
        resizeToAvoidBottomInset: false, 
        body: Stack(
          children: [
            const HiddenVideoPlayer(), // Keeps player active but hidden
            IndexedStack(
              index: _currentIndex,
              children: _rootPages.asMap().entries.map((entry) {
                 final int idx = entry.key;
                 final Widget rootPage = entry.value;
                 
                 return Navigator(
                   key: _navigatorKeys[idx],
                   onGenerateRoute: (settings) {
                     WidgetBuilder builder;
                     if (settings.name == '/') {
                        builder = (context) => rootPage;
                     } else {
                        builder = (context) => rootPage; // Fallback
                     }
                     
                     return MaterialPageRoute(
                         builder: (context) => AnimatedPadding(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          // Remove bottom padding so content extends behind the glass bars
                          padding: EdgeInsets.zero, 
                          child: builder(context), 
                        ),
                       settings: settings
                     );
                   },
                 );
              }).toList(),
            ),
            
            Positioned(
              left: 0, 
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   AnimatedSize(
                     duration: const Duration(milliseconds: 300),
                     curve: Curves.easeInOut,
                     child: hasTrack ? const MiniPlayer() : const SizedBox.shrink(),
                   ),
                   _buildBottomNav(),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    // GestureDetector ensures touches don't pass through the nav bar to content behind
    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: BlackGlassBlurSurface(
        height: 80,
        topBorder: true,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _navItem(0, Icons.home_rounded, "Home"),
            _navItem(1, Icons.search_rounded, "Search"),
            _navItem(2, Icons.library_music_rounded, "Library"),
            _navItem(3, Icons.person_rounded, "Profile"),
          ],
        )
      ),
    );
  }
  
  Widget _navItem(int index, IconData icon, String label) {
    bool isSelected = _currentIndex == index;
    // Expanded increases the hit target to fill the row
    return Expanded(
      child: GestureDetector(
        onTap: () => _onTabTapped(index),
        behavior: HitTestBehavior.translucent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : Colors.white24,
              size: 28,
            ),
            if (isSelected) ...[
              const SizedBox(height: 4),
              Container(
                width: 4, height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.primaryGradient,
                ),
              )
            ]
          ],
        ),
      ),
    );
  }
}
