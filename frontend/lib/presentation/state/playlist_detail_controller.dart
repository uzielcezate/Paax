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
import '../../data/repositories/playlist_repository.dart';

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
      for (final c in collabRows) {
        if (c['status']?.toString() != 'accepted') continue;
        final prof = c['profiles'];
        final username = (prof is Map)
            ? (prof['username'] ?? prof['display_name'] ?? '').toString()
            : '';
        accepted.add(PlaylistCollaborator(
          userId: c['user_id']?.toString() ?? '',
          username: username,
          role: c['role']?.toString() ?? CollaboratorRole.editor,
          status: CollaboratorStatus.accepted,
          position: DateTime.tryParse(c['joined_at']?.toString() ?? '')
                  ?.millisecondsSinceEpoch ??
              0,
        ));
      }
      accepted.sort((a, b) => a.position.compareTo(b.position));
      _collaborators = accepted;

      // Owner username + activity actor name (batched).
      final ids = <String>{if (_ownerId != null) _ownerId!};
      _isFollowing = await _repo.isFollowing(playlistId);

      final activityRow = await _repo.fetchLatestActivity(playlistId);
      if (activityRow != null) {
        String? actorName;
        final prof = activityRow['profiles'];
        if (prof is Map) {
          actorName = (prof['username'] ?? prof['display_name'])?.toString();
        }
        _latestActivity =
            PlaylistActivity.fromMap(activityRow, actorUsername: actorName);
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
    // Refetch authoritative state on any relevant change (bounded — one open
    // playlist). The realtime service already applies a version guard.
    // ignore: discarded_futures
    refresh();
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

  Future<Map<String, dynamic>> clone({String? title}) =>
      _repo.clone(playlistId, newTitle: title);

  Future<void> addToExisting(String targetPlaylistId) =>
      _repo.addTracksFromSource(playlistId, targetPlaylistId);

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
