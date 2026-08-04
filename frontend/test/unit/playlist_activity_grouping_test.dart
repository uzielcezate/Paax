// test/unit/playlist_activity_grouping_test.dart — Phase 3.4.1.2A.
//
// Presentation grouping rules for the activity timeline.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';
import 'package:beaty/domain/entities/playlist_activity_grouping.dart';

final _base = DateTime(2026, 8, 4, 12, 0, 0);

PlaylistActivity _ev(
  String id,
  String type, {
  String actor = 'a1',
  int minutes = 0,
  List<String> titles = const [],
}) =>
    PlaylistActivity(
      id: id,
      playlistId: 'p',
      actorId: actor,
      actorUsername: actor,
      eventType: type,
      createdAt: _base.subtract(Duration(minutes: minutes)),
      metadata: {
        'count': titles.length,
        'tracks': titles.map((t) => {'title': t}).toList(),
      },
    );

void main() {
  test('one-by-one adds by same actor within 5 min group into one', () {
    // newest-first
    final rows = ActivityGrouper.group([
      _ev('3', 'tracks_added', minutes: 0, titles: ['C']),
      _ev('2', 'tracks_added', minutes: 2, titles: ['B']),
      _ev('1', 'tracks_added', minutes: 4, titles: ['A']),
    ]);
    expect(rows.length, 1);
    expect(rows.first.metadata['count'], 3);
    // chronological (oldest-first) title order
    final titles = (rows.first.metadata['tracks'] as List)
        .map((e) => (e as Map)['title'])
        .toList();
    expect(titles, ['A', 'B', 'C']);
  });

  test('same actor OUTSIDE 5 min → separate groups', () {
    final rows = ActivityGrouper.group([
      _ev('2', 'tracks_added', minutes: 0, titles: ['B']),
      _ev('1', 'tracks_added', minutes: 8, titles: ['A']),
    ]);
    expect(rows.length, 2);
  });

  test('different actors within 5 min → separate groups', () {
    final rows = ActivityGrouper.group([
      _ev('2', 'tracks_added', actor: 'a2', minutes: 0, titles: ['B']),
      _ev('1', 'tracks_added', actor: 'a1', minutes: 1, titles: ['A']),
    ]);
    expect(rows.length, 2);
  });

  test('add then remove are never grouped', () {
    final rows = ActivityGrouper.group([
      _ev('2', 'tracks_removed', minutes: 0, titles: ['B']),
      _ev('1', 'tracks_added', minutes: 1, titles: ['A']),
    ]);
    expect(rows.length, 2);
  });

  test('create/rename/visibility are singular and never merged', () {
    final rows = ActivityGrouper.group([
      _ev('3', 'visibility_changed', minutes: 0),
      _ev('2', 'playlist_renamed', minutes: 1),
      _ev('1', 'playlist_created', minutes: 2),
    ]);
    expect(rows.length, 3);
  });

  test('created never suppresses later events; newest-first preserved', () {
    final rows = ActivityGrouper.group([
      _ev('2', 'tracks_added', minutes: 0, titles: ['New']),
      _ev('1', 'playlist_created', minutes: 4),
    ]);
    expect(rows.length, 2);
    expect(rows.first.eventType, 'tracks_added');
    expect(rows.last.eventType, 'playlist_created');
  });

  test('a single multi-track RPC event is one group already', () {
    final rows = ActivityGrouper.group([
      _ev('1', 'tracks_added', titles: ['A', 'B', 'C', 'D']),
    ]);
    expect(rows.length, 1);
    expect(rows.first.metadata['count'], 4);
  });

  group('dedupeById', () {
    test('removes duplicate ids, keeps first, preserves order', () {
      final out = ActivityGrouper.dedupeById([
        _ev('1', 'tracks_added'),
        _ev('2', 'tracks_added'),
        _ev('1', 'tracks_added'),
      ]);
      expect(out.map((e) => e.id), ['1', '2']);
    });
  });
}
