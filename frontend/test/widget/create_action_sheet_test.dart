// test/widget/create_action_sheet_test.dart — Phase 3.4.1.1 §G.
//
// The "+" menu offers Create playlist and Start a Party. Party is an entry
// scaffold: it opens an informational prep sheet and NEVER creates a playlist.
// With the feature flag OFF (default), the prep sheet's CTA is disabled
// ("Coming soon").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/widgets/create_action_sheet.dart';

void main() {
  testWidgets('shows both actions; Create playlist runs the create flow',
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
    expect(find.text('Start a Party'), findsOneWidget);

    await tester.tap(find.text('Create playlist'));
    await tester.pumpAndSettle();
    expect(created, isTrue);
  });

  testWidgets('Start a Party opens the prep sheet and creates nothing',
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
    await tester.tap(find.text('Start a Party'));
    await tester.pumpAndSettle();

    // Prep/informational sheet, flag OFF → CTA disabled, no playlist created.
    expect(find.textContaining('temporary shared listening session'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget);
    expect(created, isFalse);
  });
}
