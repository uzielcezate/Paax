import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../core/constants/api_constants.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart'; 

class DeezerApiClient {
  final http.Client client;

  // Web Proxy Configuration
  // Note: Using a public CORS proxy is for development/demo only. 
  // Production apps should use a backend proxy.
  // Proxy Strategies
  static const List<String> _proxies = [
    "https://cors.isomorphic-git.org/",
    "https://api.allorigins.win/raw?url=",
    "https://corsproxy.io/?",
  ];

  DeezerApiClient({http.Client? client}) : client = client ?? http.Client();

  Future<Map<String, dynamic>> _get(String endpoint) async {
    if (kIsWeb) {
      return _getWeb(endpoint);
    } else {
      return _makeRequest('${ApiConstants.baseUrl}$endpoint');
    }
  }

  // In-memory cache
  final Map<String, dynamic> _cache = {};
  int _workingProxyIndex = 0; // Optimization: remember working proxy

  Future<Map<String, dynamic>> _getWeb(String endpoint) async {
    if (_cache.containsKey(endpoint)) {
      if (kDebugMode) print("[Cache Hit] $endpoint");
      return _cache[endpoint];
    }

    String lastError = "";
    final String targetUrl = '${ApiConstants.baseUrl}$endpoint';

    // Order: Try working proxy first, then others
    final List<int> indices = List.generate(_proxies.length, (i) => i);
    if (_workingProxyIndex != 0) {
      indices.remove(_workingProxyIndex);
      indices.insert(0, _workingProxyIndex);
    }

    for (int i in indices) {
        final proxyBase = _proxies[i];
        String finalUrl;
        
        if (proxyBase.contains("allorigins")) {
          finalUrl = "$proxyBase${Uri.encodeComponent(targetUrl)}";
        } else {
          finalUrl = "$proxyBase$targetUrl";
        }
        
        if (kDebugMode) print("[Web Proxy $i] Trying: $finalUrl");

        try {
          final response = await client.get(Uri.parse(finalUrl)).timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) {
             final body = utf8.decode(response.bodyBytes);
             // HTML Check
             if (body.trimLeft().startsWith("<!DOCTYPE") || body.trimLeft().startsWith("<html")) {
                if (kDebugMode) print("[Web Proxy $i] Blocked (HTML)");
                continue; 
             }
             try {
                final data = json.decode(body);
                // Success
                if (kDebugMode) print("[Web Proxy $i] Success");
                _workingProxyIndex = i; 
                _cache[endpoint] = data; 
                return data;
             } catch (e) {
                if (kDebugMode) print("[Web Proxy $i] JSON Error");
                continue;
             }
          }
        } catch (e) {
           lastError = e.toString();
        }
    }
    throw Exception("All proxies failed. Last: $lastError");
  }

  Future<Map<String, dynamic>> _makeRequest(String url) async {
    // Simple caching for mobile too
    // Extract endpoint to key
    String endpoint = url;
    if (url.startsWith(ApiConstants.baseUrl)) {
      endpoint = url.substring(ApiConstants.baseUrl.length);
    }
    
    if (_cache.containsKey(endpoint)) return _cache[endpoint];

    try {
      final response = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        _cache[endpoint] = data;
        return data;
      } else {
        throw Exception('API Error: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Network Error: $e');
    }
  }

  // --- New Endpoints ---
  
  Future<Map<String, dynamic>> getArtist(int id) async {
    return await _get(ApiConstants.artist(id));
  }
  
  Future<List<SavedAlbum>> getArtistAlbums(int id) async {
    final json = await _get('${ApiConstants.artist(id)}/albums?limit=50');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) => _mapAlbum(e)).toList();
    }
    return [];
  }
  
  Future<List<Map<String, dynamic>>> getArtistDiscography(int id) async {
    final json = await _get('${ApiConstants.artist(id)}/albums?limit=100');
    if (json.containsKey('data')) {
      return (json['data'] as List).cast<Map<String, dynamic>>();
    }
    return [];
  }
  
  Future<Map<String, dynamic>> getTrack(int id) async {
    return await _get('${ApiConstants.track(id)}');
  }

  Future<Map<String, dynamic>> getAlbumDetails(int id) async {
    // Returns full album object including 'tracks'
    return await _get(ApiConstants.album(id));
  }

  Future<List<Track>> getChartTracks() async {
    try {
      final json = await _get(ApiConstants.chart);
      if (json.containsKey('tracks') && json['tracks']['data'] != null) {
        return (json['tracks']['data'] as List)
            .map((e) => _mapTrack(e))
            .toList();
      }
    } catch (e) {
      print("Chart Tracks Error: $e");
      rethrow;
    }
    return [];
  }
  
  Future<List<SavedAlbum>> getChartAlbums() async {
    final json = await _get(ApiConstants.chart);
    if (json.containsKey('albums') && json['albums']['data'] != null) {
      return (json['albums']['data'] as List)
          .map((e) => _mapAlbum(e))
          .toList();
    }
    return [];
  }

  Future<List<Artist>> getChartArtists() async {
    final json = await _get(ApiConstants.chart);
    if (json.containsKey('artists') && json['artists']['data'] != null) {
      return (json['artists']['data'] as List).map((e) {
        return Artist(
          id: e['id'],
          name: e['name'] ?? 'Unknown',
          picture: e['picture_xl'] ?? e['picture_medium'] ?? '',
        );
      }).toList();
    }
    return [];
  }

  Future<List<Track>> searchTracks(String query) async {
    if (query.isEmpty) return [];
    final json = await _get('${ApiConstants.search}?q=$query');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) => _mapTrack(e)).toList();
    }
    return [];
  }

  Future<List<SavedAlbum>> searchAlbums(String query) async {
    if (query.isEmpty) return [];
    final json = await _get('${ApiConstants.searchAlbum}?q=$query');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) => _mapAlbum(e)).toList();
    }
    return [];
  }
  
  Future<List<Artist>> searchArtists(String query) async {
    if (query.isEmpty) return [];
    final json = await _get('${ApiConstants.searchArtist}?q=$query');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) {
        return Artist(
          id: e['id'],
          name: e['name'] ?? 'Unknown',
          picture: e['picture_xl'] ?? e['picture_medium'] ?? '',
        );
      }).toList();
    }
    return [];
  }

  Track _mapTrack(Map<String, dynamic> data) {
    return Track(
      id: data['id'],
      title: data['title'] ?? 'Unknown',
      artistName: data['artist']['name'] ?? 'Unknown Artist',
      artistId: data['artist']['id'],
      albumId: data['album']['id'] ?? 0,
      albumTitle: data['album']['title'] ?? '',
      artworkUrl: data['album']['cover_xl'] ?? data['album']['cover_medium'] ?? '',
      previewUrl: data['preview'],
      duration: data['duration'] ?? 0,
    );
  }
  
  SavedAlbum _mapAlbum(Map<String, dynamic> data) {
    return SavedAlbum(
      albumId: data['id'],
      title: data['title'] ?? 'Unknown Album',
      artistName: data['artist']?['name'] ?? 'Unknown Artist',
      artistId: data['artist']?['id'],
      artworkUrl: data['cover_xl'] ?? data['cover_medium'] ?? '',
    );
  }
  
  Future<List<Artist>> getRelatedArtists(int artistId) async {
    final json = await _get('${ApiConstants.artist(artistId)}/related');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) {
        return Artist(
          id: e['id'],
          name: e['name'] ?? 'Unknown',
          picture: e['picture_xl'] ?? e['picture_medium'] ?? '',
          nbFans: e['nb_fan'] ?? 0,
        );
      }).toList();
    }
    return [];
  }
  
  Future<List<Track>> getArtistTopTracks(int artistId) async {
    final json = await _get(ApiConstants.artistTop(artistId) + '?limit=50');
    if (json.containsKey('data')) {
      return (json['data'] as List).map((e) => _mapTrack(e)).toList();
    }
    return [];
  }

  Future<List<Track>> getAlbumTracks(int albumId) async {
    final json = await _get(ApiConstants.album(albumId));
    
    if (json.containsKey('tracks') && json['tracks']['data'] != null) {
      final artistName = json['artist']?['name'] ?? 'Unknown';
      final artistId = json['artist']?['id'] ?? 0;
      final albumCover = json['cover_xl'] ?? json['cover_medium'] ?? '';
      final albumTitle = json['title'] ?? '';
      
      return (json['tracks']['data'] as List).map((e) {
        return Track(
          id: e['id'],
          title: e['title'],
          artistName: e['artist']?['name'] ?? artistName,
          artistId: e['artist']?['id'] ?? artistId,
          albumId: albumId,
          albumTitle: albumTitle,
          artworkUrl: albumCover,
          previewUrl: e['preview'],
          duration: e['duration'] ?? 0
        );
      }).toList();
    }
    return [];
  }
}
