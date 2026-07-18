// lib/data/remote/library_remote_data_source.dart
//
// Phase 3.2A — Cloud Library Sync.
//
// Thin data-access layer over the user relation tables and the readable
// catalog tables. All ids exchanged here are Supabase UUIDs (resolve Deezer
// ids first via CatalogResolver).
//
// Writes:
//   - INSERTs set user_id = the authenticated user's id and are idempotent
//     (a duplicate-key 23505 is treated as success — the row already exists).
//   - DELETEs match on (user_id, <entity>_id).
//   - Counter columns are trigger-maintained — NEVER written here.
//
// This class rethrows Postgrest/network errors (except idempotent 23505s) so
// the repository can decide whether to enqueue a pending op. The repository is
// the layer responsible for degrading gracefully.

import 'package:supabase_flutter/supabase_flutter.dart';

class LibraryRemoteDataSource {
  final SupabaseClient _client;

  LibraryRemoteDataSource([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  // Relation tables.
  static const String _likedTable = 'user_liked_tracks';
  static const String _savedTable = 'user_saved_albums';
  static const String _followedTable = 'user_followed_artists';
  static const String _followedGenresTable = 'user_followed_genres';
  static const String _hiddenTable = 'user_hidden_tracks';

  // Catalog tables.
  static const String _artistsTable = 'artists';
  static const String _albumsTable = 'albums';
  static const String _tracksTable = 'tracks';
  static const String _genresTable = 'genres';

  String? get _uid => _client.auth.currentUser?.id;

  /// The authenticated user's id, or null when signed out.
  String? get currentUserId => _uid;

  // ── Fetch relation sets (returns Supabase UUIDs) ─────────────────

  Future<Set<String>> fetchLikedTrackIds() =>
      _fetchIds(_likedTable, 'track_id');

  Future<Set<String>> fetchSavedAlbumIds() =>
      _fetchIds(_savedTable, 'album_id');

  Future<Set<String>> fetchFollowedArtistIds() =>
      _fetchIds(_followedTable, 'artist_id');

  Future<Set<String>> fetchFollowedGenreIds() =>
      _fetchIds(_followedGenresTable, 'genre_id');

  Future<Set<String>> fetchHiddenTrackIds() =>
      _fetchIds(_hiddenTable, 'track_id');

  Future<Set<String>> _fetchIds(String table, String column) async {
    final uid = _uid;
    if (uid == null) return <String>{};
    final rows = await _client.from(table).select(column).eq('user_id', uid);
    final out = <String>{};
    for (final row in (rows as List)) {
      final v = row[column]?.toString();
      if (v != null && v.isNotEmpty) out.add(v);
    }
    return out;
  }

  // ── Mutations ────────────────────────────────────────────────────

  Future<void> likeTrack(String trackUuid) =>
      _insert(_likedTable, 'track_id', trackUuid);
  Future<void> unlikeTrack(String trackUuid) =>
      _delete(_likedTable, 'track_id', trackUuid);

  Future<void> saveAlbum(String albumUuid) =>
      _insert(_savedTable, 'album_id', albumUuid);
  Future<void> unsaveAlbum(String albumUuid) =>
      _delete(_savedTable, 'album_id', albumUuid);

  Future<void> followArtist(String artistUuid) =>
      _insert(_followedTable, 'artist_id', artistUuid);
  Future<void> unfollowArtist(String artistUuid) =>
      _delete(_followedTable, 'artist_id', artistUuid);

  Future<void> followGenre(String genreUuid) =>
      _insert(_followedGenresTable, 'genre_id', genreUuid);
  Future<void> unfollowGenre(String genreUuid) =>
      _delete(_followedGenresTable, 'genre_id', genreUuid);

  Future<void> hideTrack(String trackUuid) =>
      _insert(_hiddenTable, 'track_id', trackUuid);
  Future<void> unhideTrack(String trackUuid) =>
      _delete(_hiddenTable, 'track_id', trackUuid);

  Future<void> _insert(String table, String column, String uuid) async {
    final uid = _uid;
    if (uid == null) {
      throw StateError('Cannot write $table: no authenticated user.');
    }
    try {
      await _client.from(table).insert({'user_id': uid, column: uuid});
    } on PostgrestException catch (e) {
      // 23505 = unique_violation → row already exists → idempotent success.
      if (e.code == '23505') return;
      rethrow;
    }
  }

  Future<void> _delete(String table, String column, String uuid) async {
    final uid = _uid;
    if (uid == null) {
      throw StateError('Cannot write $table: no authenticated user.');
    }
    await _client.from(table).delete().eq('user_id', uid).eq(column, uuid);
  }

  // ── Catalog hydration reads (by Supabase UUID) ───────────────────

  Future<List<Map<String, dynamic>>> fetchCatalogArtists(
    Iterable<String> uuids,
  ) =>
      _fetchCatalog(
        _artistsTable,
        'id, deezer_id, name, image_original_url, image_cached_url',
        uuids,
      );

  Future<List<Map<String, dynamic>>> fetchCatalogAlbums(
    Iterable<String> uuids,
  ) =>
      _fetchCatalog(
        _albumsTable,
        'id, deezer_id, title, cover_original_url, cover_cached_url',
        uuids,
      );

  Future<List<Map<String, dynamic>>> fetchCatalogTracks(
    Iterable<String> uuids,
  ) =>
      _fetchCatalog(
        _tracksTable,
        'id, deezer_id, title, preferred_youtube_video_id, duration_seconds',
        uuids,
      );

  Future<List<Map<String, dynamic>>> fetchCatalogGenres(
    Iterable<String> uuids,
  ) =>
      _fetchCatalog(
        _genresTable,
        'id, deezer_id, name, slug, image_original_url, image_cached_url',
        uuids,
      );

  Future<List<Map<String, dynamic>>> _fetchCatalog(
    String table,
    String columns,
    Iterable<String> uuids,
  ) async {
    final ids = uuids.where((e) => e.isNotEmpty).toList();
    if (ids.isEmpty) return const [];
    final rows =
        await _client.from(table).select(columns).inFilter('id', ids);
    return (rows as List).cast<Map<String, dynamic>>();
  }
}
