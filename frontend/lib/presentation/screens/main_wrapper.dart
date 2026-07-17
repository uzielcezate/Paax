import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../widgets/mini_player.dart';
import '../widgets/hidden_video_player.dart';
import 'home_screen.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'profile_screen.dart';
import 'player_screen.dart';
import '../../core/utils/safe_insets.dart';

class MainWrapper extends StatefulWidget {
  const MainWrapper({super.key});

  static final GlobalKey<MainWrapperState> shellKey =
      GlobalKey<MainWrapperState>();

  /// One RouteObserver per tab navigator. Each detail screen's
  /// DynamicBackground subscribes to the observer of its own tab
  /// so it receives didPopNext when a route pushed on top is popped.
  ///
  /// IMPORTANT: Each Navigator gets its OWN observer instance.
  /// Sharing one observer across multiple Navigators causes
  /// "observer.navigator == null" assertion in debug and silent
  /// breakage in release.
  static final List<RouteObserver<ModalRoute<dynamic>>> tabObservers = [
    RouteObserver<ModalRoute<dynamic>>(), // Home
    RouteObserver<ModalRoute<dynamic>>(), // Search
    RouteObserver<ModalRoute<dynamic>>(), // Library
    RouteObserver<ModalRoute<dynamic>>(), // Profile
  ];

  /// Returns the RouteObserver for the currently active tab.
  /// DynamicBackground calls this to subscribe to the correct observer.
  static RouteObserver<ModalRoute<dynamic>> get activeObserver =>
      tabObservers[shellKey.currentState?._currentIndex ?? 0];

  @override
  State<MainWrapper> createState() => MainWrapperState();
}

class MainWrapperState extends State<MainWrapper>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  final List<int> _history = [];
  PlaybackController? _playbackController;

  // ── Full Player Overlay State ──
  bool _isPlayerOpen = false;
  late final AnimationController _playerAnimation;

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

  @override
  void initState() {
    super.initState();
    _playerAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 120),
    );

    // Always set light status bar (white icons on dark bg)
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light.copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
  }

  /// Open the full player overlay (called from MiniPlayer)
  void openPlayer() {
    if (_isPlayerOpen) return;
    setState(() => _isPlayerOpen = true);
    _playerAnimation.forward();
  }

  /// Close the full player overlay
  void closePlayer() {
    if (!_isPlayerOpen) return;
    _playerAnimation.reverse().then((_) {
      if (mounted) {
        setState(() => _isPlayerOpen = false);
      }
    });
  }

  /// Returns true if the back action was handled internally (pop or tab switch).
  /// Returns false if the app should probably exit or do default behavior.
  ///
  /// Priority order (same in debug AND release):
  ///   0. Close full player
  ///   1. Pop internal route in current tab (e.g. artist detail → search)
  ///   2. Go back to previous tab (history)
  ///   3. Go to Home if not already there
  ///   4. Exit app
  bool onBackPressed() {
    // 0. Close full player first if it's open
    if (_isPlayerOpen) {
      closePlayer();
      return true;
    }

    final NavigatorState? currentNavigator =
        _navigatorKeys[_currentIndex].currentState;

    // 1. Try to pop internal route in current tab
    if (currentNavigator != null && currentNavigator.canPop()) {
      currentNavigator.pop();
      return true;
    }

    // 2. Try to go back to previous tab
    if (_history.isNotEmpty) {
      final prevIndex = _history.removeLast();
      setState(() => _currentIndex = prevIndex);
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
    _playerAnimation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.watch<PlaybackController>().currentTrack != null;
    final bottomPadding = SafeInsets.bottomInset(context);

    return PopScope(
      canPop: false, // We handle all back navigation ourselves
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final handled = onBackPressed();
        if (!handled) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
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
                  observers: [
                    // Each tab gets its OWN _NavRouteObserver (fresh instance)
                    _NavRouteObserver(onChanged: () {}),
                    // Each tab gets its OWN RouteObserver (from the per-tab list)
                    MainWrapper.tabObservers[idx],
                  ],
                  onGenerateRoute: (settings) {
                    WidgetBuilder builder;
                    if (settings.name == '/') {
                      builder = (context) => rootPage;
                    } else {
                      builder = (context) => rootPage; // Fallback
                    }

                    return MaterialPageRoute(
                        builder: (context) => AnimatedPadding(
                              duration: const Duration(milliseconds: 50),
                              curve: Curves.easeOut,
                              padding: EdgeInsets.zero,
                              child: builder(context),
                            ),
                        settings: settings);
                  },
                );
              }).toList(),
            ),

            // ── Bottom Chrome: fade + mini player + nav icons ──
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: RepaintBoundary(
                child: _buildBottomDock(hasTrack, bottomPadding),
              ),
            ),

            // ── Full Player Overlay ──
            if (_isPlayerOpen)
              SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.0, 1.0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: _playerAnimation,
                  curve: Curves.ease,
                )),
                child: const PlayerScreen(),
              ),
          ],
        ),
      ),
    );
  }

  /// Bottom dock: gradient fade → mini player → nav icons.
  /// The fade makes scrolling content disappear under the controls.
  Widget _buildBottomDock(bool hasTrack, double bottomSafePadding) {
    // Nav icon row height + safe area
    const double navHeight = 55;
    // Mini player height (67) + 4px spacing top
    const double miniPlayerZone = 71;
    // Extra fade above everything so content starts dissolving earlier
    const double fadeExtra = 40;

    final double contentHeight =
        (hasTrack ? miniPlayerZone : 0) + navHeight + bottomSafePadding;
    final double totalHeight = contentHeight + fadeExtra;

    return SizedBox(
      height: totalHeight,
      child: Stack(
        children: [
          // ── Fade gradient: transparent → #080808 ──
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.background.withValues(alpha: 0.0),
                      AppColors.background.withValues(alpha: 0.60),
                      AppColors.background.withValues(alpha: 0.80),
                      AppColors.background.withValues(alpha: 1.0),
                    ],
                    stops: const [0.0, 0.20, 0.50, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ── Mini player + Nav icons (positioned at bottom) ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Mini player
                AnimatedSize(
                  duration: const Duration(milliseconds: 70),
                  curve: Curves.easeOut,
                  child:
                      hasTrack ? const MiniPlayer() : const SizedBox.shrink(),
                ),

                if (hasTrack) const SizedBox(height: 4),

                // Nav icons
                Padding(
                  padding: EdgeInsets.only(bottom: bottomSafePadding),
                  child: SizedBox(
                    height: navHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _navIconSvg(0, 'assets/icons/home.svg',
                            'assets/icons/home-filled.svg'),
                        _navIconSvg(1, 'assets/icons/magnifying-glass.svg',
                            'assets/icons/magnifying-glass-filled.svg'),
                        _navIcon(2, Icons.library_music_outlined,
                            Icons.library_music),
                        _navIcon(3, Icons.person_outline_rounded,
                            Icons.person_rounded),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navIcon(int index, IconData outlinedIcon, IconData filledIcon) {
    final isSelected = _currentIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onTabTapped(index),
        behavior: HitTestBehavior.translucent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Icon(
              isSelected ? filledIcon : outlinedIcon,
              color: isSelected ? Colors.white : Colors.white54,
              size: 33,
            ),
            if (isSelected) ...[
              const SizedBox(height: 3),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// SVG-based nav icon for Home and Search.
  Widget _navIconSvg(int index, String outlinedAsset, String filledAsset) {
    final isSelected = _currentIndex == index;
    final color = isSelected ? Colors.white : Colors.white54;
    final asset = isSelected ? filledAsset : outlinedAsset;
    return Expanded(
      child: GestureDetector(
        onTap: () => _onTabTapped(index),
        behavior: HitTestBehavior.translucent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            SizedBox(
              width: 33,
              height: 33,
              child: SvgPicture.asset(
                asset,
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                fit: BoxFit.contain,
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: 3),
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Lightweight route observer that calls [onChanged] whenever a route is
/// pushed or popped inside a tab Navigator.
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
