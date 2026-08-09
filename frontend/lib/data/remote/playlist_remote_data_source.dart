// lib/data/remote/playlist_remote_data_source.dart
//
// Phase 3.4.1 — thin Supabase wrapper for the cloud-playlist RPCs + reads.
// Supabase is the authoritative source. Every mutation goes through a
// permission-/version-checked SECURITY DEFINER RPC (never raw table writes).
// Errors are mapped to typed exceptions the sync layer understands.

import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

/// The playlist row changed on the server since the client's expected version.
///
/// TERMINAL BY CONTRACT (Phase 3.4.3). This is an authoritative, deterministic
/// answer: the server compared versions and they differ. Re-sending the same
/// request cannot change the outcome, so this exception must NEVER be routed
/// into a retry path.
///
/// That rule is not stylistic. Until 2026-08-08 the server raised this conflict
/// with SQLSTATE 40001 (`serialization_failure`), which PostgREST treats as a
/// transient race and retries — one stale Save produced ~2,565 executions/sec
/// for hours. The server now returns HTTP 409 with a machine-readable code, and
/// this type carries the authoritative version so the client can reconcile in a
/// single round trip instead of guessing (or retrying).
class PlaylistConflictException implements Exception {
  /// Stable machine-readable identifier from the server (`error.code`).
  static const String code = 'PLAYLIST_VERSION_CONFLICT';

  final String message;

  /// The version the client believed was current.
  final int? expectedVersion;

  /// The AUTHORITATIVE current version, straight from the server. Reconciling
  /// against this needs no extra fetch.
  final int? actualVersion;

  const PlaylistConflictException({
    this.message = code,
    this.expectedVersion,
    this.actualVersion,
  });

  /// True when the server told us the current version, so a deterministic
  /// rebase is possible without another round trip.
  bool get canRebase => actualVersion != null;

  @override
  String toString() =>
      'PlaylistConflictException(expected=$expectedVersion, actual=$actualVersion)';
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
  //
  // Branches on the machine-readable `code` FIRST and only falls back to
  // message text. Supabase's own guidance is to branch on `code`, because
  // message text changes between Postgres/PostgREST versions while codes are
  // stable. The text fallback exists solely so an app build that predates the
  // 409 migration still recognises the conflict.
  Never _map(Object e) {
    if (e is PostgrestException) {
      if (e.code == PlaylistConflictException.code) {
        final v = _parseConflictVersions(e.details);
        throw PlaylistConflictException(
          expectedVersion: v.$1,
          actualVersion: v.$2,
        );
      }
      if (e.code == '42501' || e.code == '403' || e.code == '401') {
        throw const PlaylistForbiddenException();
      }
    }
    final s = e.toString();
    if (s.contains(PlaylistConflictException.code)) {
      throw const PlaylistConflictException(); // legacy/no-version fallback
    }
    if (s.contains('FORBIDDEN') || s.contains('NOT_OWNER') || s.contains('42501')) {
      throw const PlaylistForbiddenException();
    }
    throw PlaylistRemoteException(s);
  }

  /// Extracts `(expected_version, actual_version)` from the 409 `details`
  /// payload. Tolerant of shape: the server sends a JSON string, but a future
  /// version could send an object. Unparseable → (null, null), which simply
  /// means "reconcile by refetching" rather than an error.
  static (int?, int?) _parseConflictVersions(dynamic details) {
    try {
      final map = details is String
          ? jsonDecode(details) as Map<String, dynamic>
          : (details is Map ? details.cast<String, dynamic>() : null);
      if (map == null) return (null, null);
      int? asInt(dynamic v) => v is int ? v : int.tryParse('${v ?? ''}');
      return (asInt(map['expected_version']), asInt(map['actual_version']));
    } catch (_) {
      return (null, null);
    }
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

  /// Invite by (normalized) username — resolution happens SERVER-SIDE inside a
  /// SECURITY DEFINER RPC (the client can't SELECT other users' `profiles` rows
  /// under own-row-only RLS; that was the "No user" bug). Pass the value already
  /// normalized via AuthValidators.normalizeUsername.
  Future<void> inviteByUsername(String playlistId, String username,
          {String role = 'editor'}) =>
      _guard(() async => _client.rpc('playlist_invite_collaborator_by_username',
          params: {'p_playlist_id': playlistId, 'p_username': username, 'p_role': role}));

  /// Bounded, privacy-safe people search for the collaborator picker. Returns
  /// only invitation-safe public fields (user_id, username, display_name,
  /// avatar_url); server enforces owner-only, min length, exclusions, limit.
  Future<List<Map<String, dynamic>>> searchInvitableProfiles(
          String playlistId, String query, {int limit = 10}) =>
      _guard(() async {
        final rows = await _client.rpc('search_invitable_profiles', params: {
          'p_playlist_id': playlistId,
          'p_query': query,
          'p_limit': limit,
        });
        return (rows as List).cast<Map<String, dynamic>>();
      });

  /// Batch id→public profile (username/display_name/avatar) via the
  /// `public_profiles` view (readable for non-private users), used to render
  /// collaborator/owner rows without relying on the RLS-restricted base table.
  Future<List<Map<String, dynamic>>> fetchPublicProfiles(Iterable<String> ids) =>
      _guard(() async {
        final list = ids.where((i) => i.trim().isNotEmpty).toSet().toList();
        if (list.isEmpty) return <Map<String, dynamic>>[];
        final rows = await _client
            .from('public_profiles')
            .select('id, username, display_name, avatar_url')
            .inFilter('id', list);
        return (rows as List).cast<Map<String, dynamic>>();
      });

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
        final rows = await _client.rpc('playlist_get_activity', params: {
          'p_playlist_id': playlistId,
          'p_limit': 1,
        });
        final list = (rows as List).cast<Map<String, dynamic>>();
        return list.isEmpty ? null : list.first;
      });

  /// One page of activity, newest-first, with the actor's display fields
  /// resolved. Keyset pagination: pass the oldest loaded `created_at` (ISO) as
  /// [beforeIso] to get the next older page.
  ///
  /// Reads through the SECURITY DEFINER `playlist_get_activity` RPC (not a
  /// PostgREST embed): `playlist_activity.actor_id` has no FK to `profiles`, so
  /// the old `profiles:actor_id(...)` embed 400'd (PGRST200), and even with an
  /// FK the own-row-only `profiles` RLS would hide other actors from non-owner
  /// viewers. The RPC authorizes via `can_view_playlist` (soft-deleted /
  /// unauthorized → FORBIDDEN) and returns flat `actor_*` display columns.
  Future<List<Map<String, dynamic>>> fetchActivityPage(
    String playlistId, {
    int limit = 30,
    String? beforeIso,
  }) =>
      _guard(() async {
        final rows = await _client.rpc('playlist_get_activity', params: {
          'p_playlist_id': playlistId,
          'p_limit': limit,
          if (beforeIso != null) 'p_before': beforeIso,
        });
        return (rows as List).cast<Map<String, dynamic>>();
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
