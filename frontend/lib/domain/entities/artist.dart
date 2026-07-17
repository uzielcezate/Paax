import 'package:hive/hive.dart';

part 'artist.g.dart';

@HiveType(typeId: 4)
class Artist extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String name;

  @HiveField(2)
  final String picture;


  @HiveField(3)
  final int nbFans;

  @HiveField(4)
  final List<dynamic> albums; // storing as dynamic to avoid circular dep issues with SavedAlbum in strict Hive gen, but ideally SavedAlbum

  @HiveField(5)
  final List<dynamic> singles;

  @HiveField(6)
  final List<dynamic> topTracks;

  @HiveField(7)
  final List<Artist> relatedArtists;

  Artist({
    required this.id,
    required this.name,
    required this.picture,
    this.nbFans = 0,
    this.albums = const [],
    this.singles = const [],
    this.topTracks = const [],
    this.relatedArtists = const [],
    this.albumsParams,
    this.singlesParams,
  });

  // Non-persisted params for pagination
  final String? albumsParams; // "View All" params for albums
  final String? singlesParams; // "View All" params for singles

  /// Creates a copy with selectively overridden fields.
  /// Used for progressive profile rendering (basic → enriched).
  Artist copyWith({
    String? id,
    String? name,
    String? picture,
    int? nbFans,
    List<dynamic>? albums,
    List<dynamic>? singles,
    List<dynamic>? topTracks,
    List<Artist>? relatedArtists,
    String? albumsParams,
    String? singlesParams,
  }) {
    return Artist(
      id: id ?? this.id,
      name: name ?? this.name,
      picture: picture ?? this.picture,
      nbFans: nbFans ?? this.nbFans,
      albums: albums ?? this.albums,
      singles: singles ?? this.singles,
      topTracks: topTracks ?? this.topTracks,
      relatedArtists: relatedArtists ?? this.relatedArtists,
      albumsParams: albumsParams ?? this.albumsParams,
      singlesParams: singlesParams ?? this.singlesParams,
    );
  }
}
