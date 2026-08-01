import 'dart:convert';
import 'package:hive/hive.dart';
import '../../domain/entities/track.dart';
import 'playlist_contributors.dart';

part 'playlist.g.dart';

/// Playlist visibility (future Supabase `playlists.visibility`).
class PlaylistVisibility {
  static const String private = 'private';
  static const String public = 'public';
}

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

  // ── Phase 3.3.6: cloud-ready ownership / collaboration / ordering ──
  // All additive + nullable so pre-3.3.6 Hive records read back cleanly and are
  // upgraded once by HiveStorage._migratePlaylists (idempotent).

  /// Canonical (Supabase) user id of the single owner. Null on legacy records
  /// until the migration derives it from the stored profile.
  @HiveField(5)
  final String? ownerId;

  /// Owner's username at write time (display convenience; the id is the durable
  /// identity). Null → the UI falls back to the current profile username.
  @HiveField(6)
  final String? ownerUsername;

  /// 'private' | 'public'. Independent of [isCollaborative]. Defaults to private.
  @HiveField(7)
  final String? visibility;

  /// Explicit collaboration capability flag — NOT inferred from the contributor
  /// count. A playlist may be collaborative with only the owner shown (e.g.
  /// while invitations are pending). Defaults to false.
  @HiveField(8)
  final bool? isCollaborative;

  /// Accepted+pending collaborator records serialized as a JSON array. Empty on
  /// all local playlists in this phase; the seam for Phase 3.4 cloud sync.
  @HiveField(9)
  final String? collaboratorsJson;

  /// Explicit zero-based positions parallel to [tracks] (`trackPositions[i]` is
  /// the stored position of `tracks[i]`). The stable cloud-ready order, kept
  /// normalized (contiguous 0..n-1, no duplicates) on every commit. Null on
  /// legacy records → derived from list order by the migration.
  @HiveField(10)
  final List<int>? trackPositions;

  Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    required this.createdAt,
    this.coverColor,
    this.ownerId,
    this.ownerUsername,
    this.visibility,
    this.isCollaborative,
    this.collaboratorsJson,
    this.trackPositions,
  });

  Playlist copyWith({
    String? id,
    String? name,
    List<Track>? tracks,
    DateTime? createdAt,
    int? coverColor,
    String? ownerId,
    String? ownerUsername,
    String? visibility,
    bool? isCollaborative,
    String? collaboratorsJson,
    List<int>? trackPositions,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      tracks: tracks ?? this.tracks,
      createdAt: createdAt ?? this.createdAt,
      coverColor: coverColor ?? this.coverColor,
      ownerId: ownerId ?? this.ownerId,
      ownerUsername: ownerUsername ?? this.ownerUsername,
      visibility: visibility ?? this.visibility,
      isCollaborative: isCollaborative ?? this.isCollaborative,
      collaboratorsJson: collaboratorsJson ?? this.collaboratorsJson,
      trackPositions: trackPositions ?? this.trackPositions,
    );
  }

  // ── Derived accessors ──────────────────────────────────────────────

  /// 'private' when unset (legacy default).
  String get visibilityOrDefault => visibility ?? PlaylistVisibility.private;

  bool get isCollaborativeOrDefault => isCollaborative ?? false;

  /// Total playing time in seconds (sum of track durations).
  int get totalDurationSeconds =>
      tracks.fold<int>(0, (sum, t) => sum + t.duration);

  int get trackCount => tracks.length;

  /// The single owner as a value object (id may be empty on a legacy record
  /// before migration; the UI supplies a fallback username).
  PlaylistOwner get owner =>
      PlaylistOwner(userId: ownerId ?? '', username: ownerUsername);

  /// Parsed collaborators (empty on all local playlists this phase).
  List<PlaylistCollaborator> get collaborators {
    final raw = collaboratorsJson;
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((m) => PlaylistCollaborator.fromJson(m.cast<String, dynamic>()))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Only ACCEPTED collaborators, in stored display order. Pending/rejected/
  /// revoked never appear.
  List<PlaylistCollaborator> get acceptedCollaborators {
    final list = collaborators.where((c) => c.isAccepted).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return list;
  }

  /// Presentation projection: owner first, then accepted collaborators, deduped
  /// by canonical user id (owner never repeated). [fallbackOwnerUsername] is used
  /// only when this record has no stored owner username (legacy).
  List<DisplayedContributor> displayedContributors({
    String? fallbackOwnerUsername,
  }) {
    final out = <DisplayedContributor>[];
    final seen = <String>{};
    final ownerName = (ownerUsername != null && ownerUsername!.trim().isNotEmpty)
        ? ownerUsername!.trim()
        : (fallbackOwnerUsername?.trim() ?? '');
    final oId = ownerId ?? '';
    if (ownerName.isNotEmpty) {
      out.add(DisplayedContributor(
        userId: oId,
        username: ownerName,
        position: 0,
        source: ContributorSource.owner,
      ));
      if (oId.isNotEmpty) seen.add(oId);
    }
    for (final c in acceptedCollaborators) {
      // Never repeat the owner (by canonical id), dedupe by id, skip blanks.
      if (c.userId.isNotEmpty && oId.isNotEmpty && c.userId == oId) continue;
      if (c.userId.isNotEmpty && !seen.add(c.userId)) continue;
      final n = (c.username ?? '').trim();
      if (n.isEmpty) continue;
      out.add(DisplayedContributor(
        userId: c.userId,
        username: n,
        position: out.length,
        source: ContributorSource.collaborator,
      ));
    }
    return out;
  }

  /// Explicit normalized (0-based, contiguous, no-duplicate) positions for the
  /// current committed track order — the cloud-contract payload shape.
  List<PlaylistTrackPosition> normalizedPositions() {
    final out = <PlaylistTrackPosition>[];
    for (var i = 0; i < tracks.length; i++) {
      out.add(PlaylistTrackPosition(trackId: tracks[i].id, position: i));
    }
    return out;
  }

  /// A copy whose [trackPositions] is normalized to the current list order
  /// (0..n-1). Guarantees no duplicate positions after a commit.
  Playlist withNormalizedPositions() {
    return copyWith(
      trackPositions: List<int>.generate(tracks.length, (i) => i),
    );
  }

  // Helper for mosaic images — dedupes and drops empty/invalid URLs.
  List<String> get uniqueArtworkUrls {
    final seen = <String>{};
    final out = <String>[];
    for (final t in tracks) {
      final url = t.artworkUrl.trim();
      if (url.isEmpty) continue;
      if (seen.add(url)) out.add(url);
    }
    return out;
  }

  // Track IDs accessor for legacy compatibility if needed
  List<String> get trackIds => tracks.map((t) => t.id).toList();
}
