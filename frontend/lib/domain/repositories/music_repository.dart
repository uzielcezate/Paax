import '../entities/track.dart';
import '../entities/saved_album.dart';
import '../entities/artist.dart';

abstract class MusicRepository {
  /// Optional: warm the HTTP connection (DNS/TLS/keep-alive) ahead of the first
  /// search so it feels instant. No-op-safe to call repeatedly.
  Future<void> prewarm() => Future<void>.value();

  Future<List<Track>> searchTracks(String query);
  Future<List<SavedAlbum>> searchAlbums(String query);
  Future<List<Artist>> searchArtists(String query);

  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getCharts([String country = 'US']);
  Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> getGenreContent(String genre, String country);
  Future<({List<SavedAlbum> playlists, List<Track> tracks, List<Artist> artists})> getGenrePage(String slug);

  Future<Artist> getArtist(String id);
  /// Returns the fast CORE artist profile (identity, artwork, follower count,
  /// discography, latest release) from the normalized catalog, WITHOUT the
  /// eager top-tracks/related fetch. Use [getArtistExtras] for those.
  Future<Artist> getArtistBasic(String id);
  /// Background-loadable extras: top tracks (playable) + related artists, from
  /// the eager legacy path. Also returns the legacy albums/singles so the
  /// artist-detail can backfill its discography if the normalized core came back
  /// empty (partial ingest). Kept off the artist-detail critical path (§2).
  Future<({
    List<Track> topTracks,
    List<Artist> relatedArtists,
    List<SavedAlbum> albums,
    List<SavedAlbum> singles,
  })> getArtistExtras(String id);
  /// Enriches album/singles release metadata (years, types). Can run in background.
  Future<({List<SavedAlbum> albums, List<SavedAlbum> singles})> enrichArtistReleases({
    required List<SavedAlbum> existingAlbums,
    required List<SavedAlbum> existingSingles,
    required List<dynamic> rawSongs,
  });
  Future<List<SavedAlbum>> getArtistAlbums(String id);
  Future<(List<SavedAlbum>, String?)> getArtistAlbumsPage(String id, String? params, String? token);
  Future<List<SavedAlbum>> getArtistSingles(String id);
  Future<List<Track>> getArtistTopTracks(String id);
  Future<List<Artist>> getRelatedArtists(String id);

  Future<SavedAlbum> getAlbum(String id);
  Future<List<Track>> getAlbumTracks(String id);
  /// Overlay real per-track credits from the normalized catalog (Supabase
  /// track_artists) onto an album's tracks, keeping each track's playback
  /// videoId. Runs off the album-open critical path (progressive, §3.3.4).
  Future<SavedAlbum> enrichAlbumCredits(SavedAlbum album);

  Future<Track> getTrack(String id);
  
  // For playlists/watch
  Future<List<Track>> getWatchPlaylist(String videoId);
  Future<String?> getStreamUrl(String trackId);
}
