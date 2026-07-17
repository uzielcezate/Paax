import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'core/config/api_config.dart';
import 'data/local/hive_storage.dart';
import 'presentation/state/auth_controller.dart';
import 'presentation/state/library_controller.dart';
import 'presentation/state/playback_controller.dart';
import 'presentation/state/search_controller.dart' as app_search;
import 'presentation/state/theme_state.dart';
import 'presentation/screens/onboarding_screen.dart';
import 'presentation/screens/auth_screen.dart';
import 'presentation/screens/main_wrapper.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:audio_service/audio_service.dart';
import 'core/playback/paax_audio_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HiveStorage.init();

  // ── Edge-to-edge rendering ──
  // Ensures consistent layout across all Android OEMs (Oppo, Xiaomi, etc.)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Initialize Foreground Service for background audio (mobile only)
  if (!kIsWeb) {
    globalAudioHandler = await AudioService.init(
      builder: () => PaaxAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.paax.music.audio',
        androidNotificationChannelName: 'Paax Music',
        androidNotificationOngoing: false,
        androidStopForegroundOnPause: false,
      ),
    );
  }

  // Print active API environment (debug only — no-op in release builds)
  ApiConfig.logStartup();

  runApp(const PaaxApp());
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

class PaaxApp extends StatelessWidget {
  const PaaxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthController()),
        ChangeNotifierProvider(create: (_) => LibraryController()),
        ChangeNotifierProvider(create: (_) => app_search.SearchController()),
        ChangeNotifierProvider(create: (_) => PlaybackController()),
        ChangeNotifierProvider(create: (_) => ThemeState()),
      ],
      child: MaterialApp(
        title: 'Paax',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        scrollBehavior: const PaaxScrollBehavior(),
        home: Consumer<AuthController>(
          builder: (context, auth, _) {
            if (!auth.onboardingCompleted) return const OnboardingScreen();
            if (!auth.isAuthenticated) return const AuthScreen();
            return MainWrapper(key: MainWrapper.shellKey);
          },
        ),
      ),
    );
  }
}

