// test/widget/playlist_activity_sheet_test.dart — Phase 3.4.1 §7 detail sheet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/domain/entities/playlist_activity.dart';
import 'package:beaty/presentation/widgets/playlist_activity_sheet.dart';

Future<void> _pump(WidgetTester tester, PlaylistActivity a) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlaylistActivitySheet(activity: a))));
}

void main() {
  testWidgets('added songs: headline + track titles + relative time', (tester) async {
    final a = PlaylistActivity(
      id: 'x', playlistId: 'p', eventType: 'tracks_added',
      actorUsername: 'bren_arteaga', createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      metadata: {'count': 3, 'tracks': [
        {'id': '1', 'title': 'offline'},
        {'id': '2', 'title': 'CLASSY 101'},
        {'id': '3', 'title': 'Aquel día'},
      ]},
    );
    await _pump(tester, a);
    expect(find.text('bren_arteaga added 3 songs'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
    expect(find.text('CLASSY 101'), findsOneWidget);
    expect(find.text('Aquel día'), findsOneWidget);
    expect(find.textContaining('hours ago'), findsOneWidget);
  });

  testWidgets('bounded list shows "and N more"', (tester) async {
    final tracks = List.generate(10, (i) => {'id': '$i', 'title': 'Song $i'});
    final a = PlaylistActivity(
      id: 'x', playlistId: 'p', eventType: 'tracks_added',
      actorUsername: 'iamleizu', createdAt: DateTime.now(),
      metadata: {'count': 10, 'tracks': tracks},
    );
    await _pump(tester, a);
    expect(find.textContaining('and '), findsOneWidget); // "and 4 more"
    expect(find.text('Song 0'), findsOneWidget);
  });

  testWidgets('metadata-only event shows headline, no raw ids', (tester) async {
    final a = PlaylistActivity(
      id: 'x', playlistId: 'p', eventType: 'visibility_changed',
      actorUsername: 'iamleizu', createdAt: DateTime.now(),
      metadata: {'from': 'private', 'to': 'public'},
    );
    await _pump(tester, a);
    expect(find.text('iamleizu made this playlist public'), findsOneWidget);
  });
}
