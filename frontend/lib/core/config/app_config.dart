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

  /// Party (temporary shared listening session) feature flag — Phase 3.4.1.1 §G.
  ///
  /// Injected via --dart-define=PARTY_ENABLED=true. Defaults to OFF: Party is an
  /// entry scaffold only. When OFF, "Start a Party" opens an informational prep
  /// sheet (no session is created) and the track-overflow "Add to Party" action
  /// is hidden. No Party backend/migrations exist yet — do not build against a
  /// live session assuming this flag is on.
  static const bool partyEnabled = bool.fromEnvironment(
    'PARTY_ENABLED',
    defaultValue: false,
  );
}
