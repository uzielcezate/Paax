// test/unit/playlist_sync_test.dart — Phase 3.4.1 offline journal + replay.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';

PlaylistOp _op(String uid, String pid, String opId, PlaylistOpType type,
        {DateTime? at}) =>
    PlaylistOp(
      opId: opId,
      userId: uid,
      playlistId: pid,
      type: type,
      createdAt: at ?? DateTime(2026, 1, 1, 0, 0, int.parse(opId.replaceAll(RegExp(r'\D'), ''))),
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_sync_test');
    Hive.init(dir.path);
    await Hive.openBox(PlaylistOpsJournal.boxName);
  });
  tearDownAll(() async {
    await Hive.close();
    try { dir.deleteSync(recursive: true); } catch (_) {}
  });

  setUp(() async => Hive.box(PlaylistOpsJournal.boxName).clear());

  test('enqueue preserves FIFO order; per-user isolation', () async {
    final j = PlaylistOpsJournal();
    await j.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    await j.enqueue(_op('u1', 'p', 'op2', PlaylistOpType.saveOrder));
    await j.enqueue(_op('u2', 'p', 'op9', PlaylistOpType.delete));
    expect(j.pending('u1').map((o) => o.opId).toList(), ['op1', 'op2']);
    expect(j.pending('u2').map((o) => o.opId).toList(), ['op9']);
  });

  test('flush: success drops ops', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    await s.enqueue(_op('u1', 'p', 'op2', PlaylistOpType.saveOrder));
    final r = await s.flush('u1', (_) async => OpOutcome.success);
    expect(r.remaining, 0);
    expect(j.hasPending('u1'), isFalse);
  });

  test('flush: version conflict drops op + reports it', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.saveOrder));
    final r = await s.flush('u1', (_) async => OpOutcome.conflict);
    expect(r.hadConflicts, isTrue);
    expect(r.remaining, 0); // stale op dropped
    expect(j.hasPending('u1'), isFalse);
  });

  test('flush: forbidden drops op + reports it', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    final r = await s.flush('u1', (_) async => OpOutcome.forbidden);
    expect(r.hadForbidden, isTrue);
    expect(r.remaining, 0);
  });

  test('flush: network retry keeps op, STOPS to preserve order', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    await s.enqueue(_op('u1', 'p', 'op2', PlaylistOpType.saveOrder));
    var calls = 0;
    final r = await s.flush('u1', (op) async {
      calls++;
      return OpOutcome.retry; // network down
    });
    expect(calls, 1); // stopped after first failure — did NOT reorder
    expect(r.remaining, 2);
    final kept = j.pending('u1');
    expect(kept.map((o) => o.opId).toList(), ['op1', 'op2']);
    expect(kept.first.retryCount, 1); // bumped
  });

  test('flush: thrown executor treated as retry', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    final r = await s.flush('u1', (_) async => throw Exception('boom'));
    expect(r.remaining, 1);
  });

  test('flush: permanent DROP removes op and KEEPS GOING (no poison pill)', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.saveOrder)); // will drop
    await s.enqueue(_op('u1', 'p', 'op2', PlaylistOpType.addTracks)); // must still run
    var ran = <String>[];
    final r = await s.flush('u1', (op) async {
      ran.add(op.opId);
      return op.opId == 'op1' ? OpOutcome.drop : OpOutcome.success;
    });
    expect(ran, ['op1', 'op2']); // did NOT stop at the dropped op
    expect(r.dropped.map((o) => o.opId), ['op1']);
    expect(r.remaining, 0);
    expect(j.hasPending('u1'), isFalse);
  });

  test('flush: an op past the retry cap is dropped (never blocks forever)', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await j.enqueue(PlaylistOp(
      opId: 'stuck', userId: 'u1', playlistId: 'p',
      type: PlaylistOpType.saveOrder, createdAt: DateTime(2026, 1, 1),
      retryCount: PlaylistSyncService.maxRetries,
    ));
    await s.enqueue(_op('u1', 'p', 'op2', PlaylistOpType.addTracks, at: DateTime(2026, 1, 2)));
    var ran = <String>[];
    final r = await s.flush('u1', (op) async { ran.add(op.opId); return OpOutcome.success; });
    expect(ran, ['op2']); // 'stuck' was dropped without executing
    expect(r.dropped.map((o) => o.opId), ['stuck']);
    expect(j.hasPending('u1'), isFalse);
  });

  test('flush only touches the given user (account isolation)', () async {
    final j = PlaylistOpsJournal();
    final s = PlaylistSyncService(j);
    await s.enqueue(_op('u1', 'p', 'op1', PlaylistOpType.addTracks));
    await s.enqueue(_op('u2', 'p', 'op2', PlaylistOpType.addTracks));
    await s.flush('u1', (_) async => OpOutcome.success);
    expect(j.hasPending('u1'), isFalse);
    expect(j.hasPending('u2'), isTrue); // u2's queue untouched
  });
}
