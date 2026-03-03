import 'package:flutter/material.dart';
import '../../data/local/hive_storage.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';

class LibraryController extends ChangeNotifier {
  List<Track> _likedTracks = [];
  List<Playlist> _playlists = [];
  List<SavedAlbum> _savedAlbums = [];
  
  List<Track> get likedTracks => _likedTracks;
  List<Playlist> get playlists => _playlists;
  List<SavedAlbum> get savedAlbums => _savedAlbums;
  
  LibraryController() {
    _loadData();
  }
  
  List<Artist> _followedArtists = [];
  List<Artist> get followedArtists => _followedArtists;

  void _loadData() {
    _likedTracks = HiveStorage.getLikedTracks();
    _playlists = HiveStorage.getPlaylists();
    _savedAlbums = HiveStorage.getSavedAlbums();
    _followedArtists = HiveStorage.getFollowedArtists();
    notifyListeners();
  }

  Future<void> toggleFollowArtist(Artist artist) async {
    await HiveStorage.toggleFollowArtist(artist);
    _loadData();
  }

  bool isArtistFollowed(String id) {
    return HiveStorage.isArtistFollowed(id);
  }
  
  Future<void> toggleLike(Track track) async {
    print("LibraryController: Toggling like for ${track.title} (ID: ${track.id})");
    // Ensure we work with ID
    await HiveStorage.toggleLike(track);
    _loadData();
  }
  
  bool isLiked(Track track) {
    return HiveStorage.isLiked(track.id);
  }
  // Helper for ID check
  bool isLikedId(String id) {
    return HiveStorage.isLiked(id);
  }
  
  Future<void> createPlaylist(String name) async {
    final newPlaylist = Playlist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      tracks: [],
      createdAt: DateTime.now(),
      coverColor: 0xFF9D4EDD, // Default purple
    );
    await HiveStorage.savePlaylist(newPlaylist);
    _loadData();
  }
  
  Future<void> addToPlaylist(Playlist playlist, Track track) async {
    // Check for duplicates
    if (!playlist.tracks.any((t) => t.id == track.id)) {
      playlist.tracks.add(track);
      await playlist.save(); 
      notifyListeners();
    }
  }

  Future<void> addTracksToPlaylist(Playlist playlist, List<Track> tracks) async {
    bool changed = false;
    for (var track in tracks) {
      if (!playlist.tracks.any((t) => t.id == track.id)) {
        playlist.tracks.add(track);
        changed = true;
      }
    }
    if (changed) {
      await playlist.save();
      notifyListeners();
    }
  }

  Future<void> removeFromPlaylist(Playlist playlist, Track track) async {
    playlist.tracks.removeWhere((t) => t.id == track.id);
    await playlist.save();
    notifyListeners();
  }
  
  Future<void> deletePlaylist(Playlist playlist) async {
    await playlist.delete();
    _loadData();
  }

  Future<void> renamePlaylist(Playlist playlist, String newName) async {
    // Create copy with new name
    final updated = Playlist(
      id: playlist.id,
      name: newName,
      tracks: playlist.tracks,
      createdAt: playlist.createdAt,
      coverColor: playlist.coverColor
    );
    // Overwrite using ID (assuming ID is key)
    await HiveStorage.savePlaylist(updated);
    _loadData();
  }
  
  Future<void> toggleSaveAlbum(SavedAlbum album) async {
    await HiveStorage.toggleSaveAlbum(album);
    _loadData();
  }
  
  bool isAlbumSaved(String id) {
    return HiveStorage.isAlbumSaved(id);
  }
}
