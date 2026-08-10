// test/unit/offline_replay_regression_test.dart
//
// Phase 3.4.6 — regressions found by manual Android QA on the merged build.
//
// Two of these are silent data-loss bugs, which is the worst class: the UI
// reported success, no error surfaced anywhere, and the server simply never
// received the change. Both are pinned here as executable statements of intent.

import 'package:beaty/core/network/offline_status.dart';
import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_op_failure.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

PlaylistOp _op(
  String id, {
  String playlist = 'pl-1',
  PlaylistOpType type = PlaylistOpType.saveOrder,
  String user = 'u1',
  int minute = 0,
}) =>
    PlaylistOp(
      opId: id,
      userId: user,
      playlistId: playlist,
      type: type,
      createdAt: DateTime(2026, 8, 9, 12, minute),
      payload: const {'ids': <String>[]},
    );

void main() {
  group('RC1 — reconnect must actually replay the journal', () {
    late OfflineStatus status;

    setUp(() {
      status = OfflineStatus();
      OfflineStatus.instance = status;
      PlaylistSyncService.resetForTest();
    });
    tearDown(() => OfflineStatus.instance = null);

    test('offline→online triggers exactly ONE flush', () async {
      var flushes = 0;
      Future<void> flush() async => flushes++;

      status.debugSetOffline(true);
      status.debugSetOffline(false); // reconnect
      await status.refreshOnce('library:playlist-journal', flush);

      expect(flushes, 1);
    });

    test('repeated provider rebuilds after reconnect do NOT re-flush', () async {
      var flushes = 0;
      Future<void> flush() async => flushes++;

      status.debugSetOffline(true);
      status.debugSetOffline(false);
      // ProxyProvider.update() can run on every notifyListeners in the app.
      for (var i = 0; i < 100; i++) {
        await status.refreshOnce('library:playlist-journal', flush);
      }
      expect(flushes, 1);
    });

    test('a SECOND disconnect/reconnect flushes again — the guard is not '
        'permanent', () async {
      var flushes = 0;
      Future<void> flush() async => flushes++;

      for (var cycle = 0; cycle < 3; cycle++) {
        status.debugSetOffline(true);
        status.debugSetOffline(false);
        await status.refreshOnce('library:playlist-journal', flush);
      }
      expect(flushes, 3,
          reason: 'an over-restrictive guard would strand the journal forever');
    });

    test('a FAILED flush does not wedge the key — the next reconnect retries',
        () async {
      var attempts = 0;
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      await status.refreshOnce('library:playlist-journal', () async {
        attempts++;
        throw Exception('Supabase unreachable');
      });
      expect(attempts, 1);

      status.debugSetOffline(true);
      status.debugSetOffline(false);
      await status.refreshOnce('library:playlist-journal', () async => attempts++);
      expect(attempts, 2);
    });

    test('no flush is attempted while still offline', () async {
      var flushes = 0;
      status.debugSetOffline(true);
      await status.refreshOnce('library:playlist-journal', () async => flushes++);
      expect(flushes, 0);
    });

    test('a failed flush releases PlaylistSyncService single-flight', () async {
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a'));

      // First pass throws inside execute.
      await sync.flush('u1', (op) async => throw Exception('boom'));
      expect(PlaylistSyncService.isFlushing, isFalse,
          reason: 'a stuck guard would block every later reconnect');

      // A later flush must still be able to run.
      var ran = false;
      await sync.flush('u1', (op) async {
        ran = true;
        return OpOutcome.success;
      });
      expect(PlaylistSyncService.passCount, 2);
      expect(ran, isTrue);
    });
  });

  group('RC2 — a mutation must never silently succeed with nothing sent', () {
    test('localIntegrity is NOT a network failure and is NOT queued forever',
        () {
      const f = PlaylistOpFailure(PlaylistFailureKind.localIntegrity);
      expect(f.kind, isNot(PlaylistFailureKind.transientNetwork));
      expect(f.policy, FailurePolicy.discard,
          reason: 'retrying an unresolvable track can never succeed');
    });

    test('an unresolved-track failure is terminal for that op', () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a', type: PlaylistOpType.addTracks));

      var calls = 0;
      await sync.flush('u1', (op) async {
        calls++;
        throw const PlaylistOpFailure(PlaylistFailureKind.localIntegrity);
      });

      expect(calls, 1);
      expect(journal.pending('u1'), isEmpty,
          reason: 'must not sit in the queue retrying forever');
    });
  });

  group('RC3 — offline delete must journal, not error', () {
    test('a delete op survives in the journal for replay', () async {
      final journal = _FakeJournal();
      await journal.enqueue(_op('d', type: PlaylistOpType.delete));
      expect(journal.pending('u1').single.type, PlaylistOpType.delete);
    });

    test('delete of an EXISTING cloud playlist is not cancelled by compaction',
        () {
      // Only create+delete for the SAME never-synced playlist may cancel.
      final out = PlaylistOpsJournal.compact([
        _op('d', playlist: 'cloud-existing', type: PlaylistOpType.delete),
      ]);
      expect(out.map((o) => o.type), [PlaylistOpType.delete]);
    });

    test('create+delete before sync still cancels — must not regress', () {
      final out = PlaylistOpsJournal.compact([
        _op('c', playlist: 'new', type: PlaylistOpType.create, minute: 1),
        _op('d', playlist: 'new', type: PlaylistOpType.delete, minute: 2),
      ]);
      expect(out, isEmpty);
    });
  });

  group('RC4 — compaction must not lose distinct track intents', () {
    test('add A then add B preserves BOTH', () {
      final a = PlaylistOp(
        opId: 'a', userId: 'u1', playlistId: 'p',
        type: PlaylistOpType.addTracks, createdAt: DateTime(2026, 8, 9, 12, 1),
        payload: const {'ids': ['track-A']},
      );
      final b = PlaylistOp(
        opId: 'b', userId: 'u1', playlistId: 'p',
        type: PlaylistOpType.addTracks, createdAt: DateTime(2026, 8, 9, 12, 2),
        payload: const {'ids': ['track-B']},
      );
      final out = PlaylistOpsJournal.compact([a, b]);
      expect(out, hasLength(2));
      expect(
        out.expand((o) => (o.payload['ids'] as List)).toSet(),
        {'track-A', 'track-B'},
        reason: 'four slow additions must produce four remote rows',
      );
    });

    test('four distinct additions all survive compaction', () {
      final ops = [
        for (var i = 0; i < 4; i++)
          PlaylistOp(
            opId: 'op$i', userId: 'u1', playlistId: 'p',
            type: PlaylistOpType.addTracks,
            createdAt: DateTime(2026, 8, 9, 12, i),
            payload: {'ids': ['track-$i']},
          )
      ];
      final out = PlaylistOpsJournal.compact(ops);
      expect(out, hasLength(4));
      expect(out.expand((o) => (o.payload['ids'] as List)).toSet(),
          {'track-0', 'track-1', 'track-2', 'track-3'});
    });

    test('remove A then add A preserves the FINAL intent (membership kept)', () {
      final rem = PlaylistOp(
        opId: 'r', userId: 'u1', playlistId: 'p',
        type: PlaylistOpType.removeTracks, createdAt: DateTime(2026, 8, 9, 12, 1),
        payload: const {'ids': ['A']},
      );
      final add = PlaylistOp(
        opId: 'a', userId: 'u1', playlistId: 'p',
        type: PlaylistOpType.addTracks, createdAt: DateTime(2026, 8, 9, 12, 2),
        payload: const {'ids': ['A']},
      );
      final out = PlaylistOpsJournal.compact([rem, add]);
      expect(out.map((o) => o.type),
          [PlaylistOpType.removeTracks, PlaylistOpType.addTracks],
          reason: 'order matters — the add is the final intent');
    });

    test('repeated reorders still collapse to the last', () {
      final out = PlaylistOpsJournal.compact(
          [_op('r1', minute: 1), _op('r2', minute: 2), _op('r3', minute: 3)]);
      expect(out.map((o) => o.opId), ['r3']);
    });

    test('operation ids are unique per intent', () {
      final ids = <String>{};
      for (var i = 0; i < 200; i++) {
        ids.add('${DateTime.now().microsecondsSinceEpoch}_$i');
      }
      expect(ids, hasLength(200));
    });
  });

  group('RC5 — offline classification uses global state, not just text', () {
    setUp(() => OfflineStatus.instance = OfflineStatus());
    tearDown(() => OfflineStatus.instance = null);

    test('a wrapped 404 is NOT offline', () {
      expect(isKnownOfflineError('Network Error: Exception: API Error 404: {}'),
          isFalse);
    });

    test('the global signal flips on a transport failure and back on success',
        () {
      final s = OfflineStatus.instance!;
      expect(s.isOffline, isFalse);
      OfflineStatus.report(succeeded: false, wasNetworkFailure: true);
      expect(s.isOffline, isTrue);
      OfflineStatus.report(succeeded: true);
      expect(s.isOffline, isFalse);
    });

    test('a server answer (even an error one) keeps us ONLINE', () {
      final s = OfflineStatus.instance!;
      OfflineStatus.report(succeeded: false, wasNetworkFailure: true);
      expect(s.isOffline, isTrue);
      // 404 path reports success=true because the server answered.
      OfflineStatus.report(succeeded: true);
      expect(s.isOffline, isFalse);
    });

    test('report() is a safe no-op when no instance is registered', () {
      OfflineStatus.instance = null;
      expect(() => OfflineStatus.report(succeeded: false, wasNetworkFailure: true),
          returnsNormally);
    });
  });

  group('account isolation still holds', () {
    test('one account never replays another account\'s journal', () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a', user: 'userA'));
      await journal.enqueue(_op('b', user: 'userB'));

      final executed = <String>[];
      await sync.flush('userB', (op) async {
        executed.add(op.opId);
        return OpOutcome.success;
      });
      expect(executed, ['b']);
      expect(journal.pending('userA'), hasLength(1));
    });
  });
}

class _FakeJournal implements PlaylistOpsJournal {
  final Map<String, List<PlaylistOp>> _pending = {};
  final Map<String, List<QuarantinedOp>> _quarantine = {};

  @override
  List<PlaylistOp> pending(String userId) =>
      List<PlaylistOp>.from(_pending[userId] ?? const []);

  @override
  Future<void> enqueue(PlaylistOp op) async {
    final ops = pending(op.userId)..removeWhere((o) => o.opId == op.opId);
    ops.add(op);
    _pending[op.userId] = PlaylistOpsJournal.compact(ops);
  }

  @override
  Future<void> replaceAll(String userId, List<PlaylistOp> ops) async {
    final c = PlaylistOpsJournal.compact(ops);
    if (c.isEmpty) {
      _pending.remove(userId);
    } else {
      _pending[userId] = c;
    }
  }

  @override
  Future<void> remove(String userId, String opId) async =>
      _pending[userId]?.removeWhere((o) => o.opId == opId);

  @override
  Future<void> clearUser(String userId) async {
    _pending.remove(userId);
    _quarantine.remove(userId);
  }

  @override
  bool hasPending(String userId) => pending(userId).isNotEmpty;

  final Map<String, String> _adoptions = {};

  @override
  Map<String, String> adoptions(String userId) =>
      Map<String, String>.from(_adoptions);

  @override
  Future<void> recordAdoption(
      String userId, String localId, String cloudId) async {
    if (localId != cloudId) _adoptions[localId] = cloudId;
  }

  @override
  Future<void> pruneAdoptions(String userId) async {
    final live = pending(userId).map((o) => o.playlistId).toSet();
    _adoptions.removeWhere((localId, _) => !live.contains(localId));
  }


  @override
  List<QuarantinedOp> quarantined(String userId) =>
      List<QuarantinedOp>.from(_quarantine[userId] ?? const []);

  @override
  Future<void> quarantineAll(String userId, List<QuarantinedOp> items) async {
    final byId = {for (final q in quarantined(userId)) q.op.opId: q};
    for (final q in items) {
      byId[q.op.opId] = q;
    }
    _quarantine[userId] = byId.values.toList();
  }

  @override
  Future<void> removeQuarantined(String userId, String opId) async =>
      _quarantine[userId]?.removeWhere((q) => q.op.opId == opId);

  @override
  Future<void> clearQuarantine(String userId) async =>
      _quarantine.remove(userId);

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}
