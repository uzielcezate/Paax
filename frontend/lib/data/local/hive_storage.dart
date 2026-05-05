import 'package:hive_flutter/hive_flutter.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/entities/artist.dart'; 

class HiveStorage {
  static const String likedTracksBox      = 'liked_tracks';
  static const String playlistsBox         = 'playlists';
  static const String savedAlbumsBox       = 'saved_albums';
  static const String userBox              = 'user_profile';
  static const String settingsBox          = 'settings';
  static const String recentSearchesBox    = 'recent_searches';
  static const String followedArtistsBox   = 'followed_artists';
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
    } catch (e) {
      // Adapters might be registered already if hot restart
    }
    
    await Hive.openBox<Track>(likedTracksBox);
    await Hive.openBox<Playlist>(playlistsBox);
    await Hive.openBox<SavedAlbum>(savedAlbumsBox);
    await Hive.openBox<UserProfile>(userBox);
    await Hive.openBox<Artist>(followedArtistsBox);
    await Hive.openBox(settingsBox);
    await Hive.openBox<String>(recentSearchesBox);
    await Hive.openBox<Track>(recentlyPlayedBox);
    // Stream URL cache — stores resolved Worker URLs for fast repeat plays
    await Hive.openBox(streamCandidatesBox);

    // Run one-time migration to fix duplicates from old .add() calls
    await _deduplicateLikedTracks();
    await _deduplicateRecentlyPlayed();
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
  
  static bool isArtistFollowed(String id) {
    return _artists.containsKey(id);
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
  
  static Future<void> clearAll() async {
    await _liked.clear();
    await _playlists.clear();
    await _albums.clear();
    await _artists.clear();
    await _userProfileBox.clear();
    await _settings.clear();
    await _recentlyPlayed.clear();
  }

}
