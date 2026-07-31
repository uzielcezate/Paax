// test/unit/follower_count_service_test.dart
//
// Phase 3.3.5 — Real-Time Global Artist Follower Counts.
//
// Verifies the authoritative-count + realtime-reconciliation logic in
// FollowerCountService against a fake backend (headless, no Supabase). Covers
// the 12 required scenarios: authoritative rendering, optimistic+reconcile,
// never-0-while-another-follows, reopen retention, remote follow/unfollow via
// realtime, stale-API-cannot-overwrite, related-nav shared channel, duplicate
// subscription prevention, disposal/reconnect, multi-account isolation, and
// singular/plural formatting.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/remote/follower_count_service.dart';
import 'package:beaty/core/utils/string_utils.dart';

class _FakeSub implements FollowerSubscription {
  final void Function() onClose;
  bool closed = false;
  _FakeSub(this.onClose);
  @override
  Future<void> close() async {
    closed = true;
    onClose();
  }
}

/// Fake transport: holds server counts, exposes a `pushRemote` helper to
/// simulate a realtime UPDATE from ANY user, and counts subscribe/fetch calls.
class _FakeBackend implements FollowerCountBackend {
  final Map<String, int> server;
  int fetchCalls = 0;
  int subscribeCalls = 0;
  final Map<String, void Function(int)> _callbacks = {};
  final List<_FakeSub> subs = [];

  _FakeBackend([Map<String, int>? initial]) : server = initial ?? {};

  @override
  Future<int?> fetchCount(String uuid) async {
    fetchCalls++;
    return server[uuid];
  }

  @override
  FollowerSubscription subscribe(String uuid, void Function(int) onCount) {
    subscribeCalls++;
    _callbacks[uuid] = onCount;
    final sub = _FakeSub(() => _callbacks.remove(uuid));
    subs.add(sub);
    return sub;
  }

  /// Simulate a realtime event (a follow/unfollow by any user).
  void pushRemote(String uuid, int count) {
    server[uuid] = count;
    _callbacks[uuid]?.call(count);
  }

  bool isSubscribed(String uuid) => _callbacks.containsKey(uuid);
}

void main() {
  const a = '603305d4-641b-4c26-a671-a94189e3d5ac'; // Maria Daniela canonical uuid

  test('1. initial server count 1, user not following → shows 1', () async {
    final be = _FakeBackend({a: 1});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    expect(s.countOf(a), 1);
  });

  test('2. user follows → optimistic 2 → server confirms 2', () async {
    final be = _FakeBackend({a: 1});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    s.applyOptimistic(a, 1); // optimistic immediately
    expect(s.countOf(a), 2);
    be.pushRemote(a, 2); // realtime from our own write reconciles
    expect(s.countOf(a), 2);
  });

  test('3. user unfollows while another remains → 1, NEVER 0', () async {
    final be = _FakeBackend({a: 2});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    final seen = <int?>[];
    s.listenable(a).addListener(() => seen.add(s.listenable(a).value));
    s.applyOptimistic(a, -1); // optimistic 1
    be.pushRemote(a, 1); // authoritative: other user still follows
    expect(s.countOf(a), 1);
    expect(seen.contains(0), isFalse, reason: 'must never flash 0');
  });

  test('4. reopening the artist retains the authoritative count', () async {
    final be = _FakeBackend({a: 2});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    be.pushRemote(a, 5); // count grows while open
    await s.unsubscribe(a); // leave screen
    await s.subscribe(a); // reopen → authoritative refresh
    expect(s.countOf(a), 5);
  });

  test('5. remote user follows while screen open → realtime 1 → 2', () async {
    final be = _FakeBackend({a: 1});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    expect(s.countOf(a), 1);
    be.pushRemote(a, 2); // User A follows; User B is watching
    expect(s.countOf(a), 2);
  });

  test('6. remote user unfollows while screen open → realtime 2 → 1', () async {
    final be = _FakeBackend({a: 2});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    be.pushRemote(a, 1);
    expect(s.countOf(a), 1);
  });

  test('7. stale cached API response cannot overwrite a newer realtime value',
      () async {
    final be = _FakeBackend({a: 1});
    final s = FollowerCountService(be);
    // A stale seed applies only while nothing authoritative is known.
    s.seedFromApi(a, 1);
    expect(s.countOf(a), 1);
    await s.subscribe(a); // authoritative refresh = 1
    be.pushRemote(a, 2); // realtime bumps to 2 (authoritative)
    expect(s.countOf(a), 2);
    s.seedFromApi(a, 1); // a late/stale API payload arrives — must be IGNORED
    expect(s.countOf(a), 2);
  });

  test('8. related-artist navigation shares one channel + live count', () async {
    final be = _FakeBackend({a: 3});
    final s = FollowerCountService(be);
    await s.subscribe(a); // screen 1 (artist)
    await s.subscribe(a); // screen 2 (same artist via Related Artists)
    expect(be.subscribeCalls, 1); // ONE realtime channel shared
    be.pushRemote(a, 4);
    expect(s.listenable(a).value, 4); // both screens see it (same listenable)
  });

  test('9. duplicate subscription prevention', () async {
    final be = _FakeBackend({a: 1});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    await s.subscribe(a);
    await s.subscribe(a);
    expect(be.subscribeCalls, 1);
  });

  test('10. disposal closes the last channel; resume reconciles missed events',
      () async {
    final be = _FakeBackend({a: 2});
    final s = FollowerCountService(be);
    await s.subscribe(a); // ref 1
    await s.subscribe(a); // ref 2
    await s.unsubscribe(a); // ref 1 — channel stays open
    expect(be.isSubscribed(a), isTrue);
    expect(be.subs.first.closed, isFalse);
    await s.unsubscribe(a); // ref 0 — channel closed
    expect(be.isSubscribed(a), isFalse);
    expect(be.subs.first.closed, isTrue);

    // Reconnect / app-resume path: a value changed while disconnected (no event
    // delivered) is picked up by an authoritative refresh.
    await s.subscribe(a);
    be.server[a] = 7; // changed silently (missed realtime)
    await s.refresh(a);
    expect(s.countOf(a), 7);
  });

  test('11. multi-account switch isolation drops channels + cached state',
      () async {
    final be = _FakeBackend({a: 2});
    final s = FollowerCountService(be);
    await s.onUserSession('user-1');
    await s.subscribe(a);
    expect(s.countOf(a), 2);
    await s.onUserSession('user-2'); // account switch
    expect(s.countOf(a), isNull); // cached count cleared
    expect(be.isSubscribed(a), isFalse); // channel torn down
    expect(be.subs.first.closed, isTrue);
    // New session re-reads authoritative cleanly.
    await s.subscribe(a);
    expect(s.countOf(a), 2);
  });

  test('12. singular/plural formatting', () {
    expect(formatFollowers(0), '0 Followers');
    expect(formatFollowers(1), '1 Follower');
    expect(formatFollowers(2), '2 Followers');
  });

  test('bonus: optimistic unfollow floors at 0 (never negative)', () async {
    final be = _FakeBackend({a: 0});
    final s = FollowerCountService(be);
    await s.subscribe(a);
    s.applyOptimistic(a, -1);
    expect(s.countOf(a), 0);
  });
}
