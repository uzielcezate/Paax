// test/widget/playlist_collaborators_sheet_test.dart — Phase 3.4.1 §12/§13.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/state/playlist_detail_controller.dart';
import 'package:beaty/presentation/widgets/playlist_collaborators_sheet.dart';

ManagedCollaborator _c(String name, String status) =>
    ManagedCollaborator(userId: name, username: name, role: 'editor', status: status);

void main() {
  testWidgets('lists owner + accepted + pending; invite validates', (tester) async {
    String? invited;
    final removed = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ManageCollaboratorsSheet(
          ownerName: 'iamleizu',
          collaborators: [_c('bren_arteaga', 'accepted'), _c('invited_user', 'pending')],
          onInvite: (u) async {
            invited = u;
            return u == 'ghost' ? 'No user "ghost"' : null;
          },
          onRemove: (id) async => removed.add(id),
          onTransfer: () {},
        ),
      ),
    ));

    expect(find.text('iamleizu'), findsOneWidget); // owner
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('bren_arteaga'), findsOneWidget); // accepted
    expect(find.text('invited_user'), findsOneWidget); // pending
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Transfer ownership'), findsOneWidget);

    // Invite a non-existent user → inline error.
    await tester.enterText(find.byType(TextField), 'ghost');
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(invited, 'ghost');
    expect(find.text('No user "ghost"'), findsOneWidget);

    // Remove the accepted collaborator (its close icon).
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump();
    expect(removed, contains('bren_arteaga'));
  });

  testWidgets('transfer sheet lists accepted collaborators only', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransferOwnershipSheet(
          accepted: [_c('bren_arteaga', 'accepted')],
          onTransfer: (id) async => null,
        ),
      ),
    ));
    expect(find.text('Transfer ownership'), findsOneWidget);
    expect(find.text('bren_arteaga'), findsOneWidget);
  });
}
