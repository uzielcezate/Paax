// lib/data/sync/playlist_migration_service.dart
//
// Phase 3.4.1 — idempotent migration of a signed-in user's local Hive playlists
// into cloud playlists. For each eligible local playlist we allocate a stable
// client-side cloud UUID (persisted BEFORE the create so a retry reuses it and
// the RPC dedups), resolve track Deezer ids → catalog UUIDs, and call
// playlist_create(imported:true). Runs at most once per user (per device) unless
// a prior run left failures. The CALLER must only invoke this for a clearly
// account-bound local library (never upload a pre-existing unowned library to an
// arbitrary account — see LibraryRepository's unattributed-local rule).

import 'dart:math';

import 'package:hive/hive.dart';

import '../../domain/entities/playlist.dart';
import '../remote/catalog_resolver.dart';
import '../remote/playlist_remote_data_source.dart';

class PlaylistMigrationResult {
  final int migrated;
  final int failed;
  final bool skipped;
  const PlaylistMigrationResult({this.migrated = 0, this.failed = 0, this.skipped = false});
}

/// Create one cloud playlist (defaults to the real RPC; overridable for tests).
typedef PlaylistCreateFn = Future<Map<String, dynamic>> Function({
  required String name,
  required String visibility,
  required List<String> trackUuids,
  required String id,
  required bool imported,
});

/// Resolve Deezer track ids → catalog UUIDs (defaults to CatalogResolver).
typedef TrackResolveFn = Future<Map<String, String>> Function(Iterable<String?> deezerIds);

class PlaylistMigrationService {
  final Box _settings;
  final PlaylistCreateFn _create;
  final TrackResolveFn _resolve;

  static const String _migratedUsersKey = 'playlists_migrated_users';
  static const String _idMapKey = 'playlist_local_cloud_map';

  PlaylistMigrationService({
    PlaylistRemoteDataSource? remote,
    CatalogResolver? resolver,
    Box? settings,
    PlaylistCreateFn? create,
    TrackResolveFn? resolve,
  })  : _settings = settings ?? Hive.box('settings'),
        _create = create ??
            (({required name, required visibility, required trackUuids, required id, required imported}) =>
                (remote ?? PlaylistRemoteDataSource()).createPlaylist(
                    name: name,
                    visibility: visibility,
                    trackUuids: trackUuids,
                    id: id,
                    imported: imported)),
        _resolve = resolve ??
            ((ids) => (resolver ?? CatalogResolver()).resolveTracks(ids));

  // ── migrated-user flag ──
  Set<String> _migratedUsers() {
    final raw = _settings.get(_migratedUsersKey);
    if (raw is List) return raw.map((e) => e.toString()).toSet();
    return <String>{};
  }

  bool isMigrated(String uid) => _migratedUsers().contains(uid);

  Future<void> _markMigrated(String uid) async {
    final s = _migratedUsers()..add(uid);
    await _settings.put(_migratedUsersKey, s.toList());
  }

  // ── local id → cloud uuid map, PER USER (stable, retry-safe, no cross-account
  //    handoff of a pre-allocated UUID) ──
  String _mapKey(String uid) => '$_idMapKey::$uid';

  Map<String, String> _idMap(String uid) {
    final raw = _settings.get(_mapKey(uid));
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return <String, String>{};
  }

  String? cloudIdFor(String uid, String localId) => _idMap(uid)[localId];

  Future<void> _putMap(String uid, String localId, String cloudId) async {
    final m = _idMap(uid)..[localId] = cloudId;
    await _settings.put(_mapKey(uid), m);
  }

  /// Idempotent migration for [uid]. Returns counts; only marks the user fully
  /// migrated when nothing failed (so a partial/offline run retries next session
  /// without creating duplicates — the persisted client UUID makes create a
  /// no-op retry).
  Future<PlaylistMigrationResult> migrateForUser(
      String uid, List<Playlist> localPlaylists) async {
    if (uid.trim().isEmpty) return const PlaylistMigrationResult(skipped: true);
    if (isMigrated(uid)) return const PlaylistMigrationResult(skipped: true);

    var migrated = 0;
    var failed = 0;
    for (final p in localPlaylists) {
      try {
        var cloudId = cloudIdFor(uid, p.id);
        if (cloudId == null) {
          cloudId = _uuidV4();
          await _putMap(uid, p.id, cloudId); // persist before create → retry-safe
        }
        final deezerIds = p.tracks.map((t) => t.deezerTrackId).toList();
        final resolved = await _resolve(deezerIds);
        final ordered = <String>[];
        for (final t in p.tracks) {
          final u = resolved[(t.deezerTrackId ?? '').trim()];
          if (u != null) ordered.add(u);
        }
        await _create(
          name: p.name,
          visibility: p.visibilityOrDefault,
          trackUuids: ordered,
          id: cloudId,
          imported: true,
        );
        migrated += 1;
      } catch (_) {
        failed += 1;
      }
    }
    if (failed == 0) await _markMigrated(uid);
    return PlaylistMigrationResult(migrated: migrated, failed: failed);
  }

  // RFC-4122 v4 (random). Adequate for a client-allocated cloud id; the server
  // rejects duplicates via the primary key, and the persisted map keeps retries
  // stable.
  static final Random _rng = Random.secure();
  static String _uuidV4() {
    final b = List<int>.generate(16, (_) => _rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    final s = List.generate(16, h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
        '${s.substring(16, 20)}-${s.substring(20)}';
  }
}
