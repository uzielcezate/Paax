// lib/core/policy/playlist_permissions.dart
//
// Phase 3.4.1 — CENTRALIZED playlist permission policy (no scattered widget
// booleans). Authorization is derived from owner + ACCEPTED collaborators (by
// canonical user id) + follow state — never from the displayed contributor
// list. RLS on Supabase is the last line of defence; this mirrors it client-side
// to drive the role-dependent UI and to fail fast on obviously-forbidden actions.

import '../../domain/entities/playlist_contributors.dart';

enum PlaylistRole { owner, moderator, editor, viewer, follower, none }

class PlaylistPermissions {
  final PlaylistRole role;

  const PlaylistPermissions(this.role);

  /// Resolve the current user's effective role for a playlist.
  static PlaylistRole roleFor({
    required String? currentUserId,
    required String? ownerId,
    required List<PlaylistCollaborator> collaborators,
    required bool isFollowing,
  }) {
    final uid = (currentUserId ?? '').trim();
    if (uid.isNotEmpty && uid == (ownerId ?? '').trim()) return PlaylistRole.owner;
    if (uid.isNotEmpty) {
      for (final c in collaborators) {
        if (c.userId == uid && c.status == CollaboratorStatus.accepted) {
          switch (c.role) {
            case CollaboratorRole.moderator:
              return PlaylistRole.moderator;
            case CollaboratorRole.viewer:
              return PlaylistRole.viewer;
            default:
              return PlaylistRole.editor;
          }
        }
      }
    }
    if (isFollowing) return PlaylistRole.follower;
    return PlaylistRole.none;
  }

  factory PlaylistPermissions.forUser({
    required String? currentUserId,
    required String? ownerId,
    required List<PlaylistCollaborator> collaborators,
    required bool isFollowing,
  }) =>
      PlaylistPermissions(roleFor(
        currentUserId: currentUserId,
        ownerId: ownerId,
        collaborators: collaborators,
        isFollowing: isFollowing,
      ));

  bool get isOwner => role == PlaylistRole.owner;

  /// Owner or an accepted collaborator with an editing role.
  bool get isEditorMember =>
      role == PlaylistRole.owner ||
      role == PlaylistRole.moderator ||
      role == PlaylistRole.editor;

  // ── conceptual permission helpers (spec §8) ──
  bool get canEditTracks => isEditorMember;
  bool get canReorderTracks => isEditorMember;
  bool get canEditMetadata => isOwner; // conservative default policy
  bool get canChangeVisibility => isOwner;
  bool get canManageCollaborators => isOwner;
  bool get canTransferOwnership => isOwner;
  bool get canDeletePlaylist => isOwner;
  bool get canDisableCollaboration => isOwner;

  /// Following is a non-member concept; owners/collaborators manage the playlist
  /// rather than follow it (spec §9/§10 — the follow button shows for non-members).
  bool get canFollow => role == PlaylistRole.follower || role == PlaylistRole.none;

  /// Anyone who can see the playlist may clone it / add its tracks elsewhere.
  bool get canClone => true;

  // ── UI action-row gating (spec §9 clarification) ──
  /// Owner / accepted collaborator → the current edit-capable action row
  /// (Shuffle · Pin · Play · Reorder). Otherwise the non-member row
  /// (Shuffle · Add-to-playlist · Play · Follow/Following; Pin → overflow).
  bool get showEditActionRow => isEditorMember;
  bool get showFollowAction => !isEditorMember;
  bool get showReorderAction => canReorderTracks;
  bool get pinInPrimaryRow => isEditorMember; // else Pin lives in the overflow menu
}
