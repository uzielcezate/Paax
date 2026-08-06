import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/theme/app_theme.dart';
import 'core/config/api_config.dart';
import 'core/config/supabase_config.dart';
import 'data/local/hive_storage.dart';
import 'data/local/playlist_ops_journal.dart';
import 'data/remote/follower_count_service.dart';
import 'data/remote/notification_realtime_service.dart';
import 'data/remote/playlist_realtime_service.dart';
import 'data/repositories/library_repository.dart';
import 'data/repositories/playlist_repository.dart';
import 'data/sync/playlist_sync_service.dart';
import 'presentation/state/auth_controller.dart';
import 'presentation/state/home_controller.dart';
import 'presentation/state/library_controller.dart';
import 'presentation/state/notification_controller.dart';
import 'presentation/state/party_controller.dart';
import 'presentation/state/playback_controller.dart';
import 'presentation/state/search_controller.dart' as app_search;
import 'presentation/state/theme_state.dart';
import 'presentation/screens/auth/auth_gate.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:audio_service/audio_service.dart';
import 'core/playback/paax_audio_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HiveStorage.init();

  // Initialize Supabase (public anon key only; RLS-protected). Auth deep links
  // (paax://auth/...) are handled by the SDK. Fail gracefully if misconfigured.
  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      authOptions:
          const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
    );
  } catch (e) {
    // ignore: avoid_print
    if (!kIsWeb) print('[Paax] Supabase init failed: $e');
  }

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
        // Phase 3.2A: LibraryController gets a cloud-sync repository and is
        // driven by the auth session — on sign-in/restore it flushes pending
        // ops, hydrates cloud data, and runs the one-time Hive→cloud migration;
        // on sign-out it clears session state. onUserSession is idempotent per
        // identity, so calling it on every AuthController notification is safe.
        ChangeNotifierProxyProvider<AuthController, LibraryController>(
          create: (_) => LibraryController(
            LibraryRepository(),
            // Phase 3.4.1 — cloud playlist repository (best-effort; local Hive
            // stays authoritative). Shares the offline ops journal.
            PlaylistRepository(sync: PlaylistSyncService(PlaylistOpsJournal())),
          ),
          update: (_, auth, lib) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            lib!.onUserSession(uid);
            return lib;
          },
        ),
        ChangeNotifierProvider(create: (_) => app_search.SearchController()),
        ChangeNotifierProvider(create: (_) => PlaybackController()),
        ChangeNotifierProvider(create: (_) => ThemeState()),
        // Phase 3.4.1.2C: single source of truth for (future) live Party
        // session state. No runtime yet → hasActiveParty is always false, so
        // "Add to Party" resolves to the start-a-party scaffold. App-scoped so
        // every track menu shares one resolver.
        ChangeNotifierProvider(create: (_) => PartyController()),
        // Phase 3.3.5: authoritative, realtime-synced global follower counts.
        // App-scoped singleton so multiple ArtistDetailScreen instances (e.g.
        // via Related Artists) share one realtime channel per artist. Driven by
        // the auth session so an account switch drops all channels/cached counts
        // (multi-account isolation); the global count itself is user-independent.
        ProxyProvider<AuthController, FollowerCountService>(
          create: (_) => FollowerCountService(SupabaseFollowerCountBackend()),
          update: (_, auth, service) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            service!.onUserSession(uid);
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
        // Phase 3.4.1: cloud-playlist repository + realtime service. Supabase is
        // authoritative; Hive is the cache/journal. The realtime service is
        // driven by the auth session so channels tear down on account switch.
        Provider<PlaylistRepository>(
          create: (_) => PlaylistRepository(
            sync: PlaylistSyncService(PlaylistOpsJournal()),
          ),
        ),
        ProxyProvider<AuthController, PlaylistRealtimeService>(
          create: (_) => PlaylistRealtimeService(SupabasePlaylistRealtimeBackend()),
          update: (_, auth, service) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            service!.onUserSession(uid);
            return service;
          },
          dispose: (_, service) => service.dispose(),
        ),
        // Phase 3.4.1.1: in-app notification inbox. The realtime service is a
        // plain singleton; the controller drives its account binding via
        // onUserSession (bind(uid) on sign-in, bind(null) on sign-out) so the
        // bell badge is live and tears down cleanly on an account switch.
        Provider<NotificationRealtimeService>(
          create: (_) =>
              NotificationRealtimeService(SupabaseNotificationRealtimeBackend()),
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProxyProvider<AuthController, NotificationController>(
          create: (ctx) => NotificationController(
            realtime: ctx.read<NotificationRealtimeService>(),
            respondInvitation: ctx.read<PlaylistRepository>().respondInvitation,
          ),
          update: (_, auth, notif) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            notif!.onUserSession(uid);
            return notif;
          },
        ),
        // Phase 3.2.5: personalized Home feed (real Supabase catalog sections).
        // Driven by the auth session so a persistent Home tab drops the previous
        // user's personalized content on an account switch (idempotent per id).
        ChangeNotifierProxyProvider<AuthController, HomeController>(
          create: (_) => HomeController(),
          update: (_, auth, home) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            home!.onUserSession(uid);
            return home;
          },
        ),
      ],
      child: MaterialApp(
        title: 'Paax',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        scrollBehavior: const PaaxScrollBehavior(),
        home: const AuthGate(),
      ),
    );
  }
}

