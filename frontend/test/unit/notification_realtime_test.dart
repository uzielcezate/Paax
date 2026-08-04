// test/unit/notification_realtime_test.dart — Phase 3.4.1.1 inbox realtime.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/remote/notification_realtime_service.dart';

class _FakeSub implements NotificationRealtimeSub {
  final void Function() onClose;
  bool closed = false;
  _FakeSub(this.onClose);
  @override
  Future<void> close() async {
    closed = true;
    onClose();
  }
}

class _FakeBackend implements NotificationRealtimeBackend {
  int subscribeCalls = 0;
  String? boundUid;
  void Function(NotificationRealtimeEvent)? cb;
  final List<_FakeSub> subs = [];
  @override
  NotificationRealtimeSub subscribe(
      String userId, void Function(NotificationRealtimeEvent) onEvent) {
    subscribeCalls++;
    boundUid = userId;
    cb = onEvent;
    final s = _FakeSub(() {
      if (boundUid == userId) boundUid = null;
    });
    subs.add(s);
    return s;
  }
}

void main() {
  test('bind subscribes once; same uid is a no-op', () async {
    final be = _FakeBackend();
    final s = NotificationRealtimeService(be);
    await s.bind('u1');
    await s.bind('u1');
    expect(be.subscribeCalls, 1);
    expect(be.boundUid, 'u1');
  });

  test('account switch closes old channel and opens a new one', () async {
    final be = _FakeBackend();
    final s = NotificationRealtimeService(be);
    await s.bind('u1');
    await s.bind('u2');
    expect(be.subscribeCalls, 2);
    expect(be.subs.first.closed, isTrue);
    expect(be.boundUid, 'u2');
  });

  test('bind(null) tears down (sign-out)', () async {
    final be = _FakeBackend();
    final s = NotificationRealtimeService(be);
    await s.bind('u1');
    await s.bind(null);
    expect(be.subs.first.closed, isTrue);
  });

  test('events dispatch to listeners; removed listeners stop receiving', () async {
    final be = _FakeBackend();
    final s = NotificationRealtimeService(be);
    final kinds = <String>[];
    void l(NotificationRealtimeEvent e) => kinds.add(e.kind);
    s.addListener(l);
    await s.bind('u1');
    be.cb!(const NotificationRealtimeEvent('insert'));
    s.removeListener(l);
    be.cb!(const NotificationRealtimeEvent('update'));
    expect(kinds, ['insert']);
  });

  test('dispose closes the channel and clears listeners', () async {
    final be = _FakeBackend();
    final s = NotificationRealtimeService(be);
    await s.bind('u1');
    await s.dispose();
    expect(be.subs.first.closed, isTrue);
  });
}
