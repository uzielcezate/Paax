import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:beaty/core/config/api_config.dart';

class YouTubeMusicDataSource {
  // Base URL resolved from --dart-define=ENV= (local | lan | prod).
  // See lib/core/config/api_config.dart for full documentation.
  static String get _baseUrl => ApiConfig.baseUrl;
  
  final http.Client _client;

  YouTubeMusicDataSource({http.Client? client}) : _client = client ?? http.Client();

  Future<dynamic> _get(String path, {Map<String, String>? params}) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: params);
    try {
      final response = await _client.get(uri);
      if (response.statusCode == 200) {
        return json.decode(utf8.decode(response.bodyBytes));
      } else {
        throw Exception('API Error ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
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
    final res = await _get('/v2/search', params: {'q': query, 'type': type, 'limit': limit.toString()});
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
}
