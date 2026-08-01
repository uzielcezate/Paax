// test/widget/playlist_cover_test.dart
//
// Phase 3.3.6 — generated cover collage layout. Verifies the collage fills its
// parent as a perfect square with evenly-sized quadrants (the old fixed-size
// grid was clipped/uneven inside a smaller parent), for 0/1/2/3/4 artworks and
// the invalid-URL fallback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:beaty/presentation/widgets/playlist_cover.dart';
import 'package:beaty/presentation/widgets/app_image.dart';

Track _t(String id, String art) => Track(
      id: id,
      title: id,
      artistName: 'a',
      albumId: '',
      albumTitle: '',
      artworkUrl: art,
      duration: 100,
    );

Playlist _p(List<Track> tracks) => Playlist(
      id: 'p',
      name: 'P',
      tracks: tracks,
      createdAt: DateTime(2026, 1, 1),
      coverColor: 0xFF2A2A2E,
    );

Future<void> _pump(WidgetTester tester, Playlist p, {double box = 200}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: box,
          height: box,
          child: PlaylistCover(playlist: p, size: box, borderRadius: 12),
        ),
      ),
    ),
  ));
}

void main() {
  setUp(() {
    // Fire visibility callbacks synchronously so AppImage leaves no pending
    // batching timer at test end.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('4 covers → square + four identical quadrants', (tester) async {
    await _pump(
      tester,
      _p([
        _t('a', 'http://x/a.jpg'),
        _t('b', 'http://x/b.jpg'),
        _t('c', 'http://x/c.jpg'),
        _t('d', 'http://x/d.jpg'),
      ]),
      box: 200,
    );

    // The collage clip is a perfect square filling the 200x200 box.
    final clipSize = tester.getSize(find.byType(ClipRRect).first);
    expect(clipSize.width, clipSize.height); // square
    expect(clipSize.width, 200);

    // Four image tiles, each exactly one quadrant (100x100), identical size.
    final tiles = find.byType(AppImage);
    expect(tiles, findsNWidgets(4));
    final sizes = tester.widgetList(tiles).map((_) => null).toList();
    expect(sizes.length, 4);
    for (var i = 0; i < 4; i++) {
      final s = tester.getSize(tiles.at(i));
      expect(s.width, 100);
      expect(s.height, 100);
    }
  });

  testWidgets('1 cover → single full image (no grid)', (tester) async {
    await _pump(tester, _p([_t('a', 'http://x/a.jpg')]));
    expect(find.byType(AppImage), findsOneWidget);
    final s = tester.getSize(find.byType(AppImage));
    expect(s.width, 200);
    expect(s.height, 200);
  });

  testWidgets('2 covers → balanced 50/50 (two tiles, each half width)',
      (tester) async {
    await _pump(tester,
        _p([_t('a', 'http://x/a.jpg'), _t('b', 'http://x/b.jpg')]));
    final tiles = find.byType(AppImage);
    expect(tiles, findsNWidgets(2));
    final s = tester.getSize(tiles.first);
    expect(s.width, 100); // half of 200
    expect(s.height, 200); // full height
  });

  testWidgets('3 covers → left full-height + right split', (tester) async {
    await _pump(
        tester,
        _p([
          _t('a', 'http://x/a.jpg'),
          _t('b', 'http://x/b.jpg'),
          _t('c', 'http://x/c.jpg'),
        ]));
    final tiles = find.byType(AppImage);
    expect(tiles, findsNWidgets(3));
    // First tile = left half, full height.
    final left = tester.getSize(tiles.at(0));
    expect(left.width, 100);
    expect(left.height, 200);
    // Right tiles = half width, half height.
    final right = tester.getSize(tiles.at(1));
    expect(right.width, 100);
    expect(right.height, 100);
  });

  testWidgets('duplicate + invalid URLs are ignored before layout',
      (tester) async {
    await _pump(
        tester,
        _p([
          _t('a', 'http://x/same.jpg'),
          _t('b', 'http://x/same.jpg'), // duplicate → collapsed
          _t('c', ''), // invalid → ignored
        ]));
    // Only ONE unique valid URL remains → single image, not a collage.
    expect(find.byType(AppImage), findsOneWidget);
  });

  testWidgets('no artwork → placeholder square (no AppImage)', (tester) async {
    await _pump(tester, _p([_t('a', ''), _t('b', '   ')]));
    expect(find.byType(AppImage), findsNothing);
    // Placeholder icon present, laid out square.
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    final clipSize = tester.getSize(find.byType(ClipRRect).first);
    expect(clipSize.width, clipSize.height);
  });

  testWidgets('empty playlist → placeholder', (tester) async {
    await _pump(tester, _p([]));
    expect(find.byType(AppImage), findsNothing);
    expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
  });
}
