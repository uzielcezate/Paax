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
    this.uuid,
    this.platformFollowers,
  });

  // Non-persisted params for pagination
  final String? albumsParams; // "View All" params for albums
  final String? singlesParams; // "View All" params for singles

  // ── Phase 3.3: normalized-catalog fields (transient, NOT persisted to Hive) ──
  /// Canonical Supabase catalog UUID for this artist, when resolved via the
  /// normalized `/v2` catalog. `id` remains the Deezer id (navigation key);
  /// this carries the durable catalog identity alongside it.
  final String? uuid;

  /// Paax platform follower count (`artists.platform_followers_count`), shown
  /// in the artist header instead of the external Deezer fan count. Null when
  /// unknown (e.g. an artist loaded only from a legacy/Hive source).
  final int? platformFollowers;

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
    String? uuid,
    int? platformFollowers,
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
      uuid: uuid ?? this.uuid,
      platformFollowers: platformFollowers ?? this.platformFollowers,
    );
  }
}
