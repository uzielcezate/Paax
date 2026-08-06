// test/unit/playlist_activity_rpc_row_test.dart — Phase 3.4.1.2C regression.
//
// Regresses the PRODUCTION Activity failure: the client read activity via a
// PostgREST embed `playlist_activity?select=*,profiles:actor_id(...)`, but
// actor_id has no FK to profiles → 400 (PGRST200) → "Couldn't load activity".
// The fix routes through the SECURITY DEFINER `playlist_get_activity` RPC, which
// returns FLAT actor columns (actor_username / actor_display_name /
// actor_avatar_url / actor_avatar_original_url). These tests pin
// PlaylistActivity.fromRpcRow to that exact shape and prove every stored event
// type renders with a human actor (never a raw UUID).

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';

// A row shaped exactly like a `playlist_get_activity` result.
Map<String, dynamic> _rpcRow(
  String id,
  String type, {
  String actorUuid = '266ac582-20e7-4ebb-9090-36a4e07c4947',
  String? username = 'uziel',
  String? displayName = 'Uziel Sandoval',
  String? avatar,
  Map<String, dynamic> metadata = const {},
  int version = 1,
}) =>
    {
      'id': id,
      'playlist_id': 'd5320c88-3562-4f77-9a87-eac592cf361f',
      'actor_id': actorUuid,
      'event_type': type,
      'created_at': '2026-08-04T00:16:02.670766+00:00',
      'playlist_version': version,
      'metadata': metadata,
      'grouped_change_id': 'g-$id',
      'actor_username': username,
      'actor_display_name': displayName,
      'actor_avatar_url': avatar,
      'actor_avatar_original_url': null,
    };

void main() {
  group('fromRpcRow parses the flat RPC actor shape', () {
    test('resolves actor username + avatar; never surfaces the UUID', () {
      final a = PlaylistActivity.fromRpcRow(_rpcRow('1', 'playlist_created',
          avatar: 'https://cdn/av.webp',
          metadata: {'title': 'prueba 3', 'track_count': 0}));
      expect(a.actorUsername, 'uziel');
      expect(a.actorAvatarUrl, 'https://cdn/av.webp');
      expect(a.actorLabel, 'uziel');
      expect(a.actorLabel.contains('266ac582'), isFalse);
      expect(a.eventType, 'playlist_created');
    });

    test('falls back to display_name, then "Deleted user" (never a UUID)', () {
      final noUsername =
          PlaylistActivity.fromRpcRow(_rpcRow('2', 'tracks_added', username: null));
      expect(noUsername.actorUsername, 'Uziel Sandoval');

      final noActor = PlaylistActivity.fromRpcRow(
          _rpcRow('3', 'tracks_added', username: null, displayName: null));
      expect(noActor.actorLabel, 'Deleted user');
      expect(noActor.actorLabel.contains('-'), isFalse); // not a uuid
    });

    test('still parses a legacy nested profiles embed row', () {
      final legacy = PlaylistActivity.fromRpcRow({
        'id': '9',
        'playlist_id': 'p',
        'actor_id': 'u',
        'event_type': 'tracks_added',
        'created_at': '2026-08-04T00:16:02Z',
        'metadata': const {'count': 1},
        'profiles': {'username': 'maria205', 'avatar_url': 'a.png'},
      });
      expect(legacy.actorUsername, 'maria205');
      expect(legacy.actorAvatarUrl, 'a.png');
    });
  });

  test('a full page of EVERY stored event type renders (created not suppressed)',
      () {
    // Mirrors the acceptance list: the sheet must show every stored event.
    final page = <Map<String, dynamic>>[
      _rpcRow('e7', 'ownership_transferred', metadata: {'to': 'uuid-should-not-leak'}, version: 7),
      _rpcRow('e6', 'collaborator_joined', version: 6),
      _rpcRow('e5', 'visibility_changed', metadata: {'from': 'private', 'to': 'public'}, version: 5),
      _rpcRow('e4', 'playlist_renamed', metadata: {'to': 'Verano'}, version: 4),
      _rpcRow('e3', 'tracks_removed', metadata: {
        'count': 2,
        'tracks': [{'id': 't1', 'title': 'MONACO'}, {'id': 't2', 'title': 'DtMF'}]
      }, version: 3),
      _rpcRow('e2', 'tracks_added', metadata: {
        'count': 5,
        'tracks': [
          {'id': 'a', 'title': 'Duro'},
          {'id': 'b', 'title': 'WASSUP'},
          {'id': 'c', 'title': 'offline'},
          {'id': 'd', 'title': 'Perro Negro'},
          {'id': 'e', 'title': 'MERCEDES'},
        ]
      }, version: 2),
      _rpcRow('e1', 'playlist_created', metadata: {'title': 'prueba 3'}, version: 1),
    ];

    final parsed = page.map(PlaylistActivity.fromRpcRow).toList();
    expect(parsed.length, 7);

    // Created is present and not suppressed by later events.
    expect(parsed.any((a) => a.eventType == 'playlist_created'), isTrue);

    // Every event yields a human headline with a real actor (no raw UUID).
    for (final a in parsed) {
      final h = ActivitySummary.headline(a);
      expect(h.trim(), isNotEmpty);
      expect(h.contains('266ac582'), isFalse);
      expect(h.contains('uuid-should-not-leak'), isFalse);
    }

    // Bounded track overflow ("and N more").
    final added = parsed.firstWhere((a) => a.eventType == 'tracks_added');
    final summary = ActivitySummary.inlineTrackSummary(added, max: 3);
    expect(summary, 'Duro, WASSUP, offline and 2 more');
  });
}
