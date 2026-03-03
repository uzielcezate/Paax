
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
  });
}
