import 'package:flutter/foundation.dart';

// ============================================================================
// TEMPORARY DEBUG-ONLY FILE — remove before shipping to production.
// Provides an in-app diagnostics panel for mobile playback issues.
// ============================================================================

/// Structured playback diagnostics captured during [PlaybackEngineImpl.load()].
///
/// In debug builds ([kDebugMode]), this is written before + after every
/// [setAudioSource] call so the UI can display the exact source info
/// and failure reason without relying on logcat.
///
/// In release builds this class is never instantiated (all call-sites are
/// inside [kDebugMode] guards), so it has zero production cost.
class PlaybackDiagnostics {
  // ── Source info (set before setAudioSource) ───────────────────────────────
  final String videoId;
  final String urlHost;
  final String urlScheme;
  final String mimeType;
  final String container;
  final int bitrateKbps;
  final bool sizeKnown;
  final int totalBytes;
  final bool headersAttached;
  final bool directStream;
  final bool isManifest;

  // ── Outcome (set after load completes or fails) ───────────────────────────
  final bool succeeded;

  /// Which stage failed: 'resolve', 'setAudioSource', or 'play'.
  final String? failedAt;

  /// Raw exception message (trimmed).
  final String? exceptionMessage;

  /// Short human-readable reason inferred from the exception.
  final String? shortReason;

  const PlaybackDiagnostics({
    required this.videoId,
    required this.urlHost,
    required this.urlScheme,
    required this.mimeType,
    required this.container,
    required this.bitrateKbps,
    required this.sizeKnown,
    required this.totalBytes,
    required this.headersAttached,
    required this.directStream,
    required this.isManifest,
    required this.succeeded,
    this.failedAt,
    this.exceptionMessage,
    this.shortReason,
  });

  /// Pending state shown while resolution is in progress.
  factory PlaybackDiagnostics.resolving(String videoId) =>
      PlaybackDiagnostics(
        videoId: videoId,
        urlHost: '…',
        urlScheme: '…',
        mimeType: '…',
        container: '…',
        bitrateKbps: 0,
        sizeKnown: false,
        totalBytes: 0,
        headersAttached: false,
        directStream: false,
        isManifest: false,
        succeeded: false,
        failedAt: null,
        exceptionMessage: null,
        shortReason: 'Resolving stream…',
      );

  /// Infers a short human-readable failure reason from the exception string.
  static String inferReason(String exc) {
    final e = exc.toLowerCase();
    if (e.contains('cdn') && e.contains('403')) return 'CDN 403 — headers rejected';
    if (e.contains('cdn') && e.contains('416')) return 'CDN 416 — invalid Range';
    if (e.contains('cdn')) return 'CDN request rejected (see status code)';
    if (e.contains('source error') || e.contains('(0)')) {
      return 'ExoPlayer rejected source — possible DASH/format issue';
    }
    if (e.contains('manifest') || e.contains('m3u8') || e.contains('mpd')) {
      return 'Manifest/playlist URL — not a direct audio stream';
    }
    if (e.contains('no audio stream')) return 'No audio streams in manifest';
    if (e.contains('no mp4') || e.contains('no compatible')) {
      return 'No mp4/AAC stream available (webm only?)';
    }
    if (e.contains('connection') || e.contains('socket')) {
      return 'Network connection error';
    }
    if (e.contains('timeout')) return 'Request timed out';
    return 'Unknown — see exception message above';
  }
}

/// Global [ValueNotifier] used by [PlaybackEngineImpl] to publish diagnostics.
///
/// Only used in debug mode. The [PlaybackController] exposes this via
/// [PlaybackController.debugDiagnostics] and the player screen reads it.
// ignore: non_constant_identifier_names
final PlaybackDiagnosticsNotifier =
    ValueNotifier<PlaybackDiagnostics?>(null);
