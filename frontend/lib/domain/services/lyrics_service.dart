import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../core/config/api_config.dart';
import '../../presentation/widgets/synced_lyrics_view.dart';

/// Lyrics fetch result.
class LyricsResult {
  final List<LyricLine> lines;
  final String? plainText;
  final String? source;
  final bool isAvailable;
  final bool isSynced;

  const LyricsResult({
    required this.lines,
    this.plainText,
    this.source,
    this.isAvailable = true,
    this.isSynced = false,
  });

  static const unavailable = LyricsResult(lines: [], isAvailable: false);
}

/// Lyrics service — calls our backend `/lyrics` endpoint only.
///
/// The backend handles:
///   1. LRCLIB exact match + search fallback (synced LRC timestamps)
///   2. ytmusicapi plain text fallback
///   3. Title normalization (strips Official Video, Remastered, etc.)
///
/// Flutter never calls LRCLIB directly.
class LyricsService {
  final http.Client _http;
  static String get _baseUrl => ApiConfig.baseUrl;

  /// In-memory cache: videoId → LyricsResult
  final Map<String, LyricsResult> _cache = {};

  LyricsService({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// Fetch lyrics for a track via our backend.
  Future<LyricsResult> getLyrics(
    String videoId, {
    String title = '',
    String artist = '',
    String album = '',
    int trackDurationMs = 0,
  }) async {
    // Return cached
    if (_cache.containsKey(videoId)) {
      return _cache[videoId]!;
    }

    try {
      final params = <String, String>{};
      if (videoId.isNotEmpty) params['trackId'] = videoId;
      if (title.isNotEmpty) params['title'] = title;
      if (artist.isNotEmpty) params['artist'] = artist;
      if (album.isNotEmpty) params['album'] = album;
      if (trackDurationMs > 0) {
        params['duration'] = (trackDurationMs / 1000).round().toString();
      }

      final uri = Uri.parse('$_baseUrl/lyrics').replace(queryParameters: params);

      final response = await _http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('[Lyrics] Backend HTTP ${response.statusCode}');
        _cache[videoId] = LyricsResult.unavailable;
        return LyricsResult.unavailable;
      }

      final data = json.decode(utf8.decode(response.bodyBytes));

      if (data is! Map<String, dynamic>) {
        _cache[videoId] = LyricsResult.unavailable;
        return LyricsResult.unavailable;
      }

      final available = data['lyricsAvailable'] as bool? ?? false;
      if (!available) {
        _cache[videoId] = LyricsResult.unavailable;
        return LyricsResult.unavailable;
      }

      final type = data['type'] as String? ?? 'plain';
      final source = data['source'] as String?;

      if (type == 'synced') {
        // Backend returns pre-parsed list of {timeMs, endTimeMs, text}
        final rawLines = data['lyrics'] as List<dynamic>? ?? [];
        final lines = rawLines.map((item) {
          final map = item as Map<String, dynamic>;
          final timeMs = (map['timeMs'] as num?)?.toInt() ?? 0;
          final endTimeMs = (map['endTimeMs'] as num?)?.toInt();
          final text = (map['text'] as String?) ?? '';
          final isGap = text.isEmpty;
          return LyricLine(
            time: Duration(milliseconds: timeMs),
            endTime: endTimeMs != null ? Duration(milliseconds: endTimeMs) : null,
            text: isGap ? '...' : text,
            isInstrumentalGap: isGap,
          );
        }).toList();

        final result = LyricsResult(
          lines: lines,
          source: source,
          isAvailable: lines.isNotEmpty,
          isSynced: true,
        );
        _cache[videoId] = result;
        debugPrint('[Lyrics] Synced: ${lines.length} lines (source: $source)');
        return result;
      } else {
        // Plain text lyrics — no timestamps
        final plainText = data['lyrics'] as String? ?? '';
        if (plainText.trim().isEmpty) {
          _cache[videoId] = LyricsResult.unavailable;
          return LyricsResult.unavailable;
        }

        // Parse into LyricLine objects without timing for display
        final lines = _parsePlainLines(plainText);

        final result = LyricsResult(
          lines: lines,
          plainText: plainText,
          source: source,
          isAvailable: true,
          isSynced: false,
        );
        _cache[videoId] = result;
        debugPrint('[Lyrics] Plain: ${lines.length} lines (source: $source)');
        return result;
      }
    } catch (e) {
      debugPrint('[Lyrics] Error: $e');
      _cache[videoId] = LyricsResult.unavailable;
      return LyricsResult.unavailable;
    }
  }

  void clearCache(String videoId) {
    _cache.remove(videoId);
  }

  /// Parse plain text into LyricLine objects without timing.
  /// These are for display only — no auto-advancement.
  List<LyricLine> _parsePlainLines(String text) {
    final rawLines = text.split('\n');
    final lines = <LyricLine>[];
    bool lastWasEmpty = false;

    for (final line in rawLines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (!lastWasEmpty && lines.isNotEmpty) {
          lines.add(const LyricLine(
            time: Duration.zero,
            text: '...',
            isInstrumentalGap: true,
          ));
          lastWasEmpty = true;
        }
      } else {
        lines.add(LyricLine(
          time: Duration.zero,
          text: trimmed,
        ));
        lastWasEmpty = false;
      }
    }

    return lines;
  }
}
