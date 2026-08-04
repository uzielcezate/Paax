// test/unit/playlist_activity_timeline_controller_test.dart — Phase 3.4.1.2A.
//
// Paginated + realtime timeline state: initial load, load-more keyset,
// realtime append (deduped), newest-first ordering, and the created event
// never suppressing later events.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/remote/playlist_realtime_service.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';
import 'package:beaty/presentation/state/playlist_activity_timeline_controller.dart';

class _Sub implements PlaylistRealtimeSub {
  @override
  Future<void> close() async {}
}

class _Backend implements PlaylistRealtimeBackend {
  final Map<String, void Function(PlaylistRealtimeEvent)> cbs = {};
  @override
  PlaylistRealtimeSub subscribe(
      String pid, void Function(PlaylistRealtimeEvent) onEvent) {
    cbs[pid] = onEvent;
    return _Sub();
  }

  void push(String pid, PlaylistRealtimeEvent e) => cbs[pid]?.call(e);
}

final _base = DateTime(2026, 8, 4, 12, 0, 0);

PlaylistActivity _ev(String id, String type, {int minutes = 0}) => PlaylistActivity(
      id: id,
      playlistId: 'p',
      actorId: 'a1',
      actorUsername: 'uziel',
      eventType: type,
      createdAt: _base.subtract(Duration(minutes: minutes)),
      metadata: const {'count': 1, 'tracks': [{'title': 'X'}]},
    );

void main() {
  test('initial load surfaces the full history (not just created)', () async {
    final pages = [
      [_ev('3', 'tracks_added'), _ev('2', 'visibility_changed', minutes: 1), _ev('1', 'playlist_created', minutes: 4)]
    ];
    final c = PlaylistActivityTimelineController(
      fetchPage: ({int limit = 30, DateTime? before}) async => pages.first,
      realtime: PlaylistRealtimeService(_Backend()),
      playlistId: 'p',
      pageSize: 30,
    );
    await c.load();
    expect(c.isEmpty, isFalse);
    expect(c.rows.length, 3);
    expect(c.rows.first.eventType, 'tracks_added'); // newest first
    expect(c.rows.any((r) => r.eventType == 'playlist_created'), isTrue);
  });

  test('hasMore true only when a full page returns', () async {
    final full = List.generate(30, (i) => _ev('$i', 'tracks_added', minutes: i));
    final c = PlaylistActivityTimelineController(
      fetchPage: ({int limit = 30, DateTime? before}) async => full,
      realtime: PlaylistRealtimeService(_Backend()),
      playlistId: 'p',
    );
    await c.load();
    expect(c.hasMore, isTrue);

    final c2 = PlaylistActivityTimelineController(
      fetchPage: ({int limit = 30, DateTime? before}) async => [_ev('1', 'tracks_added')],
      realtime: PlaylistRealtimeService(_Backend()),
      playlistId: 'p',
    );
    await c2.load();
    expect(c2.hasMore, isFalse);
  });

  test('loadMore appends older keyset page, deduped', () async {
    final page1 = List.generate(30, (i) => _ev('p1-$i', 'tracks_added', minutes: i));
    final page2 = [
      _ev('p1-29', 'tracks_added', minutes: 29), // overlap → deduped
      _ev('old', 'tracks_removed', minutes: 40),
    ];
    var calls = 0;
    final c = PlaylistActivityTimelineController(
      fetchPage: ({int limit = 30, DateTime? before}) async {
        calls++;
        return before == null ? page1 : page2;
      },
      realtime: PlaylistRealtimeService(_Backend()),
      playlistId: 'p',
    );
    await c.load();
    await c.loadMore();
    expect(calls, 2);
    // The 30 adjacent adds group into one; 'old' (a later removal, >5min gap)
    // is its own group. Overlap p1-29 is deduped, so the add group's merged
    // count stays 30 (no double-count).
    expect(c.rows.any((r) => r.id == 'old'), isTrue);
    final addGroup = c.rows.firstWhere((r) => r.eventType == 'tracks_added');
    expect(addGroup.metadata['count'], 30);
  });

  test('realtime activity event merges the new event into the head', () async {
    var current = [_ev('1', 'playlist_created', minutes: 5)];
    final be = _Backend();
    final c = PlaylistActivityTimelineController(
      fetchPage: ({int limit = 30, DateTime? before}) async => current,
      realtime: PlaylistRealtimeService(be),
      playlistId: 'p',
    );
    await c.load();
    expect(c.rows.length, 1);
    // A new add happens; the next fetch returns it too.
    current = [_ev('2', 'tracks_added', minutes: 0), _ev('1', 'playlist_created', minutes: 5)];
    be.push('p', const PlaylistRealtimeEvent('activity', record: {'x': 1}));
    await Future<void>.delayed(Duration.zero); // let _mergeNewest run
    expect(c.rows.first.eventType, 'tracks_added');
    expect(c.rows.length, 2);
  });
}
