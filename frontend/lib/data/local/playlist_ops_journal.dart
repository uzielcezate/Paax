// lib/data/local/playlist_ops_journal.dart
//
// Hive-backed pending-operation journal for offline playlist writes
// (Phase 3.4.1 → 3.4.3).
//
// Keyed per user id so a queued op can never replay under the wrong account.
// Stored as JSON so it needs no Hive adapter.
//
// Phase 3.4.3 adds:
//   • a QUARANTINE (dead-letter) lane — terminal failures are preserved rather
//     than silently dropped, so the user's intent is never lost and a poisoned
//     op can never re-enter the replay queue;
//   • COMPACTION — collapses redundant queued work before it ever reaches the
//     network, which is both a correctness fix (create+delete must produce zero
//     cloud rows) and the cheapest possible defence against request volume.

import 'package:hive/hive.dart';
import '../sync/playlist_op.dart';
import '../sync/playlist_sync_service.dart';

class PlaylistOpsJournal {
  static const String boxName = 'playlist_ops';
  static String _quarantineKey(String userId) => '$userId::quarantine';

  Box get _box => Hive.box(boxName);

  /// Pending ops for [userId], oldest first (replay order).
  List<PlaylistOp> pending(String userId) {
    final raw = _box.get(userId);
    if (raw is! List) return [];
    final ops = raw
        .whereType<Map>()
        .map((m) => PlaylistOp.fromJson(m.cast<String, dynamic>()))
        .toList();
    ops.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return ops;
  }

  Future<void> _write(String userId, List<PlaylistOp> ops) async {
    if (ops.isEmpty) {
      await _box.delete(userId);
    } else {
      await _box.put(userId, ops.map((o) => o.toJson()).toList());
    }
  }

  Future<void> enqueue(PlaylistOp op) async {
    final ops = pending(op.userId);
    // Idempotent by opId (retry of the same offline action doesn't duplicate).
    ops.removeWhere((o) => o.opId == op.opId);
    ops.add(op);
    await _write(op.userId, compact(ops));
  }

  Future<void> remove(String userId, String opId) async {
    final ops = pending(userId)..removeWhere((o) => o.opId == opId);
    await _write(userId, ops);
  }

  Future<void> replaceAll(String userId, List<PlaylistOp> ops) =>
      _write(userId, compact(ops));

  Future<void> clearUser(String userId) async {
    await _box.delete(userId);
    await _box.delete(_quarantineKey(userId));
  }

  bool hasPending(String userId) => pending(userId).isNotEmpty;

  // ── quarantine (dead letter) ───────────────────────────────────────────────

  /// Terminally-failed ops, preserved so the user's intent is recoverable and
  /// so a poisoned op can never re-enter the replay queue.
  List<QuarantinedOp> quarantined(String userId) {
    final raw = _box.get(_quarantineKey(userId));
    if (raw is! List) return [];
    final out = <QuarantinedOp>[];
    for (final e in raw.whereType<Map>()) {
      try {
        final m = e.cast<String, dynamic>();
        final op = PlaylistOp.fromJson(
            (m['op'] as Map).cast<String, dynamic>());
        final reason = QuarantineReason.values.firstWhere(
          (r) => r.name == m['reason'],
          orElse: () => QuarantineReason.conflict,
        );
        final av = m['actualVersion'];
        out.add(QuarantinedOp(op, reason,
            actualVersion: av is int ? av : int.tryParse('${av ?? ''}')));
      } catch (_) {
        // A corrupt quarantine entry is skipped, never fatal.
      }
    }
    return out;
  }

  Future<void> quarantineAll(String userId, List<QuarantinedOp> items) async {
    final existing = quarantined(userId);
    final byId = {for (final q in existing) q.op.opId: q};
    for (final q in items) {
      byId[q.op.opId] = q; // idempotent by opId
    }
    // Bound the dead-letter lane so it can never grow without limit.
    final all = byId.values.toList()
      ..sort((a, b) => a.op.createdAt.compareTo(b.op.createdAt));
    final capped = all.length > 200 ? all.sublist(all.length - 200) : all;
    await _box.put(
      _quarantineKey(userId),
      capped
          .map((q) => {
                'op': q.op.toJson(),
                'reason': q.reason.name,
                'actualVersion': q.actualVersion,
              })
          .toList(),
    );
  }

  Future<void> removeQuarantined(String userId, String opId) async {
    final kept = quarantined(userId).where((q) => q.op.opId != opId).toList();
    if (kept.isEmpty) {
      await _box.delete(_quarantineKey(userId));
    } else {
      await quarantineAll(userId, kept);
    }
  }

  Future<void> clearQuarantine(String userId) =>
      _box.delete(_quarantineKey(userId));

  // ── compaction ─────────────────────────────────────────────────────────────

  /// Collapses redundant queued work, preserving observable intent.
  ///
  /// Pure and order-preserving, so it is exhaustively unit-testable and safe to
  /// run on every write. Rules, in order:
  ///
  ///   1. delete-after-create for a playlist that never reached the cloud →
  ///      drop the create AND every dependent op. Nothing is ever created
  ///      remotely, so no ghost row and no orphaned cloud playlist.
  ///   2. any op targeting a playlist deleted later in the queue → drop
  ///      (the delete supersedes it).
  ///   3. repeated saveOrder / updateMetadata / setFollow for one playlist →
  ///      keep only the LAST (they are absolute, not incremental).
  ///
  /// addTracks/removeTracks are intentionally NOT collapsed against each other:
  /// they are set operations whose net effect depends on server state, so
  /// merging them locally could silently lose a user's intent.
  static List<PlaylistOp> compact(List<PlaylistOp> input) {
    if (input.length < 2) return List<PlaylistOp>.from(input);
    final ops = List<PlaylistOp>.from(input)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Rule 1 + 2: find playlists deleted in-queue.
    final deleted = <String>{
      for (final o in ops)
        if (o.type == PlaylistOpType.delete) o.playlistId
    };
    final createdInQueue = <String>{
      for (final o in ops)
        if (o.type == PlaylistOpType.create) o.playlistId
    };
    // Created AND deleted before ever syncing ⇒ the whole chain is a no-op.
    final bornAndDied = createdInQueue.intersection(deleted);

    final kept = <PlaylistOp>[];
    for (final o in ops) {
      if (bornAndDied.contains(o.playlistId)) continue; // rule 1
      if (deleted.contains(o.playlistId) && o.type != PlaylistOpType.delete) {
        continue; // rule 2 — superseded by the delete
      }
      kept.add(o);
    }

    // Rule 3: last-wins for absolute operations.
    const lastWins = {
      PlaylistOpType.saveOrder,
      PlaylistOpType.updateMetadata,
      PlaylistOpType.setFollow,
    };
    final lastIndex = <String, int>{};
    for (var i = 0; i < kept.length; i++) {
      final o = kept[i];
      if (lastWins.contains(o.type)) {
        lastIndex['${o.type.name}::${o.playlistId}'] = i;
      }
    }
    final out = <PlaylistOp>[];
    for (var i = 0; i < kept.length; i++) {
      final o = kept[i];
      if (lastWins.contains(o.type) &&
          lastIndex['${o.type.name}::${o.playlistId}'] != i) {
        continue; // an identical-kind later op supersedes this one
      }
      out.add(o);
    }
    return out;
  }
}
