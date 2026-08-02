// lib/data/remote/playlist_remote_data_source.dart
//
// Phase 3.4.1 — thin Supabase wrapper for the cloud-playlist RPCs + reads.
// Supabase is the authoritative source. Every mutation goes through a
// permission-/version-checked SECURITY DEFINER RPC (never raw table writes).
// Errors are mapped to typed exceptions the sync layer understands.

import 'package:supabase_flutter/supabase_flutter.dart';

/// The playlist row changed on the server since the client's expected version.
class PlaylistConflictException implements Exception {
  final String message;
  const PlaylistConflictException([this.message = 'PLAYLIST_VERSION_CONFLICT']);
  @override
  String toString() => 'PlaylistConflictException($message)';
}

/// The caller lost/never had permission for the attempted action.
class PlaylistForbiddenException implements Exception {
  final String message;
  const PlaylistForbiddenException([this.message = 'FORBIDDEN']);
  @override
  String toString() => 'PlaylistForbiddenException($message)';
}

/// Any other remote failure (network, not-found, validation).
class PlaylistRemoteException implements Exception {
  final String message;
  const PlaylistRemoteException(this.message);
  @override
  String toString() => 'PlaylistRemoteException($message)';
}

class PlaylistRemoteDataSource {
  final SupabaseClient _client;

  PlaylistRemoteDataSource([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  // ── error mapping ──
  Never _map(Object e) {
    final s = e.toString();
    if (s.contains('PLAYLIST_VERSION_CONFLICT')) throw const PlaylistConflictException();
    if (s.contains('FORBIDDEN') ||
        s.contains('NOT_OWNER') ||
        s.contains('42501')) {
      throw const PlaylistForbiddenException();
    }
    throw PlaylistRemoteException(s);
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PlaylistConflictException {
      rethrow;
    } catch (e) {
      _map(e);
    }
  }

  Map<String, dynamic> _row(dynamic r) {
    if (r is List) {
      if (r.isEmpty) throw const PlaylistRemoteException('EMPTY_RESULT');
      return (r.first as Map).cast<String, dynamic>();
    }
    return (r as Map).cast<String, dynamic>();
  }

  // ── mutations (RPCs) ──
  Future<Map<String, dynamic>> createPlaylist({
    required String name,
    String visibility = 'private',
    List<String> trackUuids = const [],
    String? id,
    String? sourcePlaylistId,
    bool imported = false,
  }) =>
      _guard(() async => _row(await _client.rpc('playlist_create', params: {
            'p_name': name,
            'p_visibility': visibility,
            'p_track_ids': trackUuids,
            'p_id': id,
            'p_source_playlist_id': sourcePlaylistId,
            'p_imported': imported,
          })));

  Future<Map<String, dynamic>> saveOrder(
          String playlistId, List<String> orderedTrackUuids, int? expectedVersion) =>
      _guard(() async => _row(await _client.rpc('playlist_save_order', params: {
            'p_playlist_id': playlistId,
            'p_ordered_track_ids': orderedTrackUuids,
            'p_expected_version': expectedVersion,
          })));

  Future<Map<String, dynamic>> addTracks(String playlistId, List<String> trackUuids) =>
      _guard(() async => _row(await _client.rpc('playlist_add_tracks',
          params: {'p_playlist_id': playlistId, 'p_track_ids': trackUuids})));

  Future<Map<String, dynamic>> removeTracks(String playlistId, List<String> trackUuids) =>
      _guard(() async => _row(await _client.rpc('playlist_remove_tracks',
          params: {'p_playlist_id': playlistId, 'p_track_ids': trackUuids})));

  Future<Map<String, dynamic>> updateMetadata(
    String playlistId, {
    String? name,
    String? description,
    String? visibility,
    bool? collaborative,
    int? expectedVersion,
  }) =>
      _guard(() async => _row(await _client.rpc('playlist_update_metadata', params: {
            'p_playlist_id': playlistId,
            'p_name': name,
            'p_description': description,
            'p_visibility': visibility,
            'p_collaborative': collaborative,
            'p_expected_version': expectedVersion,
          })));

  Future<void> deletePlaylist(String playlistId) => _guard(() async =>
      _client.rpc('playlist_delete', params: {'p_playlist_id': playlistId}));

  Future<int> setFollow(String playlistId, bool follow) =>
      _guard(() async {
        final r = await _client.rpc('playlist_set_follow',
            params: {'p_playlist_id': playlistId, 'p_follow': follow});
        return (r as num?)?.toInt() ?? 0;
      });

  Future<void> invite(String playlistId, String userId, {String role = 'editor'}) =>
      _guard(() async => _client.rpc('playlist_invite_collaborator',
          params: {'p_playlist_id': playlistId, 'p_user_id': userId, 'p_role': role}));

  Future<void> respondInvitation(String playlistId, bool accept) =>
      _guard(() async => _client.rpc('playlist_respond_invitation',
          params: {'p_playlist_id': playlistId, 'p_accept': accept}));

  Future<void> leave(String playlistId) => _guard(() async =>
      _client.rpc('playlist_leave', params: {'p_playlist_id': playlistId}));

  Future<void> removeCollaborator(String playlistId, String userId, {String? reason}) =>
      _guard(() async => _client.rpc('playlist_remove_collaborator', params: {
            'p_playlist_id': playlistId,
            'p_user_id': userId,
            'p_reason': reason,
          }));

  Future<Map<String, dynamic>> transferOwnership(String playlistId, String newOwner) =>
      _guard(() async => _row(await _client.rpc('playlist_transfer_ownership',
          params: {'p_playlist_id': playlistId, 'p_new_owner': newOwner})));

  Future<Map<String, dynamic>> clone(String playlistId, {String? newId, String? newTitle}) =>
      _guard(() async => _row(await _client.rpc('playlist_clone', params: {
            'p_playlist_id': playlistId,
            'p_new_id': newId,
            'p_new_title': newTitle,
          })));

  Future<Map<String, dynamic>> addTracksFromSource(String sourceId, String targetId) =>
      _guard(() async => _row(await _client.rpc('playlist_add_tracks_from_source',
          params: {'p_source': sourceId, 'p_target': targetId})));

  // ── reads ──
  /// Playlists owned by the current user (RLS-filtered).
  Future<List<Map<String, dynamic>>> fetchOwnedPlaylists(String uid) => _guard(() async {
        final rows = await _client
            .from('playlists')
            .select()
            .eq('owner_id', uid)
            .filter('deleted_at', 'is', null);
        return (rows as List).cast<Map<String, dynamic>>();
      });

  /// Playlist ids the current user follows.
  Future<List<String>> fetchFollowedPlaylistIds(String uid) => _guard(() async {
        final rows = await _client
            .from('user_followed_playlists')
            .select('playlist_id')
            .eq('user_id', uid);
        return (rows as List)
            .map((r) => (r as Map)['playlist_id'].toString())
            .toList();
      });

  /// Playlist ids the current user is an ACCEPTED collaborator on.
  Future<List<String>> fetchCollaboratingPlaylistIds(String uid) => _guard(() async {
        final rows = await _client
            .from('playlist_collaborators')
            .select('playlist_id')
            .eq('user_id', uid)
            .eq('status', 'accepted');
        return (rows as List)
            .map((r) => (r as Map)['playlist_id'].toString())
            .toList();
      });

  Future<Map<String, dynamic>?> fetchPlaylist(String playlistId) => _guard(() async {
        final row = await _client
            .from('playlists')
            .select()
            .eq('id', playlistId)
            .maybeSingle();
        return row == null ? null : (row as Map).cast<String, dynamic>();
      });

  Future<List<Map<String, dynamic>>> fetchPlaylistsByIds(List<String> ids) =>
      _guard(() async {
        if (ids.isEmpty) return <Map<String, dynamic>>[];
        final rows = await _client
            .from('playlists')
            .select()
            .inFilter('id', ids)
            .filter('deleted_at', 'is', null);
        return (rows as List).cast<Map<String, dynamic>>();
      });

  /// Ordered tracks joined with playable catalog fields.
  Future<List<Map<String, dynamic>>> fetchTracks(String playlistId) => _guard(() async {
        final rows = await _client
            .from('playlist_tracks')
            .select(
                'position, track_id, added_by, tracks(id, deezer_id, title, duration_seconds, preferred_youtube_video_id, image_cached_url, image_original_url)')
            .eq('playlist_id', playlistId)
            .order('position');
        return (rows as List).cast<Map<String, dynamic>>();
      });

  Future<List<Map<String, dynamic>>> fetchCollaborators(String playlistId) =>
      _guard(() async {
        final rows = await _client
            .from('playlist_collaborators')
            .select('user_id, role, status, joined_at, profiles(username, display_name)')
            .eq('playlist_id', playlistId);
        return (rows as List).cast<Map<String, dynamic>>();
      });

  Future<bool> fetchIsFollowing(String playlistId, String uid) => _guard(() async {
        final row = await _client
            .from('user_followed_playlists')
            .select('playlist_id')
            .eq('user_id', uid)
            .eq('playlist_id', playlistId)
            .maybeSingle();
        return row != null;
      });

  Future<Map<String, dynamic>?> fetchLatestActivity(String playlistId) => _guard(() async {
        final row = await _client
            .from('playlist_activity')
            .select('*, profiles:actor_id(username, display_name)')
            .eq('playlist_id', playlistId)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle();
        return row == null ? null : (row as Map).cast<String, dynamic>();
      });

  /// user_id → username, batched (no N+1).
  Future<Map<String, String>> resolveUsernames(Iterable<String> userIds) =>
      _guard(() async {
        final ids = userIds.where((i) => i.trim().isNotEmpty).toSet().toList();
        if (ids.isEmpty) return <String, String>{};
        final rows = await _client
            .from('profiles')
            .select('id, username, display_name')
            .inFilter('id', ids);
        final out = <String, String>{};
        for (final r in (rows as List)) {
          final m = r as Map;
          final name = (m['username'] ?? m['display_name'] ?? '').toString();
          if (name.isNotEmpty) out[m['id'].toString()] = name;
        }
        return out;
      });

  /// Resolve a username → user id (for collaborator invitations).
  Future<String?> resolveUserIdByUsername(String username) => _guard(() async {
        final row = await _client
            .from('profiles')
            .select('id')
            .eq('username', username.trim())
            .maybeSingle();
        return row == null ? null : (row as Map)['id'].toString();
      });
}
