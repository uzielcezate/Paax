import '../../core/network/offline_status.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:beaty/core/config/api_config.dart';

/// Top-level so it can run in a background isolate via [compute]: decode +
/// UTF-8 the raw body off the main thread for large (search) responses, keeping
/// the UI thread free for 60 FPS scrolling while results load.
Object? _decodeBody(List<int> bytes) => json.decode(utf8.decode(bytes));

class YouTubeMusicDataSource {
  // Base URL resolved from --dart-define=ENV= (local | lan | prod).
  // See lib/core/config/api_config.dart for full documentation.
  static String get _baseUrl => ApiConfig.baseUrl;

  // A single persistent client per data source. On mobile this is an IOClient
  // that pools + keep-alives connections; reusing one instance across searches
  // means the TLS/socket is established once and reused.
  final http.Client _client;

  YouTubeMusicDataSource({http.Client? client}) : _client = client ?? http.Client();

  bool _prewarmed = false;

  /// Establishes the DNS + TLS + keep-alive connection to the API host up front
  /// so the first real search reuses an open socket. Fire-and-forget; failures
  /// are ignored (it is purely an optimization).
  Future<void> prewarm() async {
    if (_prewarmed) return;
    _prewarmed = true;
    try {
      await _client.head(Uri.parse(_baseUrl));
    } catch (_) {
      // Non-fatal — a real request will simply establish the connection itself.
    }
  }

  Future<dynamic> _get(String path,
      {Map<String, String>? params, bool offloadDecode = false}) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
    try {
      final response = await _client.get(uri);
      if (response.statusCode == 200) {
        // Reaching paax-api proves the device is online. This is the single
        // choke point for catalog/search traffic, so reporting here keeps the
        // shared offline signal accurate for Home, Artist, Album and Search.
        OfflineStatus.report(succeeded: true);
        final bytes = response.bodyBytes;
        // Offload large payloads (search results carry per-track match blocks)
        // to a background isolate so decoding never janks the UI thread.
        if (offloadDecode && bytes.length > 32 * 1024) {
          return await compute(_decodeBody, bytes);
        }
        return json.decode(utf8.decode(bytes));
      } else {
        // The server ANSWERED — online, it just said no. Reporting success is
        // what stops a 404 from being mistaken for "offline".
        OfflineStatus.report(succeeded: true);
        throw Exception('API Error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      // Everything below is rewrapped as "Network Error: ...", which is exactly
      // why the UI could not classify offline from the message alone — a 404
      // became "Network Error: Exception: API Error 404". Classify HERE, where
      // the original exception type is still intact.
      final isTransport = !e.toString().contains('API Error');
      if (isTransport) {
        OfflineStatus.report(succeeded: false, wasNetworkFailure: true);
      }
      throw Exception('Network Error: $e');
    }
  }

  Future<dynamic> search(String query, String filter) => _get('/search', params: {'q': query, 'filter': filter});
  
  Future<Map<String, dynamic>> getCharts(String country) async {
    final res = await _get('/home/charts', params: {'country': country});
    return res as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getGenreContent(String genre, String country) async {
    final res = await _get('/home/top', params: {'genre': genre, 'country': country});
    return res as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getGenrePage(String slug) async {
    final res = await _get('/genre/$slug');
    return res as Map<String, dynamic>;
  }
  

  
  Future<dynamic> getArtist(String id) => _get('/artist/$id');
  
  Future<dynamic> getArtistAlbums(String id) => _get('/artist/$id/albums');

  Future<Map<String, dynamic>> getArtistAlbumsPage(String channelId, String? params, String? token) async {
    final query = <String, String>{};
    if (params != null) query['params'] = params;
    if (token != null) query['ctoken'] = token;
    final res = await _get('/artist/$channelId/albums/page', params: query);
    return res as Map<String, dynamic>;
  }
  
  Future<dynamic> getAlbum(String id) => _get('/album/$id');
  
  Future<dynamic> getSong(String id) => _get('/song/$id');
  
  Future<Map<String, dynamic>> getWatchPlaylist(String videoId) async {
      final res = await _get('/watch', params: {'videoId': videoId});
      return res as Map<String, dynamic>;
  }
  
  Future<String?> getStreamUrl(String videoId) async {
    try {
      final result = await _get('/stream/$videoId');
      return result['url'];
    } catch (e) {
      print("Error fetching stream: $e");
      return null;
    }
  }

  /// Fetch lyrics for a given videoId.
  /// Returns raw API response: {"lyrics": "line1\nline2\n...", "source": "..."} or {"error": "..."}
  Future<Map<String, dynamic>> getLyrics(String videoId) async {
    try {
      final result = await _get('/lyrics/$videoId');
      return result is Map<String, dynamic> ? result : {};
    } catch (e) {
      print("Error fetching lyrics for $videoId: $e");
      return {'error': 'Network error: $e'};
    }
  }

  // ── v2 Endpoints (Deezer metadata + YouTube playback ID) ─────────────────

  /// Search via Deezer with YouTube video ID matching.
  /// [type]: tracks | albums | artists
  Future<Map<String, dynamic>> searchV2(String query, String type, {int limit = 25}) async {
    final res = await _get('/v2/search',
        params: {'q': query, 'type': type, 'limit': limit.toString()},
        offloadDecode: true);
    return res as Map<String, dynamic>;
  }

  /// Full Deezer artist profile with YouTube-matched top tracks.
  Future<Map<String, dynamic>> getArtistV2(int deezerId) async {
    final res = await _get('/v2/artist/$deezerId');
    return res as Map<String, dynamic>;
  }

  /// Artist top tracks from Deezer with YouTube video IDs.
  Future<Map<String, dynamic>> getArtistTopV2(int deezerId, {int limit = 50}) async {
    final res = await _get('/v2/artist/$deezerId/top', params: {'limit': limit.toString()});
    return res as Map<String, dynamic>;
  }

  /// Artist albums from Deezer.
  Future<Map<String, dynamic>> getArtistAlbumsV2(int deezerId, {int limit = 100}) async {
    final res = await _get('/v2/artist/$deezerId/albums', params: {'limit': limit.toString()});
    return res as Map<String, dynamic>;
  }

  /// Full Deezer album with YouTube-matched tracks.
  Future<Map<String, dynamic>> getAlbumV2(int deezerId) async {
    final res = await _get('/v2/album/$deezerId');
    return res as Map<String, dynamic>;
  }

  /// Single Deezer track with YouTube video ID.
  Future<Map<String, dynamic>> getTrackV2(int deezerId) async {
    final res = await _get('/v2/track/$deezerId');
    return res as Map<String, dynamic>;
  }

  /// Deezer chart data (tracks, albums, artists).
  Future<Map<String, dynamic>> getChartV2() async {
    final res = await _get('/v2/chart');
    return res as Map<String, dynamic>;
  }

  // ── Normalized (Supabase-first) /v2 catalog endpoints ────────────────────
  //
  // These read the normalized Supabase catalog (Redis → Supabase → Deezer
  // ingest) and carry canonical UUIDs, follower counts, collaborators, and
  // deterministic discography ordering. Playback is intentionally NOT sourced
  // from here — the eager legacy endpoints above remain the playback path.

  /// GET a normalized /v2 resource. On `503 { status: processing }` (an
  /// ingest is in flight for a cold entity) this waits for `Retry-After` and
  /// retries a bounded number of times before giving up.
  Future<Map<String, dynamic>?> _getNormalized(String path,
      {Map<String, String>? params, int maxRetries = 3}) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
    var attempt = 0;
    while (true) {
      final response = await _client.get(uri);
      if (response.statusCode == 200) {
        final decoded = json.decode(utf8.decode(response.bodyBytes));
        return decoded is Map<String, dynamic> ? decoded : null;
      }
      if (response.statusCode == 404) return null;
      if (response.statusCode == 503 && attempt < maxRetries) {
        // Ingesting or briefly degraded — honor Retry-After (capped) and retry.
        final retryAfter = int.tryParse(response.headers['retry-after'] ?? '') ?? 1;
        await Future.delayed(Duration(milliseconds: (retryAfter.clamp(1, 3)) * 1000));
        attempt++;
        continue;
      }
      throw Exception('API Error ${response.statusCode}: ${response.body}');
    }
  }

  /// Normalized artist profile by Deezer id (ingest-on-miss). Carries the
  /// canonical UUID, `platformFollowersCount`, genres, deterministically
  /// ordered `discography`, and `latestRelease`.
  Future<Map<String, dynamic>?> getArtistNormalizedByDeezerId(int deezerId) =>
      _getNormalized('/v2/artists/deezer/$deezerId');

  /// Normalized artist profile by canonical Supabase UUID.
  Future<Map<String, dynamic>?> getArtistNormalizedByUuid(String uuid) =>
      _getNormalized('/v2/artists/$uuid');

  /// Normalized, deterministically ordered discography for an artist UUID.
  Future<Map<String, dynamic>?> getArtistDiscographyNormalized(String uuid) =>
      _getNormalized('/v2/artists/$uuid/discography');

  /// Normalized album by Deezer id (metadata only; playback stays legacy).
  Future<Map<String, dynamic>?> getAlbumNormalizedByDeezerId(int deezerId) =>
      _getNormalized('/v2/albums/deezer/$deezerId');

  /// Normalized catalog search. [type]: tracks | albums | artists.
  Future<Map<String, dynamic>?> findV2(String query, String type,
          {int limit = 25}) =>
      _getNormalized('/v2/find',
          params: {'q': query, 'type': type, 'limit': limit.toString()});
}
