import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
// URL analysis helper — debug diagnostics only.
// ---------------------------------------------------------------------------
Map<String, String> _analyzeUrl(Uri uri, AudioOnlyStreamInfo info) {
  final path = uri.path.toLowerCase();
  final ext = path.contains('.') ? path.split('.').last.split('?').first : '';
  final isManifest = ext == 'm3u8' ||
      ext == 'mpd' ||
      path.contains('manifest') ||
      path.contains('playlist') ||
      uri.queryParameters.containsKey('manifest_type');
  final isSigned = uri.queryParameters.containsKey('expire') ||
      uri.queryParameters.containsKey('sig') ||
      uri.queryParameters.containsKey('signature') ||
      uri.queryParameters.containsKey('lsig');
  final totalBytes = info.size.totalBytes;

  return {
    'scheme': uri.scheme,
    'host': uri.host,
    'path_ext': ext.isEmpty ? '(none — direct CDN path)' : ext,
    'mime': info.codec.mimeType,
    'container': info.container.name,
    'is_manifest': '$isManifest',
    'is_signed_url': '$isSigned',
    'query_params': '${uri.queryParameters.length}',
    'total_bytes': '$totalBytes',
    'size_known': '${totalBytes > 0}',
    'direct_playable': '${_isDirectPlayable(info)}',
    // DASH indicator: YouTube progressive streams serve full content-length,
    // while DASH segments use 'clen=' query param alongside 'sq='
    'has_sq_param': '${uri.queryParameters.containsKey('sq')}',
    'has_clen_param': '${uri.queryParameters.containsKey('clen')}',
  };
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
        if (state.processingState == ProcessingState.completed) {
          _completionController.add(null);
        }
      }),
    );
  }

  // -------------------------------------------------------------------------
  // Stream resolution
  // -------------------------------------------------------------------------

  // ── Typed resolution result ────────────────────────────────────────────────
  // isMuxedFallback = true  → chosen from manifest.muxed (video+audio container)
  // isMuxedFallback = false → chosen from manifest.audioOnly (preferred)

  /// Resolves the best playable stream for [videoId].
  ///
  /// Resolution order:
  ///   1. [AUDIO STREAM]  — audioOnly, direct-playable mp4/m4a (no sq=).
  ///   2. [MUXED FALLBACK] — muxed mp4 when all audio-only are DASH-segmented.
  ///
  /// The YoutubeExplode session is opened and closed inside this method.
  Future<
    ({Uri url, String codec, String container, int bitrateKbps, bool isMuxedFallback})
  > _resolveStream(String videoId) async {
    final yt = YoutubeExplode();
    try {
      if (kDebugMode) {
        debugPrint('[PlaybackEngine] ▶ Resolving stream for $videoId');
      }

      final manifest = await yt.videos.streamsClient.getManifest(videoId);

      // ── PATH 1: audio-only ───────────────────────────────────────────────
      final audioStreams = manifest.audioOnly;

      if (kDebugMode) {
        debugPrint(
            '[AUDIO STREAM] ${audioStreams.length} audio-only candidates:');
        for (final s in audioStreams) {
          final pass = _isDirectPlayable(s) ? '✓ direct' : '✗ skip';
          final bytes = s.size.totalBytes;
          final url = s.url;
          debugPrint(
            '  $pass  mime=${s.codec.mimeType}  '
            'container=${s.container.name}  '
            'bitrate=${(s.bitrate.bitsPerSecond / 1000).round()} kbps  '
            'size=${bytes > 0 ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : 'unknown'}  '
            'has_sq=${url.queryParameters.containsKey('sq')}  '
            'host=${url.host.split('.').take(3).join('.')}',
          );
        }
      }

      final directStreams = audioStreams.where(_isDirectPlayable).toList();

      if (kDebugMode) {
        for (final s in audioStreams) {
          final accepted = _isDirectPlayable(s);
          final url = s.url;
          final hasSq = url.queryParameters.containsKey('sq');
          final hasClen = url.queryParameters.containsKey('clen');
          final verdict = accepted ? '✓ direct' : '✗ skip';
          final reason = !accepted
              ? (hasSq ? 'sq=DASH-segment' : 'container/mime')
              : (hasClen ? 'clen=known-size' : 'no-clen');
          debugPrint(
            '  $verdict  ${s.codec.mimeType}/${s.container.name}  '
            '${(s.bitrate.bitsPerSecond / 1000).round()} kbps  '
            'sq=$hasSq  clen=$hasClen  → $reason',
          );
        }
      }

      if (directStreams.isNotEmpty) {
        // Sort: clen= streams first (known-length file), then highest bitrate.
        directStreams.sort((a, b) {
          final aClen = a.url.queryParameters.containsKey('clen') ? 1 : 0;
          final bClen = b.url.queryParameters.containsKey('clen') ? 1 : 0;
          if (bClen != aClen) return bClen - aClen;
          return b.bitrate.compareTo(a.bitrate);
        });
        final chosen = directStreams.first;
        final bitrateKbps = (chosen.bitrate.bitsPerSecond / 1000).round();
        final uri = chosen.url;

        if (kDebugMode) {
          final diag = _analyzeUrl(uri, chosen);
          debugPrint('[AUDIO STREAM] ✓ Selected direct-playable audio-only stream:');
          diag.forEach((k, v) => debugPrint('  $k: $v'));
          debugPrint('  bitrate    : $bitrateKbps kbps');
          debugPrint('  clen_known : ${uri.queryParameters.containsKey('clen')}');
          debugPrint('  url_preview: ${uri.toString().substring(0, uri.toString().length.clamp(0, 80))}…');
          if (diag['has_sq_param'] == 'true') {
            debugPrint('[AUDIO STREAM] ⚠ UNEXPECTED: selected URL still has sq= — filter bug?');
          }
        }

        return (
          url: uri,
          codec: chosen.codec.mimeType,
          container: chosen.container.name,
          bitrateKbps: bitrateKbps,
          isMuxedFallback: false,
        );
      }

      // ── PATH 2: muxed fallback ───────────────────────────────────────────
      // All audio-only streams were DASH-segmented (sq=) or incompatible.
      // Try muxed mp4: ExoPlayer plays only the audio track from the container.
      if (kDebugMode) {
        debugPrint(
          '[MUXED FALLBACK] No direct audio-only streams — '
          'all ${audioStreams.length} candidates had sq= or incompatible container. '
          'Trying muxed mp4 streams…',
        );
      }

      return await _resolveMuxedFallback(videoId, manifest);
    } catch (e) {
      debugPrint('[PlaybackEngine][Error] Resolution failed for $videoId: $e');
      rethrow;
    } finally {
      yt.close();
    }
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
    // Stopping NOW (before the network call) guarantees silence instantly when
    // a new track is tapped, regardless of how long resolution takes.
    debugPrint('[PLAYER STOP] Stopping for new load — videoId=$videoId');
    await _player.stop();
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
    debugPrint('[PLAYER LOAD] setAudioSource() starting — $pathTag — $videoId');
    try {
      // preload: false — ExoPlayer defers buffering until play() is called,
      // giving sub-second perceived startup latency.
      await _player.setAudioSource(source, preload: false);
      if (_loadId != myId) {
        debugPrint('[PLAYER LOAD] Superseded after setAudioSource — bailing ($videoId)');
        return;
      }
      if (kDebugMode) {
        debugPrint('[PLAYER LOAD] setAudioSource() OK — $videoId');
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
    // seek(Duration.zero) before play() prevents ExoPlayer resuming mid-file
    // if the same source URL was previously loaded.
    final finalUri = resolved.url;
    final finalPathTag = resolved.isMuxedFallback ? '[MUXED FALLBACK]' : '[AUDIO STREAM]';
    debugPrint('[PLAYER PLAY] play() starting — $finalPathTag — $videoId');
    try {
      await _player.seek(Duration.zero);
      if (_loadId != myId) {
        debugPrint('[PLAYER PLAY] Superseded before play() — bailing ($videoId)');
        return;
      }
      await _player.play();
      if (kDebugMode) {
        debugPrint(
          '$finalPathTag play() OK — $videoId\n'
          '  container : ${resolved.container}  codec : ${resolved.codec}  '
          'bitrate : ${resolved.bitrateKbps} kbps  result : ACCEPTED',
        );
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
    if (videoId.isEmpty || _isDisposed) return;
    debugPrint('[TRACK PREFETCH] Starting background resolution for $videoId');
    _resolveStream(videoId).then((_) {
      debugPrint('[TRACK PREFETCH] ✓ Resolved $videoId — stream URL warm in CDN cache');
    }).catchError((Object e) {
      debugPrint('[TRACK PREFETCH] ✗ Failed for $videoId — ignored ($e)');
    });
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
