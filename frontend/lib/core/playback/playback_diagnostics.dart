import 'package:flutter/foundation.dart';

// ============================================================================
// TEMPORARY DEBUG-ONLY FILE — remove before shipping to production.
// ============================================================================

// ---------------------------------------------------------------------------
// Stage enum — every distinct step + failure mode
// ---------------------------------------------------------------------------
enum PlaybackStage {
  idle,

  // ── Resolution ──────────────────────────────────────────────────────────
  resolving,              // HTTP GET sent to Worker
  resolved,               // Worker returned 200 JSON

  // ── Player setup ────────────────────────────────────────────────────────
  settingSource,          // setAudioSource() in progress
  sourceReady,            // setAudioSource() returned OK

  // ── Buffer / Playback ───────────────────────────────────────────────────
  buffering,              // play() called; waiting for bytes
  playing,                // confirmed: ready + bytes moving

  // ── Terminal / success ─────────────────────────────────────────────────
  completed,

  // ── Failure ─────────────────────────────────────────────────────────────
  failedResolveTimeout,   // Worker call timed out (15s)
  failedResolveHttp,      // Worker returned non-200
  failedSetSource,        // setAudioSource() threw
  failedBuffering,        // play() returned but no bytes in 3s
  falsePlayingDetected,   // play() + processingState=playing but pos=0/buf=0
  stalledAfterResolved,   // CDN URL obtained but player never left idle

  // ── Retry ───────────────────────────────────────────────────────────────
  fallbackRetryStarted,   // stall detected; invalidating + re-resolving
  fallbackRetrySucceeded, // retry produced confirmed playback
  fallbackRetryFailed,    // retry also produced no bytes
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
  final String sourceType;
  final String mimeType;
  final String clientUsed;  // e.g. 'ANDROID', 'ANDROID_VR', 'IOS'
  final int    itag;        // 140 = audio/mp4 128kbps
  final int    expiresAt;
  final String urlHost;

  // ── Resolve timing ────────────────────────────────────────────────────────
  final DateTime? resolveStartedAt;
  final DateTime? resolveFinishedAt;
  final int       workerHttpStatus;
  final String?   workerErrorBody;

  // ── setAudioSource ────────────────────────────────────────────────────────
  final bool    setSourceCalled;
  final bool    setSourceSucceeded;
  final String? setSourceError;

  // ── play() ────────────────────────────────────────────────────────────────
  final bool    playCalled;
  final bool    playSucceeded;
  final String? playError;

  // ── Retry tracking ────────────────────────────────────────────────────────
  final int     retryCount;
  final String? retryClientUsed;

  // ── Player live state ─────────────────────────────────────────────────────
  final String   processingState;
  final bool     isPlaying;
  final Duration position;
  final Duration buffered;
  final Duration duration;

  // ── Error ─────────────────────────────────────────────────────────────────
  final String? lastError;

  const PlaybackDiagnostics({
    required this.stage,
    required this.stageEnteredAt,
    required this.videoId,
    this.sourceType       = '…',
    this.mimeType         = '…',
    this.clientUsed       = '…',
    this.itag             = 0,
    this.expiresAt        = 0,
    this.urlHost          = '…',
    this.resolveStartedAt,
    this.resolveFinishedAt,
    this.workerHttpStatus = 0,
    this.workerErrorBody,
    this.setSourceCalled    = false,
    this.setSourceSucceeded = false,
    this.setSourceError,
    this.playCalled    = false,
    this.playSucceeded = false,
    this.playError,
    this.retryCount      = 0,
    this.retryClientUsed,
    this.processingState = 'idle',
    this.isPlaying       = false,
    this.position        = Duration.zero,
    this.buffered        = Duration.zero,
    this.duration        = Duration.zero,
    this.lastError,
  });

  bool get isUrlExpired {
    if (expiresAt == 0) return false;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 >= expiresAt;
  }

  Duration get stageAge => DateTime.now().difference(stageEnteredAt);

  Duration? get resolveElapsed {
    if (resolveStartedAt == null || resolveFinishedAt == null) return null;
    return resolveFinishedAt!.difference(resolveStartedAt!);
  }

  String get stageName => stage.name;

  // ── copyWith ──────────────────────────────────────────────────────────────
  PlaybackDiagnostics copyWith({
    PlaybackStage? stage,   DateTime? stageEnteredAt,
    String?  videoId,
    String?  sourceType,    String?   mimeType,
    String?  clientUsed,    int?      itag,
    int?     expiresAt,     String?   urlHost,
    DateTime? resolveStartedAt, DateTime? resolveFinishedAt,
    int?     workerHttpStatus,  String?   workerErrorBody,
    bool?    setSourceCalled,   bool?     setSourceSucceeded, String? setSourceError,
    bool?    playCalled,        bool?     playSucceeded,      String? playError,
    int?     retryCount,        String?   retryClientUsed,
    String?  processingState,
    bool?    isPlaying,
    Duration? position,  Duration? buffered,  Duration? duration,
    String?  lastError,
  }) => PlaybackDiagnostics(
    stage:              stage              ?? this.stage,
    stageEnteredAt:     stageEnteredAt     ?? this.stageEnteredAt,
    videoId:            videoId            ?? this.videoId,
    sourceType:         sourceType         ?? this.sourceType,
    mimeType:           mimeType           ?? this.mimeType,
    clientUsed:         clientUsed         ?? this.clientUsed,
    itag:               itag               ?? this.itag,
    expiresAt:          expiresAt          ?? this.expiresAt,
    urlHost:            urlHost            ?? this.urlHost,
    resolveStartedAt:   resolveStartedAt   ?? this.resolveStartedAt,
    resolveFinishedAt:  resolveFinishedAt  ?? this.resolveFinishedAt,
    workerHttpStatus:   workerHttpStatus   ?? this.workerHttpStatus,
    workerErrorBody:    workerErrorBody    ?? this.workerErrorBody,
    setSourceCalled:    setSourceCalled    ?? this.setSourceCalled,
    setSourceSucceeded: setSourceSucceeded ?? this.setSourceSucceeded,
    setSourceError:     setSourceError     ?? this.setSourceError,
    playCalled:         playCalled         ?? this.playCalled,
    playSucceeded:      playSucceeded      ?? this.playSucceeded,
    playError:          playError          ?? this.playError,
    retryCount:         retryCount         ?? this.retryCount,
    retryClientUsed:    retryClientUsed    ?? this.retryClientUsed,
    processingState:    processingState    ?? this.processingState,
    isPlaying:          isPlaying          ?? this.isPlaying,
    position:           position           ?? this.position,
    buffered:           buffered           ?? this.buffered,
    duration:           duration           ?? this.duration,
    lastError:          lastError          ?? this.lastError,
  );

  factory PlaybackDiagnostics.atStage(
    PlaybackStage stage, {
    required String videoId,
    String?  sourceType,   String? mimeType,
    String   clientUsed   = '…',  int itag = 0,
    int      expiresAt    = 0,     String urlHost = '…',
    DateTime? resolveStartedAt, DateTime? resolveFinishedAt,
    int      workerHttpStatus  = 0,
    String?  workerErrorBody,
    bool     setSourceCalled    = false,
    bool     setSourceSucceeded = false,
    String?  setSourceError,
    bool     playCalled    = false,
    bool     playSucceeded = false,
    String?  playError,
    int      retryCount      = 0,
    String?  retryClientUsed,
    String   processingState = 'idle',
    bool     isPlaying   = false,
    Duration position    = Duration.zero,
    Duration buffered    = Duration.zero,
    Duration duration    = Duration.zero,
    String?  lastError,
  }) => PlaybackDiagnostics(
    stage:              stage,
    stageEnteredAt:     DateTime.now(),
    videoId:            videoId,
    sourceType:         sourceType  ?? '…',
    mimeType:           mimeType    ?? '…',
    clientUsed:         clientUsed,
    itag:               itag,
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
    retryCount:         retryCount,
    retryClientUsed:    retryClientUsed,
    processingState:    processingState,
    isPlaying:          isPlaying,
    position:           position,
    buffered:           buffered,
    duration:           duration,
    lastError:          lastError,
  );

  factory PlaybackDiagnostics.resolving(String videoId, {DateTime? resolveStartedAt}) =>
      PlaybackDiagnostics.atStage(
        PlaybackStage.resolving,
        videoId: videoId,
        resolveStartedAt: resolveStartedAt ?? DateTime.now(),
      );
}

/// Global [ValueNotifier] published by [PlaybackEngineImpl].
// ignore: non_constant_identifier_names
final PlaybackDiagnosticsNotifier = ValueNotifier<PlaybackDiagnostics?>(null);
