// test/unit/search_controller_test.dart
//
// Behavioural tests for the optimized search pipeline (Phase: search perf).
// Uses a fake repository (injected) so no network is involved. Real short
// delays exercise the 220 ms debounce + generation cancellation.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/state/search_controller.dart' as app;
import 'package:beaty/domain/repositories/music_repository.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/domain/entities/saved_album.dart';
import 'package:beaty/domain/entities/artist.dart';

class _FakeRepo implements MusicRepository {
  int trackCalls = 0;
  int albumCalls = 0;
  int artistCalls = 0;
  int prewarmCalls = 0;

  /// Optional per-query delay (defaults to instant).
  Duration Function(String q)? delayFor;

  @override
  Future<void> prewarm() async {
    prewarmCalls++;
  }

  Future<void> _maybeDelay(String q) async {
    final d = delayFor?.call(q) ?? Duration.zero;
    if (d > Duration.zero) await Future.delayed(d);
  }

  @override
  Future<List<Track>> searchTracks(String q) async {
    trackCalls++;
    await _maybeDelay(q);
    return [
      Track(
          id: 't-$q',
          title: 't-$q',
          artistName: '',
          albumId: '',
          albumTitle: '',
          artworkUrl: '',
          duration: 0),
    ];
  }

  @override
  Future<List<SavedAlbum>> searchAlbums(String q) async {
    albumCalls++;
    await _maybeDelay(q);
    return [SavedAlbum(albumId: 'a-$q', title: 'a-$q', artistName: '', artworkUrl: '')];
  }

  @override
  Future<List<Artist>> searchArtists(String q) async {
    artistCalls++;
    await _maybeDelay(q);
    return [Artist(id: 'r-$q', name: 'r-$q', picture: '', nbFans: 0)];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('prewarms the connection on construction', () {
    final repo = _FakeRepo();
    app.SearchController(repository: repo);
    expect(repo.prewarmCalls, 1);
  });

  test('a single character does not trigger a search', () async {
    final repo = _FakeRepo();
    final c = app.SearchController(repository: repo);
    c.onQueryChanged('a');
    await Future.delayed(const Duration(milliseconds: 320));
    expect(repo.trackCalls, 0);
    expect(c.trackResults, isEmpty);
    expect(c.isLoading, isFalse);
  });

  test('two characters trigger a search and populate all categories', () async {
    final repo = _FakeRepo();
    final c = app.SearchController(repository: repo);
    c.onQueryChanged('ab');
    await Future.delayed(const Duration(milliseconds: 320));
    expect(repo.trackCalls, 1);
    expect(c.trackResults.single.title, 't-ab');
    expect(c.albumResults.single.title, 'a-ab');
    expect(c.artistResults.single.name, 'r-ab');
    expect(c.isLoading, isFalse);
  });

  test('a newer query never gets overwritten by a slower older query',
      () async {
    final repo = _FakeRepo();
    // "aa" is slow; "bb" is instant.
    repo.delayFor =
        (q) => q == 'aa' ? const Duration(milliseconds: 500) : Duration.zero;
    final c = app.SearchController(repository: repo);
    c.onQueryChanged('aa');
    await Future.delayed(const Duration(milliseconds: 260)); // aa's fetch in flight
    c.onQueryChanged('bb'); // newer query invalidates aa's generation
    await Future.delayed(const Duration(milliseconds: 600)); // let both settle
    expect(c.query, 'bb');
    expect(c.trackResults.single.title, 't-bb',
        reason: "slow 'aa' result must not overwrite newer 'bb'");
  });

  test('a repeated query is served instantly from cache (synchronously)',
      () async {
    final repo = _FakeRepo();
    final c = app.SearchController(repository: repo);
    c.onQueryChanged('rock');
    await Future.delayed(const Duration(milliseconds: 320));
    expect(c.trackResults.single.title, 't-rock');

    c.onQueryChanged(''); // clear
    c.onQueryChanged('rock'); // cache hit
    // Results are present immediately — no await, no debounce wait.
    expect(c.trackResults.single.title, 't-rock');
    expect(c.isLoading, isFalse);
  });
}
