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
    // Scope DEVICE-LOCAL pin state to this account so pins never leak across
    // accounts on the same device (Phase 3.3.6). Safe to set even without a repo.
    HiveStorage.setCurrentAccount(userId);
    if (_repo == null) {
      _loadData();
      return;
    }
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
    // Stamp the canonical owner on any playlist that predates ownership (derive
    // owner from the current profile when missing — Phase 3.3.6). Idempotent.
    if (userId != null) {
      await HiveStorage.migratePlaylists(ownerId: userId);
    }
    _loadData();
  }
  
  List<Artist> _followedArtists = [];
  List<Artist> get followedArtists => _followedArtists;

  /// Dedupe followed artists (by Deezer id, then UUID) and drop entries that
  /// cannot navigate to an artist screen (no Deezer id and no UUID). §13.
  static List<Artist> _dedupeNavigableArtists(List<Artist> list) {
    final seen = <String>{};
    final out = <Artist>[];
    for (final a in list) {
      final id = a.id.trim();
      final uuid = (a.uuid ?? '').trim();
      if (id.isEmpty && uuid.isEmpty) continue; // un-navigable
      final key = id.isNotEmpty ? 'd:$id' : 'u:$uuid';
      if (!seen.add(key)) continue; // duplicate
      out.add(a);
    }
    return out;
  }

  List<Genre> _followedGenres = [];
  List<Genre> get followedGenres => _followedGenres;

  void _loadData() {
    _likedTracks = HiveStorage.getLikedTracks();
    _playlists = HiveStorage.getPlaylists();
    _savedAlbums = HiveStorage.getSavedAlbums();
    // Phase 3.3 §13: dedupe followed artists and drop any that can't navigate
    // (no Deezer id AND no canonical UUID) so Home never renders dead cards.
    _followedArtists = _dedupeNavigableArtists(HiveStorage.getFollowedArtists());
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
      // Phase 3.3.6: stamp the canonical owner + cloud-ready defaults. Username
      // is display-only (the pill falls back to the live profile); the id is the
      // durable ownership identity.
      ownerId: HiveStorage.currentAccountId,
      visibility: PlaylistVisibility.private,
      isCollaborative: false,
      trackPositions: const [],
    );
    await HiveStorage.savePlaylist(newPlaylist);
    _loadData();
  }
  
  Future<void> addToPlaylist(Playlist playlist, Track track) async {
    // Check for duplicates
    if (!playlist.tracks.any((t) => t.id == track.id)) {
      // Appended after the current maximum position (list end); positions are
      // re-normalized on persist so they stay contiguous with no duplicates.
      playlist.tracks.add(track);
      await _persistPlaylist(playlist);
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
      await _persistPlaylist(playlist);
    }
  }

  Future<void> removeFromPlaylist(Playlist playlist, Track track) async {
    // Removal never corrupts the remaining order — positions are re-normalized.
    playlist.tracks.removeWhere((t) => t.id == track.id);
    await _persistPlaylist(playlist);
  }

  /// Commit a manually-reordered track list (Phase 3.3.6). Called ONLY when the
  /// user presses Save in Edit Order mode — reordering is staged locally in the
  /// screen until then, so cancelling/back retains the previously committed
  /// order. Explicit positions are normalized (0-based, contiguous, no dupes)
  /// and persisted to Hive; the cloud seam is invoked for Phase 3.4.
  Future<void> commitPlaylistOrder(Playlist playlist, List<Track> newOrder) async {
    playlist.tracks
      ..clear()
      ..addAll(newOrder);
    await _persistPlaylist(playlist);
    // Cloud-ready seam — local only in this phase (no Supabase call yet).
    await _repo?.updatePlaylistTrackPositions(
        playlist.id, playlist.normalizedPositions());
  }

  /// Persist a playlist with normalized explicit track positions, then reload so
  /// the in-memory list reflects the stored object.
  Future<void> _persistPlaylist(Playlist playlist) async {
    final normalized = playlist.withNormalizedPositions();
    await HiveStorage.savePlaylist(normalized);
    _loadData();
  }
  
  Future<void> deletePlaylist(Playlist playlist) async {
    await playlist.delete();
    _loadData();
  }

  Future<void> renamePlaylist(Playlist playlist, String newName) async {
    // copyWith preserves owner/collaborators/visibility/positions (Phase 3.3.6).
    await HiveStorage.savePlaylist(playlist.copyWith(name: newName));
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
