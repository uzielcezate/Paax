// lib/data/local/library_sync_state.dart
//
// Phase 3.2A — Cloud Library Sync.
//
// Persists small pieces of sync bookkeeping in SharedPreferences:
//   - lastUserId: which account last synced on THIS device (cross-account guard).
//   - migratedVersion (per user id): whether the one-time local→cloud migration
//     already ran for that user, and at which version.
//   - pending-ops journal: optimistic local mutations that could not yet reach
//     the cloud (unresolved Deezer id, or a network failure). Replayed later by
//     LibraryRepository.flushPending().
//
// A pending op is a JSON object:
//   { "op": "add"|"remove",
//     "kind": "like"|"save"|"follow"|"hide"|"genreFollow",
//     "deezerId": "<deezer id, or track deezer id for like/hide>",
//     "ts": <millisSinceEpoch> }
//
// Nothing here throws; all SharedPreferences access is best-effort.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Current migration schema version. Bump to force a re-migration for all users.
const int kLibraryMigrationVersion = 1;

enum SyncOpKind { like, save, follow, hide, genreFollow }

enum SyncOpType { add, remove }

class PendingOp {
  final SyncOpType op;
  final SyncOpKind kind;
  final String deezerId;
  final int ts;

  PendingOp({
    required this.op,
    required this.kind,
    required this.deezerId,
    int? ts,
  }) : ts = ts ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'op': op.name,
        'kind': kind.name,
        'deezerId': deezerId,
        'ts': ts,
      };

  static PendingOp? fromJson(Map<String, dynamic> m) {
    final op = SyncOpType.values
        .cast<SyncOpType?>()
        .firstWhere((e) => e!.name == m['op'], orElse: () => null);
    final kind = SyncOpKind.values
        .cast<SyncOpKind?>()
        .firstWhere((e) => e!.name == m['kind'], orElse: () => null);
    final deezerId = m['deezerId']?.toString();
    if (op == null || kind == null || deezerId == null || deezerId.isEmpty) {
      return null;
    }
    final ts = m['ts'];
    return PendingOp(
      op: op,
      kind: kind,
      deezerId: deezerId,
      ts: ts is int ? ts : int.tryParse('${ts ?? ''}'),
    );
  }

  /// Dedup identity — same kind+deezerId collapses to the latest op.
  String get dedupKey => '${kind.name}:$deezerId';
}

class LibrarySyncState {
  static const String _kLastUserId = 'library_sync_last_user_id';
  static const String _kPendingOps = 'library_sync_pending_ops_v1';
  static const String _kMigratedPrefix = 'library_sync_migrated_v_';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ── lastUserId ───────────────────────────────────────────────────

  Future<String?> getLastUserId() async {
    try {
      return (await _prefs).getString(_kLastUserId);
    } catch (_) {
      return null;
    }
  }

  Future<void> setLastUserId(String? userId) async {
    try {
      final prefs = await _prefs;
      if (userId == null) {
        await prefs.remove(_kLastUserId);
      } else {
        await prefs.setString(_kLastUserId, userId);
      }
    } catch (_) {}
  }

  // ── migrated flag (per user) ─────────────────────────────────────

  Future<int> getMigratedVersion(String userId) async {
    try {
      return (await _prefs).getInt('$_kMigratedPrefix$userId') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> isMigrated(String userId) async =>
      (await getMigratedVersion(userId)) >= kLibraryMigrationVersion;

  Future<void> setMigrated(
    String userId, {
    int version = kLibraryMigrationVersion,
  }) async {
    try {
      await (await _prefs).setInt('$_kMigratedPrefix$userId', version);
    } catch (_) {}
  }

  // ── pending-ops journal ──────────────────────────────────────────

  Future<List<PendingOp>> getPendingOps() async {
    try {
      final raw = (await _prefs).getString(_kPendingOps);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final ops = <PendingOp>[];
      for (final e in decoded) {
        if (e is Map) {
          final op = PendingOp.fromJson(Map<String, dynamic>.from(e));
          if (op != null) ops.add(op);
        }
      }
      return ops;
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeOps(List<PendingOp> ops) async {
    try {
      final prefs = await _prefs;
      await prefs.setString(
        _kPendingOps,
        jsonEncode(ops.map((o) => o.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// Enqueue an op. Any prior op with the same kind+deezerId is superseded
  /// (last write wins) so add/remove churn collapses to the final intent.
  Future<void> enqueue(PendingOp op) async {
    final ops = await getPendingOps();
    ops.removeWhere((o) => o.dedupKey == op.dedupKey);
    ops.add(op);
    await _writeOps(ops);
  }

  /// Replace the whole journal (used after a flush attempt).
  Future<void> replaceAll(List<PendingOp> ops) => _writeOps(ops);

  Future<void> clearPending() async {
    try {
      await (await _prefs).remove(_kPendingOps);
    } catch (_) {}
  }
}
