import 'package:hive/hive.dart';
import '../../domain/entities/track.dart';

part 'playlist.g.dart';

@HiveType(typeId: 1)
class Playlist extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final List<Track> tracks;

  @HiveField(3)
  final DateTime createdAt;
  
  @HiveField(4)
  final int? coverColor; // Store as int (0xAARRGGBB)

  Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
    this.coverColor,
  });
  // Helper for mosaic images
  List<String> get uniqueArtworkUrls {
    return tracks.map((t) => t.artworkUrl).where((url) => url.isNotEmpty).toSet().toList();
  }
  
  // Track IDs accessor for legacy compatibility if needed
  List<String> get trackIds => tracks.map((t) => t.id).toList();
}
