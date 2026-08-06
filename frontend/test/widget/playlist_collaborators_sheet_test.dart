// test/widget/playlist_collaborators_sheet_test.dart
// Phase 3.4.1 §12/§13 + Phase 3.4.1.2C People Picker.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/state/playlist_detail_controller.dart';
import 'package:beaty/presentation/widgets/playlist_collaborators_sheet.dart';

ManagedCollaborator _c(String id, String username, String status, {String? display}) =>
    ManagedCollaborator(
        userId: id, username: username, displayName: display, role: 'editor', status: status);

PeoplePickerResult _r(String id, String username, {String? display}) =>
    PeoplePickerResult(userId: id, username: username, displayName: display);

class _Harness {
  final List<String> searched = [];
  final List<String> invitedUsers = [];
  final List<String> invitedNames = [];
  List<PeoplePickerResult> Function(String) results = (_) => const [];
  Completer<void>? holdInvite; // when set, invites block until completed
  String? Function(String)? inviteUserError;

  Future<List<PeoplePickerResult>> onSearch(String q) async {
    searched.add(q);
    return results(q);
  }

  Future<String?> onInviteUser(String id) async {
    invitedUsers.add(id);
    if (holdInvite != null) await holdInvite!.future;
    return inviteUserError?.call(id);
  }

  Future<String?> onInvite(String name) async {
    invitedNames.add(name);
    return name.contains('ghost') ? 'User not found' : null;
  }
}

Widget _host(_Harness h, {List<ManagedCollaborator> collaborators = const []}) => MaterialApp(
      home: Scaffold(
        body: ManageCollaboratorsSheet(
          ownerName: 'uziel',
          collaborators: collaborators,
          onInvite: h.onInvite,
          onInviteUser: h.onInviteUser,
          onSearch: h.onSearch,
          onRemove: (_) async {},
          onTransfer: () {},
        ),
      ),
    );

void main() {
  testWidgets('renders Owner / Collaborators / Pending sections', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h, collaborators: [
      _c('u1', 'bren_arteaga24', 'accepted', display: 'Bren'),
      _c('u2', 'maria205', 'pending', display: 'Maria Reyes'),
    ]));
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Collaborators'), findsWidgets); // header + section label
    expect(find.text('Bren'), findsOneWidget);
    expect(find.text('Maria Reyes'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('@maria205'), findsOneWidget);
    expect(find.text('SEARCH PEOPLE'), findsOneWidget);
  });

  testWidgets('search needs >= 2 chars; below that no request and a hint shows', (tester) async {
    final h = _Harness()..results = (_) => [_r('x', 'maria205')];
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'm');
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.searched, isEmpty);
    expect(find.text('Search by name or username.'), findsOneWidget);
  });

  testWidgets('debounced search shows results; tapping invites by UUID', (tester) async {
    final h = _Harness()
      ..results = (q) => [_r('uuid-maria', 'maria205', display: 'Maria Reyes')];
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump(const Duration(milliseconds: 350)); // fire debounce
    await tester.pumpAndSettle();
    expect(h.searched, ['mar']);
    expect(find.text('@maria205'), findsOneWidget);

    await tester.tap(find.text('Maria Reyes'));
    await tester.pumpAndSettle();
    expect(h.invitedUsers, ['uuid-maria']); // authoritative UUID, not the handle
    expect(find.text('Invitation sent'), findsOneWidget);
    // Result cleared from the list after a successful invite.
    expect(find.text('@maria205'), findsNothing);
  });

  testWidgets('rapid double tap sends only ONE invitation', (tester) async {
    final h = _Harness();
    h.results = (q) => [_r('uuid-maria', 'maria205', display: 'Maria Reyes')];
    h.holdInvite = Completer<void>();
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Maria Reyes'));
    await tester.pump(); // invite in flight (blocked on completer)
    await tester.tap(find.text('Maria Reyes'), warnIfMissed: false); // second tap ignored
    await tester.pump();
    h.holdInvite!.complete();
    await tester.pumpAndSettle();
    expect(h.invitedUsers, ['uuid-maria']); // exactly one
  });

  testWidgets('exact-username enter failure keeps the field and shows the error', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(_host(h));
    await tester.enterText(find.byType(TextField), 'ghost');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(h.invitedNames, ['ghost']);
    expect(find.text('User not found'), findsOneWidget);
    expect(find.text('ghost'), findsOneWidget); // field retained on failure
  });

  testWidgets('already-managed users are excluded from results', (tester) async {
    final h = _Harness()
      ..results = (q) => [
            _r('u1', 'bren_arteaga24', display: 'Bren'), // already a collaborator
            _r('uuid-maria', 'maria205', display: 'Maria Reyes'),
          ];
    await tester.pumpWidget(_host(h, collaborators: [_c('u1', 'bren_arteaga24', 'accepted', display: 'Bren')]));
    await tester.enterText(find.byType(TextField), 'a');
    await tester.enterText(find.byType(TextField), 'ar');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    // Exactly one selectable RESULT row (Maria); Bren is excluded because he is
    // already a collaborator. Each result row carries the invite (+person) icon.
    expect(find.byIcon(Icons.person_add_alt_1_rounded), findsOneWidget);
    expect(find.text('@maria205'), findsOneWidget);
  });

  testWidgets('a stale (slower) response never replaces a newer query', (tester) async {
    final slow = Completer<List<PeoplePickerResult>>();
    final h = _Harness();
    // First query 'ma' resolves slowly; second query 'mar' resolves immediately.
    h.results = (q) => q == 'mar' ? [_r('uuid-maria', 'maria205', display: 'Maria Reyes')] : const [];
    // Override onSearch to make 'ma' hang.
    final sheet = ManageCollaboratorsSheet(
      ownerName: 'uziel',
      collaborators: const [],
      onInvite: h.onInvite,
      onInviteUser: h.onInviteUser,
      onSearch: (q) async {
        h.searched.add(q);
        if (q == 'ma') return slow.future;
        return h.results(q);
      },
      onRemove: (_) async {},
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: sheet)));

    await tester.enterText(find.byType(TextField), 'ma');
    await tester.pump(const Duration(milliseconds: 350)); // fires search('ma') → hangs
    await tester.enterText(find.byType(TextField), 'mar');
    await tester.pump(const Duration(milliseconds: 350)); // fires search('mar') → resolves
    await tester.pumpAndSettle();
    expect(find.text('@maria205'), findsOneWidget);

    // Now the stale 'ma' resolves empty — it must NOT wipe the 'mar' results.
    slow.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text('@maria205'), findsOneWidget);
  });
}
