import 'package:flutter/material.dart';
import '../../data/local/hive_storage.dart';
import '../../data/repositories/library_repository.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/genre.dart';

class LibraryController extends ChangeNotifier {
  List<Track> _likedTracks = [];
  List<Playlist> _playlists = [];
  List<SavedAlbum> _savedAlbums = [];
  Set<String> _hiddenTrackIds = {};
  Map<String, int> _pinnedPlaylistMap = {};

  /// Phase 3.2A — optional cloud-sync repository. Null keeps the controller
  /// purely local (existing tests/usages compile unchanged).
  final LibraryRepository? _repo;

  List<Track> get likedTracks => _likedTracks;
  List<Playlist> get playlists => _playlists;
  List<SavedAlbum> get savedAlbums => _savedAlbums;

  LibraryController([this._repo]) {
    _loadData();
  }

  /// Tracks the last auth identity handled so a ProxyProvider can safely call
  /// [onUserSession] on every AuthController notification without re-hydrating.
  String? _sessionUid;
  bool _sessionUidSet = false;

  /// Wire the auth flow to this: pushes any pending ops, hydrates cloud data
  /// into Hive, runs the one-time migration, then reloads from Hive. No-op when
  /// no repository was injected. Idempotent per identity — repeated calls with
  /// the same user id are ignored. Never throws to the UI.
  Future<void> onUserSession(String? userId) async {
    if (_repo == null) return;
    if (_sessionUidSet && userId == _sessionUid) return; // same identity — skip
    final isAccountSwitch = _sessionUidSet && _sessionUid != null && userId != _sessionUid;
    _sessionUid = userId;
    _sessionUidSet = true;
    // On a real account switch the repo clears the local boxes and rehydrates;
    // drop the previous account's in-memory lists IMMEDIATELY so its data is
    // never shown to the new user during the async sync window.
    if (isAccountSwitch) {
      _likedTracks = [];
      _savedAlbums = [];
      _followedArtists = [];
      _followedGenres = [];
      _hiddenTrackIds = {};
      notifyListeners();
    }
    try {
      await _repo.onUserSession(userId);
    } catch (_) {
      // Cloud sync is best-effort; local library is already authoritative.
    }
    _loadData();
  }
  
  List<Artist> _followedArtists = [];
  List<Artist> get followedArtists => _followedArtists;

  List<Genre> _followedGenres = [];
  List<Genre> get followedGenres => _followedGenres;

  void _loadData() {
    _likedTracks = HiveStorage.getLikedTracks();
    _playlists = HiveStorage.getPlaylists();
    _savedAlbums = HiveStorage.getSavedAlbums();
    _followedArtists = HiveStorage.getFollowedArtists();
    _followedGenres = HiveStorage.getFollowedGenres();
    _hiddenTrackIds = HiveStorage.getHiddenTrackIds();
    _pinnedPlaylistMap = HiveStorage.getPinnedPlaylistMap();
    // Clean up stale pinned entries for deleted playlists
    final existingIds = _playlists.map((p) => p.id).toSet();
    HiveStorage.cleanPinnedPlaylists(existingIds);
    notifyListeners();
  }

  Future<void> toggleFollowArtist(Artist artist) async {
    await HiveStorage.toggleFollowArtist(artist);
    _loadData();
    // Fire-and-forget cloud sync with the post-toggle state.
    _repo?.pushFollow(artist, nowFollowed: HiveStorage.isArtistFollowed(artist.id));
  }

  bool isArtistFollowed(String id) {
    return HiveStorage.isArtistFollowed(id);
  }

  Future<void> toggleFollowGenre(Genre genre) async {
    await HiveStorage.toggleFollowGenre(genre);
    _loadData();
    // Fire-and-forget cloud sync with the post-toggle state.
    _repo?.pushFollowGenre(genre,
        nowFollowed: HiveStorage.isGenreFollowed(genre.id));
  }

  bool isGenreFollowed(String deezerId) {
    return HiveStorage.isGenreFollowed(deezerId);
  }

  Future<void> toggleLike(Track track) async {
    print("LibraryController: Toggling like for ${track.title} (ID: ${track.id})");
    // Ensure we work with ID
    await HiveStorage.toggleLike(track);
    _loadData();
    _repo?.pushLike(track, nowLiked: HiveStorage.isLiked(track.id));
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
      coverColor: 0xFF2A2A2E, // Default neutral dark gray
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

  /// Reorder a track within a playlist. Persists new order immediately.
  Future<void> reorderPlaylistTrack(Playlist playlist, int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    final track = playlist.tracks.removeAt(oldIndex);
    playlist.tracks.insert(newIndex, track);
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
    _repo?.pushSave(album, nowSaved: HiveStorage.isAlbumSaved(album.albumId));
  }
  
  bool isAlbumSaved(String id) {
    return HiveStorage.isAlbumSaved(id);
  }

  // ── Hidden Tracks ──

  bool isHidden(String trackId) => _hiddenTrackIds.contains(trackId);

  Future<void> toggleHideTrack(String trackId) async {
    await HiveStorage.toggleHideTrack(trackId);
    _hiddenTrackIds = HiveStorage.getHiddenTrackIds();
    notifyListeners();
    // Best-effort: recover the Track (for its Deezer id) from the loaded liked
    // list so the cloud side can resolve it. If not found, pushHide is a
    // documented local-only no-op.
    Track? track;
    for (final t in _likedTracks) {
      if (t.id == trackId) {
        track = t;
        break;
      }
    }
    _repo?.pushHide(trackId,
        nowHidden: HiveStorage.isTrackHidden(trackId), track: track);
  }

  // ── Pinned Playlists ──

  bool isPlaylistPinned(String playlistId) =>
      _pinnedPlaylistMap.containsKey(playlistId);

  int get pinnedCount => _pinnedPlaylistMap.length;

  /// Returns the pinnedAt timestamp for sorting. 0 if not pinned.
  int pinnedAt(String playlistId) => _pinnedPlaylistMap[playlistId] ?? 0;

  /// Toggle pin. Returns true=pinned, false=unpinned, null=limit reached.
  Future<bool?> togglePinPlaylist(String playlistId) async {
    final result = await HiveStorage.togglePinPlaylist(playlistId);
    _pinnedPlaylistMap = HiveStorage.getPinnedPlaylistMap();
    notifyListeners();
    return result;
  }
}
