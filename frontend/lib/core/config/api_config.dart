// lib/core/config/api_config.dart
//
// Single source of truth for environment-based API configuration.
//
// ─────────────────────────────────────────────────────────────────────────────
// Available Dart defines (set at compile / run time with --dart-define):
//
//   ENV              → local | lan | prod          (default: prod)
//   LAN_IP           → your PC's LAN IP address   (required for ENV=lan)
//   STREAM_BASE_URL  → override for the stream backend URL
//
// ─────────────────────────────────────────────────────────────────────────────
// Run commands:
//
//   ① LOCAL  (Flutter Web / Chrome)
//       flutter run -d chrome --dart-define=ENV=local
//
//   ② LAN    (physical Android/iOS on same Wi-Fi)
//       flutter run -d <device-id> \
//         --dart-define=ENV=lan \
//         --dart-define=LAN_IP=192.168.1.X
//
//   ③ PRODUCTION  (Railway — default)
//       flutter run -d <device-id>
//
//   ④ PRODUCTION BUILD with custom stream backend
//       flutter build apk \
//         --dart-define=STREAM_BASE_URL=https://your-stream-server.com
//
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';

/// Environment selector injected at compile time.
enum _Env { local, lan, prod }

class ApiConfig {
  ApiConfig._(); // Non-instantiable

  // ── Dart-define constants ──────────────────────────────────────────────────

  static const _envRaw         = String.fromEnvironment('ENV',              defaultValue: 'prod');
  static const _lanIp          = String.fromEnvironment('LAN_IP',           defaultValue: '');
  static const _streamBaseUrlOverride = String.fromEnvironment('STREAM_BASE_URL', defaultValue: '');

  // ── Resolved environment ───────────────────────────────────────────────────

  static _Env get _env {
    switch (_envRaw.toLowerCase()) {
      case 'local': return _Env.local;
      case 'lan':   return _Env.lan;
      default:      return _Env.prod;
    }
  }

  // ── Metadata base URL ──────────────────────────────────────────────────────

  /// Base URL for search / metadata API (FastAPI on Railway).
  static String get baseUrl {
    switch (_env) {
      case _Env.local:
        return 'http://127.0.0.1:8000';
      case _Env.lan:
        if (_lanIp.isEmpty) {
          assert(false, '[ApiConfig] ENV=lan but LAN_IP is not set. '
              'Run with: --dart-define=LAN_IP=<your-PC-IP>');
          return 'http://127.0.0.1:8000';
        }
        return 'http://$_lanIp:8000';
      case _Env.prod:
        return 'https://paax-production.up.railway.app';
    }
  }

  // ── Stream proxy URL ────────────────────────────────────────────────────────

  /// Base URL for the IPv6 streaming proxy (DigitalOcean VPS).
  ///
  /// The proxy accepts raw CDN URLs from the client and streams them
  /// through the IPv6 rotation pool with device fingerprinting.
  ///
  /// Override at build time:
  ///   --dart-define=STREAM_BASE_URL=https://your-stream-server.com
  static String get streamBaseUrl {
    if (_streamBaseUrlOverride.isNotEmpty) return _streamBaseUrlOverride;
    switch (_env) {
      case _Env.local:
        return 'http://127.0.0.1:8080';
      case _Env.lan:
        if (_lanIp.isEmpty) return 'http://127.0.0.1:8080';
        return 'http://$_lanIp:8080';
      case _Env.prod:
        return 'https://resolver.paaxmusic.app';
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
      print('┌─────────────────────────────────────────────────────────────┐');
      // ignore: avoid_print
      print('│  🌐  API Environment  : ${envLabel.padRight(38)}│');
      // ignore: avoid_print
      print('│      Metadata URL     : $baseUrl');
      // ignore: avoid_print
      print('│      Stream URL       : $streamBaseUrl');
      // ignore: avoid_print
      print('└─────────────────────────────────────────────────────────────┘');
    }
  }
}

