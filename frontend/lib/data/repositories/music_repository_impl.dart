import 'package:flutter/foundation.dart';
import '../../domain/repositories/music_repository.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../api/youtube_music_data_source.dart';
import '../../core/utils/string_utils.dart';
import '../../core/utils/artwork_resolver.dart';
import '../../core/utils/track_credits.dart';
import '../../core/utils/search_dedupe.dart';

class MusicRepositoryImpl implements MusicRepository {
  final YouTubeMusicDataSource _dataSource;

  MusicRepositoryImpl({YouTubeMusicDataSource? dataSource}) 
      : _dataSource = dataSource ?? YouTubeMusicDataSource();

  /// In-memory cache for album detail responses, keyed by browseId.
  /// Avoids repeated /album/{id} fetches during enrichment.
  final Map<String, Map<String, dynamic>> _albumDetailCache = {};

  @override
  Future<void> prewarm() => _dataSource.prewarm();

  @override
  Future<(List<SavedAlbum>, String?)> getArtistAlbumsPage(String id, String? params, String? token) async {
    // v2: Deezer pagination uses offset/limit, no tokens.
    // Return all albums from the v2 endpoint.
    try {
      final deezerId = int.parse(id);
      final result = await _dataSource.getArtistAlbumsV2(deezerId);
      final items = (result['data'] as List?)?.map((e) => _mapAlbumV2(e)).toList() ?? [];
      return (items, null); // No pagination token for Deezer
    } catch (e) {
      debugPrint('[Repo] getArtistAlbumsPage v2 error: $e');
      return (<SavedAlbum>[], null);
    }
  }

  @override
  Future<List<Track>> searchTracks(String query) async {
    final result = await _dataSource.searchV2(query, 'tracks');
    final mapped = (result['data'] as List? ?? [])
        .map((e) {
          try { return _mapTrackV2(e as Map<String, dynamic>); }
          catch (err) { debugPrint('[Repo] searchTracks v2 skip: $err'); return null; }
        })
        .whereType<Track>()
        .toList();
    return _dedupeTracks(mapped);
  }

  // Phase 3.3.3: collapse exact duplicate rows (same Deezer track id, or an
  // id-less title+artist+duration match) while keeping legitimate versions.
  List<Track> _dedupeTracks(List<Track> tracks) => dedupeBy<Track>(
        tracks,
        id: (t) => t.deezerTrackId,
        fallbackKey: (t) => '${normalizeForDedupe(t.title)}|'
            '${normalizeForDedupe(t.artistName)}|${(t.duration / 3).round()}',
      );

  List<SavedAlbum> _dedupeAlbums(List<SavedAlbum> albums) => dedupeBy<SavedAlbum>(
        albums,
        id: (a) => a.albumId,
        fallbackKey: (a) => '${normalizeForDedupe(a.title)}|'
            '${normalizeForDedupe(a.artistName)}|${a.releaseType}|${a.releaseDate ?? ''}',
      );

  @override
  Future<List<SavedAlbum>> searchAlbums(String query) async {
    // Normalized Supabase-first discovery (albums are navigational, not played
    // directly, so no playback path is involved). Falls back to legacy on error.
    try {
      final result = await _dataSource.findV2(query, 'albums');
      final items = (result?['items'] as List? ?? []);
      final mapped = items
          .map((e) {
            try { return _mapAlbumFind(e as Map<String, dynamic>); }
            catch (err) { debugPrint('[Repo] searchAlbums find skip: $err'); return null; }
          })
          .whereType<SavedAlbum>()
          .where((a) => a.albumId.isNotEmpty)
          .toList();
      if (mapped.isNotEmpty) return _dedupeAlbums(mapped);
    } catch (err) {
      debugPrint('[Repo] searchAlbums find error, falling back to legacy: $err');
    }
    final result = await _dataSource.searchV2(query, 'albums');
    final mapped = (result['data'] as List? ?? [])
        .map((e) {
          try { return _mapAlbumV2(e as Map<String, dynamic>); }
          catch (err) { debugPrint('[Repo] searchAlbums v2 skip: $err'); return null; }
        })
        .whereType<SavedAlbum>()
        .toList();
    return _dedupeAlbums(mapped);
  }

  @override
  Future<List<Artist>> searchArtists(String query) async {
    // Normalized Supabase-first discovery (artists navigate to the artist
    // screen; no playback path). Falls back to legacy on error.
    try {
      final result = await _dataSource.findV2(query, 'artists');
      final items = (result?['items'] as List? ?? []);
      final mapped = items
          .map((e) {
            try { return _mapArtistFind(e as Map<String, dynamic>); }
            catch (err) { debugPrint('[Repo] searchArtists find skip: $err'); return null; }
          })
          .whereType<Artist>()
          .where((a) => a.id.isNotEmpty)  // must be navigable (has a Deezer id)
          .toList();
      if (mapped.isNotEmpty) return mapped;
    } catch (err) {
      debugPrint('[Repo] searchArtists find error, falling back to legacy: $err');
    }
    final result = await _dataSource.searchV2(query, 'artists');
    return (result['data'] as List? ?? [])
        .map((e) {
          try { return _mapArtistV2(e as Map<String, dynamic>); }
          catch (err) { debugPrint('[Repo] searchArtists v2 skip: $err'); return null; }
        })
        .whereType<Artist>()
        .toList();
  }

  @override
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getCharts([String country = 'US']) async {
    final result = await _dataSource.getChartV2();
    return _mapStructuredResponseV2(result);
  }

  @override
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getGenreContent(String genre, String country) async {
    // v2: Use Deezer search to simulate genre content
    final trackResult = await _dataSource.searchV2('$genre top songs', 'tracks', limit: 10);
    final albumResult = await _dataSource.searchV2('$genre albums', 'albums', limit: 10);
    final artistResult = await _dataSource.searchV2('$genre artists', 'artists', limit: 10);

    final tracks = (trackResult['data'] as List? ?? []).map((e) {
      try { return _mapTrackV2(e as Map<String, dynamic>); }
      catch (_) { return null; }
    }).whereType<Track>().toList();

    final albums = (albumResult['data'] as List? ?? []).map((e) {
      try { return _mapAlbumV2(e as Map<String, dynamic>); }
      catch (_) { return null; }
    }).whereType<SavedAlbum>().toList();

    final artists = (artistResult['data'] as List? ?? []).map((e) {
      try { return _mapArtistV2(e as Map<String, dynamic>); }
      catch (_) { return null; }
    }).whereType<Artist>().toList();

    return (tracks: tracks, albums: albums, artists: artists);
  }

  @override
  Future<({List<SavedAlbum> playlists, List<Track> tracks, List<Artist> artists})> getGenrePage(String slug) async {
    // v2: Use Deezer search for genre content
    final trackResult = await _dataSource.searchV2('$slug music', 'tracks', limit: 15);
    final artistResult = await _dataSource.searchV2('$slug', 'artists', limit: 10);

    final playlists = <SavedAlbum>[];
    final tracks = (trackResult['data'] as List? ?? []).map((e) {
      try { return _mapTrackV2(e as Map<String, dynamic>); }
      catch (_) { return null; }
    }).whereType<Track>().toList();

    final artists = (artistResult['data'] as List? ?? []).map((e) {
      try { return _mapArtistV2(e as Map<String, dynamic>); }
      catch (_) { return null; }
    }).whereType<Artist>().toList();

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

  /// v2 structured response mapper for Deezer chart data.
  ({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists}) _mapStructuredResponseV2(Map<String, dynamic> result) {
    final tracks = (result['tracks'] as List? ?? [])
        .map((e) { try { return _mapTrackV2(e as Map<String, dynamic>); } catch (err) { debugPrint('[Repo] v2 chart track skip: $err'); return null; } })
        .whereType<Track>()
        .toList();
    final albums = (result['albums'] as List? ?? [])
        .map((e) { try { return _mapAlbumV2(e as Map<String, dynamic>); } catch (err) { debugPrint('[Repo] v2 album skip: $err'); return null; } })
        .whereType<SavedAlbum>()
        .toList();
    final artists = (result['artists'] as List? ?? [])
        .map((e) { try { return _mapArtistV2(e as Map<String, dynamic>); } catch (err) { debugPrint('[Repo] v2 artist skip: $err'); return null; } })
        .whereType<Artist>()
        .toList();
    return (tracks: tracks, albums: albums, artists: artists);
  }

  @override
  Future<Artist> getArtist(String id) async {
    final stopwatch = Stopwatch()..start();
    final deezerId = int.parse(id);

    // Phase 3.3.1 §2: the CORE profile (identity, artwork, Paax follower count,
    // genres, deterministically-ordered discography, latest release) comes from
    // the normalized Supabase-first catalog and is fast. It does NOT block on the
    // legacy /v2/artist/{id} call, which eagerly YouTube-matches up to 50 top
    // tracks (tens of seconds). Top tracks + related artists load separately via
    // getArtistExtras() as background sections. Bounded so a slow ingest can't
    // hang the page indefinitely.
    Map<String, dynamic>? normalized;
    try {
      normalized = await _dataSource
          .getArtistNormalizedByDeezerId(deezerId)
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      debugPrint('[Repo] normalized artist core error/timeout: $e');
      normalized = null;
    }

    if (normalized != null) {
      final name = normalized['name']?.toString() ?? 'Unknown Artist';
      final disc = normalized['discography'] as Map<String, dynamic>? ?? {};
      final artistDzId = _asInt(normalized['deezerId']) ?? deezerId;
      List<SavedAlbum> mapRel(String key) => (disc[key] as List? ?? [])
          .map((r) { try {
            return _mapReleaseToSavedAlbum(r as Map<String, dynamic>,
                artistName: name, artistDeezerId: artistDzId);
          } catch (_) { return null; } })
          .whereType<SavedAlbum>().toList();
      debugPrint('[Perf] getArtist($id) core in ${stopwatch.elapsedMilliseconds}ms (normalized)');
      return Artist(
        id: id,
        name: name,
        picture: ArtworkResolver.artist(normalized),
        nbFans: _asInt(normalized['deezerFansCount']) ?? 0,
        albums: [...mapRel('albums'), ...mapRel('compilations')],
        singles: [...mapRel('singles'), ...mapRel('eps')],
        // Top tracks + related load separately (getArtistExtras) — NOT here.
        topTracks: const [],
        relatedArtists: const [],
        uuid: normalized['id']?.toString(),
        platformFollowers: _asInt(normalized['platformFollowersCount']),
      );
    }

    // Normalized unavailable → legacy fallback (full profile incl. top tracks +
    // related). Slower, but only when the Supabase catalog can't resolve. Bound
    // it so a normalized outage can't reintroduce the 40s cold-artist hang (§2);
    // on timeout the screen shows its retry state.
    debugPrint('[Repo] getArtist($id) falling back to legacy full profile');
    final legacy = await _dataSource
        .getArtistV2(deezerId)
        .timeout(const Duration(seconds: 15));
    final topTracks = (legacy['topTracks'] as List? ?? []).map((t) {
      try { return _mapTrackV2(t as Map<String, dynamic>); } catch (_) { return null; }
    }).whereType<Track>().toList();
    final relatedArtists = (legacy['relatedArtists'] as List? ?? []).map((a) {
      try { return _mapArtistV2(a as Map<String, dynamic>); } catch (_) { return null; }
    }).whereType<Artist>().toList();
    return Artist(
      id: id,
      name: legacy['name']?.toString() ?? 'Unknown Artist',
      picture: ArtworkResolver.artist(legacy),
      nbFans: _asInt(legacy['nbFans']) ?? 0,
      albums: (legacy['albums'] as List? ?? []).map((a) {
        try { return _mapAlbumV2(a as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<SavedAlbum>().toList(),
      singles: (legacy['singles'] as List? ?? []).map((a) {
        try { return _mapAlbumV2(a as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<SavedAlbum>().toList(),
      topTracks: topTracks,
      relatedArtists: relatedArtists,
    );
  }

  /// Returns the fast CORE artist profile (see [getArtist]).
  @override
  Future<Artist> getArtistBasic(String id) => getArtist(id);

  @override
  Future<({
    List<Track> topTracks,
    List<Artist> relatedArtists,
    List<SavedAlbum> albums,
    List<SavedAlbum> singles,
  })> getArtistExtras(String id) async {
    // Background section (Phase 3.3.1 §2): top tracks (eager, playable — the
    // Play action stays legacy) + related artists (+ legacy discography as a
    // backfill for a partial normalized core). Off the artist-detail critical
    // path; bounded so a slow eager match can't hang forever.
    try {
      final deezerId = int.parse(id);
      final legacy = await _dataSource
          .getArtistV2(deezerId)
          .timeout(const Duration(seconds: 30));
      final topTracks = (legacy['topTracks'] as List? ?? []).map((t) {
        try { return _mapTrackV2(t as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<Track>().toList();
      final related = (legacy['relatedArtists'] as List? ?? []).map((a) {
        try { return _mapArtistV2(a as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<Artist>().toList();
      final albums = (legacy['albums'] as List? ?? []).map((a) {
        try { return _mapAlbumV2(a as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<SavedAlbum>().toList();
      final singles = (legacy['singles'] as List? ?? []).map((a) {
        try { return _mapAlbumV2(a as Map<String, dynamic>); } catch (_) { return null; }
      }).whereType<SavedAlbum>().toList();
      return (topTracks: topTracks, relatedArtists: related, albums: albums, singles: singles);
    } catch (e) {
      debugPrint('[Repo] getArtistExtras error: $e');
      rethrow; // let the section show its retry state
    }
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Map a normalized discography [ReleaseResponse] into a [SavedAlbum]. The
  /// album id is the Deezer id so album-detail navigation stays on the existing
  /// (legacy) album path; artwork uses the canonical resolver.
  SavedAlbum _mapReleaseToSavedAlbum(Map<String, dynamic> r,
      {required String artistName, required int artistDeezerId}) {
    // Album navigation uses the legacy album path (int Deezer id); use the
    // numeric id only (catalog releases always carry one).
    final dz = _asInt(r['deezerId']);
    // Prefer the exact date; fall back to the year so year-only releases still
    // sort/label correctly on the client (extractYear handles both forms).
    final releaseDate = r['releaseDate']?.toString() ?? _asInt(r['releaseYear'])?.toString();
    return SavedAlbum(
      albumId: dz?.toString() ?? '',
      title: r['title']?.toString() ?? 'Unknown Album',
      artistName: artistName,
      artistId: artistDeezerId.toString(),
      artworkUrl: ArtworkResolver.cover(r),
      releaseDate: releaseDate,
      releaseType: r['albumType']?.toString() ?? 'album',
      trackCount: _asInt(r['totalTracks']),
    );
  }

  // ── Album Enrichment Pipeline ───────────────────────────────────────────

  /// Fetch album detail with caching.
  Future<Map<String, dynamic>> _fetchAlbumCached(String browseId) async {
    if (_albumDetailCache.containsKey(browseId)) {
      debugPrint('[Repo] Album cache HIT: $browseId');
      return _albumDetailCache[browseId]!;
    }
    debugPrint('[Repo] Album cache MISS: $browseId');
    final data = await _dataSource.getAlbum(browseId);
    final map = data is Map<String, dynamic> ? data : <String, dynamic>{};
    _albumDetailCache[browseId] = map;
    return map;
  }

  /// Public enrichment method — no-op in v2 since Deezer provides complete metadata.
  @override
  Future<({List<SavedAlbum> albums, List<SavedAlbum> singles})> enrichArtistReleases({
    required List<SavedAlbum> existingAlbums,
    required List<SavedAlbum> existingSingles,
    required List<dynamic> rawSongs,
  }) async {
    // Deezer data already includes release dates and types — no enrichment needed.
    return (albums: existingAlbums, singles: existingSingles);
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
    final stopwatch = Stopwatch()..start();

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
      debugPrint('[Perf] enrichArtistReleases: nothing to enrich (${stopwatch.elapsedMilliseconds}ms)');
      return (albums: existingAlbums, singles: existingSingles);
    }

    // Cap at 10 fetches to limit network usage
    final fetchList = idsToFetch.take(10).toList();
    debugPrint('[Repo] Enriching ${fetchList.length} releases: $fetchList');

    // Fetch in batches of 5 for controlled concurrency
    int cacheHits = 0;
    int cacheMisses = 0;
    final fetchedMap = <String, Map<String, dynamic>>{};

    for (int i = 0; i < fetchList.length; i += 5) {
      final batch = fetchList.sublist(i, (i + 5).clamp(0, fetchList.length));
      final batchResults = await Future.wait(
        batch.map((id) async {
          final wasCached = _albumDetailCache.containsKey(id);
          try {
            final data = await _fetchAlbumCached(id);
            if (wasCached) cacheHits++;
            else cacheMisses++;
            return MapEntry(id, data);
          } catch (err) {
            cacheMisses++;
            debugPrint('[Repo] Failed to fetch album $id: $err');
            return MapEntry(id, <String, dynamic>{});
          }
        }),
      );
      fetchedMap.addEntries(batchResults.where((e) => e.value.isNotEmpty));
    }

    debugPrint('[Perf] enrichArtistReleases: ${fetchList.length} fetches '
        '(${cacheHits} hits, ${cacheMisses} misses) in ${stopwatch.elapsedMilliseconds}ms');

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
    try {
      final deezerId = int.parse(id);
      final result = await _dataSource.getArtistAlbumsV2(deezerId);
      return (result['data'] as List? ?? [])
          .map((e) {
            try { return _mapAlbumV2(e as Map<String, dynamic>); }
            catch (_) { return null; }
          })
          .whereType<SavedAlbum>()
          .toList();
    } catch (e) {
      debugPrint('[Repo] getArtistAlbums v2 error: $e');
      return [];
    }
  }

  @override
  Future<List<SavedAlbum>> getArtistSingles(String id) async {
    try {
      final deezerId = int.parse(id);
      final result = await _dataSource.getArtistAlbumsV2(deezerId);
      return (result['data'] as List? ?? [])
          .map((e) {
            try { return _mapAlbumV2(e as Map<String, dynamic>); }
            catch (_) { return null; }
          })
          .whereType<SavedAlbum>()
          .where((a) => a.releaseType == 'single')
          .toList();
    } catch (e) {
      debugPrint('[Repo] getArtistSingles v2 error: $e');
      return [];
    }
  }

  @override
  Future<List<Track>> getArtistTopTracks(String id) async {
    try {
      final deezerId = int.parse(id);
      final result = await _dataSource.getArtistTopV2(deezerId);
      return (result['data'] as List? ?? [])
          .map((e) {
            try { return _mapTrackV2(e as Map<String, dynamic>); }
            catch (_) { return null; }
          })
          .whereType<Track>()
          .toList();
    } catch (e) {
      debugPrint('[Repo] getArtistTopTracks v2 error: $e');
      return [];
    }
  }

  @override
  Future<List<Artist>> getRelatedArtists(String id) async {
    // v2: Related artists come from the full artist profile
    try {
      final artist = await getArtist(id);
      return artist.relatedArtists ?? [];
    } catch (e) {
      debugPrint('[Repo] getRelatedArtists v2 error: $e');
      return [];
    }
  }

  @override
  Future<SavedAlbum> getAlbum(String id) async {
    try {
      final deezerId = int.parse(id);
      final e = await _dataSource.getAlbumV2(deezerId);

      // Phase 3.3.3 (issue 3/4): the legacy /v2/album payload only carries the
      // album's primary artist per track (Deezer's album tracklist omits
      // contributors), so every row collapsed to the album artist. Overlay the
      // real per-track credits from the normalized album (Supabase track_artists)
      // — keyed by Deezer track id — while KEEPING the legacy videoId for
      // playback (Track.id). Best-effort: falls back to legacy on any error.
      final creditMap = await _fetchAlbumTrackCredits(deezerId);

      // Map tracks from the album detail response
      final tracks = (e['tracks'] as List? ?? []).map((t) {
        try {
          final track = _mapTrackV2(t as Map<String, dynamic>);
          return _applyTrackCredits(track, creditMap);
        } catch (_) { return null; }
      }).whereType<Track>().toList();

      // Build artist info
      final artistObj = e['artist'] as Map<String, dynamic>? ?? {};
      final artistsList = <Map<String, String>>[];
      if (e['artists'] is List) {
        for (var a in (e['artists'] as List)) {
          final name = a['name']?.toString() ?? '';
          final aid = a['id']?.toString() ?? '';
          if (name.isNotEmpty) artistsList.add({'name': name, 'id': aid});
        }
      }
      if (artistsList.isEmpty && artistObj['name'] != null) {
        artistsList.add({'name': artistObj['name'].toString(), 'id': artistObj['id']?.toString() ?? ''});
      }

      return SavedAlbum(
        albumId: id,
        title: e['title']?.toString() ?? 'Unknown Album',
        artistName: artistsList.isNotEmpty
            ? artistsList.map((a) => a['name']!).join(', ')
            : artistObj['name']?.toString() ?? 'Unknown Artist',
        artistId: artistObj['id']?.toString() ?? '',
        artworkUrl: e['coverUrl']?.toString() ?? '',
        tracks: tracks,
        duration: e['duration'] as int? ?? tracks.fold<int>(0, (sum, t) => sum + t.duration),
        trackCount: e['trackCount'] as int? ?? tracks.length,
        releaseDate: e['releaseDate']?.toString(),
        label: '',
        artists: artistsList.isNotEmpty ? artistsList : null,
        releaseType: e['type']?.toString() ?? 'album',
      );
    } catch (e) {
      debugPrint('[Repo] getAlbum v2 error: $e');
      rethrow;
    }
  }

  @override
  Future<List<Track>> getAlbumTracks(String id) async {
    try {
      final deezerId = int.parse(id);
      final e = await _dataSource.getAlbumV2(deezerId);
      final creditMap = await _fetchAlbumTrackCredits(deezerId);
      return (e['tracks'] as List? ?? []).map((t) {
        try {
          return _applyTrackCredits(_mapTrackV2(t as Map<String, dynamic>), creditMap);
        } catch (_) { return null; }
      }).whereType<Track>().toList();
    } catch (e) {
      debugPrint('[Repo] getAlbumTracks v2 error: $e');
      return [];
    }
  }

  /// Per-track visible credits from the normalized album (Supabase
  /// track_artists), keyed by Deezer track id. Best-effort — empty on failure.
  Future<Map<int, List<Map<String, String>>>> _fetchAlbumTrackCredits(int deezerId) async {
    final out = <int, List<Map<String, String>>>{};
    try {
      final norm = await _dataSource
          .getAlbumNormalizedByDeezerId(deezerId)
          .timeout(const Duration(seconds: 8));
      if (norm == null) return out;
      for (final t in (norm['tracks'] as List? ?? [])) {
        if (t is! Map) continue;
        final tm = t.cast<String, dynamic>();
        final dz = _asInt(tm['deezerId']);
        if (dz == null) continue;
        final credits = TrackCredits.resolve((tm['artists'] as List?) ?? const []);
        if (credits.isNotEmpty) out[dz] = credits;
      }
    } catch (err) {
      debugPrint('[Repo] normalized album credits error: $err');
    }
    return out;
  }

  /// Overlay resolved per-track credits onto a legacy track (keeps its videoId).
  Track _applyTrackCredits(Track track, Map<int, List<Map<String, String>>> creditMap) {
    final dz = _asInt(track.deezerTrackId);
    if (dz == null) return track;
    final credits = creditMap[dz];
    if (credits == null || credits.isEmpty) return track;
    return track.copyWith(
      artists: credits,
      artistName: credits.map((a) => a['name']).whereType<String>().join(', '),
    );
  }

  @override
  Future<Track> getTrack(String id) async {
    try {
      final deezerId = int.parse(id);
      final e = await _dataSource.getTrackV2(deezerId);
      return _mapTrackV2(e);
    } catch (e) {
      debugPrint('[Repo] getTrack v2 error: $e');
      rethrow;
    }
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
      isExplicit: e['isExplicit'] == true,
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
       isExplicit: e['isExplicit'] == true,
     );
  }

  SavedAlbum _mapAlbum(Map<String, dynamic> e, {String defaultType = 'album', String? defaultArtistName}) {
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
        : (defaultArtistName ?? 'Various Artists');
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

  // ═══════════════════════════════════════════════════════════════════════════
  // v2 Mappers — Deezer metadata + YouTube playback ID
  // ═══════════════════════════════════════════════════════════════════════════

  /// Map a v2 track response (Deezer metadata + YouTube playback block)
  /// into a [Track] entity.
  ///
  /// CRITICAL: `Track.id` = `playback.videoId` (YouTube video ID) to preserve
  /// the [PlaybackEngine.load(videoId)] contract.
  Track _mapTrackV2(Map<String, dynamic> e) {
    // ── Playback block ────────────────────────────────────────────────────
    final playback = e['playback'] as Map<String, dynamic>? ?? {};
    final videoId = playback['videoId']?.toString() ?? '';

    // ── Artist info ───────────────────────────────────────────────────────
    final artistObj = e['artist'] as Map<String, dynamic>? ?? {};
    final artistsList = <Map<String, String>>[];
    if (e['artists'] is List) {
      for (var a in (e['artists'] as List)) {
        final name = a['name']?.toString() ?? '';
        final id = a['id']?.toString() ?? '';
        if (name.isNotEmpty) {
          artistsList.add({'name': name, 'id': id});
        }
      }
    }
    if (artistsList.isEmpty && artistObj['name'] != null) {
      artistsList.add({
        'name': artistObj['name'].toString(),
        'id': artistObj['id']?.toString() ?? '',
      });
    }

    final artistName = artistsList.isNotEmpty
        ? artistsList.map((a) => a['name']!).join(', ')
        : 'Unknown Artist';
    final artistId = artistsList.isNotEmpty
        ? artistsList.first['id']!
        : artistObj['id']?.toString() ?? '';

    // ── Album info ────────────────────────────────────────────────────────
    final albumObj = e['album'] as Map<String, dynamic>? ?? {};

    return Track(
      id: videoId,  // YouTube video ID for playback
      title: e['title']?.toString() ?? 'Unknown',
      artistName: artistName,
      artistId: artistId,
      albumId: albumObj['id']?.toString() ?? '',
      albumTitle: albumObj['title']?.toString() ?? '',
      artworkUrl: albumObj['coverUrl']?.toString() ?? '',
      duration: e['duration'] as int? ?? 0,
      artists: artistsList,
      isExplicit: e['explicit'] == true,
      // Deezer track id (top-level `id`) — kept only to resolve to the Supabase
      // tracks.id UUID for cloud library sync (Phase 3.2A).
      deezerTrackId: e['id']?.toString(),
    );
  }

  /// Map a v2 album response into a [SavedAlbum] entity.
  SavedAlbum _mapAlbumV2(Map<String, dynamic> e) {
    final artistObj = e['artist'] as Map<String, dynamic>? ?? {};
    final artistsList = <Map<String, String>>[];
    if (e['artists'] is List) {
      for (var a in (e['artists'] as List)) {
        final name = a['name']?.toString() ?? '';
        final id = a['id']?.toString() ?? '';
        if (name.isNotEmpty) {
          artistsList.add({'name': name, 'id': id});
        }
      }
    }

    return SavedAlbum(
      albumId: e['id']?.toString() ?? '',
      title: e['title']?.toString() ?? 'Unknown Album',
      artistName: artistsList.isNotEmpty
          ? artistsList.map((a) => a['name']!).join(', ')
          : artistObj['name']?.toString() ?? 'Unknown Artist',
      artistId: artistObj['id']?.toString() ?? '',
      artworkUrl: e['coverUrl']?.toString() ?? '',
      artists: artistsList.isNotEmpty ? artistsList : null,
      releaseDate: e['releaseDate']?.toString(),
      releaseType: e['type']?.toString() ?? 'album',
      trackCount: e['trackCount'] as int?,
    );
  }

  /// Map a legacy v2 artist response into an [Artist] entity. Uses the canonical
  /// artwork resolver so cards no longer blank out when the image lives under a
  /// different key than the singular `/v2/artist` detail response (Phase 3.3 §7).
  Artist _mapArtistV2(Map<String, dynamic> e) {
    return Artist(
      id: e['id']?.toString() ?? '',
      name: e['name']?.toString() ?? 'Unknown Artist',
      picture: ArtworkResolver.artist(e),
      nbFans: _asInt(e['nbFans']) ?? 0,
    );
  }

  /// Map a normalized `/v2/find` artist item into an [Artist]. `id` is the
  /// Deezer id (navigation key → artist detail); the Supabase UUID is carried
  /// on [Artist.uuid]. Discovery items with only a UUID (not yet ingested with
  /// a Deezer id) are skipped by the caller when unnavigable.
  Artist _mapArtistFind(Map<String, dynamic> e) {
    // Navigation id MUST be the numeric Deezer id — getArtist(id) does
    // int.parse(id). Items with only a UUID (no Deezer id) get an empty id and
    // are dropped by the caller's `id.isNotEmpty` filter rather than producing
    // a card that throws on tap.
    final dz = _asInt(e['deezerId']);
    return Artist(
      id: dz?.toString() ?? '',
      name: e['name']?.toString() ?? 'Unknown Artist',
      picture: ArtworkResolver.artist(e),
      uuid: e['id']?.toString(),
    );
  }

  /// Map a normalized `/v2/find` album item into a [SavedAlbum]. `albumId` is
  /// the Deezer id so album-detail navigation stays on the existing path.
  SavedAlbum _mapAlbumFind(Map<String, dynamic> e) {
    // Album navigation uses the legacy album path (int Deezer id). UUID-only
    // items get an empty albumId and are filtered by the caller.
    final dz = _asInt(e['deezerId']);
    final name = e['artistName']?.toString() ?? '';
    return SavedAlbum(
      albumId: dz?.toString() ?? '',
      title: e['title']?.toString() ?? 'Unknown Album',
      artistName: name.isNotEmpty ? name : 'Unknown Artist',
      artistId: '',
      artworkUrl: ArtworkResolver.cover(e),
      releaseDate: e['releaseDate']?.toString(),
      releaseType: e['albumType']?.toString() ?? 'album',
    );
  }
}
