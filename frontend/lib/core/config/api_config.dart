// lib/core/config/api_config.dart
//
// Single source of truth for environment-based API configuration.
//
// ─────────────────────────────────────────────────────────────────────────────
// Available Dart defines (set at compile / run time with --dart-define):
//
//   ENV      → local | lan | prod          (default: prod)
//   LAN_IP   → your PC's LAN IP address   (required for ENV=lan)
//
// ─────────────────────────────────────────────────────────────────────────────
// Run commands — copy/paste these:
//
//   ① LOCAL  (Flutter Web / Chrome, backend running on same machine)
//       flutter run -d chrome \
//         --dart-define=ENV=local
//
//   ② LAN    (physical Android/iOS phone on same Wi-Fi, replace IP)
//       flutter run -d <device-id> \
//         --dart-define=ENV=lan \
//         --dart-define=LAN_IP=192.168.1.X
//
//   ③ PRODUCTION  (connects to Railway backend — default)
//       flutter run  -d <device-id>
//       flutter run  -d chrome
//
//   ④ PRODUCTION BUILD
//       flutter build apk
//       flutter build web
//       flutter build ipa
//
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';

/// Environment selector injected at compile time.
enum _Env { local, lan, prod }

class ApiConfig {
  ApiConfig._(); // Non-instantiable

  // ── Dart-define constants ──────────────────────────────────────────────────

  static const _envRaw = String.fromEnvironment('ENV', defaultValue: 'prod');
  static const _lanIp  = String.fromEnvironment('LAN_IP', defaultValue: '');

  // ── Resolved environment ───────────────────────────────────────────────────

  static _Env get _env {
    switch (_envRaw.toLowerCase()) {
      case 'local': return _Env.local;
      case 'lan':   return _Env.lan;
      default:      return _Env.prod;
    }
  }

  // ── Base URL ───────────────────────────────────────────────────────────────

  /// The API base URL for this build. Every HTTP call must use this.
  static String get baseUrl {
    switch (_env) {
      case _Env.local:
        return 'http://127.0.0.1:8000';
      case _Env.lan:
        if (_lanIp.isEmpty) {
          // Fallback with clear error in debug builds
          assert(false, '[ApiConfig] ENV=lan but LAN_IP is not set. '
              'Run with: --dart-define=LAN_IP=<your-PC-IP>');
          return 'http://127.0.0.1:8000';
        }
        return 'http://$_lanIp:8000';
      case _Env.prod:
        return 'https://paax-production.up.railway.app';
    }
  }

  // ── Human-readable label for logging ──────────────────────────────────────

  static String get envLabel {
    switch (_env) {
      case _Env.local: return 'LOCAL  (127.0.0.1:8000)';
      case _Env.lan:   return 'LAN    ($_lanIp:8000)';
      case _Env.prod:  return 'PROD   (Railway)';
    }
  }

  // ── Startup diagnostic log ─────────────────────────────────────────────────

  /// Call once from main() to print the active environment.
  static void logStartup() {
    if (kDebugMode) {
      // ignore: avoid_print
      print('┌─────────────────────────────────────────┐');
      // ignore: avoid_print
      print('│  🌐  API Environment : ${envLabel.padRight(17)}│');
      // ignore: avoid_print
      print('│      Base URL        : $baseUrl');
      // ignore: avoid_print
      print('└─────────────────────────────────────────┘');
    }
  }
}
