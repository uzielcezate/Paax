// test/widget/create_action_sheet_test.dart — Phase 3.4.1.1 §G + 3.4.1.2 Party entry.
//
// The "+" menu offers Create playlist and (flag-gated) Start a Party. With
// AppConfig.partyEnabled OFF — the default in tests and production — the Party
// row is HIDDEN (consistent with the track-menu entry). The shared prep sheet
// (showPartyEntrySheet) is the single Party seam for both Library and track
// entries; it accepts an optional seed track and creates nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/config/app_config.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/presentation/widgets/create_action_sheet.dart';

Track _track(String title) => Track(
      id: 'v1',
      title: title,
      artistName: 'Bad Bunny',
      albumId: 'al',
      albumTitle: 'Album',
      artworkUrl: 'http://x/a.jpg',
      duration: 200,
      deezerTrackId: '123',
    );

void main() {
  testWidgets('Create playlist always shows and runs the create flow; Party gated',
      (tester) async {
    var created = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showCreateActionSheet(context,
                  onCreatePlaylist: () => created = true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Create playlist'), findsOneWidget);
    // partyEnabled is false in tests → the Party row is hidden.
    expect(find.text('Start a Party'), AppConfig.partyEnabled ? findsOneWidget : findsNothing);

    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();
    expect(created, isTrue);
  });

  testWidgets('shared prep sheet: seeded with a track, informational, creates nothing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () =>
                  showPartyEntrySheet(context, seedTrack: _track('MONACO')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary shared listening session'), findsOneWidget);
    expect(find.textContaining('MONACO'), findsOneWidget); // seeded title shown
    // Flag OFF → the CTA is disabled ("Coming soon"); nothing is created.
    expect(find.text('Coming soon'), AppConfig.partyEnabled ? findsNothing : findsOneWidget);
  });

  testWidgets('prep sheet without a seed shows the generic copy', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showPartyEntrySheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('invite friends'), findsOneWidget);
  });
}
