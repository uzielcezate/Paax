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

import '../api/youtube_music_data_source.dart';

class CatalogResolver {
  final SupabaseClient _client;

  /// paax-api client, used ONLY to trigger catalog ingestion for a track that
  /// Supabase does not have yet. Injectable for tests.
  final YouTubeMusicDataSource _api;

  CatalogResolver([SupabaseClient? client, YouTubeMusicDataSource? api])
      : _client = client ?? Supabase.instance.client,
        _api = api ?? YouTubeMusicDataSource();

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

  /// videoId → track UUID cache (second identity path).
  final Map<String, String> _videoIdCache = {};
  static const String _kVideoIdsCache = 'catalog_resolver_video_ids';

  Future<Map<String, String>> resolveTracks(Iterable<String?> deezerIds) =>
      _resolveMany(
        'tracks',
        deezerIds.whereType<String>(),
        _trackCache,
        _kTracksCache,
      );

  /// Resolve YouTube videoIds → canonical Paax track UUIDs.
  ///
  /// The SECOND identity path (Phase 3.4.7). Deezer identity must not be
  /// mandatory for playlist membership: `Track.id` in this app IS the YouTube
  /// videoId, and `tracks.preferred_youtube_video_id` stores it, so a track with
  /// no numeric `deezerTrackId` can still be resolved. Before this existed,
  /// such a track silently produced an EMPTY uuid array and
  /// `playlist_add_tracks` accepted it as a no-op success — the UI kept a song
  /// the server never received.
  ///
  /// Backed by `idx_tracks_preferred_youtube_video_id`.
  /// Asks paax-api for each track, which upserts it into the Supabase catalog
  /// as a side effect, so a subsequent resolve can find it.
  ///
  /// Exists because Artist Top Tracks is the only add-to-playlist entry point
  /// that never triggers ingestion (Album/Search/Player all hit endpoints that
  /// upsert the catalog graph). Bounded: capped, best-effort, and never
  /// retried here — the caller re-resolves once and then fails explicitly.
  Future<void> ingestTracks(Iterable<String> deezerIds) async {
    // Retained for callers that only have track ids; see ingestAlbums for the
    // path that actually populates the catalog.
    final ids = deezerIds
        .map((e) => e.trim())
        .where((e) => int.tryParse(e) != null)
        .toSet()
        .take(20)
        .toList();
    if (ids.isEmpty) return;
    await Future.wait(ids.map((id) async {
      try {
        await _api.getTrackV2(int.parse(id));
      } catch (_) {/* best-effort */}
    }));
  }

  /// Ingests a track's ALBUM, which is what actually upserts the catalog.
  ///
  /// PROVEN 2026-08-11: `/v2/track/{deezerId}` returns data but does NOT write
  /// to Supabase — after calling it for CLASSY 101 (2216510797), BIAF <3
  /// (3936484551) and Chulo pt.2 (2328294525), `public.tracks` still held zero
  /// rows for all three. `/v2/albums/deezer/{albumDeezerId}` DOES upsert the
  /// whole album graph: one call created
  /// `a3d2fe3c-0b65-499e-b968-24f0e82cfed2` for CLASSY 101.
  ///
  /// That is also why "open the album first, then add" always worked — opening
  /// an album performs exactly this ingest as a side effect. Adding straight
  /// from Artist Top Tracks skipped it, so the track was never catalogued.
  ///
  /// Bounded and idempotent: capped, deduplicated by album, best-effort per
  /// album, and never retried here — the caller re-resolves once and then fails
  /// explicitly. The upsert is keyed by Deezer id server-side, so concurrent
  /// callers converge on ONE canonical row rather than creating duplicates.
  Future<void> ingestAlbums(Iterable<String?> albumDeezerIds) async {
    final ids = albumDeezerIds
        .map((e) => (e ?? '').trim())
        .where((e) => int.tryParse(e) != null)
        .toSet()
        .take(10) // one add must never become a burst of requests
        .toList();
    if (ids.isEmpty) return;
    await Future.wait(ids.map((id) async {
      try {
        await _api.getAlbumNormalizedByDeezerId(int.parse(id));
      } catch (_) {
        // Best-effort. A track whose album cannot be ingested becomes an
        // explicit localIntegrity failure upstream, never a silent drop.
      }
    }));
  }

  /// Records track identities we ALREADY hold authoritatively, so resolving
  /// them later needs no network.
  ///
  /// THE OFFLINE-MUTATION BLOCKER (Phase 3.4.12). Every cloud mutation resolves
  /// local tracks → catalog UUIDs before it can be journaled, and this cache was
  /// only ever filled as a side effect of a successful QUERY. A playlist that
  /// arrived through cloud hydration therefore had none of its tracks cached:
  /// the app knew each row's `track_id` and threw it away. Offline, resolution
  /// then failed for every track and `_resolveOrThrow` raised `localIntegrity`
  /// BEFORE the journaling wrapper ran — so an offline reorder was never queued
  /// at all, and no replay could ever fix it.
  ///
  /// Hydration reads exactly the mapping resolution needs, so it seeds it here.
  /// Purely additive and idempotent: it can only turn a future network lookup
  /// into a cache hit.
  Future<void> seedTrackIdentities({
    Map<String, String> byDeezerId = const {},
    Map<String, String> byVideoId = const {},
  }) async {
    await _ensureLoaded();
    var tracksChanged = false;
    byDeezerId.forEach((deezerId, uuid) {
      final key = deezerId.trim();
      if (!_isValidDeezerId(key) || uuid.isEmpty) return;
      if (_trackCache[key] == uuid) return;
      _trackCache[key] = uuid;
      tracksChanged = true;
    });
    var videosChanged = false;
    byVideoId.forEach((videoId, uuid) {
      final key = videoId.trim();
      if (key.isEmpty || uuid.isEmpty) return;
      if (_videoIdCache[key] == uuid) return;
      _videoIdCache[key] = uuid;
      videosChanged = true;
    });
    if (tracksChanged) await _persist(_kTracksCache, _trackCache);
    if (videosChanged) await _persist(_kVideoIdsCache, _videoIdCache);
  }

  Future<Map<String, String>> resolveTracksByVideoId(
      Iterable<String?> videoIds) async {
    await _ensureLoaded();
    final result = <String, String>{};
    final toQuery = <String>{};

    for (final raw in videoIds) {
      final key = (raw ?? '').trim();
      if (key.isEmpty) continue;
      final cached = _videoIdCache[key];
      if (cached != null) {
        result[key] = cached;
      } else {
        toQuery.add(key);
      }
    }
    if (toQuery.isEmpty) return result;

    try {
      final rows = await _client
          .from('tracks')
          .select('id, preferred_youtube_video_id')
          .inFilter('preferred_youtube_video_id', toQuery.toList());
      var changed = false;
      for (final row in (rows as List)) {
        final uuid = row['id']?.toString();
        final vid = row['preferred_youtube_video_id']?.toString();
        if (uuid == null || uuid.isEmpty || vid == null || vid.isEmpty) continue;
        _videoIdCache[vid] = uuid;
        result[vid] = uuid;
        changed = true;
      }
      if (changed) await _persist(_kVideoIdsCache, _videoIdCache);
    } catch (_) {
      // Return whatever was cached; the caller reports unresolved tracks
      // explicitly rather than dropping them.
    }
    return result;
  }

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
