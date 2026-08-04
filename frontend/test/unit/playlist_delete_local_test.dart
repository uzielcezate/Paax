// test/unit/playlist_delete_local_test.dart — Phase 3.4.1.2B.
//
// Local (Hive) side of the owner-delete contract: once the authoritative cloud
// soft-delete succeeds, the local cache removal must make the playlist vanish
// from the library read model and stay gone across a simulated restart. Pairs
// with supabase/tests/playlist_delete_contract_test.sql (the DB-contract half).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:beaty/data/local/hive_storage.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/track.dart';

Playlist _pl(String id) => Playlist(
      id: id,
      name: 'PL $id',
      tracks: const <Track>[],
      createdAt: DateTime(2026, 8, 4),
      ownerId: 'owner-1',
      visibility: PlaylistVisibility.private,
      isCollaborative: false,
      trackPositions: const [],
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_del_test');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(TrackAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(PlaylistAdapter());
    await Hive.openBox<Playlist>('playlists');
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('delete removes the playlist from the local read model', () async {
    await HiveStorage.savePlaylist(_pl('keep'));
    await HiveStorage.savePlaylist(_pl('gone'));
    expect(HiveStorage.getPlaylists().map((p) => p.id), containsAll(['keep', 'gone']));

    await HiveStorage.deletePlaylist('gone');
    final ids = HiveStorage.getPlaylists().map((p) => p.id).toList();
    expect(ids, contains('keep'));
    expect(ids, isNot(contains('gone')));
  });

  test('deleted playlist does not come back after a simulated restart', () async {
    await HiveStorage.savePlaylist(_pl('temp'));
    await HiveStorage.deletePlaylist('temp');
    // Close + reopen the box from disk (app restart).
    await Hive.close();
    Hive.init(dir.path);
    await Hive.openBox<Playlist>('playlists');
    expect(HiveStorage.getPlaylists().any((p) => p.id == 'temp'), isFalse);
  });
}
