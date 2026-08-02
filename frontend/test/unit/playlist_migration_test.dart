// test/unit/playlist_migration_test.dart — Phase 3.4.1 idempotent migration.

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:beaty/data/sync/playlist_migration_service.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/track.dart';

Track _t(String deezerId) => Track(
      id: 'v$deezerId', title: 't', artistName: 'a', albumId: '', albumTitle: '',
      artworkUrl: '', duration: 100, deezerTrackId: deezerId);

Playlist _p(String id, List<Track> tracks) =>
    Playlist(id: id, name: 'P$id', tracks: tracks, createdAt: DateTime(2026, 1, 1));

void main() {
  late Directory dir;
  late Box settings;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_mig_test');
    Hive.init(dir.path);
    settings = await Hive.openBox('mig_settings');
  });
  tearDownAll(() async {
    await Hive.close();
    try { dir.deleteSync(recursive: true); } catch (_) {}
  });
  setUp(() async => settings.clear());

  PlaylistMigrationService service({
    required List<Map<String, dynamic>> createLog,
    Set<String>? failIds,
    Map<String, String> resolveMap = const {'100': 'uuid-100', '200': 'uuid-200'},
  }) =>
      PlaylistMigrationService(
        settings: settings,
        resolve: (ids) async => resolveMap,
        create: ({required name, required visibility, required trackUuids, required id, required imported}) async {
          if (failIds != null && failIds.contains(id)) {
            throw Exception('network');
          }
          createLog.add({'name': name, 'id': id, 'tracks': trackUuids, 'imported': imported});
          return {'id': id, 'name': name};
        },
      );

  test('migrates each local playlist once, resolves tracks, marks migrated', () async {
    final log = <Map<String, dynamic>>[];
    final s = service(createLog: log);
    final res = await s.migrateForUser('userA', [
      _p('l1', [_t('100'), _t('200')]),
      _p('l2', [_t('100')]),
    ]);
    expect(res.migrated, 2);
    expect(res.failed, 0);
    expect(log.length, 2);
    expect(log.first['imported'], isTrue);
    expect(log.first['tracks'], ['uuid-100', 'uuid-200']);
    expect(s.isMigrated('userA'), isTrue);
    // stable cloud id recorded for local id
    expect(s.cloudIdFor('userA', 'l1'), isNotNull);
  });

  test('idempotent: a second run does nothing', () async {
    final log = <Map<String, dynamic>>[];
    final s = service(createLog: log);
    await s.migrateForUser('userA', [_p('l1', [_t('100')])]);
    final res2 = await s.migrateForUser('userA', [_p('l1', [_t('100')])]);
    expect(res2.skipped, isTrue);
    expect(log.length, 1); // NOT created twice
  });

  test('partial failure does not mark migrated; retry reuses the same cloud id', () async {
    final log = <Map<String, dynamic>>[];
    // First: allocate l1's cloud id but fail its create.
    final s1 = service(createLog: log, failIds: {});
    // We don't know l1's generated id up-front, so fail ALL creates first run.
    final failing = PlaylistMigrationService(
      settings: settings,
      resolve: (ids) async => {'100': 'uuid-100'},
      create: ({required name, required visibility, required trackUuids, required id, required imported}) async =>
          throw Exception('network'),
    );
    final r1 = await failing.migrateForUser('userB', [_p('l1', [_t('100')])]);
    expect(r1.failed, 1);
    expect(failing.isMigrated('userB'), isFalse); // not marked
    final firstCloudId = failing.cloudIdFor('userB', 'l1');
    expect(firstCloudId, isNotNull); // id persisted before create (retry-safe)

    // Retry with a working create: must reuse the SAME cloud id.
    final s2 = service(createLog: log);
    final r2 = await s2.migrateForUser('userB', [_p('l1', [_t('100')])]);
    expect(r2.migrated, 1);
    expect(log.single['id'], firstCloudId);
    expect(s2.isMigrated('userB'), isTrue);
  });

  test('empty user id is skipped', () async {
    final s = service(createLog: []);
    final r = await s.migrateForUser('', [_p('l1', [_t('100')])]);
    expect(r.skipped, isTrue);
  });
}
