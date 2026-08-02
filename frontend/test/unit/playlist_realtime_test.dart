// test/unit/playlist_realtime_test.dart — Phase 3.4.1 realtime lifecycle guards.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/remote/playlist_realtime_service.dart';

class _FakeSub implements PlaylistRealtimeSub {
  final void Function() onClose;
  bool closed = false;
  _FakeSub(this.onClose);
  @override
  Future<void> close() async { closed = true; onClose(); }
}

class _FakeBackend implements PlaylistRealtimeBackend {
  int subscribeCalls = 0;
  final Map<String, void Function(PlaylistRealtimeEvent)> cbs = {};
  final List<_FakeSub> subs = [];
  @override
  PlaylistRealtimeSub subscribe(String pid, void Function(PlaylistRealtimeEvent) onEvent) {
    subscribeCalls++;
    cbs[pid] = onEvent;
    final s = _FakeSub(() => cbs.remove(pid));
    subs.add(s);
    return s;
  }
  void push(String pid, PlaylistRealtimeEvent e) => cbs[pid]?.call(e);
  bool subscribed(String pid) => cbs.containsKey(pid);
}

void main() {
  const p = 'playlist-1';

  test('ref-counted: two subscribes share one channel; closes on last leave', () async {
    final be = _FakeBackend();
    final s = PlaylistRealtimeService(be);
    await s.subscribe(p);
    await s.subscribe(p); // e.g. Related-nav second instance
    expect(be.subscribeCalls, 1);
    await s.unsubscribe(p);
    expect(be.subscribed(p), isTrue); // still one watcher
    await s.unsubscribe(p);
    expect(be.subscribed(p), isFalse); // last watcher left → closed
    expect(be.subs.first.closed, isTrue);
  });

  test('version guard: stale playlist events ignored, newer applied', () async {
    final be = _FakeBackend();
    final s = PlaylistRealtimeService(be);
    final seen = <int?>[];
    s.addListener(p, (e) { if (e.kind == 'playlist') seen.add(e.version); });
    await s.subscribe(p);
    be.push(p, const PlaylistRealtimeEvent('playlist', version: 5));
    be.push(p, const PlaylistRealtimeEvent('playlist', version: 4)); // stale
    be.push(p, const PlaylistRealtimeEvent('playlist', version: 5)); // equal → stale
    be.push(p, const PlaylistRealtimeEvent('playlist', version: 6)); // newer
    expect(seen, [5, 6]);
  });

  test('non-playlist events (tracks/collaborators/activity) always dispatch', () async {
    final be = _FakeBackend();
    final s = PlaylistRealtimeService(be);
    final kinds = <String>[];
    s.addListener(p, (e) => kinds.add(e.kind));
    await s.subscribe(p);
    be.push(p, const PlaylistRealtimeEvent('tracks'));
    be.push(p, const PlaylistRealtimeEvent('collaborators'));
    be.push(p, const PlaylistRealtimeEvent('activity'));
    expect(kinds, ['tracks', 'collaborators', 'activity']);
  });

  test('account switch tears down channels', () async {
    final be = _FakeBackend();
    final s = PlaylistRealtimeService(be);
    await s.onUserSession('u1');
    await s.subscribe(p);
    expect(be.subscribed(p), isTrue);
    await s.onUserSession('u2');
    expect(be.subscribed(p), isFalse);
    expect(be.subs.first.closed, isTrue);
  });

  test('deleted event dispatches to listeners', () async {
    final be = _FakeBackend();
    final s = PlaylistRealtimeService(be);
    var deleted = false;
    s.addListener(p, (e) { if (e.kind == 'deleted') deleted = true; });
    await s.subscribe(p);
    be.push(p, const PlaylistRealtimeEvent('deleted'));
    expect(deleted, isTrue);
  });
}
