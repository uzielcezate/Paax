// test/unit/playlist_persistence_test.dart
//
// Phase 3.3.6 — real Hive round-trip (restart persistence) + idempotent
// backward-compat migration. Uses Hive.init(tempDir) which works headless
// (unlike Hive.initFlutter, which needs path_provider).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:beaty/data/local/hive_storage.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/track.dart';

Track _t(String id) => Track(
      id: id,
      title: 't$id',
      artistName: 'a',
      albumId: '',
      albumTitle: '',
      artworkUrl: 'http://x/$id.jpg',
      duration: 100,
    );

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_hive_test');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(TrackAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(PlaylistAdapter());
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('order + metadata survive a simulated restart (close/reopen)', () async {
    var box = await Hive.openBox<Playlist>('playlists');
    await box.clear();
    final p = Playlist(
      id: 'p1',
      name: 'My List',
      tracks: [_t('a'), _t('b'), _t('c')],
      createdAt: DateTime(2026, 1, 1),
      ownerId: 'u1',
      ownerUsername: 'iamleizu',
      visibility: PlaylistVisibility.private,
      isCollaborative: false,
      collaboratorsJson: '[]',
      trackPositions: const [0, 1, 2],
    );
    await box.put(p.id, p);

    // Simulate app restart: close and reopen the box from disk.
    await box.close();
    box = await Hive.openBox<Playlist>('playlists');
    final read = box.get('p1')!;

    expect(read.tracks.map((t) => t.id).toList(), ['a', 'b', 'c']);
    expect(read.trackPositions, [0, 1, 2]);
    expect(read.ownerId, 'u1');
    expect(read.ownerUsername, 'iamleizu');
    expect(read.visibilityOrDefault, 'private');
    expect(read.isCollaborativeOrDefault, isFalse);
    // Playback ids preserved.
    expect(read.tracks.first.id, 'a');
    await box.close();
  });

  test('legacy record (null new fields) reads back with safe defaults', () async {
    final box = await Hive.openBox<Playlist>('playlists');
    await box.clear();
    // A pre-3.3.6 shape: only the original fields set.
    final legacy = Playlist(
      id: 'legacy',
      name: 'Old',
      tracks: [_t('x'), _t('y')],
      createdAt: DateTime(2025, 1, 1),
    );
    await box.put(legacy.id, legacy);
    final read = box.get('legacy')!;
    expect(read.ownerId, isNull);
    expect(read.visibility, isNull);
    expect(read.trackPositions, isNull);
    // Derived accessors still safe.
    expect(read.visibilityOrDefault, 'private');
    expect(read.isCollaborativeOrDefault, isFalse);
    expect(read.normalizedPositions().map((e) => e.position).toList(), [0, 1]);
    await box.close();
  });

  test('migratePlaylists is idempotent (running twice = same state)', () async {
    final box = await Hive.openBox<Playlist>('playlists');
    await box.clear();
    await box.put(
      'legacy',
      Playlist(
        id: 'legacy',
        name: 'Old',
        tracks: [_t('x'), _t('y'), _t('z')],
        createdAt: DateTime(2025, 1, 1),
      ),
    );

    await HiveStorage.migratePlaylists(ownerId: 'u1');
    final after1 = box.get('legacy')!;
    expect(after1.ownerId, 'u1');
    expect(after1.visibility, PlaylistVisibility.private);
    expect(after1.isCollaborative, false);
    expect(after1.collaboratorsJson, '[]');
    expect(after1.trackPositions, [0, 1, 2]);
    expect(after1.tracks.map((t) => t.id).toList(), ['x', 'y', 'z']); // unchanged

    // Second run must not change anything.
    await HiveStorage.migratePlaylists(ownerId: 'u1');
    final after2 = box.get('legacy')!;
    expect(after2.ownerId, after1.ownerId);
    expect(after2.visibility, after1.visibility);
    expect(after2.isCollaborative, after1.isCollaborative);
    expect(after2.collaboratorsJson, after1.collaboratorsJson);
    expect(after2.trackPositions, after1.trackPositions);
    expect(after2.tracks.length, 3); // no duplication
    await box.close();
  });
}
