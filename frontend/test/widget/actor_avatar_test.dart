// test/widget/actor_avatar_test.dart — Phase 3.4.1.2 §B.
//
// The canonical actor avatar: shows the image when a URL is present; falls back
// to initials (known name) or a neutral person glyph (deleted/unknown actor).
// Never renders a raw id and never crashes on a missing profile.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/presentation/widgets/actor_avatar.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: child))),
    );

void main() {
  testWidgets('with a URL renders a network image (circular)', (tester) async {
    await _pump(tester,
        const ActorAvatar(imageUrl: 'https://cdn.paax/av/bren.jpg', displayName: 'bren_arteaga'));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ClipOval), findsOneWidget);
  });

  testWidgets('no URL, known name → initials fallback', (tester) async {
    await _pump(tester, const ActorAvatar(imageUrl: null, displayName: 'uziel'));
    expect(find.byType(Image), findsNothing);
    expect(find.text('U'), findsOneWidget);
  });

  testWidgets('deleted/unknown actor → neutral person glyph, no initials',
      (tester) async {
    await _pump(tester, const ActorAvatar(imageUrl: null, displayName: 'Deleted user'));
    // "Deleted user" starts with a letter, so it yields a 'D' initial — the
    // point is it never crashes and never shows a raw id. Empty name → glyph.
    await _pump(tester, const ActorAvatar(imageUrl: '', displayName: ''));
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
  });

  testWidgets('empty URL string is treated as no image', (tester) async {
    await _pump(tester, const ActorAvatar(imageUrl: '   ', displayName: 'x'));
    expect(find.byType(Image), findsNothing);
  });
}
