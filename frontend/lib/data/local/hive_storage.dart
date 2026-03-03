import 'package:hive_flutter/hive_flutter.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/entities/artist.dart'; 

class HiveStorage {
  static const String likedTracksBox = 'liked_tracks';
  static const String playlistsBox = 'playlists';
  static const String savedAlbumsBox = 'saved_albums';
  static const String userBox = 'user_profile';
  static const String settingsBox = 'settings';
  static const String recentSearchesBox = 'recent_searches';
  static const String followedArtistsBox = 'followed_artists';
  static const String recentlyPlayedBox = 'recently_played';

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
    // Remove if exists to bubble up
    final existingKey = _recentlyPlayed.keys.firstWhere(
      (k) {
         final val = _recentlyPlayed.get(k);
         return val?.id == track.id;
      }, orElse: () => null
    );
    if (existingKey != null) {
      await _recentlyPlayed.delete(existingKey);
    }
    
    // Store a COPY to avoid Hive "same instance in multiple boxes" error
    await _recentlyPlayed.add(track.copyWith());
    
    // Keep max 20
    if (_recentlyPlayed.length > 20) {
      await _recentlyPlayed.deleteAt(0);
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
      // Store a COPY to avoid Hive error
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
