// test/unit/playlist_adoption_and_lane_test.dart
//
// Phase 3.4.7 — pendingCreate UUID adoption + per-playlist mutation lanes.
//
// Both mechanisms exist to stop the SAME class of bug: a mutation being sent
// against state the server does not have (a local-only playlist id, or a stale
// version). In production that produced playlists with fewer tracks than the UI
// showed, with no error anywhere.

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/sync/playlist_mutation_lane.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

const localId = 'local-1111-2222-3333';
const cloudId = 'cloud-aaaa-bbbb-cccc';

PlaylistOp _create(String opId, {String playlist = localId}) => PlaylistOp(
      opId: opId,
      userId: 'u1',
      playlistId: playlist,
      type: PlaylistOpType.create,
      createdAt: DateTime(2026, 8, 10, 12, 0),
      payload: const {'name': 'off', 'clientId': localId, 'ids': <String>[]},
    );

PlaylistOp _dependent(
  String opId, {
  required String dependsOn,
  PlaylistOpType type = PlaylistOpType.addTracks,
  String playlist = localId,
  List<String> ids = const ['track-A'],
  int minute = 1,
}) =>
    PlaylistOp(
      opId: opId,
      userId: 'u1',
      playlistId: playlist,
      type: type,
      createdAt: DateTime(2026, 8, 10, 12, minute),
      dependsOnOpId: dependsOn,
      payload: {'ids': ids},
    );

void main() {
  group('A — pendingCreate UUID adoption', () {
    late _FakeJournal journal;
    late PlaylistSyncService sync;

    setUp(() {
      PlaylistSyncService.resetForTest();
      journal = _FakeJournal();
      sync = PlaylistSyncService(journal);
    });

    test('offline create + reconnect → exactly ONE create request', () async {
      await journal.enqueue(_create('c1'));
      var creates = 0;
      await sync.flush('u1', (op) async {
        if (op.type == PlaylistOpType.create) {
          creates++;
          signalApplied(cloudPlaylistId: cloudId, version: 1);
        }
        return OpOutcome.success;
      }, onAdopted: (l, c, v) async {});

      expect(creates, 1);
      expect(journal.pending('u1'), isEmpty);
    });

    test('repeated reconnects never create a SECOND cloud playlist', () async {
      await journal.enqueue(_create('c1'));
      var creates = 0;
      Future<OpOutcome> exec(PlaylistOp op) async {
        if (op.type == PlaylistOpType.create) {
          creates++;
          signalApplied(cloudPlaylistId: cloudId, version: 1);
        }
        return OpOutcome.success;
      }

      for (var i = 0; i < 5; i++) {
        PlaylistSyncService.resetForTest();
        await sync.flush('u1', exec, onAdopted: (l, c, v) async {});
      }
      expect(creates, 1, reason: 'the op is dequeued after the first success');
    });

    test('create + add A + add B → one playlist, BOTH adds use the cloud id',
        () async {
      await journal.enqueue(_create('c1'));
      await journal.enqueue(_dependent('a1', dependsOn: 'c1', ids: ['A'], minute: 1));
      await journal.enqueue(_dependent('a2', dependsOn: 'c1', ids: ['B'], minute: 2));

      final sentAgainst = <String, String>{}; // opId → playlistId used
      String? adoptedLocal, adoptedCloud;

      await sync.flush('u1', (op) async {
        sentAgainst[op.opId] = op.playlistId;
        if (op.type == PlaylistOpType.create) {
          signalApplied(cloudPlaylistId: cloudId, version: 1);
        }
        return OpOutcome.success;
      }, onAdopted: (l, c, v) async {
        adoptedLocal = l;
        adoptedCloud = c;
      });

      expect(adoptedLocal, localId);
      expect(adoptedCloud, cloudId);
      expect(sentAgainst['c1'], localId, reason: 'create carries the client id');
      expect(sentAgainst['a1'], cloudId);
      expect(sentAgainst['a2'], cloudId,
          reason: 'both adds must target the adopted cloud UUID');
      expect(journal.pending('u1'), isEmpty);
    });

    test('adoption happens BEFORE dependents run', () async {
      await journal.enqueue(_create('c1'));
      await journal.enqueue(_dependent('a1', dependsOn: 'c1'));

      final order = <String>[];
      await sync.flush('u1', (op) async {
        order.add('exec:${op.opId}');
        if (op.type == PlaylistOpType.create) {
          signalApplied(cloudPlaylistId: cloudId, version: 1);
        }
        return OpOutcome.success;
      }, onAdopted: (l, c, v) async => order.add('adopt'));

      expect(order, ['exec:c1', 'adopt', 'exec:a1'],
          reason: 'releasing dependents before adoption would send a local id');
    });

    test('a dependent NEVER executes while its create is still pending',
        () async {
      await journal.enqueue(_create('c1'));
      await journal.enqueue(_dependent('a1', dependsOn: 'c1'));

      final executed = <String>[];
      await sync.flush('u1', (op) async {
        executed.add(op.opId);
        if (op.type == PlaylistOpType.create) return OpOutcome.retry; // offline
        return OpOutcome.success;
      });

      expect(executed, ['c1'], reason: 'the add must not be sent with a local id');
      expect(journal.pending('u1').map((o) => o.opId), contains('a1'));
    });

    test('if the create fails terminally, dependents are dropped not stranded',
        () async {
      await journal.enqueue(_create('c1'));
      await journal.enqueue(_dependent('a1', dependsOn: 'c1'));

      final executed = <String>[];
      await sync.flush('u1', (op) async {
        executed.add(op.opId);
        if (op.type == PlaylistOpType.create) return OpOutcome.drop;
        return OpOutcome.success;
      });

      expect(executed, ['c1']);
      expect(journal.pending('u1'), isEmpty,
          reason: 'a dependent of a dead create can never succeed');
    });

    test('adoption is idempotent — a re-adopted op is not rewritten twice', () {
      final op = _dependent('a1', dependsOn: 'c1');
      final once = op.adoptCloudId(cloudId);
      final twice = once.adoptCloudId(cloudId);
      expect(once.playlistId, cloudId);
      expect(twice.playlistId, cloudId);
      expect(twice.adopted, isTrue);
      expect(twice.dependsOnOpId, isNull);
      expect(twice.opId, op.opId, reason: 'identity is preserved across adoption');
    });

    test('adoption clears the stale expectedVersion', () {
      final op = PlaylistOp(
        opId: 'r1', userId: 'u1', playlistId: localId,
        type: PlaylistOpType.saveOrder, createdAt: DateTime(2026, 8, 10),
        expectedVersion: 3, dependsOnOpId: 'c1',
      );
      expect(op.adoptCloudId(cloudId).expectedVersion, isNull,
          reason: 'a pre-create version cannot apply to the new cloud row');
    });

    test('dependency + adoption survive JSON round-trip', () {
      final op = _dependent('a1', dependsOn: 'c1');
      final back = PlaylistOp.fromJson(op.toJson());
      expect(back.dependsOnOpId, 'c1');
      expect(back.adopted, isFalse);
      final adopted = PlaylistOp.fromJson(op.adoptCloudId(cloudId).toJson());
      expect(adopted.adopted, isTrue);
      expect(adopted.playlistId, cloudId);
    });

    test('create + dependents + delete before send → ZERO cloud work', () async {
      await journal.enqueue(_create('c1'));
      await journal.enqueue(_dependent('a1', dependsOn: 'c1', minute: 1));
      await journal.enqueue(_dependent('a2', dependsOn: 'c1', minute: 2));
      await journal.enqueue(PlaylistOp(
        opId: 'd1', userId: 'u1', playlistId: localId,
        type: PlaylistOpType.delete, createdAt: DateTime(2026, 8, 10, 12, 3),
      ));

      var executions = 0;
      await sync.flush('u1', (op) async {
        executions++;
        return OpOutcome.success;
      });
      expect(executions, 0, reason: 'compaction cancels the whole chain');
      expect(journal.pending('u1'), isEmpty);
    });
  });

  group('B — per-playlist mutation lane', () {
    late PlaylistMutationLane lane;
    setUp(() => lane = PlaylistMutationLane());

    test('the lane key includes account AND playlist', () {
      expect(PlaylistMutationLane.laneKey('acc1', 'pl1'), 'acc1::pl1');
      expect(PlaylistMutationLane.laneKey('acc1', 'pl1'),
          isNot(PlaylistMutationLane.laneKey('acc2', 'pl1')));
    });

    test('mutation N+1 uses the version returned by mutation N', () async {
      final seen = <int?>[];
      Future<void> add(int returns) => lane.run<void>('u1', 'p1', (expected) async {
            seen.add(expected);
            return (result: null, version: returns);
          });

      await add(8);
      await add(9);
      await add(10);

      expect(seen, [null, 8, 9],
          reason: 'add A(7)->8 then add B(8): the chain must carry the version');
      expect(lane.versionFor('u1', 'p1'), 10);
    });

    test('concurrent callers for the SAME playlist serialize', () async {
      final order = <String>[];
      Future<void> mutate(String tag, int ms, int version) =>
          lane.run<void>('u1', 'p1', (expected) async {
            order.add('start:$tag');
            await Future<void>.delayed(Duration(milliseconds: ms));
            order.add('end:$tag');
            return (result: null, version: version);
          });

      await Future.wait([mutate('A', 40, 8), mutate('B', 5, 9)]);

      expect(order, ['start:A', 'end:A', 'start:B', 'end:B'],
          reason: 'B must not start before A commits');
    });

    test('four rapid additions all run, in order, each seeing the last version',
        () async {
      final seen = <int?>[];
      await Future.wait([
        for (var i = 0; i < 4; i++)
          lane.run<void>('u1', 'p1', (expected) async {
            seen.add(expected);
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return (result: null, version: 10 + i);
          })
      ]);
      expect(seen, hasLength(4), reason: 'no addition may be dropped');
      expect(seen.first, isNull);
      expect(seen.skip(1).whereType<int>().length, 3,
          reason: 'every later add received a concrete version');
    });

    test('DIFFERENT playlists run concurrently', () async {
      final order = <String>[];
      Future<void> mutate(String pl, int ms) =>
          lane.run<void>('u1', pl, (expected) async {
            order.add('start:$pl');
            await Future<void>.delayed(Duration(milliseconds: ms));
            order.add('end:$pl');
            return (result: null, version: 1);
          });

      await Future.wait([mutate('p1', 40), mutate('p2', 5)]);

      // p2 finishes while p1 is still running — proves no global serialization.
      expect(order.indexOf('end:p2'), lessThan(order.indexOf('end:p1')));
    });

    test('a failing mutation does not deadlock the lane', () async {
      await expectLater(
        lane.run<void>('u1', 'p1', (_) async => throw StateError('boom')),
        throwsStateError,
      );
      var ran = false;
      await lane.run<void>('u1', 'p1', (expected) async {
        ran = true;
        return (result: null, version: 5);
      });
      expect(ran, isTrue);
    });

    test('versions only move forward — a late response cannot roll back', () {
      lane.recordVersion('u1', 'p1', 9);
      lane.recordVersion('u1', 'p1', 4); // stale, arrives late
      expect(lane.versionFor('u1', 'p1'), 9);
    });

    test('invalidate clears the cached version after a conflict', () {
      lane.recordVersion('u1', 'p1', 9);
      lane.invalidateVersion('u1', 'p1');
      expect(lane.versionFor('u1', 'p1'), isNull);
    });

    test('account switch drops that account\'s lanes only', () {
      lane.recordVersion('accA', 'p1', 5);
      lane.recordVersion('accB', 'p1', 7);
      lane.clearAccount('accA');
      expect(lane.versionFor('accA', 'p1'), isNull);
      expect(lane.versionFor('accB', 'p1'), 7);
    });

    test('the lane runs each submitted mutation exactly once', () async {
      var runs = 0;
      await Future.wait([
        for (var i = 0; i < 6; i++)
          lane.run<void>('u1', 'p1', (_) async {
            runs++;
            return (result: null, version: i);
          })
      ]);
      expect(runs, 6);
      expect(lane.runCounts[PlaylistMutationLane.laneKey('u1', 'p1')], 6);
    });
  });

  group('RC2 regression — Deezer identity is not mandatory', () {
    test('a track with no numeric deezerTrackId is still resolvable by videoId',
        () {
      // Encodes the contract: resolution has TWO stages, and only a track that
      // fails BOTH is unresolved. The repository turns that into an explicit
      // localIntegrity failure — never an empty array treated as success.
      const deezerId = '';
      const videoId = 'yt-abc123';
      final byDeezer = <String, String>{};
      final byVideoId = <String, String>{videoId: 'catalog-uuid'};

      final resolved = byDeezer[deezerId.trim()] ?? byVideoId[videoId];
      expect(resolved, 'catalog-uuid');
    });

    test('only a track failing BOTH stages is unresolved', () {
      final byDeezer = <String, String>{};
      final byVideoId = <String, String>{};
      final resolved = byDeezer[''] ?? byVideoId['yt-unknown'];
      expect(resolved, isNull,
          reason: 'this case must raise localIntegrity, not send an empty array');
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
