// test/unit/app_notification_test.dart — Phase 3.4.1.1 notification model.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/app_notification.dart';

void main() {
  Map<String, dynamic> row({
    String type = NotificationType.invited,
    String? readAt,
    String? actedAt,
    Map<String, dynamic>? data,
    String? entityId = 'pl-1',
  }) =>
      {
        'id': 'n1',
        'user_id': 'u-recipient',
        'actor_user_id': 'u-actor',
        'type': type,
        'title': 'Paax',
        'body': 'iamleizu invited you to collaborate',
        'data': data ?? {'playlist_id': 'pl-1', 'playlist_title': 'Road Trip', 'actor_username': 'iamleizu'},
        'entity_type': 'playlist',
        'entity_id': entityId,
        'created_at': '2026-08-03T10:00:00Z',
        'read_at': readAt,
        'acted_at': actedAt,
      };

  test('fromMap parses core fields and display payload', () {
    final n = AppNotification.fromMap(row());
    expect(n.id, 'n1');
    expect(n.type, NotificationType.invited);
    expect(n.playlistId, 'pl-1');
    expect(n.playlistTitle, 'Road Trip');
    expect(n.actorUsername, 'iamleizu');
    expect(n.isRead, isFalse);
  });

  test('a pending invite is actionable', () {
    expect(AppNotification.fromMap(row()).isActionable, isTrue);
  });

  test('an acted invite is NOT actionable (accepted/declined/revoked)', () {
    final n = AppNotification.fromMap(row(actedAt: '2026-08-03T11:00:00Z'));
    expect(n.isActionable, isFalse);
  });

  test('a non-invite type is never actionable', () {
    final n = AppNotification.fromMap(row(type: NotificationType.accepted));
    expect(n.isActionable, isFalse);
  });

  test('isRead reflects read_at', () {
    expect(AppNotification.fromMap(row(readAt: '2026-08-03T10:05:00Z')).isRead, isTrue);
  });

  test('playlistId falls back to entity_id when data lacks playlist_id', () {
    final n = AppNotification.fromMap(row(data: {}, entityId: 'pl-fallback'));
    expect(n.playlistId, 'pl-fallback');
  });

  test('copyWith preserves identity and updates read/acted', () {
    final n = AppNotification.fromMap(row());
    final at = DateTime.now();
    final r = n.copyWith(readAt: at, actedAt: at);
    expect(r.id, n.id);
    expect(r.isRead, isTrue);
    expect(r.isActionable, isFalse);
  });
}
