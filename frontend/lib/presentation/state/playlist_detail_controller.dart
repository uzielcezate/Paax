// lib/presentation/state/playlist_detail_controller.dart
//
// Phase 3.4.1 — per-open-playlist cloud state for the Playlist Detail screen:
// owner + accepted collaborators, visibility, follower count, last-modified,
// version, the current user's role, follow state, and the latest activity.
// Fetches from the cloud, subscribes to realtime while the screen is mounted,
// and exposes the role-dependent actions (follow / clone / add-to-existing).
// Gracefully no-ops for a not-yet-cloud (local) playlist so existing local
// playlists keep working unchanged.

import 'package:flutter/foundation.dart';

import '../../core/policy/playlist_permissions.dart';
import '../../domain/entities/playlist_activity.dart';
import '../../domain/entities/playlist_contributors.dart';
import '../../data/remote/playlist_realtime_service.dart';
import '../../data/remote/playlist_remote_data_source.dart' show PlaylistConflictException;
import '../../data/repositories/playlist_repository.dart';

/// A collaborator row for the owner's management sheet (accepted or pending).
class ManagedCollaborator {
  final String userId;
  final String username;
  final String role;
  final String status;
  const ManagedCollaborator({
    required this.userId,
    required this.username,
    required this.role,
    required this.status,
  });
  bool get isPending => status == 'pending';
  bool get isAccepted => status == 'accepted';
}

class PlaylistDetailController extends ChangeNotifier {
  final PlaylistRepository _repo;
  final PlaylistRealtimeService _realtime;
  final String? currentUserId;
  final String playlistId;

  PlaylistDetailController({
    required PlaylistRepository repository,
    required PlaylistRealtimeService realtime,
    required this.currentUserId,
    required this.playlistId,
    String? initialOwnerId,
    String? initialOwnerUsername,
    String initialVisibility = 'private',
  })  : _repo = repository,
        _realtime = realtime,
        _ownerId = initialOwnerId,
        _ownerUsername = initialOwnerUsername,
        _visibility = initialVisibility;

  // ── state ──
  bool _loaded = false;
  bool _isCloud = false;
  String? _ownerId;
  String? _ownerUsername;
  List<PlaylistCollaborator> _collaborators = const [];
  String _visibility;
  int? _followerCount;
  DateTime? _lastModifiedAt;
  int _version = 1;
  bool _isFollowing = false;
  PlaylistActivity? _latestActivity;
  bool _followBusy = false;
  List<ManagedCollaborator> _allCollaborators = const [];
  bool _myPendingInvite = false;
  bool _deleted = false;

  /// True when the playlist was deleted (soft) or the user lost access — the
  /// Detail screen resolves to an unavailable state (spec 3.4.1.1 B).
  bool get isDeleted => _deleted;

  /// All non-terminal collaborators (accepted + pending) for the owner's manage
  /// sheet, with resolved usernames.
  List<ManagedCollaborator> get allCollaborators => _allCollaborators;

  /// True when the CURRENT user has a pending invitation on this playlist.
  bool get myPendingInvite => _myPendingInvite;

  bool get loaded => _loaded;
  bool get isCloud => _isCloud;
  String? get ownerId => _ownerId;
  String? get ownerUsername => _ownerUsername;
  List<PlaylistCollaborator> get collaborators => _collaborators;
  String get visibility => _visibility;
  int? get followerCount => _followerCount;
  DateTime? get lastModifiedAt => _lastModifiedAt;
  int get version => _version;
  bool get isFollowing => _isFollowing;
  PlaylistActivity? get latestActivity => _latestActivity;

  PlaylistPermissions get permissions => PlaylistPermissions.forUser(
        currentUserId: currentUserId,
        ownerId: _ownerId,
        collaborators: _collaborators,
        isFollowing: _isFollowing,
      );

  static bool _looksLikeUuid(String s) =>
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(s);

  Future<void> load() async {
    _isCloud = _looksLikeUuid(playlistId);
    if (!_isCloud) {
      _loaded = true;
      notifyListeners();
      return; // local-only playlist — header falls back to local data
    }
    _realtime.addListener(playlistId, _onRealtime);
    // ignore: discarded_futures
    _realtime.subscribe(playlistId);
    await refresh();
  }

  Future<void> refresh() async {
    if (!_isCloud) return;
    try {
      final row = await _repo.fetchPlaylist(playlistId);
      if (row == null) {
        // Deleted (soft) or access lost — RLS denies the select either way.
        _deleted = true;
        _loaded = true;
        notifyListeners();
        return;
      }
      _ownerId = row['owner_id']?.toString();
      _visibility = row['visibility']?.toString() ?? _visibility;
      _followerCount = (row['platform_followers_count'] as num?)?.toInt();
      _version = (row['version'] as num?)?.toInt() ?? _version;
      _lastModifiedAt =
          DateTime.tryParse(row['last_modified_at']?.toString() ?? '')?.toLocal();

      final collabRows = await _repo.fetchCollaborators(playlistId);
      final accepted = <PlaylistCollaborator>[];
      final managed = <ManagedCollaborator>[];
      var myPending = false;
      for (final c in collabRows) {
        final status = c['status']?.toString() ?? '';
        final userId = c['user_id']?.toString() ?? '';
        final prof = c['profiles'];
        final username = (prof is Map)
            ? (prof['username'] ?? prof['display_name'] ?? '').toString()
            : '';
        final role = c['role']?.toString() ?? CollaboratorRole.editor;
        if (status == 'pending' && userId == currentUserId) myPending = true;
        if (status == 'accepted' || status == 'pending') {
          managed.add(ManagedCollaborator(
              userId: userId, username: username, role: role, status: status));
        }
        if (status != 'accepted') continue;
        accepted.add(PlaylistCollaborator(
          userId: userId,
          username: username,
          role: role,
          status: CollaboratorStatus.accepted,
          position: DateTime.tryParse(c['joined_at']?.toString() ?? '')
                  ?.millisecondsSinceEpoch ??
              0,
        ));
      }
      accepted.sort((a, b) => a.position.compareTo(b.position));
      _collaborators = accepted;
      _allCollaborators = managed;
      _myPendingInvite = myPending;

      // Owner username + activity actor name (batched).
      final ids = <String>{if (_ownerId != null) _ownerId!};
      _isFollowing = await _repo.isFollowing(playlistId);

      final activityRow = await _repo.fetchLatestActivity(playlistId);
      if (activityRow != null) {
        _latestActivity = PlaylistActivity.fromRpcRow(activityRow);
      }
      final names = await _repo.resolveUsernames(ids);
      _ownerUsername = names[_ownerId] ?? _ownerUsername;

      _loaded = true;
      notifyListeners();
    } catch (_) {
      _loaded = true;
      notifyListeners(); // keep whatever we had (offline-friendly)
    }
  }

  void _onRealtime(PlaylistRealtimeEvent e) {
    if (e.kind == 'deleted') {
      _deleted = true;
      notifyListeners();
      return;
    }
    if (e.kind == 'followers') {
      // Apply the AUTHORITATIVE absolute count directly (idempotent — never a
      // delta), so a viewer sees +1/-1 in realtime even though a follow does not
      // bump `version`. Do NOT touch `_isFollowing`: the current user's follow
      // state is never inferred from the global count (spec F). No refetch.
      final c = (e.record?['platform_followers_count'] as num?)?.toInt();
      if (c != null && c != _followerCount) {
        _followerCount = c;
        notifyListeners();
      }
      return;
    }
    // Refetch authoritative state on any relevant change (bounded — one open
    // playlist). The realtime service already applies a version guard.
    // ignore: discarded_futures
    refresh();
  }

  /// Accepted collaborator leaves the playlist (spec 3.4.1.1 B). Best-effort.
  Future<void> leave() async {
    try {
      await _repo.leave(playlistId);
    } catch (_) {}
  }

  /// Owner-only visibility change (spec 3.4.1.1 D): optimistic + version-checked
  /// RPC; rollback + reconcile on conflict/failure. Returns null on success or a
  /// short message. The RPC emits the `visibility_changed` activity.
  Future<String?> changeVisibility(String newVisibility) async {
    if (!_isCloud) return null;
    final old = _visibility;
    _visibility = newVisibility;
    notifyListeners();
    try {
      final row = await _repo.updateMetadata(playlistId,
          visibility: newVisibility, expectedVersion: _version);
      _visibility = row['visibility']?.toString() ?? newVisibility;
      _version = (row['version'] as num?)?.toInt() ?? _version;
      _lastModifiedAt =
          DateTime.tryParse(row['last_modified_at']?.toString() ?? '')?.toLocal() ??
              _lastModifiedAt;
      _latestActivity = null; // force re-fetch of the visibility_changed event
      notifyListeners();
      return null;
    } on PlaylistConflictException {
      _visibility = old;
      notifyListeners();
      await refresh(); // reconcile to authoritative state
      return 'This playlist changed elsewhere — reloaded. Try again.';
    } catch (_) {
      _visibility = old;
      notifyListeners();
      return 'Could not change privacy';
    }
  }

  /// Displayed contributor usernames: owner first, then accepted collaborators,
  /// deduped by canonical id (owner never repeated). Falls back to [fallback].
  List<String> contributorNames({String? fallback}) {
    final out = <String>[];
    final seen = <String>{};
    final ownerName = (_ownerUsername ?? '').trim().isNotEmpty
        ? _ownerUsername!.trim()
        : (fallback ?? '').trim();
    if (ownerName.isNotEmpty) {
      out.add(ownerName);
      if ((_ownerId ?? '').isNotEmpty) seen.add(_ownerId!);
    }
    for (final c in _collaborators) {
      if (c.userId.isNotEmpty && c.userId == _ownerId) continue;
      if (c.userId.isNotEmpty && !seen.add(c.userId)) continue;
      final n = (c.username ?? '').trim();
      if (n.isEmpty) continue;
      out.add(n);
    }
    return out;
  }

  // ── actions ──
  Future<void> toggleFollow() async {
    if (!_isCloud || _followBusy) return;
    _followBusy = true;
    final wantFollow = !_isFollowing;
    // optimistic
    _isFollowing = wantFollow;
    _followerCount = ((_followerCount ?? 0) + (wantFollow ? 1 : -1)).clamp(0, 1 << 31);
    notifyListeners();
    try {
      final count = await _repo.setFollow(playlistId, wantFollow);
      _followerCount = count; // authoritative reconciliation
    } catch (_) {
      // rollback optimistic on failure
      _isFollowing = !wantFollow;
      _followerCount =
          ((_followerCount ?? 0) + (wantFollow ? -1 : 1)).clamp(0, 1 << 31);
    } finally {
      _followBusy = false;
      notifyListeners();
    }
  }

  /// Phase 3.4.1.1 (C): the "Last modified…" line must be tappable for EVERY
  /// cloud playlist. Return the latest activity, fetching if not yet loaded, and
  /// synthesize a "created" event when none exists (never a raw uuid).
  Future<PlaylistActivity?> ensureLatestActivity() async {
    if (!_isCloud) return null;
    if (_latestActivity != null) return _latestActivity;
    try {
      final row = await _repo.fetchLatestActivity(playlistId);
      if (row != null) {
        _latestActivity = PlaylistActivity.fromRpcRow(row);
        notifyListeners();
        return _latestActivity;
      }
    } catch (_) {}
    // No stored activity yet → show playlist creation.
    return PlaylistActivity(
      id: 'created',
      playlistId: playlistId,
      actorId: _ownerId,
      actorUsername: _ownerUsername,
      eventType: 'playlist_created',
      createdAt: _lastModifiedAt ?? DateTime.now(),
    );
  }

  Future<Map<String, dynamic>> clone({String? title}) =>
      _repo.clone(playlistId, newTitle: title);

  Future<void> addToExisting(String targetPlaylistId) =>
      _repo.addTracksFromSource(playlistId, targetPlaylistId);

  // ── collaboration management (owner) ──
  /// Invite by username. Returns null on success, or a short error message.
  Future<String?> inviteByUsername(String username) async {
    final name = username.trim();
    if (name.isEmpty) return 'Enter a username';
    try {
      final id = await _repo.resolveUserIdByUsername(name);
      if (id == null) return 'No user "$name"';
      if (id == _ownerId) return 'That user is the owner';
      await _repo.invite(playlistId, id);
      await refresh();
      return null;
    } catch (e) {
      final s = e.toString();
      if (s.contains('ALREADY_INVITED')) return 'Already invited';
      if (s.contains('USER_BLOCKED')) return 'Cannot invite this user';
      return 'Could not send invite';
    }
  }

  Future<void> removeCollaborator(String userId) async {
    try {
      await _repo.removeCollaborator(playlistId, userId);
      await refresh();
    } catch (_) {}
  }

  Future<String?> transferOwnershipTo(String newOwnerId) async {
    try {
      await _repo.transferOwnership(playlistId, newOwnerId);
      await refresh();
      return null;
    } catch (_) {
      return 'Could not transfer ownership';
    }
  }

  /// Accept or decline the current user's pending invitation.
  Future<void> respondToInvitation(bool accept) async {
    try {
      await _repo.respondInvitation(playlistId, accept);
      await refresh();
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_isCloud) {
      _realtime.removeListener(playlistId, _onRealtime);
      // ignore: discarded_futures
      _realtime.unsubscribe(playlistId);
    }
    super.dispose();
  }
}
