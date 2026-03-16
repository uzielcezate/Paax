import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'playback_diagnostics.dart';
import 'playback_engine.dart';

/// Typed exception thrown when resolution or player setup fails.
/// Already a safe, user-friendly string — never exposes raw errors.
class _PlaybackResolveException implements Exception {
  final String message;
  const _PlaybackResolveException(this.message);
  @override
  String toString() => message;
}

// User-Agent: standard browser UA.
// The YouTube mobile app UA was causing CDN to treat the request as an
// adaptive/DASH client; a browser UA signals progressive HTTP download intent.
const _kYouTubeHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/122.0.0.0 Safari/537.36',
  'Referer': 'https://www.youtube.com/',
  'Origin': 'https://www.youtube.com',
};

// ---------------------------------------------------------------------------
// Stream format filter
// ---------------------------------------------------------------------------

/// Returns true only when a stream is safe for direct progressive playback.
///
/// Acceptance criteria (ALL must be true):
///   1. Container is mp4 / m4a / AAC (not webm, not opus).
///   2. URL does NOT contain `sq=`  — presence of `sq` means the URL is a
///      DASH segment (one chunk of many), not a full progressive file.
///   3. URL does not look like a manifest (.m3u8, .mpd, manifest_type=).
///
/// Preference (used in sort, not hard rejection):
///   Streams with `clen=` in their URL have a known byte length declared by
///   the CDN, indicating the server will serve a complete seekable file.
bool _isDirectPlayable(AudioOnlyStreamInfo s) {
  final mime = s.codec.mimeType.toLowerCase();
  final container = s.container.name.toLowerCase();
  final url = s.url;
  final path = url.path.toLowerCase();
  final params = url.queryParameters;

  // ── Container check ──────────────────────────────────────────────────────
  final isMp4Mime = mime.contains('mp4') ||
      mime.contains('m4a') ||
      mime.contains('aac') ||
      container == 'mp4';
  if (!isMp4Mime) return false;
  if (mime.contains('webm') || container.contains('webm')) return false;
  if (mime.contains('opus')) return false;

  // ── URL-level DASH indicators ─────────────────────────────────────────────
  // sq= identifies a DASH segment chunk — ExoPlayer cannot use it as a
  // progressive source; it would need the full DASH manifest instead.
  if (params.containsKey('sq')) return false;

  // manifest_type, .m3u8, .mpd  → definitely a manifest, not a stream.
  if (params.containsKey('manifest_type')) return false;
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return false;
  if (path.contains('manifest') || path.contains('playlist')) return false;

  return true;
}

/// Returns true only when a MuxedStreamInfo is safe for direct progressive
/// playback by ExoPlayer. ExoPlayer will discard the video track and play
/// only the embedded audio — this is the fallback when all audio-only streams
/// are DASH-segmented.
///
/// Acceptance criteria:
///   1. Container is mp4 (not webm).
///   2. URL does NOT contain `sq=` (DASH segment indicator).
///   3. URL is not a manifest (.m3u8, .mpd, manifest_type=).
bool _isDirectPlayableMuxed(MuxedStreamInfo s) {
  final container = s.container.name.toLowerCase();
  final url = s.url;
  final path = url.path.toLowerCase();
  final params = url.queryParameters;

  if (container != 'mp4') return false;
  if (params.containsKey('sq')) return false;
  if (params.containsKey('manifest_type')) return false;
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return false;
  if (path.contains('manifest') || path.contains('playlist')) return false;

  return true;
}


// ---------------------------------------------------------------------------
// PlaybackEngineImpl
// ---------------------------------------------------------------------------

/// Native-platform playback engine shared by Android and iOS.
///
/// APPROACH (this revision):
///   Uses [AudioSource.uri()] with YouTube CDN headers passed directly.
///   This lets ExoPlayer's built-in HTTP stack handle range requests and
///   buffering natively, while the CDN headers ensure auth is accepted.
///
///   WHY NOT StreamAudioSource byte-pipe:
///   The previous _YtStreamAudioSource approach was failing at setAudioSource
///   because just_audio's internal probe request during setAudioSource was
///   also failing — meaning the byte-piping was not solving the core issue.
///   Switching to AudioSource.uri() + headers is the correctapproach because:
///   1. ExoPlayer natively handles HTTP range requests, retries and buffering
///   2. The headers param in just_audio v0.9.x is forwarded to ExoPlayer
///   3. YouTube mp4/m4a audio-only streams ARE accessible as progressive HTTP
///      streams when the correct User-Agent and Referer headers are provided
class PlaybackEngineImpl implements PlaybackEngine {
  // preload: false on setAudioSource() defers network probing/buffering until
  // play() is actually called. This cuts the ~15s startup delay to sub-second
  // perceived latency (just_audio 0.9.x equivalent of lazy preparation).
  final _player = AudioPlayer();
  final _completionController = StreamController<void>.broadcast();
  bool _isDisposed = false;
  final _subscriptions = <StreamSubscription>[];

  // ── Load-lock: integer generation counter ─────────────────────────────────
  // Bumped at the start of every load() call. Any in-flight load() that finds
  // its myId != _loadId after an await knows it has been superseded and bails
  // out silently. Prevents concurrent loads racing to _player.play().
  int _loadId = 0;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration> get durationStream => _player.durationStream
      .where((d) => d != null && d > Duration.zero)
      .map((d) => d!);

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  @override
  Future<void> initialize() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _subscriptions.add(
      session.interruptionEventStream.listen((event) {
        if (_isDisposed) return;
        if (event.begin) {
          _player.pause();
        } else if (event.type == AudioInterruptionType.pause ||
            event.type == AudioInterruptionType.duck) {
          _player.play();
        }
      }),
    );
    _subscriptions.add(
      session.becomingNoisyEventStream.listen((_) {
        if (_isDisposed) return;
        _player.pause();
      }),
    );
    _subscriptions.add(
      _player.playerStateStream.listen((state) {
        if (_isDisposed) return;
        debugPrint(
          '[PLAYER STATE] playing=${state.playing}  '
          'processingState=${state.processingState.name}',
        );
        if (state.processingState == ProcessingState.completed) {
          _completionController.add(null);
        }
      }),
    );
    _subscriptions.add(
      _player.positionStream.listen((pos) {
        if (_isDisposed) return;
        // Only log every 2 seconds to avoid flooding logcat.
        if (pos.inMilliseconds % 2000 < 250) {
          debugPrint('[PLAYER POSITION] ${pos.inSeconds}s');
        }
      }),
    );
  }

  // -------------------------------------------------------------------------
  // Stream resolution
  // -------------------------------------------------------------------------

  // ── Worker-first stream resolution ─────────────────────────────────────
  //
  // Calls the Cloudflare Worker at stream.paaxmusic.app/{videoId}.
  // The Worker does Innertube resolution + CF cache, then returns a 302
  // redirect to the signed googlevideo CDN URL.
  // We follow the redirect to obtain the final CDN URL for just_audio.
  //
  // Returns the final playable CDN Uri, or null on any failure.
  Future<Uri?> _tryWorkerResolve(String videoId) async {
    try {
      debugPrint('[WORKER STREAM] loading $videoId');
      final workerUri = Uri.parse('https://stream.paaxmusic.app/$videoId');

      // http.get follows redirects by default — it will chase the 302 the
      // Worker returns and land on the final googlevideo.com CDN URL.
      final response = await http.get(
        workerUri,
        headers: const {'Accept': '*/*'},
      ).timeout(const Duration(seconds: 10));

      // After following the redirect, the final URL is the CDN URL.
      // http package exposes it via response.request!.url after redirect chain.
      final finalUrl = response.request?.url;

      if (response.statusCode == 200 && finalUrl != null) {
        debugPrint('[WORKER STREAM] resolved to ${finalUrl.host} (status=200)');
        return finalUrl;
      }

      // If the Worker returned a non-200 final response, log and fail.
      debugPrint(
          '[WORKER STREAM] failed: HTTP ${response.statusCode} for $videoId');
      return null;
    } catch (e) {
      debugPrint('[WORKER STREAM] failed: $e');
      return null;
    }
  }

  // ── Typed resolution result ────────────────────────────────────────────────
  // isMuxedFallback = true  → chosen from manifest.muxed (video+audio container)
  // isMuxedFallback = false → chosen from manifest.audioOnly (preferred)

  /// Resolves the best playable stream for [videoId].
  ///
  /// V3 — Worker-first mode (Railway and youtube_explode_dart disabled for testing):
  ///   1. Call Cloudflare Worker at stream.paaxmusic.app/{videoId}.
  ///   2. Worker handles Innertube resolution, CF cache, and returns a CDN URL.
  ///   3. Use that CDN URL directly with just_audio.
  ///
  /// NOTE: youtube_explode_dart fallback paths are temporarily disabled so
  /// Worker-first behaviour can be verified cleanly. Re-enable by uncommenting
  /// the fallback block below once Worker is confirmed stable.
  Future<
    ({Uri url, String codec, String container, int bitrateKbps, bool isMuxedFallback})
  > _resolveStream(String videoId) async {
    // ── PATH 0: Cloudflare Worker (primary — Worker-first) ─────────────────
    final workerUrl = await _tryWorkerResolve(videoId);
    if (workerUrl != null) {
      debugPrint('[WORKER STREAM] setAudioSource OK — using CDN URL from Worker');
      return (
        url: workerUrl,
        codec: 'audio/mp4',
        container: 'mp4',
        bitrateKbps: 0,
        isMuxedFallback: false,
      );
    }

    // ── WORKER FAILED — throw instead of falling back ───────────────────────
    // youtube_explode_dart fallback intentionally disabled during Worker-first
    // testing. To re-enable, uncomment the block below and remove this throw.
    debugPrint('[WORKER STREAM] failed: Worker returned null — throwing');
    throw const _PlaybackResolveException(
      'Stream temporarily unavailable. Please try again.'
    );

    // ── DISABLED FALLBACK (re-enable post-validation) ───────────────────────
    // ignore: dead_code
    /*
    debugPrint('[RESOLVE CACHE MISS] Worker failed — falling back to youtube_explode_dart');
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final directStreams = manifest.audioOnly.where(_isDirectPlayable).toList();
      if (directStreams.isNotEmpty) {
        directStreams.sort((a, b) {
          final aClen = a.url.queryParameters.containsKey('clen') ? 1 : 0;
          final bClen = b.url.queryParameters.containsKey('clen') ? 1 : 0;
          if (bClen != aClen) return bClen - aClen;
          return b.bitrate.compareTo(a.bitrate);
        });
        final chosen = directStreams.first;
        return (
          url: chosen.url,
          codec: chosen.codec.mimeType,
          container: chosen.container.name,
          bitrateKbps: (chosen.bitrate.bitsPerSecond / 1000).round(),
          isMuxedFallback: false,
        );
      }
      return await _resolveMuxedFallback(videoId, manifest);
    } finally {
      yt.close();
    }
    */
  }

  /// Selects the best progressive mp4 muxed stream from [manifest].
  ///
  /// Sort order: clen= first (known-length), then **lowest** bitrate — we only
  /// need the audio track, so smallest file is preferable.
  Future<
    ({Uri url, String codec, String container, int bitrateKbps, bool isMuxedFallback})
  > _resolveMuxedFallback(String videoId, StreamManifest manifest) async {
    final muxedStreams = manifest.muxed;

    if (kDebugMode) {
      debugPrint('[MUXED FALLBACK] ${muxedStreams.length} muxed candidates:');
      for (final s in muxedStreams) {
        final pass = _isDirectPlayableMuxed(s) ? '✓' : '✗';
        debugPrint(
          '  $pass  container=${s.container.name}  '
          'bitrate=${(s.bitrate.bitsPerSecond / 1000).round()} kbps  '
          'has_sq=${s.url.queryParameters.containsKey('sq')}',
        );
      }
    }

    final direct = muxedStreams.where(_isDirectPlayableMuxed).toList();

    if (direct.isEmpty) {
      debugPrint('[MUXED FALLBACK] No muxed streams found either — giving up.');
      throw const _PlaybackResolveException(
        'This track is temporarily unavailable.',
      );
    }

    // Sort: clen= streams first, then lowest bitrate (smallest download).
    direct.sort((a, b) {
      final aClen = a.url.queryParameters.containsKey('clen') ? 1 : 0;
      final bClen = b.url.queryParameters.containsKey('clen') ? 1 : 0;
      if (bClen != aClen) return bClen - aClen;
      return a.bitrate.compareTo(b.bitrate); // lowest bitrate = smallest file
    });

    final chosen = direct.first;
    final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();
    final uri = chosen.url;

    if (kDebugMode) {
      debugPrint(
        '[MUXED FALLBACK] ✓ Selected muxed stream:\n'
        '  container  : ${chosen.container.name}\n'
        '  bitrate    : $bitrateKbps kbps\n'
        '  clen_known : ${uri.queryParameters.containsKey('clen')}\n'
        '  url_preview: ${uri.toString().substring(0, uri.toString().length.clamp(0, 80))}…',
      );
    }

    return (
      url: uri,
      codec: chosen.codec.mimeType,
      container: chosen.container.name,
      bitrateKbps: bitrateKbps,
      isMuxedFallback: true,
    );
  }

  // -------------------------------------------------------------------------
  // Load & play
  // -------------------------------------------------------------------------

  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty) return;

    // ── Load-lock: stamp this call with a generation ID ───────────────────
    // Any previous in-flight load() will detect _loadId has changed after its
    // next await and exit silently — preventing concurrent playback races.
    final myId = ++_loadId;

    // ── Step 1: Stop immediately — before resolution ──────────────────────
    debugPrint(
      '[PLAYER STOP] >>> before stop()  '
      'playing=${_player.playing}  '
      'state=${_player.processingState.name}  '
      'videoId=$videoId',
    );
    await _player.stop();
    debugPrint(
      '[PLAYER STOP] <<< after stop()  '
      'playing=${_player.playing}  '
      'state=${_player.processingState.name}',
    );
    if (_loadId != myId) {
      debugPrint('[PLAYER STOP] Superseded by newer load — bailing ($videoId)');
      return;
    }

    // Publish resolving state immediately so debug panel updates.
    if (kDebugMode) {
      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics.resolving(videoId);
    }

    // ── Step 2: Resolve stream (audio-only preferred, muxed fallback) ──────
    late ({Uri url, String codec, String container, int bitrateKbps, bool isMuxedFallback}) resolved;
    try {
      resolved = await _resolveStream(videoId);
    } on _PlaybackResolveException {
      rethrow;
    } catch (e) {
      debugPrint('[PlaybackEngine][Error] Unexpected resolution error for $videoId: $e');
      throw const _PlaybackResolveException('This track is temporarily unavailable.');
    }

    // Bail out if superseded during resolution (user tapped another track).
    if (_loadId != myId) {
      debugPrint('[PLAYER LOAD] Superseded during resolve — bailing ($videoId)');
      return;
    }

    final pathTag = resolved.isMuxedFallback ? '[MUXED FALLBACK]' : '[AUDIO STREAM]';

    // (old Step 2 — stop — is now Step 1 above)

    // ── Step 3: Build AudioSource.uri with YouTube CDN headers ────────────
    final uri = resolved.url;
    final source = AudioSource.uri(uri, headers: _kYouTubeHeaders);

    if (kDebugMode) {
      debugPrint(
        '$pathTag PRE-FLIGHT SUMMARY\n'
        '  videoId      : $videoId\n'
        '  path         : ${resolved.isMuxedFallback ? 'muxed mp4 (audio-only DASH fallback)' : 'audio-only direct stream'}\n'
        '  codec        : ${resolved.codec}\n'
        '  container    : ${resolved.container}\n'
        '  bitrate      : ${resolved.bitrateKbps} kbps\n'
        '  headers      : User-Agent ✓  Referer ✓  Origin ✓\n'
        '  url_host     : ${uri.host}\n'
        '  url_scheme   : ${uri.scheme}',
      );

      PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
        videoId: videoId,
        urlHost: uri.host,
        urlScheme: uri.scheme,
        mimeType: resolved.codec,
        container: resolved.container,
        bitrateKbps: resolved.bitrateKbps,
        sizeKnown: false,
        totalBytes: 0,
        headersAttached: true,
        directStream: true,
        isManifest: false,
        succeeded: false,
        shortReason: 'Waiting for setAudioSource… ($pathTag)',
      );
    }

    // ── Step 4: setAudioSource — with muxed retry on failure ──────────────
    debugPrint(
      '[PLAYER LOAD] >>> before setAudioSource()  '
      'playing=${_player.playing}  '
      'state=${_player.processingState.name}  '
      '$pathTag  videoId=$videoId',
    );
    try {
      // preload: false — ExoPlayer defers buffering until play() is called,
      // giving sub-second perceived startup latency.
      await _player.setAudioSource(source, preload: false);
      debugPrint(
        '[PLAYER LOAD] <<< after setAudioSource()  '
        'playing=${_player.playing}  '
        'state=${_player.processingState.name}  '
        'duration=${_player.duration}  '
        'position=${_player.position}  '
        'buffered=${_player.bufferedPosition}',
      );
      if (_loadId != myId) {
        debugPrint('[PLAYER LOAD] Superseded after setAudioSource — bailing ($videoId)');
        return;
      }
    } catch (e) {
      final errStr = e.toString();
      debugPrint(
        '$pathTag setAudioSource() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $errStr',
      );

      // ── Muxed retry (only if the primary path was audio-only) ────────────
      // Do NOT retry if we're already on the muxed fallback path — that
      // would just loop. Also skip retry if this is a network/auth error;
      // only retry for ExoPlayer source-rejection (PlayerException code 1000
      // or "Source error" in the message).
      if (!resolved.isMuxedFallback) {
        final isSourceError = e is PlayerException ||
            errStr.toLowerCase().contains('source error') ||
            errStr.contains('(1000)');
        if (isSourceError) {
          debugPrint(
            '[MUXED FALLBACK] Audio-only setAudioSource rejected by ExoPlayer. '
            'Attempting muxed mp4 fallback for $videoId…',
          );
          try {
            // Re-open a fresh manifest session for the muxed attempt.
            final yt = YoutubeExplode();
            late ({Uri url, String codec, String container, int bitrateKbps, bool isMuxedFallback}) muxed;
            try {
              final muxedManifest = await yt.videos.streamsClient.getManifest(videoId);
              muxed = await _resolveMuxedFallback(videoId, muxedManifest);
            } finally {
              yt.close();
            }
            final muxedSource = AudioSource.uri(muxed.url, headers: _kYouTubeHeaders);
            await _player.setAudioSource(muxedSource, preload: false);
            debugPrint('[MUXED FALLBACK] setAudioSource() OK — $videoId');
            // Update resolved binding so play() diagnostics are accurate.
            resolved = muxed;
          } catch (muxedErr) {
            debugPrint('[MUXED FALLBACK] Also failed: $muxedErr');
            // Fall through to the original error path below.
            if (kDebugMode) {
              PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
                videoId: videoId,
                urlHost: uri.host,
                urlScheme: uri.scheme,
                mimeType: resolved.codec,
                container: resolved.container,
                bitrateKbps: resolved.bitrateKbps,
                sizeKnown: false,
                totalBytes: 0,
                headersAttached: true,
                directStream: true,
                isManifest: false,
                succeeded: false,
                failedAt: 'setAudioSource+muxedFallback',
                exceptionMessage: muxedErr.toString().length > 200
                    ? '${muxedErr.toString().substring(0, 200)}…'
                    : muxedErr.toString(),
                shortReason: PlaybackDiagnostics.inferReason(muxedErr.toString()),
              );
            }
            throw _PlaybackResolveException(
              'Playback source rejected (both audio-only and muxed failed): '
              '${_friendlyPlayerError(muxedErr)}',
            );
          }
          // Muxed retry succeeded — skip the throw below, continue to play().
        } else {
          // Non-source error (network, auth, etc.) — don't retry.
          if (kDebugMode) {
            PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
              videoId: videoId,
              urlHost: uri.host,
              urlScheme: uri.scheme,
              mimeType: resolved.codec,
              container: resolved.container,
              bitrateKbps: resolved.bitrateKbps,
              sizeKnown: false,
              totalBytes: 0,
              headersAttached: true,
              directStream: true,
              isManifest: false,
              succeeded: false,
              failedAt: 'setAudioSource',
              exceptionMessage:
                  errStr.length > 200 ? '${errStr.substring(0, 200)}…' : errStr,
              shortReason: PlaybackDiagnostics.inferReason(errStr),
            );
          }
          const hint = kDebugMode ? ' (setAudioSource failed)' : '';
          throw _PlaybackResolveException(
            'Playback source rejected$hint: ${_friendlyPlayerError(e)}',
          );
        }
      } else {
        // Already on muxed path and it still failed.
        if (kDebugMode) {
          PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
            videoId: videoId,
            urlHost: uri.host,
            urlScheme: uri.scheme,
            mimeType: resolved.codec,
            container: resolved.container,
            bitrateKbps: resolved.bitrateKbps,
            sizeKnown: false,
            totalBytes: 0,
            headersAttached: true,
            directStream: true,
            isManifest: false,
            succeeded: false,
            failedAt: 'setAudioSource (muxed)',
            exceptionMessage:
                errStr.length > 200 ? '${errStr.substring(0, 200)}…' : errStr,
            shortReason: PlaybackDiagnostics.inferReason(errStr),
          );
        }
        const hint = kDebugMode ? ' (muxed setAudioSource failed)' : '';
        throw _PlaybackResolveException(
          'Playback source rejected$hint: ${_friendlyPlayerError(e)}',
        );
      }
    }

    // ── Step 5: seek to zero + play ───────────────────────────────────────
    // CRITICAL: No _loadId guard between seek() and play().
    // The seek+play pair must be atomic — inserting an async bail point here
    // was the root cause of silent playback (play() was being skipped).
    final finalUri = resolved.url;
    final finalPathTag = resolved.isMuxedFallback ? '[MUXED FALLBACK]' : '[AUDIO STREAM]';
    try {
      debugPrint(
        '[PLAYER PLAY] >>> before seek(0)  '
        'playing=${_player.playing}  '
        'state=${_player.processingState.name}  '
        'videoId=$videoId',
      );
      await _player.seek(Duration.zero);
      debugPrint(
        '[PLAYER PLAY] <<< after seek(0)  '
        'playing=${_player.playing}  '
        'state=${_player.processingState.name}  '
        'position=${_player.position}',
      );

      debugPrint(
        '[PLAYER PLAY] >>> before play()  '
        'playing=${_player.playing}  '
        'state=${_player.processingState.name}',
      );
      await _player.play();
      debugPrint(
        '[PLAYER PLAY] <<< after play()  '
        'playing=${_player.playing}  '
        'state=${_player.processingState.name}  '
        'duration=${_player.duration}  '
        'position=${_player.position}  '
        'buffered=${_player.bufferedPosition}  '
        '$finalPathTag  videoId=$videoId',
      );

      // ── 2-second stall detector ────────────────────────────────────────
      // After play() returns, schedule a check: if the position hasn't
      // advanced after 2 seconds, something is stalled.
      final posAtPlayStart = _player.position;
      final stallCheckId = myId; // capture so we can detect superseded loads
      Future.delayed(const Duration(seconds: 2), () {
        if (_isDisposed || _loadId != stallCheckId) return;
        final currentPos = _player.position;
        if (currentPos <= posAtPlayStart) {
          debugPrint(
            '[PLAYBACK STALLED] Position has not advanced after 2s!  '
            'playing=${_player.playing}  '
            'state=${_player.processingState.name}  '
            'posAtStart=$posAtPlayStart  '
            'posNow=$currentPos  '
            'duration=${_player.duration}  '
            'buffered=${_player.bufferedPosition}  '
            'videoId=$videoId',
          );
        } else {
          debugPrint(
            '[PLAYBACK STALLED] OK — position advanced from '
            '${posAtPlayStart.inMilliseconds}ms to ${currentPos.inMilliseconds}ms',
          );
        }
      });

      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId: videoId,
          urlHost: finalUri.host,
          urlScheme: finalUri.scheme,
          mimeType: resolved.codec,
          container: resolved.container,
          bitrateKbps: resolved.bitrateKbps,
          sizeKnown: false,
          totalBytes: 0,
          headersAttached: true,
          directStream: true,
          isManifest: false,
          succeeded: true,
          shortReason: resolved.isMuxedFallback ? 'Muxed mp4 fallback' : 'Audio-only direct stream',
        );
      }
    } catch (e) {
      final errStr = e.toString();
      debugPrint(
        '$finalPathTag play() FAILED — $videoId\n'
        '  type   : ${e.runtimeType}\n'
        '  value  : $errStr',
      );
      if (kDebugMode) {
        PlaybackDiagnosticsNotifier.value = PlaybackDiagnostics(
          videoId: videoId,
          urlHost: finalUri.host,
          urlScheme: finalUri.scheme,
          mimeType: resolved.codec,
          container: resolved.container,
          bitrateKbps: resolved.bitrateKbps,
          sizeKnown: false,
          totalBytes: 0,
          headersAttached: true,
          directStream: true,
          isManifest: false,
          succeeded: false,
          failedAt: 'play()',
          exceptionMessage:
              errStr.length > 200 ? '${errStr.substring(0, 200)}…' : errStr,
          shortReason: PlaybackDiagnostics.inferReason(errStr),
        );
      }
      const hint = kDebugMode ? ' (play() failed)' : '';
      throw _PlaybackResolveException(
        'Playback failed to start$hint: ${_friendlyPlayerError(e)}',
      );
    }
  }

  String _friendlyPlayerError(Object e) {
    if (e is PlayerException) {
      return '(${e.code}) ${e.message ?? 'Unknown player error'}';
    }
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  // -------------------------------------------------------------------------
  // Playback controls
  // -------------------------------------------------------------------------

  @override
  Future<void> play() async {
    debugPrint('[PLAYER PLAY] resume');
    await _player.play();
  }

  @override
  Future<void> pause() async {
    debugPrint('[PLAYER PAUSE]');
    await _player.pause();
  }

  @override
  Future<void> seek(Duration position) async => _player.seek(position);

  // ---------------------------------------------------------------------------
  // Background prefetch
  // ---------------------------------------------------------------------------

  @override
  void prefetchNext(String videoId) {
    // Prefetch intentionally no-oped during Worker-first testing.
    // The Cloudflare Worker's CF Cache handles repeat-play latency.
    debugPrint('[TRACK PREFETCH] skipped — Worker-first mode (CF Cache handles caching)');
  }

  @override
  void dispose() {
    _isDisposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _player.dispose();
    _completionController.close();
  }

  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox.shrink();
}
