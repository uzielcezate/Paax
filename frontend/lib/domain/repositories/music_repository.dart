import '../entities/track.dart';
import '../entities/saved_album.dart';
import '../entities/artist.dart';

abstract class MusicRepository {
  Future<List<Track>> searchTracks(String query);
  Future<List<SavedAlbum>> searchAlbums(String query);
  Future<List<Artist>> searchArtists(String query);

  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getCharts([String country = 'US']);
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getGenreContent(String genre, String country);
  Future<({List<SavedAlbum> playlists, List<Track> tracks, List<Artist> artists})> getGenrePage(String slug);

  Future<Artist> getArtist(String id);
  Future<List<SavedAlbum>> getArtistAlbums(String id);
  Future<(List<SavedAlbum>, String?)> getArtistAlbumsPage(String id, String? params, String? token);
  Future<List<SavedAlbum>> getArtistSingles(String id);
  Future<List<Track>> getArtistTopTracks(String id);
  Future<List<Artist>> getRelatedArtists(String id);

  Future<SavedAlbum> getAlbum(String id);
  Future<List<Track>> getAlbumTracks(String id);

  Future<Track> getTrack(String id);
  
  // For playlists/watch
  Future<List<Track>> getWatchPlaylist(String videoId);
  Future<String?> getStreamUrl(String trackId);
}
