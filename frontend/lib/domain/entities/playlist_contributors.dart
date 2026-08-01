// lib/domain/entities/playlist_contributors.dart
//
// Phase 3.3.6 — cloud-ready playlist ownership / collaboration value types.
//
// These are PLAIN domain value objects (no Hive adapters). They model the
// separation the future Supabase schema requires, kept distinct from the
// beginning even though local playlists currently have exactly one owner and no
// collaborators:
//
//   * Owner            — the single creator/administrator (authorization source
//                        for ownership). Identified by canonical user id.
//   * Collaborator     — a user with an ACCEPTED collaboration record who may
//                        edit (authorization source for shared editing).
//   * DisplayedContributor — a PRESENTATION projection of owner + accepted
//                        collaborators shown below the playlist title. It is
//                        NEVER an authorization source.
//
// Usernames may change, so every relation is keyed by the immutable canonical
// user id. `isCollaborative` is an explicit playlist field and must NOT be
// inferred from the number of displayed contributors.

/// Allowed collaborator roles (future Supabase `playlist_collaborators.role`).
class CollaboratorRole {
  static const String editor = 'editor';
  static const String viewer = 'viewer';
  static const String moderator = 'moderator';
}

/// Collaboration lifecycle status (future `playlist_collaborators.status`).
/// Only [accepted] grants edit permission or appears in the contributor line.
class CollaboratorStatus {
  static const String pending = 'pending';
  static const String accepted = 'accepted';
  static const String rejected = 'rejected';
  static const String revoked = 'revoked';
}

/// Where a displayed contributor came from.
class ContributorSource {
  static const String owner = 'owner';
  static const String collaborator = 'collaborator';
}

/// The single owner of a playlist.
class PlaylistOwner {
  final String userId; // canonical (Supabase) user id — immutable
  final String? username;

  const PlaylistOwner({required this.userId, this.username});
}

/// A user with a collaboration record on a playlist. Authorization comes from
/// [role] + [status], never from whether the user is displayed.
class PlaylistCollaborator {
  final String userId; // canonical user id — immutable
  final String? username;
  final String role; // CollaboratorRole.*
  final String status; // CollaboratorStatus.*
  final int position; // stored display order among collaborators

  const PlaylistCollaborator({
    required this.userId,
    this.username,
    this.role = CollaboratorRole.editor,
    this.status = CollaboratorStatus.accepted,
    this.position = 0,
  });

  bool get isAccepted => status == CollaboratorStatus.accepted;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        if (username != null) 'username': username,
        'role': role,
        'status': status,
        'position': position,
      };

  factory PlaylistCollaborator.fromJson(Map<String, dynamic> j) =>
      PlaylistCollaborator(
        userId: (j['userId'] ?? '').toString(),
        username: j['username']?.toString(),
        role: (j['role'] ?? CollaboratorRole.editor).toString(),
        status: (j['status'] ?? CollaboratorStatus.accepted).toString(),
        position: j['position'] is int
            ? j['position'] as int
            : int.tryParse('${j['position'] ?? 0}') ?? 0,
      );
}

/// A presentation-only entry in the contributor line (owner + accepted
/// collaborators). Derived, never an authorization source.
class DisplayedContributor {
  final String userId;
  final String username;
  final int position;
  final String source; // ContributorSource.*

  const DisplayedContributor({
    required this.userId,
    required this.username,
    required this.position,
    required this.source,
  });
}

/// A stable explicit position for one playlist track — the payload shape for the
/// future cloud contract `updatePlaylistTrackPositions`. Positions are
/// **zero-based** and normalized (contiguous, no duplicates) on every commit.
class PlaylistTrackPosition {
  final String trackId; // local videoId (future: playlist_tracks.id/track_id)
  final int position;

  const PlaylistTrackPosition({required this.trackId, required this.position});

  Map<String, dynamic> toJson() => {'trackId': trackId, 'position': position};
}
