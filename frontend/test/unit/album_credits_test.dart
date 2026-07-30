// test/unit/album_credits_test.dart
//
// Phase 3.3.4 — universal per-track credits. Proves the album credit overlay is
// GENERIC (not SOMA-only): it enriches any album's tracks from the normalized
// catalog, keyed by Deezer track id, keeping each track's playback videoId, with
// ONE batched normalized request (no N+1). Concrete att./Bad Bunny fixtures.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/repositories/music_repository_impl.dart';
import 'package:beaty/data/api/youtube_music_data_source.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/domain/entities/saved_album.dart';

/// Fake data source: returns a canned normalized album and counts the calls.
class _FakeDS extends YouTubeMusicDataSource {
  final Map<int, Map<String, dynamic>> normalizedAlbums;
  int normalizedCalls = 0;
  _FakeDS(this.normalizedAlbums);

  @override
  Future<Map<String, dynamic>?> getAlbumNormalizedByDeezerId(int deezerId) async {
    normalizedCalls++;
    return normalizedAlbums[deezerId];
  }
}

Track _legacyTrack(String title, int deezerTrackId, String videoId) => Track(
      id: videoId, // playback videoId
      title: title,
      artistName: 'Young Miko', // legacy: album primary only
      albumId: '566656321',
      albumTitle: 'att.',
      artworkUrl: '',
      duration: 180,
      artists: const [{'name': 'Young Miko', 'id': '139171932'}],
      deezerTrackId: '$deezerTrackId',
    );

Map<String, dynamic> _normTrack(int deezerId, List<Map<String, dynamic>> artists) =>
    {'deezerId': deezerId, 'title': 't', 'artists': artists};

Map<String, dynamic> _artist(String name, int pos, {String role = 'primary'}) =>
    {'name': name, 'role': role, 'position': pos};

void main() {
  test('enriches att. tracks generically + keeps videoId, ONE batched call', () async {
    final ds = _FakeDS({
      566656321: {
        'artists': [{'name': 'Young Miko'}],
        'tracks': [
          _normTrack(2729119071, [_artist('Young Miko', 1), _artist('Dei V', 2)]),      // ay mami
          _normTrack(2729119091, [_artist('Young Miko', 1), _artist('Feid', 2)]),        // offline
          _normTrack(2729119111, [_artist('Young Miko', 1), _artist('Jowell & Randy', 2)]), // ID
          _normTrack(2729119999, [_artist('Young Miko', 1)]),                            // solo
        ],
      },
    });
    final repo = MusicRepositoryImpl(dataSource: ds);

    final album = SavedAlbum(
      albumId: '566656321', title: 'att.', artistName: 'Young Miko', artworkUrl: '',
      artists: const [{'name': 'Young Miko', 'id': '139171932'}],
      tracks: [
        _legacyTrack('ay mami', 2729119071, 'vidAY'),
        _legacyTrack('offline', 2729119091, 'vidOFF'),
        _legacyTrack('ID', 2729119111, 'vidID'),
        _legacyTrack('solo', 2729119999, 'vidSOLO'),
      ],
    );

    final out = await repo.enrichAlbumCredits(album);
    final byTitle = {for (final t in out.tracks!) t.title: t};

    // Concrete regression fixtures (not SOMA).
    expect(byTitle['ay mami']!.displayArtist, 'Young Miko, Dei V');
    expect(byTitle['offline']!.displayArtist, 'Young Miko, Feid');
    expect(byTitle['ID']!.displayArtist, 'Young Miko, Jowell & Randy'); // '&' name = one credit
    expect(byTitle['solo']!.displayArtist, 'Young Miko'); // primary once

    // Playback IDs preserved (album header untouched).
    expect(byTitle['offline']!.id, 'vidOFF');
    expect(byTitle['ay mami']!.id, 'vidAY');
    expect(out.artistName, 'Young Miko');

    // Batch: exactly ONE normalized request for the whole album (no N+1).
    expect(ds.normalizedCalls, 1);
  });

  test('Bad Bunny — collab track shows guest, solo track shows Bad Bunny once', () async {
    final ds = _FakeDS({
      693008911: {
        'tracks': [
          _normTrack(111, [_artist('Bad Bunny', 1)]),                       // solo
          _normTrack(222, [_artist('Bad Bunny', 1), _artist('Dei V', 2)]),  // collab
        ],
      },
    });
    final repo = MusicRepositoryImpl(dataSource: ds);
    final album = SavedAlbum(
      albumId: '693008911', title: 'DeBÍ TiRAR MáS FOToS', artistName: 'Bad Bunny', artworkUrl: '',
      tracks: [
        Track(id: 'v1', title: 'solo', artistName: 'Bad Bunny', albumId: '693008911',
            albumTitle: '', artworkUrl: '', duration: 1, deezerTrackId: '111',
            artists: const [{'name': 'Bad Bunny', 'id': '0'}]),
        Track(id: 'v2', title: 'collab', artistName: 'Bad Bunny', albumId: '693008911',
            albumTitle: '', artworkUrl: '', duration: 1, deezerTrackId: '222',
            artists: const [{'name': 'Bad Bunny', 'id': '0'}]),
      ],
    );

    final out = await repo.enrichAlbumCredits(album);
    final byTitle = {for (final t in out.tracks!) t.title: t};
    expect(byTitle['solo']!.displayArtist, 'Bad Bunny');
    expect(byTitle['collab']!.displayArtist, 'Bad Bunny, Dei V');
  });

  test('no normalized data → album unchanged (graceful fallback)', () async {
    final ds = _FakeDS({}); // no normalized album
    final repo = MusicRepositoryImpl(dataSource: ds);
    final album = SavedAlbum(
      albumId: '999', title: 'x', artistName: 'A', artworkUrl: '',
      tracks: [_legacyTrack('t', 1, 'v')],
    );
    final out = await repo.enrichAlbumCredits(album);
    expect(identical(out, album), isTrue); // unchanged
  });
}
