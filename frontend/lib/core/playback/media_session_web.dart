/*// ============================================================================
// Web Media Session API — Dart interop
// ============================================================================
// Sets navigator.mediaSession.metadata and action handlers so the browser /
// Android TWA shows native OS media notifications on the lock screen, with
// album art, title, artist, and play/pause/next/previous controls.
//
// Uses dart:js eval for maximum reliability — avoids all Dart type system
// issues with JS interop by executing MediaSession calls as raw JavaScript.
//
// This file is ONLY imported on web via conditional import; it is never
// compiled into mobile builds.
// ============================================================================

// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js' as js;
import 'dart:js_util' as js_util;
import 'package:flutter/foundation.dart';
import '../../domain/entities/track.dart';
import '../image/lh3_url_builder.dart';

// ── JS helpers ───────────────────────────────────────────────────────────────

/// Safely evaluate a JavaScript expression. Returns true on success.
bool _jsEval(String code) {
  try {
    js.context.callMethod('eval', [code]);
    return true;
  } catch (e) {
    debugPrint('[MediaSession] JS eval error: $e');
    return false;
  }
}

/// Check if the MediaSession API is available.
bool get _isSupported {
  try {
    final result = js.context.callMethod('eval', [
      'typeof navigator !== "undefined" && "mediaSession" in navigator && typeof MediaMetadata !== "undefined"'
    ]);
    return result == true;
  } catch (_) {
    return false;
  }
}

/// Escape a string for safe inclusion in a JS string literal.
String _jsEscape(String s) {
  return s
      .replaceAll('\\', '\\\\')
      .replaceAll("'", "\\'")
      .replaceAll('\n', ' ')
      .replaceAll('\r', '');
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Configures the Web Media Session for the given [track].
///
/// - Sets metadata (title, artist, artwork) on `navigator.mediaSession`.
/// - Sets action handlers for play, pause, previoustrack, nexttrack.
///
/// Call this every time the current track changes.
///
/// Uses [Track.displayArtist] which already formats artist names as
/// "Artist1, Artist2" without "- topic" suffixes — matching the full player.
void setMediaSession({
  required Track track,
  required void Function() onPlay,
  required void Function() onPause,
  required void Function() onNext,
  required void Function() onPrevious,
}) {
  if (!_isSupported) {
    debugPrint('[MediaSession] API not available in this browser');
    return;
  }

  try {
    // Build artwork URLs — square images at multiple sizes for OS compatibility.
    final art512 = _jsEscape(Lh3UrlBuilder.build(track.artworkUrl, 512));
    final art256 = _jsEscape(Lh3UrlBuilder.build(track.artworkUrl, 256));
    final art96 = _jsEscape(Lh3UrlBuilder.build(track.artworkUrl, 96));

    final title = _jsEscape(track.title);
    final artist = _jsEscape(track.displayArtist);
    final album = _jsEscape(
      track.albumTitle.isNotEmpty ? track.albumTitle : track.title,
    );

    // Set metadata via raw JS eval
    _jsEval('''
      navigator.mediaSession.metadata = new MediaMetadata({
        title: '$title',
        artist: '$artist',
        album: '$album',
        artwork: [
          { src: '$art512', sizes: '512x512', type: 'image/jpeg' },
          { src: '$art256', sizes: '256x256', type: 'image/jpeg' },
          { src: '$art96',  sizes: '96x96',   type: 'image/jpeg' }
        ]
      });
    ''');

    // Store Dart callbacks in a global JS object so the action handlers
    // can invoke them. We use allowInterop to make Dart functions callable
    // from JS.
    js_util.setProperty(
      js.context,
      '__paaxMediaCallbacks',
      js_util.jsify({}),
    );
    final callbacks = js_util.getProperty(js.context, '__paaxMediaCallbacks');
    js_util.setProperty(callbacks, 'play', js.allowInterop((_) => onPlay()));
    js_util.setProperty(callbacks, 'pause', js.allowInterop((_) => onPause()));
    js_util.setProperty(callbacks, 'next', js.allowInterop((_) => onNext()));
    js_util.setProperty(callbacks, 'prev', js.allowInterop((_) => onPrevious()));

    // Register action handlers via JS eval, calling back into our stored Dart fns.
    _jsEval('''
      navigator.mediaSession.setActionHandler('play', function() {
        window.__paaxMediaCallbacks.play(null);
      });
      navigator.mediaSession.setActionHandler('pause', function() {
        window.__paaxMediaCallbacks.pause(null);
      });
      navigator.mediaSession.setActionHandler('nexttrack', function() {
        window.__paaxMediaCallbacks.next(null);
      });
      navigator.mediaSession.setActionHandler('previoustrack', function() {
        window.__paaxMediaCallbacks.prev(null);
      });
    ''');

    debugPrint('[MediaSession] ✓ Updated: "$title" by $artist');
  } catch (e) {
    debugPrint('[MediaSession] Error setting media session: $e');
  }
}

/// Update the playback state reported to the OS notification.
/// Call this when play/pause state changes.
void updateMediaSessionPlaybackState({required bool isPlaying}) {
  if (!_isSupported) return;
  try {
    final state = isPlaying ? 'playing' : 'paused';
    _jsEval("navigator.mediaSession.playbackState = '$state';");
  } catch (e) {
    debugPrint('[MediaSession] Error updating playback state: $e');
  }
}

/// Clear the media session metadata and action handlers.
/// Call this when playback stops entirely.
void clearMediaSession() {
  if (!_isSupported) return;
  try {
    _jsEval('''
      navigator.mediaSession.metadata = null;
      navigator.mediaSession.playbackState = 'none';
    ''');
  } catch (e) {
    debugPrint('[MediaSession] Error clearing media session: $e');
  }
}
*/
