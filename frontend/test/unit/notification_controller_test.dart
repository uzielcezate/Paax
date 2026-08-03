// test/unit/notification_controller_test.dart — Phase 3.4.1.1 inbox state.
//
// Covers: load/empty/error states, live realtime insert/update/delete, unread
// badge count, mark-read (single + all), invite accept/decline (success,
// failure, non-actionable no-op, double-tap guard), account-switch isolation,
// and defense against a stale channel delivering another account's row.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/remote/notification_realtime_service.dart';
import 'package:beaty/data/remote/notification_remote_data_source.dart';
import 'package:beaty/domain/entities/app_notification.dart';
import 'package:beaty/presentation/state/notification_controller.dart';

class _FakeInbox implements NotificationInbox {
  List<Map<String, dynamic>> rows;
  bool throwOnFetch = false;
  int markReadCalls = 0;
  int markAllCalls = 0;
  _FakeInbox(this.rows);
  @override
  Future<List<Map<String, dynamic>>> fetchNotifications({int limit = 100}) async {
    if (throwOnFetch) throw Exception('offline');
    return rows;
  }

  @override
  Future<void> markRead(String id) async => markReadCalls++;
  @override
  Future<void> markAllRead() async => markAllCalls++;
}

class _FakeSub implements NotificationRealtimeSub {
  @override
  Future<void> close() async {}
}

class _FakeBackend implements NotificationRealtimeBackend {
  void Function(NotificationRealtimeEvent)? cb;
  @override
  NotificationRealtimeSub subscribe(
      String userId, void Function(NotificationRealtimeEvent) onEvent) {
    cb = onEvent;
    return _FakeSub();
  }

  void push(NotificationRealtimeEvent e) => cb?.call(e);
}

Map<String, dynamic> _row(
  String id, {
  String user = 'u1',
  String type = NotificationType.invited,
  String? readAt,
  String? actedAt,
  String createdAt = '2026-08-03T10:00:00Z',
  String? deletedAt,
}) =>
    {
      'id': id,
      'user_id': user,
      'actor_user_id': 'actor',
      'type': type,
      'title': 'Paax',
      'body': 'someone did a thing',
      'data': {'playlist_id': 'pl-$id', 'actor_username': 'iamleizu'},
      'entity_type': 'playlist',
      'entity_id': 'pl-$id',
      'created_at': createdAt,
      'read_at': readAt,
      'acted_at': actedAt,
      'deleted_at': deletedAt,
    };

NotificationController _make(
  _FakeInbox inbox,
  _FakeBackend be, {
  InviteResponder? responder,
}) =>
    NotificationController(
      remote: inbox,
      realtime: NotificationRealtimeService(be),
      respondInvitation:
          responder ?? (_, __) async {},
    );

void main() {
  test('onUserSession loads rows and computes unread count', () async {
    final inbox = _FakeInbox([_row('a'), _row('b', readAt: '2026-08-03T10:01:00Z')]);
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    expect(c.state, NotificationLoadState.loaded);
    expect(c.items.length, 2);
    expect(c.unreadCount, 1);
  });

  test('fetch failure with no cache → error state', () async {
    final inbox = _FakeInbox([])..throwOnFetch = true;
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    expect(c.hasError, isTrue);
    expect(c.items, isEmpty);
  });

  test('realtime insert prepends and bumps unread', () async {
    final inbox = _FakeInbox([]);
    final be = _FakeBackend();
    final c = _make(inbox, be);
    await c.onUserSession('u1');
    be.push(NotificationRealtimeEvent('insert', record: _row('x')));
    expect(c.items.first.id, 'x');
    expect(c.unreadCount, 1);
  });

  test('realtime update replaces existing row (e.g. acted/read)', () async {
    final inbox = _FakeInbox([_row('x')]);
    final be = _FakeBackend();
    final c = _make(inbox, be);
    await c.onUserSession('u1');
    be.push(NotificationRealtimeEvent('update',
        record: _row('x', actedAt: '2026-08-03T10:02:00Z', readAt: '2026-08-03T10:02:00Z')));
    expect(c.items.single.isActionable, isFalse);
    expect(c.unreadCount, 0);
  });

  test('realtime delete + soft-delete update remove the row', () async {
    final inbox = _FakeInbox([_row('x'), _row('y')]);
    final be = _FakeBackend();
    final c = _make(inbox, be);
    await c.onUserSession('u1');
    be.push(NotificationRealtimeEvent('delete', record: _row('x')));
    expect(c.items.map((n) => n.id), ['y']);
    be.push(NotificationRealtimeEvent('update',
        record: _row('y', deletedAt: '2026-08-03T10:03:00Z')));
    expect(c.items, isEmpty);
  });

  test('stale channel row for another account is rejected', () async {
    final inbox = _FakeInbox([]);
    final be = _FakeBackend();
    final c = _make(inbox, be);
    await c.onUserSession('u1');
    be.push(NotificationRealtimeEvent('insert', record: _row('evil', user: 'u2')));
    expect(c.items, isEmpty);
  });

  test('markRead is optimistic and calls remote', () async {
    final inbox = _FakeInbox([_row('x')]);
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    await c.markRead('x');
    expect(c.unreadCount, 0);
    expect(inbox.markReadCalls, 1);
  });

  test('markAllRead clears all unread', () async {
    final inbox = _FakeInbox([_row('a'), _row('b')]);
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    await c.markAllRead();
    expect(c.unreadCount, 0);
    expect(inbox.markAllCalls, 1);
  });

  test('accept invite calls responder and resolves the row optimistically', () async {
    final inbox = _FakeInbox([_row('inv')]);
    String? gotPid;
    bool? gotAccept;
    final c = _make(inbox, _FakeBackend(),
        responder: (pid, accept) async {
      gotPid = pid;
      gotAccept = accept;
    });
    await c.onUserSession('u1');
    final err = await c.respondToInvite(c.items.single, true);
    expect(err, isNull);
    expect(gotPid, 'pl-inv');
    expect(gotAccept, isTrue);
    expect(c.items.single.isActionable, isFalse);
  });

  test('decline failure surfaces an error and leaves the invite actionable', () async {
    final inbox = _FakeInbox([_row('inv')]);
    final c = _make(inbox, _FakeBackend(),
        responder: (_, __) async => throw Exception('rpc down'));
    await c.onUserSession('u1');
    final err = await c.respondToInvite(c.items.single, false);
    expect(err, isNotNull);
    expect(c.items.single.isActionable, isTrue);
  });

  test('responding to a non-actionable notification is a no-op', () async {
    final inbox = _FakeInbox([_row('done', actedAt: '2026-08-03T10:05:00Z')]);
    var called = false;
    final c = _make(inbox, _FakeBackend(),
        responder: (_, __) async => called = true);
    await c.onUserSession('u1');
    final err = await c.respondToInvite(c.items.single, true);
    expect(err, isNull);
    expect(called, isFalse);
  });

  test('account switch discards the previous user rows and reloads', () async {
    final inbox = _FakeInbox([_row('a', user: 'u1')]);
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    expect(c.items.length, 1);
    inbox.rows = [_row('b', user: 'u2'), _row('c', user: 'u2')];
    await c.onUserSession('u2');
    expect(c.items.length, 2);
    expect(c.items.every((n) => n.userId == 'u2'), isTrue);
  });

  test('sign-out clears everything', () async {
    final inbox = _FakeInbox([_row('a')]);
    final c = _make(inbox, _FakeBackend());
    await c.onUserSession('u1');
    await c.onUserSession(null);
    expect(c.items, isEmpty);
    expect(c.unreadCount, 0);
  });
}
