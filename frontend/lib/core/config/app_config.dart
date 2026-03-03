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
//     flutter run -d chrome --dart-define=API_BASE_URL=https://beaty.up.railway.app
//     flutter build web --dart-define=API_BASE_URL=https://beaty.up.railway.app
//
// Default (no --dart-define): http://localhost:8000

class AppConfig {
  AppConfig._(); // Non-instantiable

  /// Base URL for the Beaty FastAPI backend.
  ///
  /// Injected at compile time via --dart-define=API_BASE_URL=<url>.
  /// Defaults to http://localhost:8000 for local web development.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8000',
  );
}
