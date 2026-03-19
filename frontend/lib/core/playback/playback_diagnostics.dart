import 'package:flutter/foundation.dart';

// ============================================================================
// TEMPORARY DEBUG-ONLY FILE — remove before shipping to production.
// ============================================================================

// ---------------------------------------------------------------------------
// Stage enum — every distinct step in the load+play pipeline
// ---------------------------------------------------------------------------
enum PlaybackStage {
  idle,

  // ── Resolution ────────────────────────────────────────────────────────────
  resolving,              // HTTP GET sent to Worker, waiting for response
  resolved,               // Worker returned 200 JSON with CDN URL

  // ── Player setup ──────────────────────────────────────────────────────────
  settingSource,          // setAudioSource() in progress
  sourceReady,            // setAudioSource() returned successfully

  // ── Buffer / Playback ─────────────────────────────────────────────────────
  buffering,              // play() called; waiting for bytes
  playing,                // confirmed playing: processingState==ready AND bytes moving

  // ── Terminal / Success ────────────────────────────────────────────────────
  completed,

  // ── Failure stages ────────────────────────────────────────────────────────
  failedResolveTimeout,   // Worker call timed out (15s)
  failedResolveHttp,      // Worker returned non-200
  failedSetSource,        // setAudioSource() threw PlayerException
  failedBuffering,        // play() called but no bytes moved within 3s
  falsePlayingDetected,   // play() called + processingState=playing but pos/buf = 0
  stalledAfterResolved,   // CDN URL obtained but player never left idle
}

// ---------------------------------------------------------------------------
// PlaybackDiagnostics — full snapshot at any point in the pipeline
// ---------------------------------------------------------------------------
class PlaybackDiagnostics {
  // ── Stage ─────────────────────────────────────────────────────────────────
  final PlaybackStage stage;
  final DateTime      stageEnteredAt;

  // ── Track ─────────────────────────────────────────────────────────────────
  final String videoId;

  // ── Resolve result ────────────────────────────────────────────────────────
  final String sourceType;   // 'audioOnly' | 'muxed' | '…'
  final String mimeType;
  final int    expiresAt;    // Unix seconds; 0 = unknown
  final String urlHost;      // e.g. rr8---sn-xxx.googlevideo.com or '…'

  // ── Resolve timing ────────────────────────────────────────────────────────
  final DateTime? resolveStartedAt;
  final DateTime? resolveFinishedAt;
  /// HTTP status of the Worker response (0 = not yet / network error)
  final int   workerHttpStatus;
  /// Worker error body / code (non-200 only)
  final String? workerErrorBody;

  // ── setAudioSource ────────────────────────────────────────────────────────
  final bool    setSourceCalled;
  final bool    setSourceSucceeded;
  final String? setSourceError;     // PlayerException code + message

  // ── play() ────────────────────────────────────────────────────────────────
  final bool    playCalled;
  final bool    playSucceeded;
  final String? playError;

  // ── Player live state ─────────────────────────────────────────────────────
  final String   processingState;
  final bool     isPlaying;
  final Duration position;
  final Duration buffered;
  final Duration duration;

  // ── Error summary ─────────────────────────────────────────────────────────
  final String? lastError;

  const PlaybackDiagnostics({
    required this.stage,
    required this.stageEnteredAt,
    required this.videoId,
    // resolve
    this.sourceType       = '…',
    this.mimeType         = '…',
    this.expiresAt        = 0,
    this.urlHost          = '…',
    this.resolveStartedAt,
    this.resolveFinishedAt,
    this.workerHttpStatus = 0,
    this.workerErrorBody,
    // setAudioSource
    this.setSourceCalled    = false,
    this.setSourceSucceeded = false,
    this.setSourceError,
    // play
    this.playCalled    = false,
    this.playSucceeded = false,
    this.playError,
    // player state
    this.processingState = 'idle',
    this.isPlaying       = false,
    this.position        = Duration.zero,
    this.buffered        = Duration.zero,
    this.duration        = Duration.zero,
    // error
    this.lastError,
  });

  // ── Computed helpers ──────────────────────────────────────────────────────

  /// True when CDN URL expiry is known and has passed.
  bool get isUrlExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  /// How long the current stage has been active.
  Duration get stageAge => DateTime.now().difference(stageEnteredAt);

  /// Resolve round-trip duration (null if not yet known).
  Duration? get resolveElapsed {
    if (resolveStartedAt == null || resolveFinishedAt == null) return null;
    return resolveFinishedAt!.difference(resolveStartedAt!);
  }

  String get stageName => stage.name;

  // ── copyWith ──────────────────────────────────────────────────────────────
  PlaybackDiagnostics copyWith({
    PlaybackStage? stage,
    DateTime?  stageEnteredAt,
    String?    videoId,
    String?    sourceType,  String? mimeType,
    int?       expiresAt,   String? urlHost,
    DateTime?  resolveStartedAt, DateTime? resolveFinishedAt,
    int?       workerHttpStatus, String?   workerErrorBody,
    bool?      setSourceCalled,  bool? setSourceSucceeded, String? setSourceError,
    bool?      playCalled,       bool? playSucceeded,      String? playError,
    String?    processingState,
    bool?      isPlaying,
    Duration?  position,  Duration? buffered,  Duration? duration,
    String?    lastError,
  }) => PlaybackDiagnostics(
    stage:              stage             ?? this.stage,
    stageEnteredAt:     stageEnteredAt    ?? this.stageEnteredAt,
    videoId:            videoId           ?? this.videoId,
    sourceType:         sourceType        ?? this.sourceType,
    mimeType:           mimeType          ?? this.mimeType,
    expiresAt:          expiresAt         ?? this.expiresAt,
    urlHost:            urlHost           ?? this.urlHost,
    resolveStartedAt:   resolveStartedAt  ?? this.resolveStartedAt,
    resolveFinishedAt:  resolveFinishedAt ?? this.resolveFinishedAt,
    workerHttpStatus:   workerHttpStatus  ?? this.workerHttpStatus,
    workerErrorBody:    workerErrorBody   ?? this.workerErrorBody,
    setSourceCalled:    setSourceCalled   ?? this.setSourceCalled,
    setSourceSucceeded: setSourceSucceeded?? this.setSourceSucceeded,
    setSourceError:     setSourceError    ?? this.setSourceError,
    playCalled:         playCalled        ?? this.playCalled,
    playSucceeded:      playSucceeded     ?? this.playSucceeded,
    playError:          playError         ?? this.playError,
    processingState:    processingState   ?? this.processingState,
    isPlaying:          isPlaying         ?? this.isPlaying,
    position:           position          ?? this.position,
    buffered:           buffered          ?? this.buffered,
    duration:           duration          ?? this.duration,
    lastError:          lastError         ?? this.lastError,
  );

  // ── Static factory ────────────────────────────────────────────────────────
  /// Begin a new stage — resets stageEnteredAt to now.
  factory PlaybackDiagnostics.atStage(
    PlaybackStage stage, {
    required String videoId,
    String?    sourceType,  String? mimeType,
    int        expiresAt  = 0,
    String     urlHost    = '…',
    DateTime?  resolveStartedAt, DateTime? resolveFinishedAt,
    int        workerHttpStatus = 0,
    String?    workerErrorBody,
    bool       setSourceCalled    = false,
    bool       setSourceSucceeded = false,
    String?    setSourceError,
    bool       playCalled    = false,
    bool       playSucceeded = false,
    String?    playError,
    String     processingState = 'idle',
    bool       isPlaying   = false,
    Duration   position    = Duration.zero,
    Duration   buffered    = Duration.zero,
    Duration   duration    = Duration.zero,
    String?    lastError,
  }) => PlaybackDiagnostics(
    stage:              stage,
    stageEnteredAt:     DateTime.now(),
    videoId:            videoId,
    sourceType:         sourceType  ?? '…',
    mimeType:           mimeType    ?? '…',
    expiresAt:          expiresAt,
    urlHost:            urlHost,
    resolveStartedAt:   resolveStartedAt,
    resolveFinishedAt:  resolveFinishedAt,
    workerHttpStatus:   workerHttpStatus,
    workerErrorBody:    workerErrorBody,
    setSourceCalled:    setSourceCalled,
    setSourceSucceeded: setSourceSucceeded,
    setSourceError:     setSourceError,
    playCalled:         playCalled,
    playSucceeded:      playSucceeded,
    playError:          playError,
    processingState:    processingState,
    isPlaying:          isPlaying,
    position:           position,
    buffered:           buffered,
    duration:           duration,
    lastError:          lastError,
  );

  /// Compat factory for quick "resolving" snapshot.
  factory PlaybackDiagnostics.resolving(String videoId, {DateTime? resolveStartedAt}) =>
      PlaybackDiagnostics.atStage(
        PlaybackStage.resolving,
        videoId: videoId,
        resolveStartedAt: resolveStartedAt ?? DateTime.now(),
      );
}

/// Global [ValueNotifier] published by [PlaybackEngineImpl].
/// Only alive in debug builds — read-sites are inside kDebugMode guards.
// ignore: non_constant_identifier_names
final PlaybackDiagnosticsNotifier = ValueNotifier<PlaybackDiagnostics?>(null);
