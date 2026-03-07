import '../../domain/repositories/music_repository.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../api/youtube_music_data_source.dart';
import '../../core/utils/string_utils.dart';

class MusicRepositoryImpl implements MusicRepository {
  final YouTubeMusicDataSource _dataSource;

  MusicRepositoryImpl({YouTubeMusicDataSource? dataSource}) 
      : _dataSource = dataSource ?? YouTubeMusicDataSource();

  @override
  Future<(List<SavedAlbum>, String?)> getArtistAlbumsPage(String id, String? params, String? token) async {
    final result = await _dataSource.getArtistAlbumsPage(id, params, token);
    final items = (result['items'] as List?)?.map((e) => _mapAlbum(e)).toList() ?? [];
    final nextPageToken = result['nextPageToken'] as String?;
    return (items, nextPageToken);
  }

  @override
  Future<List<Track>> searchTracks(String query) async {
    final result = await _dataSource.search(query, 'songs');
    return (result['data'] as List).map((e) => _mapTrack(e)).toList();
  }

  @override
  Future<List<SavedAlbum>> searchAlbums(String query) async {
    final result = await _dataSource.search(query, 'albums');
    return (result['data'] as List)
        .where((e) => !_isPlaylist(e))
        .map((e) => _mapAlbum(e))
        .where((a) => !isPlaceholderArtist(a.artistName))
        .toList();
  }

  @override
  Future<List<Artist>> searchArtists(String query) async {
    final result = await _dataSource.search(query, 'artists');
    return (result['data'] as List)
        .map((e) => _mapArtist(e))
        .where((a) => !isPlaceholderArtist(a.name))
        .toList();
  }

  @override
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getCharts([String country = 'US']) async {
    final result = await _dataSource.getCharts(country);
    return _mapStructuredResponse(result);
  }

  @override
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getGenreContent(String genre, String country) async {
    final result = await _dataSource.getGenreContent(genre, country);
    return _mapStructuredResponse(result);
  }

  @override
  Future<({List<SavedAlbum> playlists, List<Track> tracks, List<Artist> artists})> getGenrePage(String slug) async {
    final result = await _dataSource.getGenrePage(slug);
    
    // Explicitly return empty playlists as per requirements
    final playlists = <SavedAlbum>[]; 
    final tracks = (result['tracks'] as List?)?.map((e) => _mapTrack(e)).toList() ?? [];
    // Filter out placeholder artists
    final artists = (result['artists'] as List?)
        ?.map((e) => _mapArtist(e))
        .where((a) => !isPlaceholderArtist(a.name))
        .toList() ?? [];
    
    return (playlists: playlists, tracks: tracks, artists: artists);
  }

  ({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists}) _mapStructuredResponse(Map<String, dynamic> result) {
      final tracks = (result['tracks'] as List?)?.map((e) => _mapTrack(e)).toList() ?? [];
      // Filter out playlists and albums by placeholder artists
      final albums = (result['albums'] as List?)
          ?.where((e) => !_isPlaylist(e))
          .map((e) => _mapAlbum(e))
          .where((a) => !isPlaceholderArtist(a.artistName))
          .toList() ?? [];
      // Filter out placeholder artists
      final artists = (result['artists'] as List?)
          ?.map((e) => _mapArtist(e))
          .where((a) => !isPlaceholderArtist(a.name))
          .toList() ?? [];
      return (tracks: tracks, albums: albums, artists: artists);
  }

  @override
  Future<Artist> getArtist(String id) async {
    final e = await _dataSource.getArtist(id);
    return Artist(
      id: id,
      name: e['name']?.toString() ?? 'Unknown Artist',
      picture: _findHeroThumbnail(e['thumbnails']), // High-res for artist hero
      nbFans: 0, // Set to 0 as requested (will be implemented with app backend later)
      albums: e['albums']?['results'] != null 
          ? (e['albums']['results'] as List).map((x) => _mapAlbum(x)).toList() 
          : [],
      singles: e['singles']?['results'] != null 
          ? (e['singles']['results'] as List).map((x) => _mapAlbum(x)).toList() 
          : [],
      topTracks: e['songs']?['results'] != null 
          ? (e['songs']['results'] as List).map((x) => _mapTrack(x)).toList() 
          : [],
      relatedArtists: e['related']?['results'] != null 
          ? (e['related']['results'] as List).map((x) => _mapArtist(x)).toList() 
          : [],
      albumsParams: e['albums']?['params']?.toString(),
      singlesParams: e['singles']?['params']?.toString(),
    );
  }

  int _parseFans(String? text) {
    if (text == null || text.isEmpty) return 0;
    
    // Example format: "1.24M subscribers" or "54 subscribers"
    final clean = text.replaceAll(' subscribers', '').replaceAll(' fans', '').replaceAll(',', '').trim();
    if (clean.isEmpty) return 0;

    double multiplier = 1.0;
    String numberPart = clean;

    if (clean.toUpperCase().endsWith('M')) {
      multiplier = 1000000.0;
      numberPart = clean.substring(0, clean.length - 1);
    } else if (clean.toUpperCase().endsWith('K')) {
      multiplier = 1000.0;
      numberPart = clean.substring(0, clean.length - 1);
    } else if (clean.toUpperCase().endsWith('B')) {
      multiplier = 1000000000.0;
      numberPart = clean.substring(0, clean.length - 1);
    }

    try {
      final value = double.parse(numberPart);
      return (value * multiplier).toInt();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<List<SavedAlbum>> getArtistAlbums(String id) async {
    final result = await _dataSource.getArtistAlbums(id);
    if (result is List) {
       return result.map((e) => _mapAlbum(e)).toList();
    }
    // Fallback: check if getArtist has albums
    final artistData = await _dataSource.getArtist(id);
    if (artistData.containsKey('albums') && artistData['albums']['results'] != null) {
       return (artistData['albums']['results'] as List).map((e) => _mapAlbum(e)).toList();
    }
    return [];
  }

  @override
  Future<List<SavedAlbum>> getArtistSingles(String id) async {
     final artistData = await _dataSource.getArtist(id);
     if (artistData.containsKey('singles') && artistData['singles']['results'] != null) {
         return (artistData['singles']['results'] as List).map((e) => _mapAlbum(e)).toList();
     }
     return [];
  }

  @override
  Future<List<Track>> getArtistTopTracks(String id) async {
      // The artist detail (getArtist) usually contains "songs" key with top songs
      final artistData = await _dataSource.getArtist(id);
      if (artistData.containsKey('songs') && artistData['songs']['results'] != null) {
          return (artistData['songs']['results'] as List).map((e) => _mapTrack(e)).toList();
      }
      return [];
  }

  @override
  Future<List<Artist>> getRelatedArtists(String id) async {
      final artistData = await _dataSource.getArtist(id);
       if (artistData.containsKey('related') && artistData['related']['results'] != null) {
          return (artistData['related']['results'] as List).map((e) => _mapArtist(e)).toList();
      }
      return [];
  }

  @override
  Future<SavedAlbum> getAlbum(String id) async {
     final e = await _dataSource.getAlbum(id);
     return _mapAlbumDetail(e, id);
  }

  @override
  Future<List<Track>> getAlbumTracks(String id) async {
     final e = await _dataSource.getAlbum(id);
     final tracks = e['tracks'] as List;
     final albumParams = {
         'albumId': id,
         'albumTitle': e['title'],
         'artworkUrl': _findThumbnail(e['thumbnails']),
         'artistName': e['artists']?[0]?['name'] ?? 'Unknown',
         'artistId': e['artists']?[0]?['id'] ?? '',
     };
     return tracks.map((t) => _mapAlbumTrack(t, albumParams)).toList();
  }

  @override
  Future<Track> getTrack(String id) async {
      final e = await _dataSource.getSong(id);
      final videoDetails = e['videoDetails'];
      return Track(
          id: videoDetails['videoId'],
          title: videoDetails['title'],
          artistName: videoDetails['author'],
          artistId: videoDetails['channelId'], 
          albumId: '', // often missing in getSong videoDetails unless specialized
          albumTitle: '',
          artworkUrl: _findThumbnail(videoDetails['thumbnail']['thumbnails']),
          duration: int.tryParse(videoDetails['lengthSeconds'] ?? '0') ?? 0,
      );
  }
  
  @override
  Future<List<Track>> getWatchPlaylist(String videoId) async {
     final result = await _dataSource.getWatchPlaylist(videoId);
     if (result.containsKey('tracks')) {
         return (result['tracks'] as List).map((e) => _mapTrack(e)).toList();
     }
     return [];
  }

  @override
  Future<String?> getStreamUrl(String trackId) async {
      return await _dataSource.getStreamUrl(trackId);
  }

  // --- Mappers ---

  /// Picks the best thumbnail URL from a list, preferring width >= [minWidth].
  /// Falls back to the largest available if none meet the minimum.
  String _pickBestThumbnail(List<dynamic>? thumbnails, {int minWidth = 226}) {
    if (thumbnails == null || thumbnails.isEmpty) return '';
    
    // Sort by width descending
    final sorted = List<Map<String, dynamic>>.from(thumbnails)
      ..sort((a, b) => (b['width'] ?? 0).compareTo(a['width'] ?? 0));
    
    // Find first >= minWidth, otherwise take largest
    for (final thumb in sorted) {
      final width = thumb['width'] ?? 0;
      if (width >= minWidth) {
        return thumb['url']?.toString() ?? '';
      }
    }
    
    // Fallback to largest available (first after sort)
    return sorted.first['url']?.toString() ?? '';
  }

  /// Standard thumbnail for cards/lists - uses default minWidth
  String _findThumbnail(List<dynamic>? thumbnails) {
    return _pickBestThumbnail(thumbnails);
  }

  /// High-res thumbnail for hero/profile images
  String _findHeroThumbnail(List<dynamic>? thumbnails) {
    return _pickBestThumbnail(thumbnails, minWidth: 800);
  }

  Track _mapTrack(Map<String, dynamic> e) {
    // Handle multi-artist
    String artistName = 'Unknown Artist';
    String artistId = '';
    List<Map<String, String>> artistsList = [];

    // Check 'artists' array (standard in search/charts)
    if (e['artists'] != null && e['artists'] is List) {
       final artists = e['artists'] as List;
       if (artists.isNotEmpty) {
           // Filter out any entry whose name looks like a view/play count
           final realArtists = artists.where((a) {
             final name = a['name']?.toString() ?? '';
             return name.isNotEmpty && !isViewCountString(name);
           }).toList();

           if (realArtists.isNotEmpty) {
               artistId = realArtists[0]['id']?.toString() ?? '';
               for (var a in realArtists) {
                  artistsList.add({
                      'name': a['name'].toString(),
                      'id': a['id']?.toString() ?? '',
                  });
               }
               // Build the stored artistName using comma separator
               artistName = artistsList.map((a) => a['name']!).join(', ');
           }
       }
    }
    
    // Fallback if 'artists' is empty or missing
    if (artistName == 'Unknown Artist') {
       if (e['author'] != null) {
           final author = e['author'].toString();
           // Only use author if it doesn't look like a view count
           if (!isViewCountString(author)) {
             artistName = author;
           }
       }
    }

    final album = e['album'] as Map<String, dynamic>?;

    return Track(
      id: e['videoId']?.toString() ?? e['id']?.toString() ?? '',
      title: e['title']?.toString() ?? 'Unknown Track',
      artistName: artistName,
      artistId: artistId,
      albumId: album?['id']?.toString() ?? album?['browseId']?.toString() ?? '',
      albumTitle: album?['name']?.toString() ?? album?['title']?.toString() ?? '',
      artworkUrl: _findThumbnail(e['thumbnails']),
      duration: _parseDuration(e['duration'] ?? e['lengthSeconds']), 
      previewUrl: null, 
      artists: artistsList,
    );
  }
  

  
  Track _mapAlbumTrack(Map<String, dynamic> e, Map<String, dynamic> albumParams) {
     String artistName = albumParams['artistName'] ?? 'Unknown';
     String artistId = albumParams['artistId'] ?? '';
     List<Map<String, String>> artistsList = [];
     
     if (e['artists'] != null && e['artists'] is List) {
        final artists = e['artists'] as List;
        if (artists.isNotEmpty) {
             // Filter out view-count pseudo-artist entries
             final realArtists = artists.where((a) {
               final name = a['name']?.toString() ?? '';
               return name.isNotEmpty && !isViewCountString(name);
             }).toList();

             if (realArtists.isNotEmpty) {
               artistId = realArtists[0]['id']?.toString() ?? '';
               for (var a in realArtists) {
                   artistsList.add({
                       'name': a['name'].toString(),
                       'id': a['id']?.toString() ?? '',
                   });
               }
               artistName = artistsList.map((a) => a['name']!).join(', ');
             }
        }
     }
     
     // If track doesn't specify artists, inherit from album artist.
     if (artistsList.isEmpty && albumParams['artistName'] != null) {
         final fallbackName = albumParams['artistName'] as String;
         if (!isViewCountString(fallbackName)) {
           artistsList.add({
               'name': fallbackName,
               'id': albumParams['artistId'] ?? '',
           });
           artistName = fallbackName;
         }
     }

     // ARTWORK RESOLUTION: Prioritize track's own artwork, fallback to album
     String artworkUrl = _findThumbnail(e['thumbnails']);
     if (artworkUrl.isEmpty) {
        artworkUrl = albumParams['artworkUrl'] ?? '';
     }

     return Track(
       id: e['videoId']?.toString() ?? '',
       title: e['title']?.toString() ?? 'Unknown',
       artistName: artistName,
       artistId: artistId,
       albumId: albumParams['albumId'] ?? '',
       albumTitle: albumParams['albumTitle'] ?? '',
       artworkUrl: artworkUrl, 
       duration: e['duration_seconds'] != null 
          ? (int.tryParse(e['duration_seconds'].toString()) ?? 0)
          : _parseDuration(e['duration'] ?? e['lengthSeconds']),
       artists: artistsList,
     );
  }

  SavedAlbum _mapAlbum(Map<String, dynamic> e) {
    final artists = e['artists'] as List?;
    final firstArtist = (artists != null && artists.isNotEmpty) ? artists[0] : null;

    return SavedAlbum(
      albumId: e['browseId']?.toString() ?? e['albumId']?.toString() ?? '',
      title: e['title']?.toString() ?? 'Unknown Album',
      artistName: firstArtist?['name']?.toString() ?? 'Unknown Artist',
      artistId: firstArtist?['id']?.toString() ?? '',
      artworkUrl: _findThumbnail(e['thumbnails']),
    );
  }
  
  // ... _mapAlbumDetail skipped (it already had some checks but good to review if needed)



  SavedAlbum _mapPlaylistToAlbum(Map<String, dynamic> e) {
     return SavedAlbum(
        albumId: e['browseId']?.toString() ?? e['playlistId']?.toString() ?? '',
        title: e['title']?.toString() ?? 'Unknown Playlist',
        artistName: 'Playlist', 
        artistId: '',
        artworkUrl: _findThumbnail(e['thumbnails']),
        tracks: [],
     );
  }

  SavedAlbum _mapAlbumDetail(Map<String, dynamic> e, String id) {
      final List<Track> tracks = [];
      if (e['tracks'] != null && e['tracks'] is List) {
          final albumParams = {
             'albumId': id,
             'albumTitle': e['title'],
             'artworkUrl': _findThumbnail(e['thumbnails']),
             'artistName': e['artists']?[0]?['name'] ?? 'Unknown',
             'artistId': e['artists']?[0]?['id'] ?? '',
          };
          for (var t in e['tracks']) {
              tracks.add(_mapAlbumTrack(t, albumParams));
          }
      }

      int duration = 0;
      // Prefer summing track durations for accuracy
      if (tracks.isNotEmpty) {
          duration = tracks.fold(0, (sum, t) => sum + t.duration);
      } else if (e['duration_seconds'] != null) {
          duration = int.tryParse(e['duration_seconds'].toString()) ?? 0;
      } else if (e['duration'] != null) {
         duration = _parseDuration(e['duration']); 
      }
      
      final trackCount = e['trackCount'] ?? tracks.length;

      return SavedAlbum(
          albumId: id,
          title: e['title']?.toString() ?? 'Unknown Album',
          artistName: e['artists']?[0]?['name'] ?? 'Unknown',
          artistId: e['artists']?[0]?['id'] ?? '',
          artworkUrl: _findThumbnail(e['thumbnails']),
          tracks: tracks,
          duration: duration,
          trackCount: trackCount,
          releaseDate: e['year']?.toString() ?? e['release_date']?.toString() ?? '',
          // Use 'label' or 'copyright' if present, otherwise empty. Do NOT use type.
          label: e['label']?.toString() ?? e['copyright']?.toString() ?? '', 
      );
  }

  Artist _mapArtist(Map<String, dynamic> e) {
    // Related artists may use 'title' instead of 'name'
    final name = e['name']?.toString() 
        ?? e['artist']?.toString() 
        ?? e['title']?.toString()
        ?? 'Unknown Artist';
    
    return Artist(
      id: e['browseId']?.toString() ?? e['channelId']?.toString() ?? e['id']?.toString() ?? '',
      name: name,
      picture: _findThumbnail(e['thumbnails']),
    );
  }
  
  bool _isPlaylist(Map<String, dynamic> item) {
      final id = item['browseId']?.toString() ?? item['playlistId']?.toString() ?? '';
      final type = item['type']?.toString().toLowerCase() ?? '';
      final resultType = item['resultType']?.toString().toLowerCase() ?? '';
      
      // Explicit type checks
      if (type == 'playlist' || type == 'station') return true;
      if (resultType == 'playlist' || resultType == 'station') return true;
      
      // ID pattern checks
      // Youtube Mix lists often start with 'RD' but those are usually fine as "Radio", 
      // but user wants NO playlists. 
      // Standard playlists: VL, PL
      // Albums: MPRE, MPREb
      if (id.startsWith('VL') || id.startsWith('PL') || id.startsWith('UU')) return true;
      
      return false;
  }

  int _parseDuration(dynamic d) {
    if (d is int) return d;
    if (d is String) {
       // "3:20" -> 200
       if (d.contains(':')) {
           final parts = d.split(':');
           if (parts.length == 2) {
               return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
           }
       }
    }
    return 0;
  }
}
