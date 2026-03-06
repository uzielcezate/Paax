import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'core/config/api_config.dart';
import 'data/local/hive_storage.dart';
import 'presentation/state/auth_controller.dart';
import 'presentation/state/library_controller.dart';
import 'presentation/state/playback_controller.dart';
import 'presentation/state/search_controller.dart' as app_search;
import 'presentation/screens/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HiveStorage.init();

  // Print active API environment (debug only — no-op in release builds)
  ApiConfig.logStartup();

  runApp(const BeatyApp());
}

/// Custom scroll behavior:
/// - Removes Android overscroll glow (no more blue flicker)
/// - Allows touch + mouse drag (web compat)
/// - Does NOT set physics here — each list owns its own physics
class PaaxScrollBehavior extends MaterialScrollBehavior {
  const PaaxScrollBehavior();

  // Allow drag scrolling with mouse (important for web/desktop)
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
  };

  // Remove overscroll glow indicator on Android
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class BeatyApp extends StatelessWidget {
  const BeatyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthController()),
        ChangeNotifierProvider(create: (_) => LibraryController()),
        ChangeNotifierProvider(create: (_) => app_search.SearchController()),
        ChangeNotifierProvider(create: (_) => PlaybackController()),
      ],
      child: MaterialApp(
        title: 'Beaty',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        scrollBehavior: const PaaxScrollBehavior(),
        home: const SplashScreen(),
      ),
    );
  }
}

