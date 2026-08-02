// lib/data/remote/playlist_realtime_service.dart
//
// Phase 3.4.1 — one ref-counted realtime subscription per OPEN playlist. While
// Playlist Detail is mounted it watches metadata/version (playlists), track
// membership/order (playlist_tracks), collaborator changes, deletion, and latest
// activity. Version-guarded so a stale event can't override newer state; torn
// down on leave and on account switch. Backend-agnostic → unit-testable.

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlaylistRealtimeEvent {
  /// 'playlist' | 'tracks' | 'collaborators' | 'activity' | 'deleted'
  final String kind;
  final Map<String, dynamic>? record;
  final int? version;
  const PlaylistRealtimeEvent(this.kind, {this.record, this.version});
}

abstract class PlaylistRealtimeSub {
  Future<void> close();
}

abstract class PlaylistRealtimeBackend {
  PlaylistRealtimeSub subscribe(
      String playlistId, void Function(PlaylistRealtimeEvent) onEvent);
}

class PlaylistRealtimeService {
  final PlaylistRealtimeBackend _backend;

  PlaylistRealtimeService(this._backend);

  final Map<String, PlaylistRealtimeSub> _subs = {};
  final Map<String, int> _refs = {};
  final Map<String, Set<void Function(PlaylistRealtimeEvent)>> _listeners = {};
  final Map<String, int> _lastVersion = {}; // monotonic guard for 'playlist'
  String? _sessionUid;
  bool _sessionSet = false;

  void addListener(String playlistId, void Function(PlaylistRealtimeEvent) l) =>
      _listeners.putIfAbsent(playlistId, () => {}).add(l);

  void removeListener(String playlistId, void Function(PlaylistRealtimeEvent) l) =>
      _listeners[playlistId]?.remove(l);

  Future<void> subscribe(String playlistId) async {
    _refs[playlistId] = (_refs[playlistId] ?? 0) + 1;
    if (!_subs.containsKey(playlistId)) {
      _subs[playlistId] =
          _backend.subscribe(playlistId, (e) => _dispatch(playlistId, e));
    }
  }

  Future<void> unsubscribe(String playlistId) async {
    final n = (_refs[playlistId] ?? 1) - 1;
    if (n > 0) {
      _refs[playlistId] = n;
      return;
    }
    _refs.remove(playlistId);
    _lastVersion.remove(playlistId);
    final s = _subs.remove(playlistId);
    await s?.close();
  }

  void _dispatch(String playlistId, PlaylistRealtimeEvent e) {
    if (e.kind == 'playlist' && e.version != null) {
      final last = _lastVersion[playlistId];
      if (last != null && e.version! <= last) return; // stale — ignore
      _lastVersion[playlistId] = e.version!;
    }
    for (final l in List.of(_listeners[playlistId] ?? const {})) {
      l(e);
    }
  }

  Future<void> onUserSession(String? uid) async {
    if (_sessionSet && uid == _sessionUid) return;
    _sessionSet = true;
    _sessionUid = uid;
    await _closeAll();
  }

  Future<void> _closeAll() async {
    final subs = List.of(_subs.values);
    _subs.clear();
    _refs.clear();
    _lastVersion.clear();
    for (final s in subs) {
      await s.close();
    }
  }

  Future<void> dispose() async {
    await _closeAll();
    _listeners.clear();
  }
}

/// Production backend: one Supabase channel per playlist watching the four tables.
class SupabasePlaylistRealtimeBackend implements PlaylistRealtimeBackend {
  final SupabaseClient _client;

  SupabasePlaylistRealtimeBackend([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));

  @override
  PlaylistRealtimeSub subscribe(
      String playlistId, void Function(PlaylistRealtimeEvent) onEvent) {
    final channel = _client.channel('playlist:$playlistId');

    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'playlists',
      filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq, column: 'id', value: playlistId),
      callback: (payload) {
        final rec = payload.newRecord;
        if (rec['deleted_at'] != null) {
          onEvent(PlaylistRealtimeEvent('deleted', record: rec));
        } else {
          onEvent(PlaylistRealtimeEvent('playlist',
              record: rec, version: _asInt(rec['version'])));
        }
      },
    );

    for (final t in const ['playlist_tracks', 'playlist_collaborators', 'playlist_activity']) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t,
        filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'playlist_id',
            value: playlistId),
        callback: (payload) {
          final kind = t == 'playlist_tracks'
              ? 'tracks'
              : (t == 'playlist_collaborators' ? 'collaborators' : 'activity');
          onEvent(PlaylistRealtimeEvent(kind,
              record: payload.newRecord.isEmpty ? payload.oldRecord : payload.newRecord));
        },
      );
    }

    channel.subscribe();
    return _SupabasePlaylistSub(_client, channel);
  }
}

class _SupabasePlaylistSub implements PlaylistRealtimeSub {
  final SupabaseClient _client;
  final RealtimeChannel _channel;
  _SupabasePlaylistSub(this._client, this._channel);
  @override
  Future<void> close() async {
    try {
      await _client.removeChannel(_channel);
    } catch (_) {}
  }
}
