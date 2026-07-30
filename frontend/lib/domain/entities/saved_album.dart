
import 'package:hive/hive.dart';
import 'track.dart';

part 'saved_album.g.dart';

@HiveType(typeId: 2)
class SavedAlbum extends HiveObject {
  @HiveField(0)
  final String albumId;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String artistName;

  @HiveField(3)
  final String artworkUrl;

  @HiveField(4)
  final String? artistId;

  // Detailed fields (not necessarily persisted)
  final String? releaseDate;
  final String? label;
  final int? duration;
  final int? trackCount;
  final List<Track>? tracks;

  /// Normalized release type: 'album', 'single', or 'ep'.
  /// Not persisted to Hive.
  final String? releaseType;

  /// Structured artist list for multi-artist albums (e.g. collaborative albums).
  /// Each entry has 'name' and 'id'. Not persisted to Hive.
  final List<Map<String, String>>? artists;

  SavedAlbum({
    required this.albumId,
    required this.title,
    required this.artistName,
    required this.artworkUrl,
    this.artistId,
    this.releaseDate,
    this.label,
    this.duration,
    this.trackCount,
    this.tracks,
    this.releaseType,
    this.artists,
  });

  SavedAlbum copyWith({
    String? albumId,
    String? title,
    String? artistName,
    String? artworkUrl,
    String? artistId,
    String? releaseDate,
    String? label,
    int? duration,
    int? trackCount,
    List<Track>? tracks,
    String? releaseType,
    List<Map<String, String>>? artists,
  }) {
    return SavedAlbum(
      albumId: albumId ?? this.albumId,
      title: title ?? this.title,
      artistName: artistName ?? this.artistName,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      artistId: artistId ?? this.artistId,
      releaseDate: releaseDate ?? this.releaseDate,
      label: label ?? this.label,
      duration: duration ?? this.duration,
      trackCount: trackCount ?? this.trackCount,
      tracks: tracks ?? this.tracks,
      releaseType: releaseType ?? this.releaseType,
      artists: artists ?? this.artists,
    );
  }
}

