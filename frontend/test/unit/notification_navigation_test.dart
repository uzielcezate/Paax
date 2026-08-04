// test/unit/notification_navigation_test.dart — Phase 3.4.1.2 §C.
//
// resolveNotificationPlaylistTarget picks the correct canonical playlist to open:
//   * in-library copy returned directly (owner/collaborator/followed);
//   * otherwise fetched + hydrated under RLS;
//   * a deleted / private-inaccessible / blocked target (null fetch) → null so
//     the caller shows a non-destructive message instead of crashing.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/app_notification.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/presentation/screens/notifications_screen.dart';

AppNotification _notif(String pid, {String type = NotificationType.invited}) =>
    AppNotification.fromMap({
      'id': 'n1',
      'user_id': 'u1',
      'type': type,
      'title': 'Paax',
      'body': 'x',
      'data': {'playlist_id': pid},
      'entity_type': 'playlist',
      'entity_id': pid,
      'created_at': '2026-08-04T10:00:00Z',
    });

Playlist _pl(String id) =>
    Playlist(id: id, name: 'PL $id', tracks: const [], createdAt: DateTime(2026, 8, 4));

void main() {
  test('in-library playlist is returned directly (no fetch)', () async {
    var fetched = false;
    final target = await resolveNotificationPlaylistTarget(
      _notif('pl-1'),
      [_pl('pl-1'), _pl('pl-2')],
      fetch: (_) async {
        fetched = true;
        return null;
      },
      hydrate: (_) async => _pl('should-not-be-used'),
    );
    expect(target?.id, 'pl-1');
    expect(fetched, isFalse);
  });

  test('not-in-library but accessible → fetched + hydrated', () async {
    final target = await resolveNotificationPlaylistTarget(
      _notif('pl-cloud'),
      const [],
      fetch: (id) async => {'id': id, 'name': 'Cloud'},
      hydrate: (row) async => _pl(row['id'].toString()),
    );
    expect(target?.id, 'pl-cloud');
  });

  test('deleted / inaccessible target (null fetch) → null', () async {
    final target = await resolveNotificationPlaylistTarget(
      _notif('gone'),
      const [],
      fetch: (_) async => null, // RLS-filtered: deleted / no-access / blocked
      hydrate: (_) async => _pl('x'),
    );
    expect(target, isNull);
  });

  test('fetch error → null (graceful, no throw)', () async {
    final target = await resolveNotificationPlaylistTarget(
      _notif('boom'),
      const [],
      fetch: (_) async => throw Exception('network'),
      hydrate: (_) async => _pl('x'),
    );
    expect(target, isNull);
  });

  test('non-playlist notification → null', () async {
    final n = AppNotification.fromMap({
      'id': 'n', 'user_id': 'u', 'type': 'system', 'title': 't', 'body': 'b',
      'data': const {}, 'created_at': '2026-08-04T10:00:00Z',
    });
    final target = await resolveNotificationPlaylistTarget(
      n, const [],
      fetch: (_) async => {'id': 'x'},
      hydrate: (_) async => _pl('x'),
    );
    expect(target, isNull);
  });
}
