import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:beaty/core/config/app_config.dart';

class YouTubeMusicDataSource {
  // API base URL is injected at compile time via --dart-define=API_BASE_URL=<url>
  // Defaults to http://localhost:8000 when not set.
  // See lib/core/config/app_config.dart for environment-specific values.
  static String get _baseUrl => AppConfig.apiBaseUrl;
  
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
}
