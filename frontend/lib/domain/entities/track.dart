import 'package:hive/hive.dart';
import '../../core/utils/string_utils.dart';

part 'track.g.dart';

@HiveType(typeId: 0)
class Track extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String title;

  @HiveField(2)
  final String artistName;

  @HiveField(3)
  final String albumId;

  @HiveField(4)
  final String albumTitle;

  @HiveField(5)
  final String artworkUrl;

  @HiveField(6)
  final String? previewUrl;

  @HiveField(7)
  final int duration;

  @HiveField(8)
  final String? artistId;

  @HiveField(9)
  final List<Map<String, String>>? artists;

  @HiveField(10)
  final bool isExplicit;

  /// Deezer track id (from the v2 payload's top-level `id`). Used ONLY to
  /// resolve this track to its Supabase `tracks.id` UUID for cloud library
  /// sync. Nullable + additive: pre-3.2A Hive records read back as null and
  /// simply stay local-only (see docs/features/library.md, CatalogResolver).
  @HiveField(11)
  final String? deezerTrackId;

  Track({
    required this.id,
    required this.title,
    required this.artistName,
    required this.albumId,
    required this.albumTitle,
    required this.artworkUrl,
    this.previewUrl,
    required this.duration,
    this.artistId,
    this.artists,
    this.isExplicit = false,
    this.deezerTrackId,
  });

  /// Single source of truth for the artist subtitle line shown in all UIs.
  /// Reads from [artists] list (filtering view-count strings), joins with ", ".
  /// Falls back to [artistName] if the list is absent or yields nothing.
  String get displayArtist {
    if (artists != null && artists!.isNotEmpty) {
      final names = artists!
          .map((a) => a['name'] ?? '')
          .where((n) => n.isNotEmpty && !isViewCountString(n))
          .toList();
      if (names.isNotEmpty) return formatArtistNames(names.cast<String>());
    }
    // Fallback: artistName may already be joined with " • " from an old mapper;
    // replace any bullet separators with ", " for a consistent look.
    if (artistName.isNotEmpty) {
      return artistName.replaceAll(' • ', ', ');
    }
    return 'Unknown Artist';
  }

  // Helper to standardizing empty/loading state if needed
  factory Track.empty() => Track(
    id: '',
    title: '',
    artistName: '',
    albumId: '',
    albumTitle: '',
    artworkUrl: '',
    duration: 0,
    artists: [],
    isExplicit: false,
  );

  Track copyWith({
    String? id,
    String? title,
    String? artistName,
    String? albumId,
    String? albumTitle,
    String? artworkUrl,
    String? previewUrl,
    int? duration,
    String? artistId,
    List<Map<String, String>>? artists,
    bool? isExplicit,
    String? deezerTrackId,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      artistName: artistName ?? this.artistName,
      albumId: albumId ?? this.albumId,
      albumTitle: albumTitle ?? this.albumTitle,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      previewUrl: previewUrl ?? this.previewUrl,
      duration: duration ?? this.duration,
      artistId: artistId ?? this.artistId,
      artists: artists ?? this.artists,
      isExplicit: isExplicit ?? this.isExplicit,
      deezerTrackId: deezerTrackId ?? this.deezerTrackId,
    );
  }
}
