import 'package:flutter/foundation.dart';
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

  /// In-memory cache for album detail responses, keyed by browseId.
  /// Avoids repeated /album/{id} fetches during enrichment.
  final Map<String, Map<String, dynamic>> _albumDetailCache = {};

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
    return (result['data'] as List)
        .where((e) => !_isOfficialMusicVideo(e))
        .map((e) {
          try { return _mapTrack(e); }
          catch (err) { debugPrint('[Repo] searchTracks skip bad item: $err'); return null; }
        })
        .whereType<Track>()
        .toList();
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
      // Filter out OMV and safely parse each item
      final tracks = (result['tracks'] as List?)
          ?.where((e) => !_isOfficialMusicVideo(e))
          .map((e) { try { return _mapTrack(e); } catch (err) { debugPrint('[Repo] chart track skip: $err'); return null; } })
          .whereType<Track>()
          .toList() ?? [];
      // Filter out playlists and albums by placeholder artists
      final albums = (result['albums'] as List?)
          ?.where((e) => !_isPlaylist(e))
          .map((e) { try { return _mapAlbum(e); } catch (err) { debugPrint('[Repo] album skip: $err'); return null; } })
          .whereType<SavedAlbum>()
          .where((a) => !isPlaceholderArtist(a.artistName))
          .toList() ?? [];
      // Filter out placeholder artists
      final artists = (result['artists'] as List?)
          ?.map((e) { try { return _mapArtist(e); } catch (err) { debugPrint('[Repo] artist skip: $err'); return null; } })
          .whereType<Artist>()
          .where((a) => !isPlaceholderArtist(a.name))
          .toList() ?? [];
      return (tracks: tracks, albums: albums, artists: artists);
  }

  @override
  Future<Artist> getArtist(String id) async {
    final e = await _dataSource.getArtist(id);

    // ── 1. Map initial data from artist endpoint ──
    var albums = _safeMapList<SavedAlbum>(e['albums']?['results'], (x) => _mapAlbum(x, defaultType: 'album'));
    var singles = _safeMapList<SavedAlbum>(e['singles']?['results'], (x) => _mapAlbum(x, defaultType: 'single'));
    final topTracks = _safeMapList<Track>(
      e['songs']?['results'],
      (x) => _mapTrack(x),
      filter: (x) => !_isOfficialMusicVideo(x),
    );

    // ── 2. Enrich releases from top tracks' album references ──
    try {
      final enriched = await _enrichArtistReleases(
        existingAlbums: albums,
        existingSingles: singles,
        rawSongs: e['songs']?['results'] as List? ?? [],
      );
      albums = enriched.albums;
      singles = enriched.singles;
    } catch (err) {
      debugPrint('[Repo] Release enrichment failed (non-fatal): $err');
    }

    return Artist(
      id: id,
      name: e['name']?.toString() ?? 'Various Artists',
      picture: _findHeroThumbnail(e['thumbnails']),
      nbFans: 0,
      albums: albums,
      singles: singles,
      topTracks: topTracks,
      relatedArtists: _safeMapList<Artist>(e['related']?['results'], (x) => _mapArtist(x)),
      albumsParams: e['albums']?['params']?.toString(),
      singlesParams: e['singles']?['params']?.toString(),
    );
  }

  // ── Album Enrichment Pipeline ───────────────────────────────────────────

  /// Fetch album detail with caching.
  Future<Map<String, dynamic>> _fetchAlbumCached(String browseId) async {
    if (_albumDetailCache.containsKey(browseId)) {
      return _albumDetailCache[browseId]!;
    }
    final data = await _dataSource.getAlbum(browseId);
    final map = data is Map<String, dynamic> ? data : <String, dynamic>{};
    _albumDetailCache[browseId] = map;
    return map;
  }

  /// Enriches artist releases by:
  /// 1. Collecting album IDs from song results (top tracks)
  /// 2. Fetching /album/{id} for IDs not already in albums/singles lists
  /// 3. Re-enriching existing items that have null year
  /// 4. Merging and deduplicating
  Future<({List<SavedAlbum> albums, List<SavedAlbum> singles})> _enrichArtistReleases({
    required List<SavedAlbum> existingAlbums,
    required List<SavedAlbum> existingSingles,
    required List<dynamic> rawSongs,
  }) async {
    // Collect existing IDs for deduplication
    final existingIds = <String>{
      ...existingAlbums.map((a) => a.albumId),
      ...existingSingles.map((a) => a.albumId),
    };

    // Collect unique album IDs from song results
    final songAlbumIds = <String>{};
    for (final song in rawSongs) {
      if (song is Map<String, dynamic>) {
        final albumId = song['album']?['id']?.toString();
        if (albumId != null && albumId.isNotEmpty) {
          songAlbumIds.add(albumId);
        }
      }
    }

    // IDs to fetch: new ones (not in existing) + existing with null year
    final idsToFetch = <String>{};

    // New releases from songs
    final newIds = songAlbumIds.difference(existingIds);
    idsToFetch.addAll(newIds);

    // Existing items with missing year
    for (final album in [...existingAlbums, ...existingSingles]) {
      if ((album.releaseDate == null || album.releaseDate!.isEmpty) && album.albumId.isNotEmpty) {
        idsToFetch.add(album.albumId);
      }
    }

    if (idsToFetch.isEmpty) {
      return (albums: existingAlbums, singles: existingSingles);
    }

    // Cap at 10 fetches to limit network usage
    final fetchList = idsToFetch.take(10).toList();
    debugPrint('[Repo] Enriching ${fetchList.length} releases: $fetchList');

    // Fetch in parallel
    final results = await Future.wait(
      fetchList.map((id) async {
        try {
          return MapEntry(id, await _fetchAlbumCached(id));
        } catch (err) {
          debugPrint('[Repo] Failed to fetch album $id: $err');
          return MapEntry(id, <String, dynamic>{});
        }
      }),
    );
    final fetchedMap = Map.fromEntries(results.where((e) => e.value.isNotEmpty));

    // Build updated albums and singles lists
    final updatedAlbums = <SavedAlbum>[];
    final updatedSingles = <SavedAlbum>[];
    final seenIds = <String>{};

    // Helper: update existing item with fetched data
    SavedAlbum maybeEnrich(SavedAlbum existing) {
      final detail = fetchedMap[existing.albumId];
      if (detail == null) return existing;
      final enrichedYear = detail['year']?.toString() ?? existing.releaseDate;
      final enrichedType = normalizeReleaseType(
        detail['type'],
        defaultType: existing.releaseType ?? 'album',
      );
      // Use trackCount for type fallback
      final trackCount = detail['trackCount'] as int?;
      String finalType = enrichedType;
      if (detail['type'] == null && trackCount != null) {
        if (trackCount == 1) {
          finalType = 'single';
        } else if (trackCount <= 6) {
          finalType = 'ep';
        } else {
          finalType = 'album';
        }
      }
      return SavedAlbum(
        albumId: existing.albumId,
        title: existing.title,
        artistName: existing.artistName,
        artistId: existing.artistId,
        artworkUrl: existing.artworkUrl,
        artists: existing.artists,
        releaseDate: enrichedYear,
        releaseType: finalType,
        trackCount: trackCount ?? existing.trackCount,
      );
    }

    // Process existing albums
    for (final album in existingAlbums) {
      if (seenIds.contains(album.albumId)) continue;
      seenIds.add(album.albumId);
      updatedAlbums.add(maybeEnrich(album));
    }

    // Process existing singles
    for (final single in existingSingles) {
      if (seenIds.contains(single.albumId)) continue;
      seenIds.add(single.albumId);
      updatedSingles.add(maybeEnrich(single));
    }

    // Process new releases from songs
    for (final newId in newIds) {
      if (seenIds.contains(newId)) continue;
      seenIds.add(newId);
      final detail = fetchedMap[newId];
      if (detail == null || detail.isEmpty) continue;

      final release = _buildReleaseFromAlbumDetail(newId, detail);
      if (release.releaseType == 'album') {
        updatedAlbums.add(release);
      } else {
        updatedSingles.add(release);
      }
    }

    return (albums: updatedAlbums, singles: updatedSingles);
  }

  /// Build a SavedAlbum from a /album/{id} response.
  SavedAlbum _buildReleaseFromAlbumDetail(String browseId, Map<String, dynamic> detail) {
    // Determine type with trackCount fallback
    final trackCount = detail['trackCount'] as int?;
    String type;
    if (detail['type'] != null) {
      type = normalizeReleaseType(detail['type']);
    } else if (trackCount != null) {
      if (trackCount == 1) {
        type = 'single';
      } else if (trackCount <= 6) {
        type = 'ep';
      } else {
        type = 'album';
      }
    } else {
      type = 'album';
    }

    // Build artist info
    final List<Map<String, String>> artists = [];
    if (detail['artists'] != null && detail['artists'] is List) {
      for (var a in (detail['artists'] as List)) {
        final name = a['name']?.toString() ?? '';
        final aid = a['id']?.toString() ?? '';
        if (name.isNotEmpty && !isViewCountString(name)) {
          artists.add({'name': name, 'id': aid});
        }
      }
    }

    final displayName = artists.isNotEmpty
        ? artists.map((a) => a['name']!).join(', ')
        : 'Various Artists';
    final primaryId = artists.isNotEmpty ? artists.first['id']! : '';

    return SavedAlbum(
      albumId: browseId,
      title: detail['title']?.toString() ?? 'Unknown',
      artistName: displayName,
      artistId: primaryId,
      artworkUrl: _findThumbnail(detail['thumbnails']),
      artists: artists.isNotEmpty ? artists : null,
      releaseDate: detail['year']?.toString(),
      releaseType: type,
      trackCount: trackCount,
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
    String artistName = 'Various Artists';
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
    if (artistName == 'Various Artists') {
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
     String artistName = albumParams['artistName'] ?? 'Various Artists';
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

  SavedAlbum _mapAlbum(Map<String, dynamic> e, {String defaultType = 'album'}) {
    // Build structured artists list
    final List<Map<String, String>> albumArtists = [];
    if (e['artists'] != null && e['artists'] is List) {
      for (var a in (e['artists'] as List)) {
        final name = a['name']?.toString() ?? '';
        final aid = a['id']?.toString() ?? '';
        if (name.isNotEmpty && !isViewCountString(name)) {
          albumArtists.add({'name': name, 'id': aid});
        }
      }
    }

    final displayName = albumArtists.isNotEmpty
        ? albumArtists.map((a) => a['name']!).join(', ')
        : 'Various Artists';
    final primaryId = albumArtists.isNotEmpty ? albumArtists.first['id']! : '';

    return SavedAlbum(
      albumId: e['browseId']?.toString() ?? e['albumId']?.toString() ?? '',
      title: e['title']?.toString() ?? 'Unknown Album',
      artistName: displayName,
      artistId: primaryId,
      artworkUrl: _findThumbnail(e['thumbnails']),
      artists: albumArtists.isNotEmpty ? albumArtists : null,
      releaseDate: e['year']?.toString(),
      releaseType: normalizeReleaseType(e['type'], defaultType: defaultType),
    );
  }

  // NOTE: Release type normalization is now handled by
  // normalizeReleaseType() in core/utils/string_utils.dart.

  
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
      // Build structured artists list from API response
      List<Map<String, String>> albumArtists = [];
      if (e['artists'] != null && e['artists'] is List) {
        for (var a in (e['artists'] as List)) {
          final name = a['name']?.toString() ?? '';
          final aid = a['id']?.toString() ?? '';
          if (name.isNotEmpty && !isViewCountString(name)) {
            albumArtists.add({'name': name, 'id': aid});
          }
        }
      }

      debugPrint('[Repo] Album "$id" raw API artists: ${e['artists']}');
      debugPrint('[Repo] Album "$id" parsed albumArtists: $albumArtists');

      // Joined display name (e.g. "Anuel AA, Ozuna") or fallback
      String displayArtistName = albumArtists.isNotEmpty
          ? albumArtists.map((a) => a['name']!).join(', ')
          : 'Various Artists';
      String primaryArtistId = albumArtists.isNotEmpty
          ? albumArtists.first['id']!
          : '';

      final List<Track> tracks = [];
      if (e['tracks'] != null && e['tracks'] is List) {
          final albumParams = {
             'albumId': id,
             'albumTitle': e['title'],
             'artworkUrl': _findThumbnail(e['thumbnails']),
             'artistName': displayArtistName,
             'artistId': primaryArtistId,
          };
          for (var t in e['tracks']) {
              try {
                debugPrint('[Repo] Track "${t['title']}" raw artists: ${t['artists']}');
                tracks.add(_mapAlbumTrack(t, albumParams));
              } catch (err) {
                debugPrint('[Repo] Skipping malformed album track: $err');
              }
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
          artistName: displayArtistName,
          artistId: primaryArtistId,
          artworkUrl: _findThumbnail(e['thumbnails']),
          tracks: tracks,
          duration: duration,
          trackCount: trackCount,
          releaseDate: e['year']?.toString() ?? e['release_date']?.toString() ?? '',
          // Use 'label' or 'copyright' if present, otherwise empty. Do NOT use type.
          label: e['label']?.toString() ?? e['copyright']?.toString() ?? '', 
          artists: albumArtists.isNotEmpty ? albumArtists : null,
      );
  }

  Artist _mapArtist(Map<String, dynamic> e) {
    // Related artists may use 'title' instead of 'name'
    final name = e['name']?.toString() 
        ?? e['artist']?.toString() 
        ?? e['title']?.toString()
        ?? 'Various Artists';
    
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

  // ── Bug 4: OMV detection ─────────────────────────────────────────────────

  /// Returns true if the item is an Official Music Video (OMV) rather than
  /// a pure Audio Track Video (ATV). We exclude OMVs from song lists.
  bool _isOfficialMusicVideo(Map<String, dynamic> item) {
    final videoType = item['videoType']?.toString() ?? '';
    final resultType = item['resultType']?.toString().toLowerCase() ?? '';
    // YouTube Music uses 'MUSIC_VIDEO_TYPE_OMV' for official music videos
    if (videoType == 'MUSIC_VIDEO_TYPE_OMV') return true;
    // Also filter generic "video" results from song lists
    if (resultType == 'video') return true;
    return false;
  }

  // ── Safe list mapper ─────────────────────────────────────────────────────

  /// Maps a JSON list to typed items, catching & skipping any malformed entry.
  /// Optional [filter] predicate runs on raw JSON before mapping.
  List<T> _safeMapList<T>(
    List<dynamic>? raw,
    T Function(Map<String, dynamic>) mapper, {
    bool Function(Map<String, dynamic>)? filter,
  }) {
    if (raw == null || raw.isEmpty) return [];
    final results = <T>[];
    for (final item in raw) {
      try {
        if (filter != null && !filter(item)) continue;
        results.add(mapper(item));
      } catch (err) {
        debugPrint('[Repo] _safeMapList skip: $err');
      }
    }
    return results;
  }
}
