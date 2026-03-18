import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'media_resolver.dart';
import 'stream_cache.dart';
import 'playback_diagnostics.dart';
import 'playback_engine.dart';

// ---------------------------------------------------------------------------
// PlaybackEngineImpl — Media Engine V1
// ---------------------------------------------------------------------------
//
// Architecture:
//   load(videoId)
//     → StreamCache.get()         ← [MEDIA CACHE HIT] / [MEDIA CACHE MISS]
//     → MediaResolver.resolve()   ← [MEDIA RESOLVE]
//     → AudioSource.uri(workerUrl)← just_audio fetches bytes from Worker
//     → _player.play()            ← [MEDIA PLAY]
//
// The Worker URL (stream.paaxmusic.app/{videoId}) never expires from the
// app's perspective. The Worker handles Innertube re-resolution and CDN
// proxy transparently. No headers are needed here — the Worker returns
// proper Content-Type, Accept-Ranges, and CORS headers.
//
// ── old paths removed ───────────────────────────────────────────────────────
//   • _tryWorkerResolve (inline HTTP) → replaced by MediaResolver
//   • youtube_explode_dart fallback   → commented-out block gone
//   • _kYouTubeHeaders                → not needed for Worker URL
//   • prefetchNext Railway call       → replaced by PrefetchManager
// ────────────────────────────────────────────────────────────────────────────

class PlaybackEngineImpl implements PlaybackEngine {
  PlaybackEngineImpl({
    MediaResolver? resolver,
    StreamCache?   cache,
  })  : _resolver = resolver ?? MediaResolver(),
        _cache    = cache    ?? StreamCache.instance;

  final MediaResolver _resolver;
  final StreamCache   _cache;
  final _player       = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();

  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

  // Load-lock: generation counter. Bumped at every load() call.
  // Any in-flight load() that finds _loadId changed after an await bails out.
  int _loadId = 0;

  // ── PlaybackEngine streams ─────────────────────────────────────────────────
  @override Stream<Duration> get positionStream  => _player.positionStream;
  @override Stream<Duration> get durationStream  => _player.durationStream
      .where((d) => d != null && d > Duration.zero)
      .map((d) => d!);
  @override Stream<bool>     get playingStream   => _player.playingStream;
  @override Stream<void>     get completionStream => _completionController.stream;

  // ── initialize ─────────────────────────────────────────────────────────────
  @override
  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(session.interruptionEventStream.listen((event) {
      if (_isDisposed) return;
      if (event.begin) {
        _player.pause();
      } else if (event.type == AudioInterruptionType.pause ||
                 event.type == AudioInterruptionType.duck) {
        _player.play();
      }
    }));

    _subscriptions.add(session.becomingNoisyEventStream.listen((_) {
      if (_isDisposed) return;
      _player.pause();
    }));

    _subscriptions.add(_player.playerStateStream.listen((state) {
      if (_isDisposed) return;
      debugPrint(
        '[PLAYER STATE] playing=${state.playing}  '
        'processingState=${state.processingState.name}',
      );
      if (state.processingState == ProcessingState.completed) {
        _completionController.add(null);
      }
    }));

    _subscriptions.add(_player.positionStream.listen((pos) {
      if (_isDisposed) return;
      if (pos.inMilliseconds % 2000 < 250) {
        debugPrint('[PLAYER POSITION] ${pos.inSeconds}s');
      }
    }));
  }

  // ── load ───────────────────────────────────────────────────────────────────
  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;
    final myId = ++_loadId;

    // Step 1: Stop previous playback immediately
    debugPrint('[PLAYER STOP] >>> videoId=$videoId');
    await _player.stop();
    if (_loadId != myId) {
      debugPrint('[PLAYER STOP] Superseded — bailing ($videoId)');
      return;
    }

    // Publish resolving state to debug panel
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(videoId);
    }

    // Step 2: Resolve stream URL (cache → Worker URL, no network probe)
    debugPrint('[MEDIA RESOLVE START] $videoId');
    late ResolvedStream resolved;
    try {
      resolved = await _resolver.resolve(videoId);
    } catch (e) {
      debugPrint('[MEDIA ERROR] $videoId — resolve threw: $e');
      throw const _MediaEngineException('Stream temporarily unavailable. Please try again.');
    }
    if (_loadId != myId) {
      debugPrint('[MEDIA RESOLVE RESULT] Superseded during resolve — bailing ($videoId)');
      return;
    }
    debugPrint('[MEDIA RESOLVE RESULT] $videoId → ${resolved.sourceType} url=${resolved.url}');
    debugPrint('[MEDIA FORMAT PICK] $videoId → ${resolved.sourceType}');

    // Step 3: Build AudioSource — no extra headers needed.
    // The Worker URL returns proper Content-Type + CORS + Accept-Ranges headers.
    final uri    = Uri.parse(resolved.url);
    final source = AudioSource.uri(uri);

    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
        videoId:        videoId,
        urlHost:        uri.host,
        urlScheme:      uri.scheme,
        mimeType:       'audio/mp4',
        container:      'mp4',
        bitrateKbps:    0,
        sizeKnown:      false,
        totalBytes:     0,
        headersAttached: false,
        directStream:   true,
        isManifest:     false,
        succeeded:      false,
        shortReason:    'Waiting for setAudioSource…',
      );
    }

    // Step 4: setAudioSource — preload:false defers buffering until play()
    debugPrint('[PLAYER SET SOURCE] $videoId → ${uri.toString().substring(0, uri.toString().length.clamp(0, 70))}…');
    try {
      await _player.setAudioSource(source, preload: false);
      debugPrint('[PLAYER SET SOURCE] OK  state=${_player.processingState.name}  videoId=$videoId');
    } on PlayerException catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId PlayerException: code=${e.code} msg=${e.message}');
      // Invalidate cache so next play re-resolves a fresh URL
      await _cache.invalidate(videoId);
      throw _MediaEngineException(
        'Playback source rejected (${e.code}): ${e.message ?? 'unknown'}',
      );
    } catch (e) {
      debugPrint('[PLAYER SET SOURCE ERROR] $videoId: $e');
      await _cache.invalidate(videoId);
      throw _MediaEngineException('Playback setup failed: $e');
    }

    if (_loadId != myId) {
      debugPrint('[PLAYER LOAD] Superseded after setAudioSource — bailing ($videoId)');
      return;
    }

    // Step 5: seek(0) + play — atomic, no guard between them
    debugPrint('[MEDIA PLAY] $videoId — starting playback');
    try {
      await _player.seek(Duration.zero);
      await _player.play();
      debugPrint('[MEDIA PLAY] $videoId OK  playing=${_player.playing}  '
          'state=${_player.processingState.name}');

      // 2-second stall detector
      final posAtStart   = _player.position;
      final stallCheckId = myId;
      Future.delayed(const Duration(seconds: 2), () {
        if (_isDisposed || _loadId != stallCheckId) return;
        final current = _player.position;
        if (current <= posAtStart) {
          debugPrint('[MEDIA ERROR] $videoId — stall detected after 2s  '
              'playing=${_player.playing}  pos=$current');
        } else {
          debugPrint('[MEDIA PLAY] $videoId advancing normally ✓');
        }
      });

      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId:        videoId,
          urlHost:        uri.host,
          urlScheme:      uri.scheme,
          mimeType:       'audio/mp4',
          container:      'mp4',
          bitrateKbps:    0,
          sizeKnown:      false,
          totalBytes:     0,
          headersAttached: false,
          directStream:   true,
          isManifest:     false,
          succeeded:      true,
          shortReason:    'Worker proxy stream',
        );
      }
    } catch (e) {
      debugPrint('[PLAYER PLAY ERROR] $videoId: $e');
      throw _MediaEngineException('Playback failed to start: $e');
    }
  }

  // ── controls ───────────────────────────────────────────────────────────────
  @override
  Future<void> play() async {
    debugPrint('[MEDIA PLAY] resume');
    await _player.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[PLAYER PAUSE]');
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint('[MEDIA SEEK] ${position.inSeconds}s');
    await _player.seek(position);
  }

  @override
  void prefetchNext(String videoId) {
    // Legacy call-site in PlaybackController; no-op here —
    // prefetching is now handled by PrefetchManager directly.
    // This stub preserves interface compatibility.
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) { sub.cancel(); }
    _subscriptions.clear();
    _player.dispose();
    _completionController.close();
  }

  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}

// ---------------------------------------------------------------------------
// Internal exception
// ---------------------------------------------------------------------------
class _MediaEngineException implements Exception {
  final String message;
  const _MediaEngineException(this.message);
  @override
  String toString() => message;
}
