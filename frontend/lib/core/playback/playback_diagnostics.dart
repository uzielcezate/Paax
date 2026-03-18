import 'package:flutter/foundation.dart';

// ============================================================================
// TEMPORARY DEBUG-ONLY FILE — remove before shipping to production.
// Provides a live in-app diagnostics overlay for mobile playback issues.
// ============================================================================

/// All the fields shown in the on-screen debug overlay.
/// Written by [PlaybackEngineImpl] throughout the load/play lifecycle.
/// Only used in debug builds — all write-sites are inside kDebugMode guards.
enum PlaybackStage {
  idle,
  resolving,        // calling Worker JSON API
  resolved,         // got CDN URL from Worker
  settingSource,    // AudioSource.uri → setAudioSource()
  sourceReady,      // setAudioSource returned OK
  buffering,        // ProcessingState.buffering / loading
  playing,          // playing=true, advancing
  completed,
  failedResolve,    // MediaResolver threw
  failedPlayer,     // PlayerException / play()
}

class PlaybackDiagnostics {
  // ── Stage ─────────────────────────────────────────────────────────────────
  final PlaybackStage stage;
  final String videoId;

  // ── Resolve result ────────────────────────────────────────────────────────
  final String sourceType;   // 'audioOnly' | 'muxed' | 'cache' | '…'
  final String mimeType;
  final int    expiresAt;    // Unix seconds from CDN URL; 0 = unknown
  final String urlHost;      // googlevideo.com or '…'

  // ── Player live state ─────────────────────────────────────────────────────
  final String processingState;   // ExoPlayer ProcessingState name
  final bool   isPlaying;
  final Duration position;
  final Duration buffered;
  final Duration duration;

  // ── Error ─────────────────────────────────────────────────────────────────
  final String? lastError;

  // ── Stall detection ───────────────────────────────────────────────────────
  /// The DateTime when the current [stage] was entered.
  /// The overlay uses this to detect if a stage has been active too long.
  final DateTime stageEnteredAt;

  const PlaybackDiagnostics({
    required this.stage,
    required this.videoId,
    this.sourceType       = '…',
    this.mimeType         = '…',
    this.expiresAt        = 0,
    this.urlHost          = '…',
    this.processingState  = 'idle',
    this.isPlaying        = false,
    this.position         = Duration.zero,
    this.buffered         = Duration.zero,
    this.duration         = Duration.zero,
    this.lastError,
    required this.stageEnteredAt,
  });

  /// Copy with specific fields overridden.
  PlaybackDiagnostics copyWith({
    PlaybackStage? stage,
    String? videoId,
    String? sourceType,
    String? mimeType,
    int? expiresAt,
    String? urlHost,
    String? processingState,
    bool? isPlaying,
    Duration? position,
    Duration? buffered,
    Duration? duration,
    String? lastError,
    DateTime? stageEnteredAt,
  }) {
    return PlaybackDiagnostics(
      stage:          stage          ?? this.stage,
      videoId:        videoId        ?? this.videoId,
      sourceType:     sourceType     ?? this.sourceType,
      mimeType:       mimeType       ?? this.mimeType,
      expiresAt:      expiresAt      ?? this.expiresAt,
      urlHost:        urlHost        ?? this.urlHost,
      processingState: processingState ?? this.processingState,
      isPlaying:      isPlaying      ?? this.isPlaying,
      position:       position       ?? this.position,
      buffered:       buffered       ?? this.buffered,
      duration:       duration       ?? this.duration,
      lastError:      lastError      ?? this.lastError,
      stageEnteredAt: stageEnteredAt ?? this.stageEnteredAt,
    );
  }

  /// Quick factory — sets stage + stageEnteredAt = now.
  factory PlaybackDiagnostics.atStage(
    PlaybackStage stage, {
    required String videoId,
    String sourceType      = '…',
    String mimeType        = '…',
    int    expiresAt       = 0,
    String urlHost         = '…',
    String processingState = 'idle',
    bool   isPlaying       = false,
    Duration position      = Duration.zero,
    Duration buffered      = Duration.zero,
    Duration duration      = Duration.zero,
    String? lastError,
  }) {
    return PlaybackDiagnostics(
      stage:          stage,
      videoId:        videoId,
      sourceType:     sourceType,
      mimeType:       mimeType,
      expiresAt:      expiresAt,
      urlHost:        urlHost,
      processingState: processingState,
      isPlaying:      isPlaying,
      position:       position,
      buffered:       buffered,
      duration:       duration,
      lastError:      lastError,
      stageEnteredAt: DateTime.now(),
    );
  }

  /// Old compat factory used by engine during initial resolving state.
  factory PlaybackDiagnostics.resolving(String videoId) =>
      PlaybackDiagnostics.atStage(PlaybackStage.resolving, videoId: videoId);

  String get stageName => stage.name;

  /// How long the current stage has been active.
  Duration get stageAge => DateTime.now().difference(stageEnteredAt);
}

/// Global [ValueNotifier] published by [PlaybackEngineImpl].
/// Only used in kDebugMode. [PlaybackDebugOverlay] listens to this.
// ignore: non_constant_identifier_names
final PlaybackDiagnosticsNotifier = ValueNotifier<PlaybackDiagnostics?>(null);
