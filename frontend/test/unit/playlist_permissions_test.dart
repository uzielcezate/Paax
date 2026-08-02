// test/unit/playlist_permissions_test.dart — Phase 3.4.1 permission policy.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/policy/playlist_permissions.dart';
import 'package:beaty/domain/entities/playlist_contributors.dart';

PlaylistCollaborator _c(String id, {String role = CollaboratorRole.editor, String status = CollaboratorStatus.accepted}) =>
    PlaylistCollaborator(userId: id, username: id, role: role, status: status);

void main() {
  const owner = 'owner-1';
  const collab = 'collab-1';
  const stranger = 'stranger-1';

  PlaylistPermissions perms(String? uid, {List<PlaylistCollaborator> collabs = const [], bool following = false}) =>
      PlaylistPermissions.forUser(
          currentUserId: uid, ownerId: owner, collaborators: collabs, isFollowing: following);

  test('owner has full control', () {
    final p = perms(owner);
    expect(p.isOwner, isTrue);
    expect(p.canEditTracks, isTrue);
    expect(p.canManageCollaborators, isTrue);
    expect(p.canTransferOwnership, isTrue);
    expect(p.canDeletePlaylist, isTrue);
    expect(p.canChangeVisibility, isTrue);
    expect(p.showEditActionRow, isTrue);
    expect(p.showFollowAction, isFalse);
    expect(p.pinInPrimaryRow, isTrue);
  });

  test('accepted editor collaborator can edit but not manage', () {
    final p = perms(collab, collabs: [_c(collab)]);
    expect(p.isOwner, isFalse);
    expect(p.canEditTracks, isTrue);
    expect(p.canReorderTracks, isTrue);
    expect(p.canManageCollaborators, isFalse);
    expect(p.canTransferOwnership, isFalse);
    expect(p.canDeletePlaylist, isFalse);
    expect(p.canEditMetadata, isFalse);
    expect(p.showEditActionRow, isTrue);
    expect(p.showFollowAction, isFalse);
  });

  test('PENDING collaborator is not an editor (shows follow row)', () {
    final p = perms(collab, collabs: [_c(collab, status: CollaboratorStatus.pending)]);
    expect(p.canEditTracks, isFalse);
    expect(p.showEditActionRow, isFalse);
    expect(p.showFollowAction, isTrue);
  });

  test('accepted VIEWER collaborator cannot edit', () {
    final p = perms(collab, collabs: [_c(collab, role: CollaboratorRole.viewer)]);
    expect(p.canEditTracks, isFalse);
    expect(p.showFollowAction, isTrue);
  });

  test('follower: follow + clone, no edit', () {
    final p = perms(stranger, following: true);
    expect(p.role, PlaylistRole.follower);
    expect(p.canEditTracks, isFalse);
    expect(p.canFollow, isTrue);
    expect(p.canClone, isTrue);
    expect(p.showFollowAction, isTrue);
    expect(p.pinInPrimaryRow, isFalse); // pin moves to overflow for non-members
  });

  test('non-member (none): can follow/clone, cannot edit/delete', () {
    final p = perms(stranger);
    expect(p.role, PlaylistRole.none);
    expect(p.canEditTracks, isFalse);
    expect(p.canDeletePlaylist, isFalse);
    expect(p.canManageCollaborators, isFalse);
    expect(p.canFollow, isTrue);
    expect(p.canClone, isTrue);
    expect(p.showFollowAction, isTrue);
  });

  test('null user is a non-member', () {
    final p = perms(null);
    expect(p.role, PlaylistRole.none);
    expect(p.canEditTracks, isFalse);
  });

  test('a removed/left collaborator is not an editor', () {
    final removed = perms(collab, collabs: [_c(collab, status: CollaboratorStatus.removed)]);
    expect(removed.canEditTracks, isFalse);
    expect(removed.showFollowAction, isTrue);
  });
}
