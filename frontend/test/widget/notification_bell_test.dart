// test/widget/notification_bell_test.dart — Phase 3.4.1.1 §F.
//
// The Home bell shows a live unread badge: hidden at 0, "1"–"99", "99+" beyond,
// and tapping opens the Notifications screen. The badge never blocks the tap.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:beaty/data/remote/notification_realtime_service.dart';
import 'package:beaty/data/remote/notification_remote_data_source.dart';
import 'package:beaty/domain/entities/app_notification.dart';
import 'package:beaty/presentation/state/notification_controller.dart';
import 'package:beaty/presentation/widgets/notification_bell.dart';

class _Inbox implements NotificationInbox {
  final List<Map<String, dynamic>> rows;
  _Inbox(this.rows);
  @override
  Future<List<Map<String, dynamic>>> fetchNotifications({int limit = 100}) async => rows;
  @override
  Future<void> markRead(String id) async {}
  @override
  Future<void> markAllRead() async {}
}

class _Sub implements NotificationRealtimeSub {
  @override
  Future<void> close() async {}
}

class _Backend implements NotificationRealtimeBackend {
  @override
  NotificationRealtimeSub subscribe(String userId, void Function(NotificationRealtimeEvent) onEvent) => _Sub();
}

List<Map<String, dynamic>> _unread(int n) => List.generate(
      n,
      (i) => {
        'id': 'n$i',
        'user_id': 'u1',
        'type': NotificationType.accepted,
        'title': 'Paax',
        'body': 'update',
        'data': const {},
        'created_at': '2026-08-03T10:00:00Z',
        'read_at': null,
        'acted_at': null,
      },
    );

Future<NotificationController> _controller(int unread) async {
  final c = NotificationController(
    remote: _Inbox(_unread(unread)),
    realtime: NotificationRealtimeService(_Backend()),
    respondInvitation: (_, __) async {},
  );
  await c.onUserSession('u1');
  return c;
}

Future<void> _pump(WidgetTester tester, NotificationController c) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<NotificationController>.value(
      value: c,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: NotificationBell())),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('no badge when there are zero unread', (tester) async {
    await _pump(tester, await _controller(0));
    expect(find.text('0'), findsNothing);
    expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);
  });

  testWidgets('badge shows exact count for 1..99', (tester) async {
    await _pump(tester, await _controller(7));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('badge caps at 99+', (tester) async {
    await _pump(tester, await _controller(150));
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('tapping opens the Notifications screen', (tester) async {
    await _pump(tester, await _controller(3));
    await tester.tap(find.byType(NotificationBell));
    await tester.pumpAndSettle();
    expect(find.text('Notifications'), findsOneWidget);
  });
}
