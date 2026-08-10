import 'core/network/offline_status.dart';
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

/// Set when local storage could not be initialized. The startup state machine
/// turns this into [StartupPhase.fatalStartupError] (a recoverable screen with
/// retry + sign-out) instead of a crash on launch.
bool localStorageFailed = false;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Phase 3.4.2 — local storage is the ONLY hard startup dependency, and even it
  // degrades to a recoverable screen rather than a crash.
  try {
    await HiveStorage.init();
  } catch (e) {
    localStorageFailed = true;
    // ignore: avoid_print
    if (!kIsWeb) print('[Paax] Local storage init failed: $e');
  }

  // Initialize Supabase (public anon key only; RLS-protected). Auth deep links
  // (paax://auth/...) are handled by the SDK.
  //
  // Phase 3.4.2: bounded. This call restores the persisted session from local
  // storage and does not require the network, but it must not be able to hold
  // the shell hostage if a platform channel or storage read stalls. On timeout
  // we continue unauthenticated-but-running rather than blocking on splash —
  // the session is re-resolved once the SDK settles.
  try {
    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      authOptions:
          const FlutterAuthClientOptions(authFlowType: AuthFlowType.pkce),
    ).timeout(const Duration(seconds: 8));
  } catch (e) {
    // ignore: avoid_print
    if (!kIsWeb) print('[Paax] Supabase init failed/timed out: $e');
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

  // Initialize Foreground Service for background audio (mobile only).
  //
  // Phase 3.4.2: this is a LOCAL platform-channel call (no network), so it is
  // not one of the remote startup dependencies the offline-first rule targets.
  // It is nonetheless bounded and non-fatal: if the channel stalls or throws we
  // still open the app, with `globalAudioHandler` null — playback degrades to
  // no OS media notification rather than the whole app failing to launch.
  if (!kIsWeb) {
    try {
      globalAudioHandler = await AudioService.init(
        builder: () => PaaxAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.paax.music.audio',
          androidNotificationChannelName: 'Paax Music',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
        ),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      // ignore: avoid_print
      print('[Paax] AudioService init failed/timed out: $e');
    }
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
        ChangeNotifierProvider(
          create: (_) => AuthController(localStorageFailed: localStorageFailed),
        ),
        // Phase 3.2A: LibraryController gets a cloud-sync repository and is
        // driven by the auth session — on sign-in/restore it flushes pending
        // ops, hydrates cloud data, and runs the one-time Hive→cloud migration;
        // on sign-out it clears session state. onUserSession is idempotent per
        // identity, so calling it on every AuthController notification is safe.
        // Phase 3.4.5 — ONE app-scoped offline signal, derived from real request
        // outcomes rather than an OS connectivity flag (which is true on a
        // captive portal and while the backend is unreachable). Also owns the
        // single-flight reconnect-refresh registry, so no screen needs its own
        // connectivity subscription or its own "refresh once" guard.
        ChangeNotifierProxyProvider<AuthController, OfflineStatus>(
          create: (_) => OfflineStatus.instance = OfflineStatus(),
          update: (_, auth, status) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            status!.onUserSession(uid);
            return status;
          },
        ),
        // Phase 3.4.6 — LibraryController is driven by BOTH auth and
        // connectivity. The second dependency is the fix for the reconnect bug:
        // `flushPending` used to be reachable only from `onUserSession`, which
        // early-returns when the user id is unchanged, so the offline journal
        // was replayed exactly once per account per app session and queued
        // mutations never synced after regaining connectivity.
        //
        // `OfflineStatus.refreshOnce` makes the trigger idempotent: at most one
        // flush per offline→online transition no matter how often this
        // ProxyProvider's update() runs.
        ChangeNotifierProxyProvider2<AuthController, OfflineStatus,
            LibraryController>(
          create: (_) => LibraryController(
            LibraryRepository(),
            // Phase 3.4.1 — cloud playlist repository (best-effort; local Hive
            // stays authoritative). Shares the offline ops journal.
            PlaylistRepository(sync: PlaylistSyncService(PlaylistOpsJournal())),
          ),
          update: (_, auth, offline, lib) {
            final uid = auth.isAuthenticated
                ? Supabase.instance.client.auth.currentUser?.id
                : null;
            // ignore: discarded_futures
            lib!.onUserSession(uid);
            if (!offline.isOffline && uid != null) {
              // ignore: discarded_futures
              offline.refreshOnce(
                  'library:playlist-journal', lib.onConnectivityRestored);
            }
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

