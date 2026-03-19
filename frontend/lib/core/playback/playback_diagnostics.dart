import 'package:flutter/foundation.dart';

// ============================================================================
// TEMPORARY DEBUG-ONLY FILE — remove before shipping to production.
// ============================================================================

// ---------------------------------------------------------------------------
// Stage enum
// ---------------------------------------------------------------------------
enum PlaybackStage {
  idle,

  // ── Resolution ─────────────────────────────────────────────────────────────
  resolving,
  resolved,

  // ── Player setup ────────────────────────────────────────────────────────────
  settingSource,
  sourceReady,

  // ── Buffer / Playback ───────────────────────────────────────────────────────
  buffering,
  playing,
  completed,

  // ── Failure — resolve ────────────────────────────────────────────────────────
  failedResolveTimeout,
  failedResolveHttp,

  // ── Failure — player ────────────────────────────────────────────────────────
  failedSetSource,
  failedBuffering,
  falsePlayingDetected,
  stalledAfterResolved,

  // ── Retry ────────────────────────────────────────────────────────────────────
  fallbackRetryStarted,    // stall detected; picking next candidate
  fallbackRetrySucceeded,  // retry produced confirmed byte flow
  fallbackRetryFailed,     // all attempts exhausted
}

// Where the failure originated
enum FailureSource { none, resolve, playback }

// ---------------------------------------------------------------------------
// PlaybackDiagnostics — full snapshot
// ---------------------------------------------------------------------------
class PlaybackDiagnostics {
  // ── Stage ──────────────────────────────────────────────────────────────────
  final PlaybackStage stage;
  final DateTime      stageEnteredAt;

  // ── Track / Attempt ────────────────────────────────────────────────────────
  final String videoId;
  final int    attempt;       // 1 = initial, 2 = first retry, 3 = second retry
  final String candidateKey; // "CLIENT:itag"  e.g. "ANDROID:140"
  final int    blacklistCount;
  final FailureSource failureSource;

  // ── Resolve result ─────────────────────────────────────────────────────────
  final String sourceType;
  final String mimeType;
  final String clientUsed;
  final int    itag;
  final int    expiresAt;
  final String urlHost;

  // ── Resolve timing ─────────────────────────────────────────────────────────
  final DateTime? resolveStartedAt;
  final DateTime? resolveFinishedAt;
  final int       workerHttpStatus;
  final String?   workerErrorBody;

  // ── setAudioSource ─────────────────────────────────────────────────────────
  final bool    setSourceCalled;
  final bool    setSourceSucceeded;
  final String? setSourceError;

  // ── play() ──────────────────────────────────────────────────────────────────
  final bool    playCalled;
  final bool    playSucceeded;
  final String? playError;

  // ── Player live state ──────────────────────────────────────────────────────
  final String   processingState;
  final bool     isPlaying;
  final Duration position;
  final Duration buffered;
  final Duration duration;

  // ── Error ──────────────────────────────────────────────────────────────────
  final String? lastError;

  const PlaybackDiagnostics({
    required this.stage,
    required this.stageEnteredAt,
    required this.videoId,
    this.attempt        = 1,
    this.candidateKey   = '…',
    this.blacklistCount = 0,
    this.failureSource  = FailureSource.none,
    this.sourceType     = '…',
    this.mimeType       = '…',
    this.clientUsed     = '…',
    this.itag           = 0,
    this.expiresAt      = 0,
    this.urlHost        = '…',
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

  Duration  get stageAge      => DateTime.now().difference(stageEnteredAt);
  Duration? get resolveElapsed {
    if (resolveStartedAt == null || resolveFinishedAt == null) return null;
    return resolveFinishedAt!.difference(resolveStartedAt!);
  }

  // ── copyWith ───────────────────────────────────────────────────────────────
  PlaybackDiagnostics copyWith({
    PlaybackStage? stage,         DateTime?    stageEnteredAt,
    String?        videoId,
    int?           attempt,       String?      candidateKey,
    int?           blacklistCount, FailureSource? failureSource,
    String?  sourceType,   String? mimeType,
    String?  clientUsed,   int?    itag,
    int?     expiresAt,    String? urlHost,
    DateTime? resolveStartedAt, DateTime? resolveFinishedAt,
    int?     workerHttpStatus,  String?   workerErrorBody,
    bool?    setSourceCalled,   bool?     setSourceSucceeded, String? setSourceError,
    bool?    playCalled,        bool?     playSucceeded,      String? playError,
    String?  processingState,   bool?     isPlaying,
    Duration? position,  Duration? buffered,  Duration? duration,
    String?  lastError,
  }) => PlaybackDiagnostics(
    stage:              stage              ?? this.stage,
    stageEnteredAt:     stageEnteredAt     ?? this.stageEnteredAt,
    videoId:            videoId            ?? this.videoId,
    attempt:            attempt            ?? this.attempt,
    candidateKey:       candidateKey       ?? this.candidateKey,
    blacklistCount:     blacklistCount     ?? this.blacklistCount,
    failureSource:      failureSource      ?? this.failureSource,
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
    int      attempt        = 1,
    String   candidateKey   = '…',
    int      blacklistCount = 0,
    FailureSource failureSource = FailureSource.none,
    String?  sourceType,    String? mimeType,
    String   clientUsed     = '…', int itag = 0,
    int      expiresAt      = 0,   String urlHost = '…',
    DateTime? resolveStartedAt, DateTime? resolveFinishedAt,
    int      workerHttpStatus  = 0, String? workerErrorBody,
    bool     setSourceCalled    = false,
    bool     setSourceSucceeded = false, String? setSourceError,
    bool     playCalled    = false,
    bool     playSucceeded = false, String? playError,
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
    attempt:            attempt,
    candidateKey:       candidateKey,
    blacklistCount:     blacklistCount,
    failureSource:      failureSource,
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
    processingState:    processingState,
    isPlaying:          isPlaying,
    position:           position,
    buffered:           buffered,
    duration:           duration,
    lastError:          lastError,
  );

  factory PlaybackDiagnostics.resolving(String videoId, {DateTime? resolveStartedAt, int attempt = 1}) =>
      PlaybackDiagnostics.atStage(
        PlaybackStage.resolving,
        videoId:          videoId,
        attempt:          attempt,
        resolveStartedAt: resolveStartedAt ?? DateTime.now(),
      );
}

/// Global notifier published by [PlaybackEngineImpl].
// ignore: non_constant_identifier_names
final PlaybackDiagnosticsNotifier = ValueNotifier<PlaybackDiagnostics?>(null);
