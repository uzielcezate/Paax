// lib/data/repositories/home_repository.dart
//
// Phase 3.2.5 — Personalized Home data access.
//
// Reads the PUBLIC catalog tables (albums, album_artists, album_genres) directly
// from Supabase to build a deterministic, real-data personalized feed. There is
// NO fake data and NO per-item (N+1) fetching — every method issues at most a
// couple of BATCHED requests using `inFilter`.
//
// All ids exchanged here are Supabase UUIDs. The typed [HomeAlbum] carries the
// Deezer id so the UI can hand it to the metadata-keyed AlbumDetailScreen.
//
// Every public method wraps its work so any Postgrest/network failure surfaces
// as a typed [HomeException] the controller can catch. Methods never return
// partial garbage: on failure they throw, on success they return a clean list.

import 'package:supabase_flutter/supabase_flutter.dart';

/// Typed album row used across the Home feed.
class HomeAlbum {
  final String uuid;
  final String? deezerId;
  final String title;
  final String? artworkUrl;
  final String? albumType;

  const HomeAlbum({
    required this.uuid,
    required this.deezerId,
    required this.title,
    required this.artworkUrl,
    required this.albumType,
  });

  /// Builds a [HomeAlbum] from a raw `albums` row.
  /// artworkUrl = cover_cached_url ?? cover_original_url.
  factory HomeAlbum.fromRow(Map<String, dynamic> row) {
    final cached = row['cover_cached_url']?.toString();
    final original = row['cover_original_url']?.toString();
    return HomeAlbum(
      uuid: (row['id'] ?? '').toString(),
      deezerId: row['deezer_id']?.toString(),
      title: (row['title'] ?? '').toString(),
      artworkUrl: (cached != null && cached.isNotEmpty) ? cached : original,
      albumType: row['album_type']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'deezer_id': deezerId,
        'title': title,
        'artwork_url': artworkUrl,
        'album_type': albumType,
      };

  factory HomeAlbum.fromJson(Map<String, dynamic> json) => HomeAlbum(
        uuid: (json['uuid'] ?? '').toString(),
        deezerId: json['deezer_id']?.toString(),
        title: (json['title'] ?? '').toString(),
        artworkUrl: json['artwork_url']?.toString(),
        albumType: json['album_type']?.toString(),
      );
}

/// Typed failure raised by [HomeRepository]. The controller catches this to
/// decide between the offline (cached) path and the hard-error path.
class HomeException implements Exception {
  final String message;
  final Object? cause;
  const HomeException(this.message, [this.cause]);

  @override
  String toString() =>
      'HomeException: $message${cause != null ? ' ($cause)' : ''}';
}

class HomeRepository {
  final SupabaseClient _client;

  HomeRepository([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  // Columns pulled for every album card. Never `SELECT *`.
  static const String _albumCols =
      'id, deezer_id, title, album_type, cover_cached_url, cover_original_url';

  static const int _limit = 15;

  // ── Relation resolution (batched) ─────────────────────────────────

  /// Distinct album UUIDs credited to any of [artistUuids].
  /// Single batched request over `album_artists`.
  Future<List<String>> albumIdsForArtists(List<String> artistUuids) async {
    final ids = artistUuids.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    return _guard('albumIdsForArtists', () async {
      final rows =
          await _client.from('album_artists').select('album_id').inFilter(
                'artist_id',
                ids,
              );
      return _distinctIds(rows as List, 'album_id');
    });
  }

  /// Distinct album UUIDs tagged with any of [genreUuids].
  /// Single batched request over `album_genres`.
  Future<List<String>> albumIdsForGenres(List<String> genreUuids) async {
    final ids = genreUuids.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    return _guard('albumIdsForGenres', () async {
      final rows =
          await _client.from('album_genres').select('album_id').inFilter(
                'genre_id',
                ids,
              );
      return _distinctIds(rows as List, 'album_id');
    });
  }

  // ── Album fetches by resolved ids (batched, ordered, limited) ─────

  /// Newest albums (by release_date desc) among [albumIds].
  Future<List<HomeAlbum>> newestAlbumsByIds(List<String> albumIds) async {
    final ids = albumIds.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    return _guard('newestAlbumsByIds', () async {
      final rows = await _client
          .from('albums')
          .select(_albumCols)
          .inFilter('id', ids)
          .order('release_date', ascending: false)
          .limit(_limit);
      return _mapAlbums(rows as List);
    });
  }

  /// Most-played albums (by platform_play_count desc) among [albumIds].
  Future<List<HomeAlbum>> popularAlbumsByIds(List<String> albumIds) async {
    final ids = albumIds.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    return _guard('popularAlbumsByIds', () async {
      final rows = await _client
          .from('albums')
          .select(_albumCols)
          .inFilter('id', ids)
          .order('platform_play_count', ascending: false)
          .order('platform_likes_count', ascending: false)
          .limit(_limit);
      return _mapAlbums(rows as List);
    });
  }

  // ── Spec-level convenience methods (self-contained) ───────────────

  /// New albums from the given followed artists, newest first.
  Future<List<HomeAlbum>> newFromArtists(List<String> artistUuids) async {
    final albumIds = await albumIdsForArtists(artistUuids);
    return newestAlbumsByIds(albumIds);
  }

  /// Popular albums from the given followed artists, by play count.
  Future<List<HomeAlbum>> popularFromArtists(List<String> artistUuids) async {
    final albumIds = await albumIdsForArtists(artistUuids);
    return popularAlbumsByIds(albumIds);
  }

  /// Recommended albums via album_genres in the followed genres. May be empty.
  Future<List<HomeAlbum>> recommendedFromGenres(
      List<String> genreUuids) async {
    final albumIds = await albumIdsForGenres(genreUuids);
    if (albumIds.isEmpty) return const [];
    return _guard('recommendedFromGenres', () async {
      final rows = await _client
          .from('albums')
          .select(_albumCols)
          .inFilter('id', albumIds)
          .order('platform_play_count', ascending: false)
          .limit(_limit);
      return _mapAlbums(rows as List);
    });
  }

  // ── Global sections (always available) ────────────────────────────

  /// Global trending albums, ordered by play count then likes.
  /// (PostgREST cannot express greatest(play,likes) in one ORDER, so we order
  /// by platform_play_count then platform_likes_count via two .order() calls.)
  Future<List<HomeAlbum>> trending() async {
    return _guard('trending', () async {
      final rows = await _client
          .from('albums')
          .select(_albumCols)
          .order('platform_play_count', ascending: false)
          .order('platform_likes_count', ascending: false)
          .limit(_limit);
      return _mapAlbums(rows as List);
    });
  }

  /// Most recently added albums, newest first.
  Future<List<HomeAlbum>> recentlyAdded() async {
    return _guard('recentlyAdded', () async {
      final rows = await _client
          .from('albums')
          .select(_albumCols)
          .order('created_at', ascending: false)
          .limit(_limit);
      return _mapAlbums(rows as List);
    });
  }

  // ── Internals ─────────────────────────────────────────────────────

  List<String> _distinctIds(List rows, String column) {
    final seen = <String>{};
    for (final row in rows) {
      if (row is Map) {
        final v = row[column]?.toString();
        if (v != null && v.isNotEmpty) seen.add(v);
      }
    }
    return seen.toList();
  }

  List<HomeAlbum> _mapAlbums(List rows) {
    final out = <HomeAlbum>[];
    for (final row in rows) {
      if (row is Map) {
        final album = HomeAlbum.fromRow(row.cast<String, dynamic>());
        if (album.uuid.isNotEmpty) out.add(album);
      }
    }
    return out;
  }

  /// Runs [action], converting any error into a typed [HomeException] so the
  /// controller gets a single, catchable failure type.
  Future<T> _guard<T>(String op, Future<T> Function() action) async {
    try {
      return await action();
    } on HomeException {
      rethrow;
    } on PostgrestException catch (e) {
      throw HomeException('$op failed: ${e.message}', e);
    } catch (e) {
      throw HomeException('$op failed', e);
    }
  }
}
