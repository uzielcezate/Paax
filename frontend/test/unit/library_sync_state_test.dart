// test/unit/library_sync_state_test.dart
//
// Unit coverage for the Phase 3.2A cloud-sync bookkeeping: the pending-ops
// journal (last-write-wins collapse so add/remove churn resolves to the final
// intent), per-user migration guard, and the cross-account lastUserId marker.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:beaty/data/local/library_sync_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pending-ops journal', () {
    test('enqueue persists an op', () async {
      final s = LibrarySyncState();
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.follow, deezerId: '27', ts: 1));
      final ops = await s.getPendingOps();
      expect(ops, hasLength(1));
      expect(ops.first.kind, SyncOpKind.follow);
      expect(ops.first.deezerId, '27');
    });

    test('same kind+deezerId collapses to the latest op (last write wins)',
        () async {
      final s = LibrarySyncState();
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.like, deezerId: '99', ts: 1));
      await s.enqueue(PendingOp(
          op: SyncOpType.remove, kind: SyncOpKind.like, deezerId: '99', ts: 2));
      final ops = await s.getPendingOps();
      expect(ops, hasLength(1), reason: 'add then remove collapses to one');
      expect(ops.first.op, SyncOpType.remove);
    });

    test('different kinds for the same deezerId are kept separate', () async {
      final s = LibrarySyncState();
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.like, deezerId: '5', ts: 1));
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.hide, deezerId: '5', ts: 2));
      expect(await s.getPendingOps(), hasLength(2));
    });

    test('genreFollow ops round-trip through the journal (Phase 3.2.4)',
        () async {
      final s = LibrarySyncState();
      await s.enqueue(PendingOp(
          op: SyncOpType.add,
          kind: SyncOpKind.genreFollow,
          deezerId: '132',
          ts: 1));
      final ops = await s.getPendingOps();
      expect(ops, hasLength(1));
      expect(ops.first.kind, SyncOpKind.genreFollow);
      expect(ops.first.deezerId, '132');
      // add then remove of the same genre collapses (last write wins).
      await s.enqueue(PendingOp(
          op: SyncOpType.remove,
          kind: SyncOpKind.genreFollow,
          deezerId: '132',
          ts: 2));
      final after = await s.getPendingOps();
      expect(after, hasLength(1));
      expect(after.first.op, SyncOpType.remove);
    });

    test('replaceAll and clearPending work', () async {
      final s = LibrarySyncState();
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.save, deezerId: '1', ts: 1));
      await s.replaceAll([]);
      expect(await s.getPendingOps(), isEmpty);
      await s.enqueue(PendingOp(
          op: SyncOpType.add, kind: SyncOpKind.save, deezerId: '2', ts: 1));
      await s.clearPending();
      expect(await s.getPendingOps(), isEmpty);
    });

    test('corrupt journal decodes to empty, never throws', () async {
      SharedPreferences.setMockInitialValues(
          {'library_sync_pending_ops_v1': 'not-json'});
      expect(await LibrarySyncState().getPendingOps(), isEmpty);
    });
  });

  group('migration guard + lastUserId', () {
    test('isMigrated flips only after setMigrated', () async {
      final s = LibrarySyncState();
      expect(await s.isMigrated('u1'), isFalse);
      await s.setMigrated('u1');
      expect(await s.isMigrated('u1'), isTrue);
      expect(await s.isMigrated('u2'), isFalse, reason: 'per-user');
    });

    test('lastUserId round-trips and clears', () async {
      final s = LibrarySyncState();
      expect(await s.getLastUserId(), isNull);
      await s.setLastUserId('user-a');
      expect(await s.getLastUserId(), 'user-a');
      await s.setLastUserId(null);
      expect(await s.getLastUserId(), isNull);
    });
  });
}
