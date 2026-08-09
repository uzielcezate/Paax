// test/unit/playlist_conflict_terminal_test.dart
//
// Phase 3.4.3 — the incident regression suite.
//
// On 2026-08-08 a stale playlist reorder produced ~2,565 DB executions/sec for
// hours because a deterministic version conflict was signalled with SQLSTATE
// 40001, which PostgREST retries. The server now returns HTTP 409 with a
// machine-readable code. These tests pin the CLIENT half of that contract:
// a conflict must be terminal, must never become a retry, and must never
// multiply — no matter how many times replay is triggered.

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PlaylistOp _op(
  String id, {
  String playlist = 'pl-1',
  PlaylistOpType type = PlaylistOpType.saveOrder,
  int? expected,
  String user = 'u1',
  int minute = 0,
}) =>
    PlaylistOp(
      opId: id,
      userId: user,
      playlistId: playlist,
      type: type,
      createdAt: DateTime(2026, 8, 8, 12, minute),
      expectedVersion: expected,
      payload: const {'ids': <String>[]},
    );

void main() {
  group('409 contract parsing', () {
    test('conflict is recognised by machine-readable code, not message text',
        () {
      // Exactly what the server now returns.
      final e = PostgrestException(
        message: 'PLAYLIST_VERSION_CONFLICT',
        code: 'PLAYLIST_VERSION_CONFLICT',
        details: '{"expected_version" : 41, "actual_version" : 42}',
      );
      expect(e.code, PlaylistConflictException.code);
    });

    test('exception carries expected + actual version for reconciliation', () {
      const c = PlaylistConflictException(expectedVersion: 41, actualVersion: 42);
      expect(c.expectedVersion, 41);
      expect(c.actualVersion, 42);
      expect(c.canRebase, isTrue,
          reason: 'the server told us the truth — no extra fetch needed');
    });

    test('a conflict without versions is still terminal, just not rebasable',
        () {
      const c = PlaylistConflictException();
      expect(c.canRebase, isFalse);
      expect(c.message, PlaylistConflictException.code);
    });
  });

  group('conflicts are TERMINAL — the core incident invariant', () {
    late PlaylistOpsJournal journal;
    late PlaylistSyncService sync;

    setUp(() {
      PlaylistSyncService.resetForTest();
      journal = _FakeJournal();
      sync = PlaylistSyncService(journal);
    });

    test('a conflict executes the op EXACTLY ONCE — never retried', () async {
      await journal.enqueue(_op('a'));
      var calls = 0;
      await sync.flush('u1', (op) async {
        calls++;
        signalConflict(42);
      });
      expect(calls, 1, reason: 'this single assertion is the whole incident');
    });

    test('a conflicted op is NOT re-enqueued — repeated flushes stay at one call',
        () async {
      await journal.enqueue(_op('a'));
      var calls = 0;
      Future<OpOutcome> exec(PlaylistOp op) async {
        calls++;
        signalConflict(42);
      }

      for (var i = 0; i < 10; i++) {
        PlaylistSyncService.resetForTest();
        await sync.flush('u1', exec);
      }
      expect(calls, 1,
          reason: '10 replay passes must not produce 10 requests');
      expect(journal.pending('u1'), isEmpty);
    });

    test('conflict never increments retryCount', () async {
      final op = _op('a');
      await journal.enqueue(op);
      await sync.flush('u1', (o) async => signalConflict(7));
      expect(op.retryCount, 0);
    });

    test('the conflicted op is quarantined with the authoritative version',
        () async {
      await journal.enqueue(_op('a', expected: 41));
      final r = await sync.flush('u1', (o) async => signalConflict(42));

      expect(r.hadConflicts, isTrue);
      expect(r.quarantined, hasLength(1));
      expect(r.quarantined.single.reason, QuarantineReason.conflict);
      expect(r.quarantined.single.actualVersion, 42);
      expect(journal.quarantined('u1'), hasLength(1),
          reason: 'user intent must be preserved, not silently dropped');
    });

    test('after a conflict, later ops for the SAME playlist are quarantined, '
        'not executed against stale state', () async {
      await journal.enqueue(_op('a', playlist: 'pl-1', minute: 1));
      await journal.enqueue(_op('b', playlist: 'pl-1', minute: 2,
          type: PlaylistOpType.addTracks));
      final executed = <String>[];
      final r = await sync.flush('u1', (op) async {
        executed.add(op.opId);
        if (op.opId == 'a') signalConflict(42);
        return OpOutcome.success;
      });

      expect(executed, ['a'], reason: 'b was computed against a stale base');
      expect(r.quarantined.map((q) => q.op.opId), containsAll(['a', 'b']));
      expect(
        r.quarantined.firstWhere((q) => q.op.opId == 'b').reason,
        QuarantineReason.blockedByConflict,
      );
    });

    test('a conflict on playlist A does not block playlist B', () async {
      await journal.enqueue(_op('a', playlist: 'A', minute: 1));
      await journal.enqueue(_op('b', playlist: 'B', minute: 2));
      final executed = <String>[];
      await sync.flush('u1', (op) async {
        executed.add(op.opId);
        if (op.playlistId == 'A') signalConflict(9);
        return OpOutcome.success;
      });
      expect(executed, ['a', 'b']);
    });

    test('forbidden is terminal too', () async {
      await journal.enqueue(_op('a'));
      var calls = 0;
      final r = await sync.flush('u1', (op) async {
        calls++;
        return OpOutcome.forbidden;
      });
      expect(calls, 1);
      expect(r.hadForbidden, isTrue);
      expect(r.quarantined.single.reason, QuarantineReason.forbidden);
    });
  });

  group('single flight — replay cannot be duplicated', () {
    late PlaylistOpsJournal journal;
    late PlaylistSyncService sync;

    setUp(() {
      PlaylistSyncService.resetForTest();
      journal = _FakeJournal();
      sync = PlaylistSyncService(journal);
    });

    test('concurrent flushes run the queue ONCE', () async {
      await journal.enqueue(_op('a'));
      var calls = 0;
      Future<OpOutcome> slow(PlaylistOp op) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return OpOutcome.success;
      }

      final results = await Future.wait([
        sync.flush('u1', slow),
        sync.flush('u1', slow),
        sync.flush('u1', slow),
        sync.flush('u1', slow),
        sync.flush('u1', slow),
      ]);

      expect(calls, 1, reason: 'reconnect storms must not multiply work');
      expect(PlaylistSyncService.passCount, 1);
      expect(results.where((r) => r.skippedInFlight), hasLength(4));
    });

    test('separate service instances still share one flight', () async {
      // Simulates a controller rebuild constructing a second service.
      await journal.enqueue(_op('a'));
      final a = PlaylistSyncService(journal);
      final b = PlaylistSyncService(journal);
      var calls = 0;
      Future<OpOutcome> slow(PlaylistOp op) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return OpOutcome.success;
      }

      await Future.wait([a.flush('u1', slow), b.flush('u1', slow)]);
      expect(calls, 1);
    });

    test('the guard clears so a later flush can run', () async {
      await journal.enqueue(_op('a'));
      await sync.flush('u1', (o) async => OpOutcome.success);
      expect(PlaylistSyncService.isFlushing, isFalse);
      await journal.enqueue(_op('b'));
      await sync.flush('u1', (o) async => OpOutcome.success);
      expect(PlaylistSyncService.passCount, 2);
    });
  });

  group('bounded transient retry', () {
    test('retries are capped and then quarantined — never infinite', () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a'));

      var calls = 0;
      for (var pass = 0; pass < 50; pass++) {
        PlaylistSyncService.resetForTest();
        await sync.flush('u1', (o) async {
          calls++;
          return OpOutcome.retry;
        });
      }
      expect(calls, lessThanOrEqualTo(PlaylistSyncService.maxRetries),
          reason: 'a dead network must not produce unbounded requests');
      expect(journal.pending('u1'), isEmpty);
      expect(
        journal.quarantined('u1').single.reason,
        QuarantineReason.retriesExhausted,
      );
    });
  });

  group('compaction — offline playlist lifecycle', () {
    test('create then delete before sync ⇒ ZERO cloud operations', () {
      final out = PlaylistOpsJournal.compact([
        _op('c', playlist: 'new', type: PlaylistOpType.create, minute: 1),
        _op('a', playlist: 'new', type: PlaylistOpType.addTracks, minute: 2),
        _op('d', playlist: 'new', type: PlaylistOpType.delete, minute: 3),
      ]);
      expect(out, isEmpty,
          reason: 'a playlist that never reached the cloud must never be created there');
    });

    test('deleting an EXISTING cloud playlist keeps the delete, drops the rest',
        () {
      final out = PlaylistOpsJournal.compact([
        _op('o', playlist: 'cloud', type: PlaylistOpType.saveOrder, minute: 1),
        _op('a', playlist: 'cloud', type: PlaylistOpType.addTracks, minute: 2),
        _op('d', playlist: 'cloud', type: PlaylistOpType.delete, minute: 3),
      ]);
      expect(out.map((o) => o.type), [PlaylistOpType.delete]);
    });

    test('repeated reorders collapse to the last one', () {
      final out = PlaylistOpsJournal.compact([
        _op('r1', minute: 1),
        _op('r2', minute: 2),
        _op('r3', minute: 3),
      ]);
      expect(out.map((o) => o.opId), ['r3']);
    });

    test('repeated metadata / follow changes collapse to the last', () {
      final out = PlaylistOpsJournal.compact([
        _op('m1', type: PlaylistOpType.updateMetadata, minute: 1),
        _op('m2', type: PlaylistOpType.updateMetadata, minute: 2),
        _op('f1', type: PlaylistOpType.setFollow, minute: 3),
        _op('f2', type: PlaylistOpType.setFollow, minute: 4),
      ]);
      expect(out.map((o) => o.opId), ['m2', 'f2']);
    });

    test('add/remove track ops are NOT merged — intent must not be lost', () {
      final out = PlaylistOpsJournal.compact([
        _op('a1', type: PlaylistOpType.addTracks, minute: 1),
        _op('r1', type: PlaylistOpType.removeTracks, minute: 2),
        _op('a2', type: PlaylistOpType.addTracks, minute: 3),
      ]);
      expect(out, hasLength(3));
    });

    test('compaction never reorders surviving operations', () {
      final out = PlaylistOpsJournal.compact([
        _op('a', type: PlaylistOpType.addTracks, minute: 1),
        _op('b', type: PlaylistOpType.removeTracks, minute: 2),
        _op('c', type: PlaylistOpType.addTracks, minute: 3),
      ]);
      expect(out.map((o) => o.opId), ['a', 'b', 'c']);
    });

    test('other playlists are untouched by a delete', () {
      final out = PlaylistOpsJournal.compact([
        _op('x', playlist: 'keep', type: PlaylistOpType.addTracks, minute: 1),
        _op('d', playlist: 'gone', type: PlaylistOpType.delete, minute: 2),
      ]);
      expect(out.map((o) => o.opId), ['x', 'd']);
    });

    test('compaction is idempotent', () {
      final input = [
        _op('c', playlist: 'n', type: PlaylistOpType.create, minute: 1),
        _op('d', playlist: 'n', type: PlaylistOpType.delete, minute: 2),
        _op('r1', playlist: 'p', minute: 3),
        _op('r2', playlist: 'p', minute: 4),
      ];
      final once = PlaylistOpsJournal.compact(input);
      final twice = PlaylistOpsJournal.compact(once);
      expect(twice.map((o) => o.opId), once.map((o) => o.opId));
    });
  });

  group('account isolation', () {
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
      expect(journal.pending('userA'), hasLength(1),
          reason: "userA's queue must survive untouched");
    });
  });
}

/// In-memory journal with the same semantics as the Hive one (including
/// compaction), so these tests need no Hive/plugin binding.
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
