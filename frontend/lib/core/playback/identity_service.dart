import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// ===========================================================================
// IdentityService — Hidden WebView Identity Provider (Phase 10)
// ===========================================================================
//
// Problem:
//   Raw Dart HTTP requests are flagged as bots by YouTube (403/401).
//   A real browser session with cookies + JS challenge tokens works fine.
//
// Solution:
//   A headless InAppWebView loads m.youtube.com in the background.
//   YouTube's JS sets real browser cookies and generates identity tokens.
//   We extract these credentials and inject them into youtube_explode_dart
//   and just_audio requests, making the app indistinguishable from Chrome.
//
// Lifecycle:
//   1. warmUp()     — call during app startup (fire-and-forget)
//   2. getIdentity() — blocks until tokens are ready, returns cached
//   3. invalidate()  — force re-extraction (e.g. on 403 from CDN)
//   4. dispose()     — clean up WebView resources
//
// Credentials extracted:
//   • Cookies:     VISITOR_INFO1_LIVE, YSC, GPS, __Secure-YEC, etc.
//   • visitorData: from ytcfg.get('VISITOR_DATA')
//   • apiKey:      from ytcfg.get('INNERTUBE_API_KEY')
//   • userAgent:   from the WebView's navigator.userAgent
// ===========================================================================

/// YouTube session identity extracted from a real browser context.
class YouTubeIdentity {
  final Map<String, String> cookies;
  final String? visitorData;
  final String? apiKey;
  final String userAgent;
  final DateTime createdAt;

  const YouTubeIdentity({
    required this.cookies,
    this.visitorData,
    this.apiKey,
    required this.userAgent,
    required this.createdAt,
  });

  /// Format cookies as a single HTTP Cookie header value.
  String get cookieHeader => cookies.entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  /// Whether this identity is stale and should be refreshed.
  /// YouTube session cookies typically last ~30 minutes.
  bool get isExpired =>
      DateTime.now().difference(createdAt).inMinutes > 25;

  /// Whether we have the critical cookies that bypass bot detection.
  bool get hasCriticalCookies =>
      cookies.containsKey('VISITOR_INFO1_LIVE') ||
      cookies.containsKey('YSC');

  @override
  String toString() {
    final vd = visitorData;
    final vdStr = vd != null && vd.length > 20
        ? '${vd.substring(0, 20)}...'
        : vd ?? 'null';
    return 'YouTubeIdentity('
        'cookies=${cookies.length}, '
        'visitor=$vdStr, '
        'apiKey=${apiKey != null ? "YES" : "NO"})';
  }
}

/// Manages a hidden WebView to obtain real browser credentials from YouTube.
///
/// Usage:
/// ```dart
/// final identity = await IdentityService.instance.getIdentity();
/// // identity.cookies, identity.cookieHeader, identity.visitorData
/// ```
class IdentityService {
  static final instance = IdentityService._();
  IdentityService._();

  YouTubeIdentity? _identity;
  Completer<YouTubeIdentity>? _pending;
  HeadlessInAppWebView? _headless;
  Timer? _timeoutTimer;

  static const _kTimeout = Duration(seconds: 20);
  static const _kPostLoadDelay = Duration(seconds: 3);
  static const _kYouTubeUrl = 'https://m.youtube.com';

  // ── User-Agent matching a real Android device ──────────────────────────────
  static const _kMobileUA =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8 Pro) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/125.0.6422.165 Mobile Safari/537.36';

  // ── JavaScript to extract YouTube identity tokens ──────────────────────────
  static const _kExtractJS = r'''
    (function() {
      try {
        var d = {
          visitorData: null,
          apiKey: null,
          clientName: null,
          clientVersion: null,
        };

        // Method 1: ytcfg global object (primary)
        if (typeof ytcfg !== 'undefined' && typeof ytcfg.get === 'function') {
          d.visitorData    = ytcfg.get('VISITOR_DATA')             || null;
          d.apiKey         = ytcfg.get('INNERTUBE_API_KEY')        || null;
          d.clientName     = ytcfg.get('INNERTUBE_CLIENT_NAME')    || null;
          d.clientVersion  = ytcfg.get('INNERTUBE_CLIENT_VERSION') || null;
        }

        // Method 2: yt.config_ fallback
        if (!d.visitorData && typeof yt !== 'undefined' && yt.config_) {
          d.visitorData = yt.config_.VISITOR_DATA         || null;
          d.apiKey      = yt.config_.INNERTUBE_API_KEY    || d.apiKey;
        }

        // Method 3: regex from page HTML (last resort)
        if (!d.visitorData) {
          var html = document.documentElement.innerHTML;
          var m = html.match(/"visitorData":"([^"]+)"/);
          if (m) d.visitorData = m[1];
          if (!d.apiKey) {
            var km = html.match(/"INNERTUBE_API_KEY":"([^"]+)"/);
            if (km) d.apiKey = km[1];
          }
        }

        return JSON.stringify(d);
      } catch(e) {
        return JSON.stringify({ error: e.toString() });
      }
    })();
  ''';

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Get a valid YouTube identity. Returns cached if fresh,
  /// otherwise starts a new headless WebView extraction.
  ///
  /// This method is safe to call concurrently — only one WebView
  /// session runs at a time.
  Future<YouTubeIdentity> getIdentity() async {
    // ── Web: the browser IS the identity ────────────────────────────────
    // On web, HTTP requests go through the browser's XHR/fetch which
    // automatically includes cookies, proper UA, and passes CORS preflight.
    // No WebView extraction needed.
    if (kIsWeb) {
      _identity ??= YouTubeIdentity(
        cookies: const {},
        userAgent: 'Browser',  // XHR uses the real browser UA automatically
        createdAt: DateTime.now(),
      );
      debugPrint('[IDENTITY] Web platform -- using native browser identity');
      return _identity!;
    }

    // ── Mobile: HeadlessInAppWebView extraction ─────────────────────────
    // Return cached if still fresh
    if (_identity != null && !_identity!.isExpired) {
      debugPrint('[IDENTITY] Cache HIT '
          '(age=${DateTime.now().difference(_identity!.createdAt).inMinutes}min, '
          'cookies=${_identity!.cookies.length})');
      return _identity!;
    }

    // Don't run concurrent WebView sessions
    if (_pending != null && !_pending!.isCompleted) {
      debugPrint('[IDENTITY] Waiting for in-flight extraction...');
      return _pending!.future;
    }

    debugPrint('[IDENTITY] Cache MISS -- starting WebView extraction');
    _pending = Completer<YouTubeIdentity>();

    _runWebView();

    // Arm timeout
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_kTimeout, () {
      if (_pending != null && !_pending!.isCompleted) {
        debugPrint('[IDENTITY] TIMEOUT after ${_kTimeout.inSeconds}s');
        _pending!.completeError(TimeoutException(
          'WebView failed to extract identity in ${_kTimeout.inSeconds}s',
          _kTimeout,
        ));
        _cleanup();
      }
    });

    return _pending!.future;
  }

  /// Fire-and-forget warm-up. Call during app startup so tokens
  /// are ready before the user taps play.
  Future<void> warmUp() async {
    try {
      final id = await getIdentity();
      debugPrint('[IDENTITY] Warm-up OK: $id');
    } catch (e) {
      debugPrint('[IDENTITY] Warm-up failed (non-fatal): $e');
    }
  }

  /// Force a fresh extraction on the next getIdentity() call.
  /// Use this when the CDN returns 403 (stale session).
  void invalidate() {
    _identity = null;
    debugPrint('[IDENTITY] Invalidated -- will re-extract');
  }

  /// Release all resources.
  void dispose() {
    _cleanup();
    _identity = null;
  }

  // ── WebView lifecycle ──────────────────────────────────────────────────────

  Future<void> _runWebView() async {
    try {
      _headless = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: Uri.parse(_kYouTubeUrl)),
        initialOptions: InAppWebViewGroupOptions(
          crossPlatform: InAppWebViewOptions(
            javaScriptEnabled: true,
            userAgent: _kMobileUA,
            mediaPlaybackRequiresUserGesture: true,
            cacheEnabled: true,
          ),
          android: AndroidInAppWebViewOptions(
            useHybridComposition: false,
            safeBrowsingEnabled: false,
          ),
        ),
        onLoadStop: _onPageLoaded,
        onLoadError: (controller, url, code, message) {
          debugPrint('[IDENTITY] Load error $code: $message (url=$url)');
          _completeWithError('WebView load error ($code): $message');
        },
        onLoadHttpError: (controller, url, statusCode, description) {
          debugPrint('[IDENTITY] HTTP error $statusCode: $description');
          // Don't fail on HTTP errors -- YouTube sometimes returns 429
          // but still sets cookies. Let onLoadStop handle extraction.
        },
        onConsoleMessage: (controller, consoleMessage) {
          if (kDebugMode) {
            debugPrint('[IDENTITY:JS] ${consoleMessage.message}');
          }
        },
      );

      debugPrint('[IDENTITY] Starting HeadlessInAppWebView -> $_kYouTubeUrl');
      await _headless!.run();
    } catch (e) {
      debugPrint('[IDENTITY] WebView startup failed: $e');
      _completeWithError('WebView startup failed: $e');
    }
  }

  Future<void> _onPageLoaded(
    InAppWebViewController controller,
    Uri? url,
  ) async {
    debugPrint('[IDENTITY] Page loaded: $url');
    debugPrint('[IDENTITY] Waiting ${_kPostLoadDelay.inSeconds}s for JS to execute...');

    try {
      // Give YouTube's JS time to fully initialize ytcfg
      await Future.delayed(_kPostLoadDelay);

      // ── 1. Extract YouTube identity tokens via JavaScript ──────────────
      final jsResult = await controller.evaluateJavascript(source: _kExtractJS);
      debugPrint('[IDENTITY] JS extraction result: $jsResult');

      Map<String, dynamic> ytData = {};
      if (jsResult != null && jsResult is String && jsResult.isNotEmpty) {
        try {
          ytData = jsonDecode(jsResult) as Map<String, dynamic>;
        } catch (e) {
          debugPrint('[IDENTITY] JSON parse error: $e');
        }
      }

      if (ytData.containsKey('error')) {
        debugPrint('[IDENTITY] JS error: ${ytData['error']}');
      }

      // ── 2. Extract cookies from the WebView's cookie jar ───────────────
      final cookies = await CookieManager.instance().getCookies(
        url: Uri.parse('https://www.youtube.com'),
      );

      final cookieMap = <String, String>{};
      for (final c in cookies) {
        cookieMap[c.name] = c.value.toString();
      }

      debugPrint('[IDENTITY] Extracted ${cookieMap.length} cookies: '
          '${cookieMap.keys.toList().join(", ")}');

      // Log critical cookie status
      final hasCritical = cookieMap.containsKey('VISITOR_INFO1_LIVE') ||
          cookieMap.containsKey('YSC');
      debugPrint('[IDENTITY] Critical cookies: '
          'VISITOR_INFO1_LIVE=${cookieMap.containsKey("VISITOR_INFO1_LIVE")}, '
          'YSC=${cookieMap.containsKey("YSC")}, '
          'GPS=${cookieMap.containsKey("GPS")}, '
          '__Secure-YEC=${cookieMap.containsKey("__Secure-YEC")}');

      if (!hasCritical && cookieMap.isEmpty) {
        debugPrint('[IDENTITY] WARNING: No cookies extracted at all!');
      }

      // ── 3. Get the real User-Agent from the WebView ────────────────────
      final uaResult = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      final userAgent = (uaResult is String && uaResult.isNotEmpty)
          ? uaResult
          : _kMobileUA;

      debugPrint('[IDENTITY] WebView UA: ${userAgent.substring(0, userAgent.length.clamp(0, 60))}...');

      // ── 4. Build and cache the identity ────────────────────────────────
      _identity = YouTubeIdentity(
        cookies: cookieMap,
        visitorData: ytData['visitorData'] as String?,
        apiKey: ytData['apiKey'] as String?,
        userAgent: userAgent,
        createdAt: DateTime.now(),
      );

      debugPrint('[IDENTITY] SUCCESS: $cookieMap.length cookies, '
          'visitorData=${_identity!.visitorData != null ? "YES" : "NO"}, '
          'apiKey=${_identity!.apiKey != null ? "YES" : "NO"}');

      if (_pending != null && !_pending!.isCompleted) {
        _pending!.complete(_identity!);
      }
    } catch (e) {
      debugPrint('[IDENTITY] Extraction failed: $e');
      _completeWithError('Token extraction failed: $e');
    } finally {
      _timeoutTimer?.cancel();
      _cleanup();
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _completeWithError(String message) {
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(Exception(message));
    }
    _timeoutTimer?.cancel();
    _cleanup();
  }

  void _cleanup() {
    try {
      _headless?.dispose();
    } catch (_) {}
    _headless = null;
  }
}
