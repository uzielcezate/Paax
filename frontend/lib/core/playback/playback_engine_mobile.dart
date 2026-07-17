// ============================================================================
// PlaybackEngineImpl — Mobile (flutter_inappwebview + YouTube IFrame API)
// ============================================================================
// Uses flutter_inappwebview instead of webview_flutter because the official
// package aggressively calls onPause() on the native WebView when the activity
// backgrounds, releasing the media codec and killing audio.
//
// flutter_inappwebview provides `allowBackgroundAudioPlaying: true` which
// prevents this behavior, allowing the Foreground Service to keep audio alive.
//
// The baseUrl is set to our domain (paaxmusic.app) so YouTube can verify
// the Referer and allow playback of restricted music videos.
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'playback_engine.dart';

class PlaybackEngineImpl implements PlaybackEngine {
  InAppWebViewController? _webViewController;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController  = StreamController<bool>.broadcast();
  final _completionController = StreamController<void>.broadcast();

  Timer? _positionTimer;
  bool _isDisposed = false;
  bool _isReady = false;
  String? _lastVideoId;

  /// Whether the YouTube player inside the WebView is initialized.
  bool get isReady => _isReady;

  /// The last video ID that was loaded (for rehydration).
  String? get lastVideoId => _lastVideoId;

  // The widget that will be placed in the tree — built once during initialize()
  late final InAppWebView _webViewWidget;

  static const String _baseUrl = 'https://paaxmusic.app';

  // ── Streams ──────────────────────────────────────────────────────────────

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<void> get completionStream => _completionController.stream;

  // ── Initialize ───────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    _webViewWidget = InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _buildPlayerHtml(),
        baseUrl: WebUri(_baseUrl),
        mimeType: 'text/html',
        encoding: 'utf-8',
      ),
      initialSettings: InAppWebViewSettings(
        // ── CRITICAL: Background audio survival ───────────────────────
        allowBackgroundAudioPlaying: true,

        // ── Media settings ────────────────────────────────────────────
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,

        // ── WebView behavior ──────────────────────────────────────────
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        supportZoom: false,
        disableVerticalScroll: true,
        disableHorizontalScroll: true,
        transparentBackground: true,

        // ── Android-specific ──────────────────────────────────────────
        useHybridComposition: false,  // Virtual Display for background
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        useWideViewPort: false,

        // ── Allow YouTube domains ─────────────────────────────────────
        resourceCustomSchemes: [],
      ),
      onWebViewCreated: (controller) {
        _webViewController = controller;

        // Register the PaaxBridge handler — JS calls:
        //   window.flutter_inappwebview.callHandler('PaaxBridge', data)
        controller.addJavaScriptHandler(
          handlerName: 'PaaxBridge',
          callback: (args) {
            if (args.isNotEmpty) {
              _onMessage(args[0]);
            }
            return null;
          },
        );
      },
      onLoadStop: (controller, url) {
        debugPrint('[MobileEngine] Page loaded: $url');
      },
      onReceivedError: (controller, request, error) {
        debugPrint('[MobileEngine] WebView error: ${error.description}');
      },
      onConsoleMessage: (controller, consoleMessage) {
        // Only log non-noisy messages
        final msg = consoleMessage.message;
        if (!msg.contains('web-share') && !msg.contains('postMessage')) {
          debugPrint('[MobileEngine][Console] $msg');
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url?.toString() ?? '';
        if (url.contains('youtube.com') ||
            url.contains('ytimg.com') ||
            url.contains('googlevideo.com') ||
            url.contains('googleapis.com') ||
            url.contains('google.com') ||
            url.contains('gstatic.com') ||
            url.startsWith('about:') ||
            url.startsWith('data:') ||
            url.startsWith('blob:')) {
          return NavigationActionPolicy.ALLOW;
        }
        debugPrint('[MobileEngine] Blocked navigation: $url');
        return NavigationActionPolicy.CANCEL;
      },
    );

    debugPrint('[MobileEngine] Initialized (InAppWebView, allowBackgroundAudioPlaying: true, baseUrl: $_baseUrl)');
  }

  // ── JavaScript Bridge ────────────────────────────────────────────────────

  void _onMessage(dynamic rawData) {
    if (_isDisposed) return;

    try {
      // rawData is already decoded from JSON by flutter_inappwebview
      final Map<String, dynamic> data;
      if (rawData is Map<String, dynamic>) {
        data = rawData;
      } else if (rawData is String) {
        data = jsonDecode(rawData) as Map<String, dynamic>;
      } else {
        return;
      }

      final event = data['event'] as String?;

      switch (event) {
        case 'ready':
          _isReady = true;
          debugPrint('[MobileEngine] ✅ YouTube player ready');
          break;

        case 'stateChange':
          final state = data['data'] as int;
          _handleStateChange(state);
          break;

        case 'error':
          final errorCode = data['data'];
          debugPrint('[MobileEngine] ❌ YT Raw Error code: $errorCode');
          break;

        case 'duration':
          final dur = (data['data'] as num).toDouble();
          if (dur > 0) {
            _durationController.add(Duration(milliseconds: (dur * 1000).toInt()));
          }
          break;

        case 'position':
          final pos = (data['data'] as num).toDouble();
          _positionController.add(Duration(milliseconds: (pos * 1000).toInt()));
          break;

        case 'keepalive':
          // Heartbeat from JS — WebView is alive in background
          break;
      }
    } catch (e) {
      debugPrint('[MobileEngine] Bridge parse error: $e');
    }
  }

  void _handleStateChange(int state) {
    // YT states: -1=unstarted, 0=ended, 1=playing, 2=paused, 3=buffering, 5=cued
    switch (state) {
      case 1: // Playing
        _playingController.add(true);
        _startPositionTimer();
        // Unmute after playback starts (muted autoplay workaround)
        _webViewController?.evaluateJavascript(
            source: 'if(player){player.unMute();player.setVolume(100);}');
        break;
      case 2: // Paused
        _playingController.add(false);
        _stopPositionTimer();
        break;
      case 0: // Ended
        _playingController.add(false);
        _stopPositionTimer();
        _completionController.add(null);
        break;
      case 3: // Buffering
        debugPrint('[MobileEngine] Buffering...');
        break;
    }
  }

  // ── Load ──────────────────────────────────────────────────────────────────

  @override
  Future<void> load(String videoId) async {
    if (videoId.isEmpty || _isDisposed || _webViewController == null) return;
    _lastVideoId = videoId;
    debugPrint('[MobileEngine] Loading: $videoId');

    await _webViewController!.evaluateJavascript(source: 'loadVideo("$videoId");');
  }

  // ── Controls ─────────────────────────────────────────────────────────────

  @override
  Future<void> play() async {
    if (_isDisposed || _webViewController == null) return;

    // First, try a health check — ask the WebView if player is alive
    try {
      final result = await _webViewController!.evaluateJavascript(
        source: '(function(){ return (player && player.getPlayerState) ? player.getPlayerState() : -99; })()',
      );
      final state = int.tryParse(result?.toString() ?? '') ?? -99;
      debugPrint('[MobileEngine] play() healthcheck state=$state');

      if (state == -99) {
        // Player object is gone or WebView JS context is dead
        // Try to reload the last video
        debugPrint('[MobileEngine] Player not alive, attempting rehydration...');
        if (_lastVideoId != null && _lastVideoId!.isNotEmpty) {
          await _webViewController!.evaluateJavascript(
            source: 'loadVideo("$_lastVideoId");',
          );
          return; // loadVideo auto-plays
        }
        return;
      }

      // State 2 = paused, -1 = unstarted, 5 = cued — all resumable
      await _webViewController!.evaluateJavascript(
        source: 'if(player)player.playVideo();',
      );
    } catch (e) {
      debugPrint('[MobileEngine] play() error: $e, attempting reload...');
      // JS evaluation failed entirely — WebView may be suspended
      // Try reloading the video as a last resort
      if (_lastVideoId != null && _lastVideoId!.isNotEmpty) {
        try {
          await _webViewController!.evaluateJavascript(
            source: 'loadVideo("$_lastVideoId");',
          );
        } catch (e2) {
          debugPrint('[MobileEngine] Rehydration also failed: $e2');
        }
      }
    }
  }

  @override
  Future<void> pause() async {
    await _webViewController?.evaluateJavascript(
        source: 'if(player)player.pauseVideo();');
  }

  @override
  Future<void> seek(Duration position) async {
    await _webViewController?.evaluateJavascript(
        source: 'if(player)player.seekTo(${position.inSeconds}, true);');
  }

  @override
  void prefetchNext(String videoId) {
    // No-op
  }

  // ── Position Timer ───────────────────────────────────────────────────────

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (_isDisposed || _webViewController == null) {
        _stopPositionTimer();
        return;
      }
      try {
        await _webViewController!.evaluateJavascript(
          source: 'if(player&&player.getCurrentTime){window.flutter_inappwebview.callHandler("PaaxBridge",{event:"position",data:player.getCurrentTime()});}',
        );
      } catch (_) {}
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  // ── Dispose ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _isDisposed = true;
    _stopPositionTimer();
    _positionController.close();
    _durationController.close();
    _playingController.close();
    _completionController.close();
    debugPrint('[MobileEngine] Disposed');
  }

  // ── Player View ──────────────────────────────────────────────────────────

  @override
  Widget buildPlayerView(BuildContext context) {
    return _webViewWidget;
  }

  // ── Player HTML ──────────────────────────────────────────────────────────
  // Key additions for background survival:
  // 1. Web Audio API silent oscillator — keeps the audio context alive
  // 2. JS heartbeat timer — pings the bridge so we know the WebView is alive
  // 3. Visibility change handler — resumes playback if Android pauses it
  //
  // Communication uses flutter_inappwebview's callHandler instead of
  // postMessage. We wait for flutterInAppWebViewPlatformReady before calling.
  // ──────────────────────────────────────────────────────────────────────────

  String _buildPlayerHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <style>
    * { margin: 0; padding: 0; }
    html, body { width: 100%; height: 100%; background: #000; overflow: hidden; }
    #player { width: 100%; height: 100%; }
  </style>
</head>
<body>
  <div id="player"></div>
  <script>
    var tag = document.createElement("script");
    tag.src = "https://www.youtube.com/iframe_api";
    document.head.appendChild(tag);

    var player;
    var isReady = false;
    var pendingVideoId = null;
    var wasPlaying = false;
    var bridgeReady = false;

    // Wait for flutter_inappwebview bridge to be ready
    window.addEventListener("flutterInAppWebViewPlatformReady", function() {
      bridgeReady = true;
      // If YT player was already ready before bridge, send the ready event now
      if (isReady) {
        sendToBridge({event: "ready", data: null});
      }
    });

    function sendToBridge(data) {
      if (bridgeReady && window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler("PaaxBridge", data);
      }
    }

    // ── Web Audio API Keep-Alive ──────────────────────────────────────
    var keepAliveCtx;
    function initKeepAlive() {
      try {
        keepAliveCtx = new (window.AudioContext || window.webkitAudioContext)();
        var oscillator = keepAliveCtx.createOscillator();
        var gain = keepAliveCtx.createGain();
        gain.gain.value = 0;
        oscillator.connect(gain);
        gain.connect(keepAliveCtx.destination);
        oscillator.start();
      } catch(e) {}
    }

    // ── Visibility Change Handler ─────────────────────────────────────
    document.addEventListener("visibilitychange", function() {
      if (document.hidden) {
        if (player && player.getPlayerState) {
          wasPlaying = (player.getPlayerState() == 1);
        }
      } else {
        if (wasPlaying && player && player.getPlayerState) {
          var state = player.getPlayerState();
          if (state == 2 || state == -1) {
            player.playVideo();
          }
        }
        if (keepAliveCtx && keepAliveCtx.state === "suspended") {
          keepAliveCtx.resume();
        }
      }
    });

    // ── Heartbeat ─────────────────────────────────────────────────────
    setInterval(function() {
      sendToBridge({event: "keepalive", data: 1});
    }, 5000);

    // ── YouTube IFrame API ────────────────────────────────────────────
    function onYouTubeIframeAPIReady() {
      initKeepAlive();

      player = new YT.Player("player", {
        height: "100%",
        width: "100%",
        host: "https://www.youtube.com",
        playerVars: {
          autoplay: 1,
          controls: 0,
          disablekb: 1,
          enablejsapi: 1,
          fs: 0,
          iv_load_policy: 3,
          modestbranding: 1,
          mute: 1,
          playsinline: 1,
          rel: 0,
          origin: "$_baseUrl"
        },
        events: {
          onReady: function(event) {
            isReady = true;
            sendToBridge({event: "ready", data: null});
            if (pendingVideoId) {
              player.loadVideoById(pendingVideoId);
              pendingVideoId = null;
            }
          },
          onStateChange: function(event) {
            sendToBridge({event: "stateChange", data: event.data});
            if (event.data == 1) {
              sendToBridge({event: "duration", data: player.getDuration()});
            }
          },
          onError: function(event) {
            sendToBridge({event: "error", data: event.data});
          }
        }
      });
    }

    function loadVideo(videoId) {
      wasPlaying = false;
      if (isReady && player) {
        player.loadVideoById(videoId);
      } else {
        pendingVideoId = videoId;
      }
    }
  </script>
</body>
</html>
''';
  }
}
