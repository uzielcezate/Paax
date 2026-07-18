// lib/data/remote/catalog_resolver.dart
//
// Phase 3.2A — Cloud Library Sync.
//
// Resolves the app's local DEEZER ids into the Supabase catalog UUIDs required
// to write the user relation tables (user_liked_tracks, user_saved_albums,
// user_followed_artists, user_hidden_tracks).
//
// The app's local entities carry Deezer ids, NOT Supabase UUIDs:
//   Artist.id            = Deezer artist id (string)
//   SavedAlbum.albumId   = Deezer album id (string)
//   Track.deezerTrackId  = Deezer track id (string, nullable)
//
// The catalog tables (artists / albums / tracks) are PUBLICLY READABLE, so we
// map deezer_id -> id by querying them. Results are cached both in memory and
// in SharedPreferences so repeat lookups are free across app launches.
//
// This class NEVER throws to callers. On a network error / missing row it
// returns null (or omits the key from a batch map); the caller keeps the item
// LOCAL-ONLY and enqueues a pending op for later.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CatalogResolver {
  final SupabaseClient _client;

  CatalogResolver([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  // ── SharedPreferences cache keys (per entity type) ──
  static const String _kArtistsCache = 'catalog_resolver_artists_v1';
  static const String _kAlbumsCache = 'catalog_resolver_albums_v1';
  static const String _kTracksCache = 'catalog_resolver_tracks_v1';
  static const String _kGenresCache = 'catalog_resolver_genres_v1';

  // ── In-memory caches: deezerId(String) -> Supabase UUID(String) ──
  final Map<String, String> _artistCache = {};
  final Map<String, String> _albumCache = {};
  final Map<String, String> _trackCache = {};
  final Map<String, String> _genreCache = {};

  bool _loaded = false;

  /// Lazily hydrate the in-memory caches from SharedPreferences. Best-effort.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _mergeInto(_artistCache, prefs.getString(_kArtistsCache));
      _mergeInto(_albumCache, prefs.getString(_kAlbumsCache));
      _mergeInto(_trackCache, prefs.getString(_kTracksCache));
      _mergeInto(_genreCache, prefs.getString(_kGenresCache));
    } catch (_) {
      // Ignore — cache is a pure optimization.
    }
  }

  void _mergeInto(Map<String, String> target, String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          if (v is String) target[k.toString()] = v;
        });
      }
    } catch (_) {
      // Corrupt cache — ignore.
    }
  }

  Future<void> _persist(String key, Map<String, String> cache) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(cache));
    } catch (_) {
      // Ignore persistence failures.
    }
  }

  /// True only for a non-empty, purely-numeric Deezer id.
  bool _isValidDeezerId(String? id) {
    if (id == null) return false;
    final trimmed = id.trim();
    if (trimmed.isEmpty) return false;
    return int.tryParse(trimmed) != null;
  }

  // ── Single resolvers ─────────────────────────────────────────────

  Future<String?> resolveArtist(String deezerArtistId) =>
      _resolveOne('artists', deezerArtistId, _artistCache, _kArtistsCache);

  Future<String?> resolveAlbum(String deezerAlbumId) =>
      _resolveOne('albums', deezerAlbumId, _albumCache, _kAlbumsCache);

  Future<String?> resolveTrack(String? deezerTrackId) {
    if (!_isValidDeezerId(deezerTrackId)) return Future.value(null);
    return _resolveOne('tracks', deezerTrackId!, _trackCache, _kTracksCache);
  }

  Future<String?> resolveGenre(String deezerGenreId) =>
      _resolveOne('genres', deezerGenreId, _genreCache, _kGenresCache);

  Future<String?> _resolveOne(
    String table,
    String deezerId,
    Map<String, String> cache,
    String cacheKey,
  ) async {
    if (!_isValidDeezerId(deezerId)) return null;
    final key = deezerId.trim();
    await _ensureLoaded();
    final cached = cache[key];
    if (cached != null) return cached;
    try {
      final row = await _client
          .from(table)
          .select('id, deezer_id')
          .eq('deezer_id', int.parse(key))
          .maybeSingle();
      if (row == null) return null;
      final uuid = row['id']?.toString();
      if (uuid == null || uuid.isEmpty) return null;
      cache[key] = uuid;
      await _persist(cacheKey, cache);
      return uuid;
    } catch (_) {
      // Network / RLS / parse error — keep item local-only.
      return null;
    }
  }

  // ── Batch resolvers (single `.inFilter` query each) ──────────────

  Future<Map<String, String>> resolveArtists(Iterable<String> deezerIds) =>
      _resolveMany('artists', deezerIds, _artistCache, _kArtistsCache);

  Future<Map<String, String>> resolveAlbums(Iterable<String> deezerIds) =>
      _resolveMany('albums', deezerIds, _albumCache, _kAlbumsCache);

  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) =>
      _resolveMany(
        'tracks',
        deezerIds.whereType<String>(),
        _trackCache,
        _kTracksCache,
      );

  Future<Map<String, String>> resolveGenres(Iterable<String> deezerIds) =>
      _resolveMany('genres', deezerIds, _genreCache, _kGenresCache);

  Future<Map<String, String>> _resolveMany(
    String table,
    Iterable<String> deezerIds,
    Map<String, String> cache,
    String cacheKey,
  ) async {
    await _ensureLoaded();
    final result = <String, String>{};

    // Collect valid, not-yet-cached numeric ids to query.
    final toQuery = <int>{};
    final validKeys = <String>{};
    for (final raw in deezerIds) {
      if (!_isValidDeezerId(raw)) continue;
      final key = raw.trim();
      validKeys.add(key);
      final cached = cache[key];
      if (cached != null) {
        result[key] = cached;
      } else {
        toQuery.add(int.parse(key));
      }
    }

    if (toQuery.isEmpty) return result;

    try {
      final rows = await _client
          .from(table)
          .select('id, deezer_id')
          .inFilter('deezer_id', toQuery.toList());
      bool changed = false;
      for (final row in (rows as List)) {
        final uuid = row['id']?.toString();
        final dz = row['deezer_id']?.toString();
        if (uuid == null || uuid.isEmpty || dz == null) continue;
        cache[dz] = uuid;
        result[dz] = uuid;
        changed = true;
      }
      if (changed) await _persist(cacheKey, cache);
    } catch (_) {
      // Return whatever was already cached; unresolved ids stay local-only.
    }
    return result;
  }
}
