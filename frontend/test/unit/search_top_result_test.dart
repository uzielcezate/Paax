// test/unit/search_top_result_test.dart
//
// Phase 3.3.3 issue 1 + 2 — Top Result relevance (controller integration) and
// progressive loading (an empty first category must not clear the loading state
// into a premature "no results" flash). Configurable fake repo, real short
// delays for the 220 ms debounce.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/state/search_controller.dart' as app;
import 'package:beaty/domain/repositories/music_repository.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/domain/entities/saved_album.dart';
import 'package:beaty/domain/entities/artist.dart';

Track _t(String title, String artist) => Track(
    id: 'vid-$title-$artist', title: title, artistName: artist,
    albumId: '', albumTitle: '', artworkUrl: '', duration: 180,
    deezerTrackId: '$title-$artist'.hashCode.toString());

SavedAlbum _a(String title, String artist) =>
    SavedAlbum(albumId: '$title-$artist'.hashCode.toString(), title: title, artistName: artist, artworkUrl: '');

Artist _ar(String name, {int followers = 0}) =>
    Artist(id: name.hashCode.toString(), name: name, picture: '', platformFollowers: followers);

class _CfgRepo implements MusicRepository {
  List<Track> Function(String) tracks = (_) => [];
  List<SavedAlbum> Function(String) albums = (_) => [];
  List<Artist> Function(String) artists = (_) => [];
  Duration Function(String category)? delay;

  @override
  Future<void> prewarm() async {}

  Future<void> _d(String c) async {
    final x = delay?.call(c) ?? Duration.zero;
    if (x > Duration.zero) await Future.delayed(x);
  }

  @override
  Future<List<Track>> searchTracks(String q) async { await _d('tracks'); return tracks(q); }
  @override
  Future<List<SavedAlbum>> searchAlbums(String q) async { await _d('albums'); return albums(q); }
  @override
  Future<List<Artist>> searchArtists(String q) async { await _d('artists'); return artists(q); }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  test('Top Result = relevance winner Shakira, not name-match DAIDAI', () async {
    final repo = _CfgRepo();
    repo.tracks = (q) => [
          _t('Dai Dai', 'Shakira'), _t('Dai Dai', 'Shakira'), _t('Dai Dai', 'Shakira'),
        ];
    repo.albums = (q) => [_a('Dai Dai', 'Shakira')];
    repo.artists = (q) {
      final nq = q.toLowerCase().trim();
      // The derived-winner resolve queries by the artist name.
      if (nq == 'shakira') return [_ar('Shakira', followers: 5000000)];
      return [_ar('DAIDAI', followers: 9000), _ar('DAI DAI DAI')];
    };

    final c = app.SearchController(repository: repo);
    c.onQueryChanged('Dai Dai');
    await Future.delayed(const Duration(milliseconds: 400));

    expect(c.topResult, isNotNull);
    expect(c.topResult!.name, 'Shakira');
  });

  test('a genuine exact artist match stays the Top Result (no resolve needed)', () async {
    final repo = _CfgRepo();
    repo.tracks = (q) => [_t('Rumble', 'Skrillex')];
    repo.albums = (q) => [];
    repo.artists = (q) => [_ar('Skrillex', followers: 1000000), _ar('Skrillex Fan')];

    final c = app.SearchController(repository: repo);
    c.onQueryChanged('Skrillex');
    await Future.delayed(const Duration(milliseconds: 400));

    expect(c.topResult?.name, 'Skrillex');
  });

  test('empty first category does not clear loading into a no-results flash', () async {
    final repo = _CfgRepo();
    // Artists return FAST but EMPTY; tracks return slower and non-empty.
    repo.artists = (q) => [];
    repo.albums = (q) => [];
    repo.tracks = (q) => [_t('song', 'artist')];
    repo.delay = (cat) => cat == 'tracks' ? const Duration(milliseconds: 200) : Duration.zero;

    final c = app.SearchController(repository: repo);
    c.onQueryChanged('xyzq');
    // After the debounce, artists+albums have returned empty; tracks still pending.
    await Future.delayed(const Duration(milliseconds: 260));
    expect(c.isLoading, isTrue, reason: 'loading must persist while a non-empty category is pending');
    expect(c.trackResults.isEmpty, isTrue);

    // Once tracks arrive, loading clears and results paint.
    await Future.delayed(const Duration(milliseconds: 200));
    expect(c.isLoading, isFalse);
    expect(c.trackResults.isNotEmpty, isTrue);
  });

  test('all-empty query eventually clears loading (No results state)', () async {
    final repo = _CfgRepo(); // all return []
    final c = app.SearchController(repository: repo);
    c.onQueryChanged('nothingmatches');
    await Future.delayed(const Duration(milliseconds: 350));
    expect(c.isLoading, isFalse);
    expect(c.trackResults.isEmpty && c.albumResults.isEmpty && c.artistResults.isEmpty, isTrue);
  });
}
