// test/unit/playlist_polish_test.dart
//
// Phase 3.4.4 — failure taxonomy + Edit Order activity correctness.
//
// The taxonomy tests exist because the 2026-08-08 incident was caused by a
// DEFAULT: an unrecognised condition was optimistically assumed safe to repeat.
// The headline case here is "unknown cannot cause an infinite replay loop".

import 'dart:async';
import 'dart:io';

import 'package:beaty/data/local/playlist_ops_journal.dart';
import 'package:beaty/data/remote/playlist_remote_data_source.dart';
import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/data/sync/playlist_op.dart';
import 'package:beaty/data/sync/playlist_op_failure.dart';
import 'package:beaty/data/sync/playlist_sync_service.dart';
import 'package:beaty/domain/entities/edit_order_diff.dart';
import 'package:beaty/domain/entities/playlist_mutation_result.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Track _t(String id) => Track(
      id: id,
      title: 'Song $id',
      artistName: 'A',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: 100,
    );

PlaylistOp _op(String id, {int retry = 0}) => PlaylistOp(
      opId: id,
      userId: 'u1',
      playlistId: 'pl-1',
      type: PlaylistOpType.saveOrder,
      createdAt: DateTime(2026, 8, 9),
      retryCount: retry,
      payload: const {'ids': <String>[]},
    );

void main() {
  group('failure classification is explicit — no "assume transient" default', () {
    PlaylistFailureKind kindOf(Object e) =>
        PlaylistRepository.classifyPlaylistOpError(e).kind;

    test('network failures are transient', () {
      expect(kindOf(const SocketException('x')),
          PlaylistFailureKind.transientNetwork);
      expect(kindOf(TimeoutException('x')),
          PlaylistFailureKind.transientNetwork);
      expect(kindOf(Exception('Failed host lookup: api')),
          PlaylistFailureKind.transientNetwork);
      expect(
        kindOf(const PostgrestException(message: 'x', code: '503')),
        PlaylistFailureKind.transientNetwork,
      );
    });

    test('version conflict is its own kind and is terminal', () {
      expect(kindOf(const PlaylistConflictException()),
          PlaylistFailureKind.versionConflict);
      expect(PlaylistFailureKind.versionConflict.policy, FailurePolicy.terminal);
      expect(PlaylistFailureKind.versionConflict.poisonsPlaylist, isTrue);
    });

    test('authorization and authentication are distinct and terminal', () {
      expect(kindOf(const PlaylistForbiddenException()),
          PlaylistFailureKind.authorization);
      expect(kindOf(const PostgrestException(message: 'x', code: '42501')),
          PlaylistFailureKind.authorization);
      expect(kindOf(const AuthException('jwt expired')),
          PlaylistFailureKind.authentication);
      expect(PlaylistFailureKind.authorization.policy, FailurePolicy.terminal);
      expect(PlaylistFailureKind.authentication.policy, FailurePolicy.terminal);
    });

    test('validation and notFound are discarded, not retried', () {
      expect(kindOf(const PlaylistRemoteException('ORDER_SET_MISMATCH')),
          PlaylistFailureKind.validation);
      expect(kindOf(const PlaylistRemoteException('NOT_FOUND')),
          PlaylistFailureKind.notFound);
      expect(PlaylistFailureKind.validation.policy, FailurePolicy.discard);
      expect(PlaylistFailureKind.notFound.policy, FailurePolicy.discard);
    });

    test('local integrity problems are not network problems', () {
      expect(kindOf(const PlaylistRemoteException('UNRESOLVED_TRACK')),
          PlaylistFailureKind.localIntegrity);
      expect(PlaylistFailureKind.localIntegrity.policy, FailurePolicy.discard);
    });

    test('UNKNOWN is not treated as transient — this is the incident lesson',
        () {
      expect(kindOf(StateError('something we have never seen')),
          PlaylistFailureKind.unknown);
      expect(PlaylistFailureKind.unknown.policy,
          isNot(FailurePolicy.retryBounded));
      expect(PlaylistFailureKind.unknown.policy,
          FailurePolicy.retryOnceThenQuarantine);
    });

    test('every kind has an explicit policy — no accidental default', () {
      for (final k in PlaylistFailureKind.values) {
        expect(() => k.policy, returnsNormally, reason: k.name);
      }
    });
  });

  group('an unknown error cannot cause an infinite replay loop', () {
    test('unknown is attempted at most twice, EVER, then quarantined', () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a'));

      var calls = 0;
      for (var pass = 0; pass < 40; pass++) {
        PlaylistSyncService.resetForTest();
        await sync.flush('u1', (op) async {
          calls++;
          throw StateError('unrecognised');
        });
      }

      expect(calls, lessThanOrEqualTo(PlaylistOpFailure.unknownAttemptCap),
          reason: '40 replay passes must not produce 40 requests');
      expect(journal.pending('u1'), isEmpty);
      expect(journal.quarantined('u1').single.reason,
          QuarantineReason.unclassified);
    });

    test('a classified terminal failure is attempted exactly once', () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a'));

      var calls = 0;
      await sync.flush('u1', (op) async {
        calls++;
        throw const PlaylistOpFailure(PlaylistFailureKind.authorization);
      });
      expect(calls, 1);
      expect(journal.pending('u1'), isEmpty);
    });

    test('validation failures are discarded without blocking later ops',
        () async {
      PlaylistSyncService.resetForTest();
      final journal = _FakeJournal();
      final sync = PlaylistSyncService(journal);
      await journal.enqueue(_op('a'));
      await journal.enqueue(PlaylistOp(
        opId: 'b',
        userId: 'u1',
        playlistId: 'pl-2', // different playlist
        type: PlaylistOpType.addTracks,
        createdAt: DateTime(2026, 8, 9, 1),
      ));

      final executed = <String>[];
      await sync.flush('u1', (op) async {
        executed.add(op.opId);
        if (op.opId == 'a') {
          throw const PlaylistOpFailure(PlaylistFailureKind.validation);
        }
        return OpOutcome.success;
      });
      expect(executed, ['a', 'b']);
    });
  });

  group('Edit Order diff — activity correctness', () {
    test('removal only ⇒ tracks_removed, NOT tracks_reordered', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2'), _t('3')],
        [_t('1'), _t('3')],
      );
      expect(d.removed.map((t) => t.id), ['2']);
      expect(d.added, isEmpty);
      expect(d.reordered, isFalse,
          reason: 'removing a song must not look like a reorder');
    });

    test('reorder only ⇒ tracks_reordered, no membership change', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2'), _t('3')],
        [_t('3'), _t('1'), _t('2')],
      );
      expect(d.reordered, isTrue);
      expect(d.removed, isEmpty);
      expect(d.added, isEmpty);
      expect(d.hasMembershipChange, isFalse);
    });

    test('addition only ⇒ tracks_added', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2')],
        [_t('1'), _t('2'), _t('3')],
      );
      expect(d.added.map((t) => t.id), ['3']);
      expect(d.removed, isEmpty);
      expect(d.reordered, isFalse);
    });

    test('removal AND reorder are reported independently', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2'), _t('3')],
        [_t('3'), _t('1')],
      );
      expect(d.removed.map((t) => t.id), ['2']);
      expect(d.reordered, isTrue);
    });

    test('no change ⇒ nothing emitted', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2')],
        [_t('1'), _t('2')],
      );
      expect(d.isEmpty, isTrue);
      expect(d.reordered, isFalse);
    });

    test('removing the FIRST track does not read as a reorder', () {
      final d = EditOrderDiff.between(
        [_t('1'), _t('2'), _t('3')],
        [_t('2'), _t('3')],
      );
      expect(d.removed.map((t) => t.id), ['1']);
      expect(d.reordered, isFalse);
    });

    test('removing everything is a pure removal', () {
      final d = EditOrderDiff.between([_t('1'), _t('2')], []);
      expect(d.removed, hasLength(2));
      expect(d.reordered, isFalse);
    });

    test('track titles are preserved for the activity payload', () {
      final d = EditOrderDiff.between([_t('1'), _t('2')], [_t('1')]);
      expect(d.removed.single.title, 'Song 2');
    });
  });

  group('mutation results', () {
    test('applied and queuedOffline are successes; refusals roll back', () {
      expect(PlaylistMutationResult.applied.isSuccess, isTrue);
      expect(PlaylistMutationResult.queuedOffline.isSuccess, isTrue);
      expect(PlaylistMutationResult.conflict.wasRolledBack, isTrue);
      expect(PlaylistMutationResult.forbidden.wasRolledBack, isTrue);
      expect(PlaylistMutationResult.failed.wasRolledBack, isTrue);
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
