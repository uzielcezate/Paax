// lib/data/remote/notification_realtime_service.dart
//
// Phase 3.4.1.1 — one realtime subscription on the caller's own notification
// rows, driving the Home bell badge + Notifications screen live. Filtered to
// `user_id=eq.<uid>` so a channel never carries another account's rows; RLS is
// the authoritative second gate. Torn down and re-opened on account switch so a
// previous user's notifications can't leak into a new session. Backend-agnostic
// so the controller is unit-testable without a live Supabase connection.

import 'dart:async';
import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationRealtimeEvent {
  /// 'insert' | 'update' | 'delete'
  final String kind;
  final Map<String, dynamic>? record;
  const NotificationRealtimeEvent(this.kind, {this.record});
}

abstract class NotificationRealtimeSub {
  Future<void> close();
}

abstract class NotificationRealtimeBackend {
  NotificationRealtimeSub subscribe(
      String userId, void Function(NotificationRealtimeEvent) onEvent);
}

class NotificationRealtimeService {
  final NotificationRealtimeBackend _backend;

  NotificationRealtimeService(this._backend);

  NotificationRealtimeSub? _sub;
  String? _uid;
  final Set<void Function(NotificationRealtimeEvent)> _listeners = {};

  void addListener(void Function(NotificationRealtimeEvent) l) =>
      _listeners.add(l);
  void removeListener(void Function(NotificationRealtimeEvent) l) =>
      _listeners.remove(l);

  /// Point the single channel at [uid]. Idempotent per identity: re-called on
  /// every auth notification, only re-subscribes when the account changes.
  Future<void> bind(String? uid) async {
    if (uid == _uid) return;
    _uid = uid;
    await _closeSub();
    if (uid != null) {
      _sub = _backend.subscribe(uid, _dispatch);
    }
  }

  void _dispatch(NotificationRealtimeEvent e) {
    for (final l in List.of(_listeners)) {
      l(e);
    }
  }

  Future<void> _closeSub() async {
    final s = _sub;
    _sub = null;
    await s?.close();
  }

  Future<void> dispose() async {
    await _closeSub();
    _listeners.clear();
    _uid = null;
  }
}

/// Production backend: one Supabase channel watching the caller's own rows.
class SupabaseNotificationRealtimeBackend implements NotificationRealtimeBackend {
  final SupabaseClient _client;

  SupabaseNotificationRealtimeBackend([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  @override
  NotificationRealtimeSub subscribe(
      String userId, void Function(NotificationRealtimeEvent) onEvent) {
    final channel = _client.channel('notifications:$userId');
    final filter = PostgresChangeFilter(
        type: PostgresChangeFilterType.eq, column: 'user_id', value: userId);

    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'notifications',
      filter: filter,
      callback: (p) =>
          onEvent(NotificationRealtimeEvent('insert', record: p.newRecord)),
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.update,
      schema: 'public',
      table: 'notifications',
      filter: filter,
      callback: (p) =>
          onEvent(NotificationRealtimeEvent('update', record: p.newRecord)),
    );
    channel.onPostgresChanges(
      event: PostgresChangeEvent.delete,
      schema: 'public',
      table: 'notifications',
      filter: filter,
      callback: (p) =>
          onEvent(NotificationRealtimeEvent('delete', record: p.oldRecord)),
    );

    channel.subscribe();
    return _SupabaseNotificationSub(_client, channel);
  }
}

class _SupabaseNotificationSub implements NotificationRealtimeSub {
  final SupabaseClient _client;
  final RealtimeChannel _channel;
  _SupabaseNotificationSub(this._client, this._channel);
  @override
  Future<void> close() async {
    try {
      await _client.removeChannel(_channel);
    } catch (_) {}
  }
}
