// lib/core/config/app_config.dart
//
// Single source of truth for environment-specific configuration.
//
// Usage at runtime:
//   AppConfig.apiBaseUrl
//
// How to set the URL per environment:
//
//   Local web dev (Chrome):
//     flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
//
//   LAN (real phone, same Wi-Fi — replace IP with your PC's LAN IP):
//     flutter run -d <device> --dart-define=API_BASE_URL=http://192.168.1.10:8000
//
//   Android emulator (accessing host machine):
//     flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000
//
//   Production (Railway):
//     flutter run -d chrome --dart-define=API_BASE_URL=https://api.paaxmusic.app
//     flutter build web --dart-define=API_BASE_URL=https://api.paaxmusic.app
//
// Default (no --dart-define): http://localhost:8000

class AppConfig {
  AppConfig._(); // Non-instantiable

  /// Base URL for the Paax FastAPI backend.
  ///
  /// Injected at compile time via --dart-define=API_BASE_URL=<url>.
  /// Defaults to http://localhost:8000 for local web development.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );

  /// Onboarding artist-discovery source (Phase 3.3 §9).
  ///
  /// Injected via --dart-define=ARTIST_DISCOVERY_MODE=<hybrid|supabase|deezer>.
  /// Defaults to `hybrid` (Supabase popular grid + paax-api search/resolve),
  /// the current production behavior. Switch to `supabase` once the Paax
  /// catalog is well populated — no UI change required.
  static const String artistDiscoveryMode = String.fromEnvironment(
    'ARTIST_DISCOVERY_MODE',
    defaultValue: 'hybrid',
  );

  /// Party ENTRY-POINT visibility — Phase 3.4.1.2C.
  ///
  /// Injected via --dart-define=PARTY_ENABLED=false to hide. Defaults to ON: the
  /// "Add to Party" track-overflow action and the Library "+" → "Start a Party"
  /// entry are visible in production. This flag ONLY controls whether the entry
  /// points appear — it does NOT assert a live Party runtime exists. Tapping an
  /// entry routes into the Party scaffold, which communicates availability via
  /// [partyRuntimeEnabled]. It never creates a persistent playlist or an empty
  /// Party.
  static const bool partyEnabled = bool.fromEnvironment(
    'PARTY_ENABLED',
    defaultValue: true,
  );

  /// Party RUNTIME availability — Phase 3.4.1.2C.
  ///
  /// Injected via --dart-define=PARTY_RUNTIME_ENABLED=true. Defaults to OFF:
  /// there is no live Party-session backend yet, so the Party scaffold shows a
  /// "coming soon" state and starting a Party is disabled (nothing is created).
  /// Flip to true only once a real Party runtime (session backend + join/queue)
  /// ships — then the scaffold's "Start a Party with this song" CTA becomes
  /// live. Keep this OFF until then so entry points are discoverable without
  /// promising a broken experience.
  static const bool partyRuntimeEnabled = bool.fromEnvironment(
    'PARTY_RUNTIME_ENABLED',
    defaultValue: false,
  );
}
