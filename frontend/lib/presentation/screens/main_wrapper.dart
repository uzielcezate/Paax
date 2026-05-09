import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../widgets/mini_player.dart';
import '../widgets/hidden_video_player.dart';
import '../widgets/glass_surface.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';
import '../state/theme_state.dart';

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  static final GlobalKey<MainWrapperState> shellKey = GlobalKey<MainWrapperState>();

  @override
  State<MainWrapper> createState() => MainWrapperState();
}

class MainWrapperState extends State<MainWrapper> {
  int _currentIndex = 0;
  final List<int> _history = [];
  PlaybackController? _playbackController;
  /// True when the current tab is showing its root page (Home/Search/Library/Profile).
  /// Global black edge fades are ONLY rendered in this state.
  bool _isOnRootPage = true;
  
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
      _refreshRootPageFlag();
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
    // Immediately check — tab switch always lands on root
    _refreshRootPageFlag(eager: true);
  }

  void navigateTo(Route route) {
     if (_navigatorKeys[_currentIndex].currentState != null) {
       _navigatorKeys[_currentIndex].currentState!.push(route);
     }
     _refreshRootPageFlag();
  }

  /// Recalculates whether the active tab is at root (no pushed routes).
  /// When [eager] is true, sets `_isOnRootPage = true` immediately
  /// (used for tab switches where we know we're landing on root).
  /// Schedules two post-frame verifications to catch animation-delayed pops.
  void _refreshRootPageFlag({bool eager = false}) {
    if (eager && !_isOnRootPage) {
      // Switching tabs always lands on root — update immediately
      setState(() => _isOnRootPage = true);
    }

    void _check() {
      if (!mounted) return;
      final nav = _navigatorKeys[_currentIndex].currentState;
      final onRoot = nav == null || !nav.canPop();
      if (onRoot != _isOnRootPage) {
        setState(() => _isOnRootPage = onRoot);
      }
    }

    // First check: immediately after current frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _check();
      // Second check: one frame later to catch animation-delayed pops
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<PlaybackController>();
    if (_playbackController != controller) {
      _playbackController?.removeListener(_onPlaybackError);
      _playbackController = controller;
      _playbackController!.addListener(_onPlaybackError);
    }
  }

  void _onPlaybackError() {
    final msg = _playbackController?.errorMessage;
    if (msg != null && mounted) {
      _playbackController!.clearError();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  void dispose() {
    _playbackController?.removeListener(_onPlaybackError);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.watch<PlaybackController>().currentTrack != null;
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final themeState = context.watch<ThemeState>();
    final bgColor = themeState.backgroundColor;
    final fgColor = themeState.foregroundColor;
    
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        extendBody: true, 
        extendBodyBehindAppBar: true,
        resizeToAvoidBottomInset: false, 
        body: Stack(
          children: [
            const HiddenVideoPlayer(),
            IndexedStack(
              index: _currentIndex,
              children: _rootPages.asMap().entries.map((entry) {
                 final int idx = entry.key;
                 final Widget rootPage = entry.value;
                 
                 return Navigator(
                   key: _navigatorKeys[idx],
                   observers: [_NavRouteObserver(onChanged: _refreshRootPageFlag)],
                   onGenerateRoute: (settings) {
                     WidgetBuilder builder;
                     if (settings.name == '/') {
                        builder = (context) => rootPage;
                     } else {
                        builder = (context) => rootPage; // Fallback
                     }
                     
                     return MaterialPageRoute(
                         builder: (context) => AnimatedPadding(
                          duration: const Duration(milliseconds: 100),
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

            // ── Top edge fade gradient ──
            // Only shown on root pages (Home/Search/Library/Profile).
            // Detail screens manage their own dynamic-color fades.
            if (_isOnRootPage)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        bgColor,
                        bgColor.withValues(alpha: 0.65),
                        bgColor.withValues(alpha: 0.25),
                        bgColor.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35, 0.65, 1.0],
                    ),
                  ),
                ),
              ),
            ),

            // ── Bottom edge gradient ──
            // Only shown on root pages.
            if (_isOnRootPage)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  height: hasTrack ? 240 : 160,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        bgColor.withValues(alpha: 0.96),
                        bgColor.withValues(alpha: 0.65),
                        bgColor.withValues(alpha: 0.25),
                        bgColor.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.35, 0.65, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            
            // ── Mini Player + Nav Bar ──
            Positioned(
              left: 0, 
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   AnimatedSize(
                     duration: const Duration(milliseconds: 80),
                     curve: Curves.easeInOut,
                     child: hasTrack ? const MiniPlayer() : const SizedBox.shrink(),
                   ),
                   _buildFloatingNavBar(bottomPadding, fgColor),
                ],
              ),
            ),
          ],
        ),
      ),
     ),
    );
  }

  Widget _buildFloatingNavBar(double bottomSafePadding, Color fgColor) {
    return Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: bottomSafePadding + 8,
        top: 4,
      ),
      child: GlassPill(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _navItem(0, Icons.home_rounded, "Home", fgColor),
            _navItem(1, Icons.search_rounded, "Search", fgColor),
            _navItem(2, Icons.library_music_rounded, "Library", fgColor),
            _navItem(3, Icons.person_rounded, "Profile", fgColor),
          ],
        ),
      ),
    );
  }
  
  Widget _navItem(int index, IconData icon, String label, Color fgColor) {
    bool isSelected = _currentIndex == index;
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
              color: isSelected ? fgColor : fgColor.withValues(alpha: 0.38),
              size: 24,
            ),
            if (isSelected) ...[
              const SizedBox(height: 3),
              Container(
                width: 4, height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fgColor,
                ),
              )
            ]
          ],
        ),
      ),
    );
  }
}

/// Lightweight route observer that calls [onChanged] whenever a route is
/// pushed or popped inside a tab Navigator — used to recalculate
/// whether the shell should show global black fades.
class _NavRouteObserver extends NavigatorObserver {
  final VoidCallback onChanged;
  _NavRouteObserver({required this.onChanged});

  @override
  void didPush(Route route, Route? previousRoute) => onChanged();
  @override
  void didPop(Route route, Route? previousRoute) => onChanged();
  @override
  void didRemove(Route route, Route? previousRoute) => onChanged();
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => onChanged();
}
