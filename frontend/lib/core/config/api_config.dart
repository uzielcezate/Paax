// lib/core/config/api_config.dart
//
// Single source of truth for environment-based API configuration.
//
// ─────────────────────────────────────────────────────────────────────────────
// Two distinct backends:
//
//   ① paax-api  (Railway)        — Metadata & search (ytmusicapi)
//   ② paax-stream (DigitalOcean) — Pure IPv6 streaming proxy
//
// ─────────────────────────────────────────────────────────────────────────────
// Available Dart defines (set at compile / run time with --dart-define):
//
//   ENV              → local | lan | prod          (default: prod)
//   LAN_IP           → your PC's LAN IP address   (required for ENV=lan)
//   API_BASE_URL     → override for the metadata/search backend URL
//   STREAM_BASE_URL  → override for the stream proxy backend URL
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
//   ③ PRODUCTION  (default)
//       flutter run -d <device-id>
//
//   ④ PRODUCTION BUILD with custom URLs
//       flutter build apk \
//         --dart-define=API_BASE_URL=https://your-api.up.railway.app \
//         --dart-define=STREAM_BASE_URL=https://your-stream-server.com
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
  static const _apiBaseUrlOverride    = String.fromEnvironment('API_BASE_URL',    defaultValue: '');
  static const _streamBaseUrlOverride = String.fromEnvironment('STREAM_BASE_URL', defaultValue: '');

  // ── Resolved environment ───────────────────────────────────────────────────

  static _Env get _env {
    switch (_envRaw.toLowerCase()) {
      case 'local': return _Env.local;
      case 'lan':   return _Env.lan;
      default:      return _Env.prod;
    }
  }

  // ── Metadata / Search API (paax-api on Railway) ────────────────────────────

  /// Base URL for search & metadata API (FastAPI + ytmusicapi on Railway).
  ///
  /// Override at build time:
  ///   --dart-define=API_BASE_URL=https://your-api.up.railway.app
  static String get baseUrl {
    if (_apiBaseUrlOverride.isNotEmpty) return _apiBaseUrlOverride;
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
        // ┌──────────────────────────────────────────────────────────────────┐
        // │  IMPORTANT: Update this URL if you redeploy paax-api on Railway │
        // │  or override at build time with --dart-define=API_BASE_URL=...  │
        // └──────────────────────────────────────────────────────────────────┘
        return 'https://api.paaxmusic.app';
    }
  }

  // ── Stream proxy (paax-stream on DigitalOcean) ─────────────────────────────

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
      case _Env.local: return 'LOCAL';
      case _Env.lan:   return 'LAN ($_lanIp)';
      case _Env.prod:  return 'PROD';
    }
  }

  // ── Startup diagnostic log ─────────────────────────────────────────────────

  /// Call once from main() to print the active environment.
  static void logStartup() {
    if (kDebugMode) {
      // ignore: avoid_print
      print('┌─────────────────────────────────────────────────────────────┐');
      // ignore: avoid_print
      print('│  API Environment : ${envLabel.padRight(42)}│');
      // ignore: avoid_print
      print('│  Metadata URL    : $baseUrl');
      // ignore: avoid_print
      print('│  Stream URL      : $streamBaseUrl');
      // ignore: avoid_print
      print('└─────────────────────────────────────────────────────────────┘');
    }
  }
}
