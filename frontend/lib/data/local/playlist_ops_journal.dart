// lib/data/local/playlist_ops_journal.dart
//
// Phase 3.4.1 — Hive-backed pending-operation journal for offline playlist
// writes. Keyed per user id so a queued op can never replay under the wrong
// account. Stored as JSON so it needs no Hive adapter.

import 'package:hive/hive.dart';
import '../sync/playlist_op.dart';

class PlaylistOpsJournal {
  static const String boxName = 'playlist_ops';

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
    await _write(op.userId, ops);
  }

  Future<void> remove(String userId, String opId) async {
    final ops = pending(userId)..removeWhere((o) => o.opId == opId);
    await _write(userId, ops);
  }

  Future<void> replaceAll(String userId, List<PlaylistOp> ops) => _write(userId, ops);

  Future<void> clearUser(String userId) async => _box.delete(userId);

  bool hasPending(String userId) => pending(userId).isNotEmpty;
}
