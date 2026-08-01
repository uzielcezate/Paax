// test/unit/playlist_order_test.dart
//
// Phase 3.3.6 — explicit, cloud-ready local track ordering (pure domain; no
// Hive). Verifies normalization, add-after-max, remove-without-corruption,
// duplicate-position normalization, and empty/one-track handling. The commit /
// cancel / restart behaviors are exercised end-to-end via the controller +
// staging buffer; here we prove the domain invariants they rely on.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/track.dart';

Track _t(String id) => Track(
      id: id,
      title: 't$id',
      artistName: 'a',
      albumId: '',
      albumTitle: '',
      artworkUrl: '',
      duration: 100,
    );

Playlist _p(List<Track> tracks, {List<int>? positions}) => Playlist(
      id: 'p1',
      name: 'P',
      tracks: tracks,
      createdAt: DateTime(2026, 1, 1),
      trackPositions: positions,
    );

List<int> _positionsOf(Playlist p) =>
    p.normalizedPositions().map((e) => e.position).toList();

List<String> _idsOf(Playlist p) =>
    p.normalizedPositions().map((e) => e.trackId).toList();

void main() {
  test('positions are zero-based and contiguous', () {
    final p = _p([_t('a'), _t('b'), _t('c')]).withNormalizedPositions();
    expect(p.trackPositions, [0, 1, 2]);
    expect(_positionsOf(p), [0, 1, 2]);
  });

  test('reorder then normalize keeps positions 0..n-1 in new order', () {
    // Simulate a committed reorder: c, a, b.
    final reordered = _p([_t('c'), _t('a'), _t('b')]).withNormalizedPositions();
    expect(_idsOf(reordered), ['c', 'a', 'b']);
    expect(reordered.trackPositions, [0, 1, 2]);
  });

  test('new track is appended AFTER the current maximum position', () {
    final base = _p([_t('a'), _t('b')]).withNormalizedPositions();
    final withAdded = base.copyWith(tracks: [...base.tracks, _t('c')])
        .withNormalizedPositions();
    expect(_idsOf(withAdded), ['a', 'b', 'c']);
    expect(withAdded.trackPositions, [0, 1, 2]);
    expect(withAdded.normalizedPositions().last.position, 2); // after max
  });

  test('removing a track does not corrupt remaining ordering', () {
    final base = _p([_t('a'), _t('b'), _t('c'), _t('d')]).withNormalizedPositions();
    final removed = base
        .copyWith(tracks: base.tracks.where((t) => t.id != 'b').toList())
        .withNormalizedPositions();
    expect(_idsOf(removed), ['a', 'c', 'd']);
    expect(removed.trackPositions, [0, 1, 2]); // contiguous, no gap
  });

  test('duplicate/garbage stored positions are normalized on commit', () {
    // A record that somehow has duplicate positions.
    final broken = _p([_t('a'), _t('b'), _t('c')], positions: [0, 0, 0]);
    final fixed = broken.withNormalizedPositions();
    expect(fixed.trackPositions, [0, 1, 2]);
    // No duplicate positions remain.
    expect(fixed.trackPositions!.toSet().length, fixed.trackPositions!.length);
  });

  test('empty playlist normalizes to empty positions', () {
    final p = _p([]).withNormalizedPositions();
    expect(p.trackPositions, isEmpty);
    expect(p.normalizedPositions(), isEmpty);
  });

  test('one-track playlist normalizes to [0]', () {
    final p = _p([_t('a')]).withNormalizedPositions();
    expect(p.trackPositions, [0]);
    expect(_positionsOf(p), [0]);
  });

  test('copyWith preserves ordering fields (rename does not drop order)', () {
    final p = _p([_t('a'), _t('b')]).withNormalizedPositions();
    final renamed = p.copyWith(name: 'New Name');
    expect(renamed.name, 'New Name');
    expect(renamed.trackPositions, [0, 1]);
    expect(renamed.tracks.map((t) => t.id).toList(), ['a', 'b']);
  });

  test('cloud contract payload shape: {trackId, position}', () {
    final p = _p([_t('x'), _t('y')]).withNormalizedPositions();
    final payload = p.normalizedPositions().map((e) => e.toJson()).toList();
    expect(payload, [
      {'trackId': 'x', 'position': 0},
      {'trackId': 'y', 'position': 1},
    ]);
  });
}
