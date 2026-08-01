import 'package:hive_flutter/hive_flutter.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/genre.dart';

class HiveStorage {
  static const String likedTracksBox      = 'liked_tracks';
  static const String playlistsBox         = 'playlists';
  static const String savedAlbumsBox       = 'saved_albums';
  static const String userBox              = 'user_profile';
  static const String settingsBox          = 'settings';
  static const String recentSearchesBox    = 'recent_searches';
  static const String followedArtistsBox   = 'followed_artists';
  static const String followedGenresBox    = 'followed_genres';
  static const String recentlyPlayedBox    = 'recently_played';
  /// Persisted stream URL cache used by StreamCache / MediaResolver.
  static const String streamCandidatesBox  = 'stream_candidates';

  static Future<void> init() async {
    await Hive.initFlutter();
    
    // Register Adapters
    try {
      Hive.registerAdapter(TrackAdapter());
      Hive.registerAdapter(PlaylistAdapter());
      Hive.registerAdapter(SavedAlbumAdapter());
      Hive.registerAdapter(UserProfileAdapter());
      Hive.registerAdapter(ArtistAdapter());
      Hive.registerAdapter(GenreAdapter());
    } catch (e) {
      // Adapters might be registered already if hot restart
    }
    
    await Hive.openBox<Track>(likedTracksBox);
    await Hive.openBox<Playlist>(playlistsBox);
    await Hive.openBox<SavedAlbum>(savedAlbumsBox);
    await Hive.openBox<UserProfile>(userBox);
    await Hive.openBox<Artist>(followedArtistsBox);
    await Hive.openBox<Genre>(followedGenresBox);
    await Hive.openBox(settingsBox);
    await Hive.openBox<String>(recentSearchesBox);
    await Hive.openBox<Track>(recentlyPlayedBox);
    // Stream URL cache — stores resolved Worker URLs for fast repeat plays
    await Hive.openBox(streamCandidatesBox);

    // Run one-time migration to fix duplicates from old .add() calls
    await _deduplicateLikedTracks();
    await _deduplicateRecentlyPlayed();
    // Phase 3.3.6 — idempotent upgrades (safe to run every launch).
    await _migratePinnedScopes();
    await migratePlaylists();
  }

  /// Removes duplicate liked tracks caused by old `.add()` (auto-key) saves.
  /// Keeps the entry with the richest artist data for each unique track ID.
  static Future<void> _deduplicateLikedTracks() async {
    final box = Hive.box<Track>(likedTracksBox);
    final Map<String, MapEntry<dynamic, Track>> bestByTrackId = {};

    // Scan all entries, keeping the one with the most artists per unique track ID
    for (final key in box.keys) {
      final track = box.get(key);
      if (track == null) continue;

      final existing = bestByTrackId[track.id];
      if (existing == null ||
          (track.artists?.length ?? 0) > (existing.value.artists?.length ?? 0)) {
        bestByTrackId[track.id] = MapEntry(key, track);
      }
    }

    // If count doesn't match, we have duplicates
    if (bestByTrackId.length < box.length) {
      // Clear and re-add using strict ID keys
      await box.clear();
      for (final entry in bestByTrackId.values) {
        await box.put(entry.value.id, entry.value.copyWith());
      }
    }
  }

  /// Removes duplicate recently played tracks.
  static Future<void> _deduplicateRecentlyPlayed() async {
    final box = Hive.box<Track>(recentlyPlayedBox);
    final Map<String, Track> bestByTrackId = {};

    for (final key in box.keys) {
      final track = box.get(key);
      if (track == null) continue;

      final existing = bestByTrackId[track.id];
      if (existing == null ||
          (track.artists?.length ?? 0) > (existing.artists?.length ?? 0)) {
        bestByTrackId[track.id] = track;
      }
    }

    if (bestByTrackId.length < box.length) {
      await box.clear();
      for (final entry in bestByTrackId.entries) {
        await box.put(entry.key, entry.value.copyWith());
      }
    }
  }
  
  // ... (existing code)

  // Recent Searches
  static Box<String> get _recentSearches => Hive.box<String>(recentSearchesBox);

  static List<String> getRecentSearches() {
    return _recentSearches.values.toList().reversed.toList();
  }

  static Future<void> addRecentSearch(String query) async {
    if (query.isEmpty) return;
    final existingKey = _recentSearches.keys.firstWhere(
      (k) => _recentSearches.get(k) == query, orElse: () => null
    );
    if (existingKey != null) {
      await _recentSearches.delete(existingKey);
    }
    
    await _recentSearches.add(query);
    
    if (_recentSearches.length > 10) {
      await _recentSearches.deleteAt(0);
    }
  }

  static Future<void> clearRecentSearches() async {
    await _recentSearches.clear();
  }
  
  // Recently Played Tracks
  static Box<Track> get _recentlyPlayed => Hive.box<Track>(recentlyPlayedBox);

  static List<Track> getRecentlyPlayed() {
    return _recentlyPlayed.values.toList().reversed.toList();
  }

  static Future<void> addRecentlyPlayed(Track track) async {
    // Upsert by track ID — delete old entry first to re-order (most recent last)
    if (_recentlyPlayed.containsKey(track.id)) {
      await _recentlyPlayed.delete(track.id);
    }
    
    // Store a COPY to avoid Hive "same instance in multiple boxes" error
    // Use .put() with track.id as key to prevent duplicates
    await _recentlyPlayed.put(track.id, track.copyWith());
    
    // Keep max 20 — trim oldest entries
    if (_recentlyPlayed.length > 20) {
      final keys = _recentlyPlayed.keys.toList();
      for (int i = 0; i < _recentlyPlayed.length - 20; i++) {
        await _recentlyPlayed.delete(keys[i]);
      }
    }
  }

  static Box<Track> get _liked => Hive.box<Track>(likedTracksBox);
  
  static List<Track> getLikedTracks() {
    return _liked.values.toList();
  }
  
  static Future<void> toggleLike(Track track) async {
    if (_liked.containsKey(track.id)) {
      await _liked.delete(track.id);
    } else {
      // Upsert: always use .put() with track.id as strict primary key.
      // This ensures metadata updates (e.g. artist name fixes) propagate
      // and prevents duplicate rows with different keys.
      await _liked.put(track.id, track.copyWith());
    }
  }
  
  static bool isLiked(String trackId) {
    return _liked.containsKey(trackId);
  }
  
  // Playlists
  static Box<Playlist> get _playlists => Hive.box<Playlist>(playlistsBox);
  
  static List<Playlist> getPlaylists() {
    return _playlists.values.toList();
  }
  
  static Future<void> savePlaylist(Playlist playlist) async {
    await _playlists.put(playlist.id, playlist);
  }
  
  static Future<void> deletePlaylist(String id) async {
    await _playlists.delete(id);
  }
  
  // Saved Albums
  static Box<SavedAlbum> get _albums => Hive.box<SavedAlbum>(savedAlbumsBox);
  
  static List<SavedAlbum> getSavedAlbums() {
    return _albums.values.toList();
  }
  
  static Future<void> toggleSaveAlbum(SavedAlbum album) async {
    if (_albums.containsKey(album.albumId)) {
      await _albums.delete(album.albumId);
    } else {
      // Upsert: strict albumId primary key prevents duplicate albums
      await _albums.put(album.albumId, album);
    }
  }
  
  static bool isAlbumSaved(String id) {
    return _albums.containsKey(id);
  }
  
  // Followed Artists
  static Box<Artist> get _artists => Hive.box<Artist>(followedArtistsBox);
  
  static List<Artist> getFollowedArtists() {
    return _artists.values.toList();
  }
  
  static Future<void> toggleFollowArtist(Artist artist) async {
    if (_artists.containsKey(artist.id)) {
      await _artists.delete(artist.id);
    } else {
      await _artists.put(artist.id, artist);
    }
  }

  /// Unconditional upsert of a followed artist (does NOT toggle). Used by
  /// cloud hydration to refresh a stored artist's artwork/uuid when the catalog
  /// now has an image the previously-stored entry lacked (Phase 3.3.1 §1).
  static Future<void> putFollowedArtist(Artist artist) async {
    await _artists.put(artist.id, artist);
  }

  /// The stored followed [Artist] for a Deezer id, or null.
  static Artist? getFollowedArtist(String id) => _artists.get(id);

  static bool isArtistFollowed(String id) {
    return _artists.containsKey(id);
  }

  // Followed Genres
  static Box<Genre> get _genres => Hive.box<Genre>(followedGenresBox);

  static List<Genre> getFollowedGenres() {
    return _genres.values.toList();
  }

  static Future<void> toggleFollowGenre(Genre genre) async {
    if (_genres.containsKey(genre.id)) {
      await _genres.delete(genre.id);
    } else {
      await _genres.put(genre.id, genre);
    }
  }

  static bool isGenreFollowed(String id) {
    return _genres.containsKey(id);
  }

  // User Profile
  static Box<UserProfile> get _userProfileBox => Hive.box<UserProfile>(userBox);
  
  static UserProfile? getUserProfile() {
    if (_userProfileBox.isEmpty) return null;
    return _userProfileBox.getAt(0);
  }
  
  static Future<void> saveUserProfile(UserProfile profile) async {
    await _userProfileBox.put(0, profile); // Single user
  }

  // Settings / Onboarding
  static Box get _settings => Hive.box(settingsBox);
  
  static bool get onboardingCompleted => _settings.get('onboarding_completed', defaultValue: false);
  static Future<void> setOnboardingCompleted(bool value) async => _settings.put('onboarding_completed', value);
  
  /// Phase 3.2A — clears the user-owned LIBRARY on account switch to prevent
  /// cross-account data leakage. Clears liked_tracks, saved_albums,
  /// followed_artists and recently_played boxes, and removes the
  /// `hidden_track_ids` key from settings. Intentionally LEAVES intact:
  /// playlists (device-local, not yet cloud-synced), user_profile, and the
  /// onboarding/pinned-playlist settings.
  static Future<void> clearLibraryBoxes() async {
    await _liked.clear();
    await _albums.clear();
    await _artists.clear();
    await _genres.clear();
    await _recentlyPlayed.clear();
    await _settings.delete(_hiddenTracksKey);
  }

  static Future<void> clearAll() async {
    await _liked.clear();
    await _playlists.clear();
    await _albums.clear();
    await _artists.clear();
    await _genres.clear();
    await _userProfileBox.clear();
    await _settings.clear();
    await _recentlyPlayed.clear();
  }
  // Hidden Tracks — stored as a list of track IDs in settings box
  static const String _hiddenTracksKey = 'hidden_track_ids';

  static Set<String> getHiddenTrackIds() {
    final list = _settings.get(_hiddenTracksKey, defaultValue: <String>[]);
    return Set<String>.from(list is List ? list.cast<String>() : <String>[]);
  }

  static Future<void> toggleHideTrack(String trackId) async {
    final ids = getHiddenTrackIds();
    if (ids.contains(trackId)) {
      ids.remove(trackId);
    } else {
      ids.add(trackId);
    }
    await _settings.put(_hiddenTracksKey, ids.toList());
  }

  static bool isTrackHidden(String trackId) {
    return getHiddenTrackIds().contains(trackId);
  }

  // ── Current account scope (Phase 3.3.6) ───────────────────────────
  //
  // The canonical id of the signed-in user, or null when signed out. Used to
  // stamp playlist owners AND to namespace DEVICE-LOCAL pin state per account so
  // one account's pins never leak into another on the same device. Set by
  // LibraryController.onUserSession.
  static String? _currentAccountId;
  static String? get currentAccountId => _currentAccountId;

  /// The pin namespace: the current account id, or '_local' when signed out.
  static String get _pinScope => _currentAccountId ?? '_local';

  static void setCurrentAccount(String? userId) {
    _currentAccountId = (userId != null && userId.trim().isNotEmpty) ? userId : null;
  }

  // Pinned Playlists — DEVICE-LOCAL preference, NEVER part of any cloud payload.
  // Stored per account scope as {scope: {playlistId: pinnedAtMillis}} so pins
  // are isolated across accounts on the same device.
  static const String _pinnedScopesKey = 'pinned_playlist_scopes';
  static const String _legacyPinnedKey = 'pinned_playlist_map';
  static const int maxPinnedPlaylists = 5;

  static Map<String, Map<String, int>> _allPinnedScopes() {
    final raw = _settings.get(_pinnedScopesKey);
    final out = <String, Map<String, int>>{};
    if (raw is Map) {
      raw.forEach((scope, inner) {
        if (inner is Map) {
          out[scope.toString()] = Map<String, int>.from(
            inner.map((k, v) => MapEntry(k.toString(), v is int ? v : 0)),
          );
        }
      });
    }
    return out;
  }

  static Future<void> _writePinnedScope(
      String scope, Map<String, int> map) async {
    final all = _allPinnedScopes();
    if (map.isEmpty) {
      all.remove(scope);
    } else {
      all[scope] = map;
    }
    await _settings.put(_pinnedScopesKey, all);
  }

  /// Returns {playlistId: pinnedAtMillisecondsSinceEpoch} for the CURRENT account.
  static Map<String, int> getPinnedPlaylistMap() {
    return _allPinnedScopes()[_pinScope] ?? <String, int>{};
  }

  static bool isPlaylistPinned(String playlistId) {
    return getPinnedPlaylistMap().containsKey(playlistId);
  }

  static int pinnedCount() => getPinnedPlaylistMap().length;

  /// Pin a playlist. Returns true if pinned, false if limit reached.
  static Future<bool> pinPlaylist(String playlistId) async {
    final map = getPinnedPlaylistMap();
    if (map.containsKey(playlistId)) return true; // already pinned
    if (map.length >= maxPinnedPlaylists) return false; // limit
    map[playlistId] = DateTime.now().millisecondsSinceEpoch;
    await _writePinnedScope(_pinScope, map);
    return true;
  }

  /// Unpin a playlist. Always succeeds.
  static Future<void> unpinPlaylist(String playlistId) async {
    final map = getPinnedPlaylistMap();
    map.remove(playlistId);
    await _writePinnedScope(_pinScope, map);
  }

  /// Toggle pin state. Returns true if now pinned, false if unpinned, null if limit.
  static Future<bool?> togglePinPlaylist(String playlistId) async {
    if (isPlaylistPinned(playlistId)) {
      await unpinPlaylist(playlistId);
      return false;
    } else {
      final ok = await pinPlaylist(playlistId);
      return ok ? true : null; // null = limit reached
    }
  }

  /// Clean up pinned entries for playlists that no longer exist (current scope).
  static Future<void> cleanPinnedPlaylists(Set<String> existingIds) async {
    final map = getPinnedPlaylistMap();
    final cleaned = Map<String, int>.from(map)
      ..removeWhere((id, _) => !existingIds.contains(id));
    if (cleaned.length != map.length) {
      await _writePinnedScope(_pinScope, cleaned);
    }
  }

  /// One-time move of legacy flat pins → the '_local' scope. Idempotent: the
  /// legacy key is deleted after the move, so subsequent runs are no-ops.
  static Future<void> _migratePinnedScopes() async {
    final legacy = _settings.get(_legacyPinnedKey);
    if (legacy is Map && legacy.isNotEmpty) {
      final all = _allPinnedScopes();
      final localMap = all['_local'] ?? <String, int>{};
      legacy.forEach((k, v) {
        localMap.putIfAbsent(k.toString(), () => v is int ? v : 0);
      });
      all['_local'] = localMap;
      await _settings.put(_pinnedScopesKey, all);
    }
    if (_settings.containsKey(_legacyPinnedKey)) {
      await _settings.delete(_legacyPinnedKey);
    }
  }

  /// Idempotent upgrade of pre-3.3.6 playlists: fill missing owner id, default
  /// visibility (private) + isCollaborative (false), empty collaborators, and
  /// derive explicit zero-based positions from the current committed track order
  /// when absent. Preserves ids/tracks/title/cover/videoIds; never duplicates or
  /// deletes. Running twice with the same inputs yields exactly the same state.
  static Future<void> migratePlaylists({String? ownerId}) async {
    final box = _playlists;
    for (final key in box.keys.toList()) {
      final p = box.get(key);
      if (p == null) continue;

      final needsOwner = (p.ownerId == null || p.ownerId!.isEmpty) &&
          (ownerId != null && ownerId.isNotEmpty);
      final needsVisibility = p.visibility == null;
      final needsCollab = p.isCollaborative == null;
      final needsCollabJson = p.collaboratorsJson == null;
      final needsPositions = p.trackPositions == null ||
          p.trackPositions!.length != p.tracks.length;

      if (!needsOwner &&
          !needsVisibility &&
          !needsCollab &&
          !needsCollabJson &&
          !needsPositions) {
        continue; // already upgraded — no-op
      }

      final updated = p.copyWith(
        ownerId: needsOwner ? ownerId : null, // copyWith keeps old when null
        visibility: p.visibility ?? PlaylistVisibility.private,
        isCollaborative: p.isCollaborative ?? false,
        collaboratorsJson: p.collaboratorsJson ?? '[]',
        trackPositions: needsPositions
            ? List<int>.generate(p.tracks.length, (i) => i)
            : p.trackPositions,
      );
      await box.put(key, updated);
    }
  }
}
