// test/widget/party_action_test.dart — Phase 3.4.1.2C.
//
// The "Add to Party" track action routes through ONE shared resolver
// (PartyActions.addToParty), so every track menu behaves identically:
//   • active Party  → add to the live queue + "Added to Party" (track preserved)
//   • no active Party → open the start-a-party scaffold seeded with the song
// These tests pin PartyController's contract and both resolver paths, including
// that the exact selected track is received with its identity intact.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/presentation/state/party_controller.dart';
import 'package:beaty/presentation/widgets/party_actions.dart';

Track _track(String id, String title) => Track(
      id: id,
      title: title,
      artistName: 'Bad Bunny',
      albumId: 'al',
      albumTitle: 'Album',
      artworkUrl: 'http://x/a.jpg',
      duration: 200,
      deezerTrackId: 'dz-$id',
      artists: [
        {'id': 'ar1', 'name': 'Bad Bunny'}
      ],
    );

/// A PartyController with a live session, capturing what gets queued.
class _ActiveParty extends PartyController {
  final List<Track> received = [];
  @override
  bool get hasActiveParty => true;
  @override
  bool get canModifyQueue => true;
  @override
  Future<AddToPartyResult> addToActiveParty(Track track) async {
    received.add(track);
    return AddToPartyResult.added;
  }
}

Widget _host<T extends PartyController>(T controller, Track track) => MaterialApp(
      home: ChangeNotifierProvider<PartyController>.value(
        value: controller,
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => PartyActions.addToParty(context, track),
                child: const Text('add'),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('PartyController contract', () {
    test('no runtime yet → inactive, empty queue, add is a no-op signal', () async {
      final c = PartyController();
      expect(c.hasActiveParty, isFalse);
      expect(c.canModifyQueue, isFalse);
      expect(c.queue, isEmpty);
      expect(c.allowsDuplicates, isTrue); // documented product rule
      expect(await c.addToActiveParty(_track('1', 'MONACO')),
          AddToPartyResult.noActiveParty);
      expect(c.queue, isEmpty);
    });
  });

  testWidgets('no active Party → opens the start-a-party sheet seeded with the song',
      (tester) async {
    await tester.pumpWidget(_host(PartyController(), _track('v1', 'MONACO')));
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();

    // The scaffold sheet opens, names the seeded song, and communicates state.
    expect(find.textContaining('temporary shared listening session'), findsOneWidget);
    expect(find.textContaining('MONACO'), findsOneWidget);
    // It never creates a persistent playlist / empty Party — just the scaffold.
    expect(find.text('Cancel'), findsOneWidget);
  });

  testWidgets('active Party → adds the exact track and confirms "Added to Party"',
      (tester) async {
    final party = _ActiveParty();
    final track = _track('v9', 'DtMF');
    await tester.pumpWidget(_host<_ActiveParty>(party, track));
    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();

    // Correct track received, identity intact.
    expect(party.received.single.id, 'v9');
    expect(party.received.single.title, 'DtMF');
    expect(party.received.single.deezerTrackId, 'dz-v9');
    // Lightweight success confirmation.
    expect(find.text('Added to Party'), findsOneWidget);
  });
}
