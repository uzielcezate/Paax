// test/unit/username_normalization_test.dart — Phase 3.4.1.2C.
//
// The shared username-normalization contract (must match the DB
// private.normalize_username): trim → strip one optional leading '@' → lower.
// All of these must map to the SAME canonical handle so an invitation resolves
// regardless of how the owner typed it.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/auth/validators.dart';

void main() {
  group('normalizeUsername', () {
    test('equivalent inputs all resolve to the same handle', () {
      const forms = ['maria205', 'Maria205', '@maria205', '  maria205  ', '  @Maria205 ', '@@'];
      // Note: '@@' strips one '@' leaving '@' → not equal; kept out of the equality set.
      final canonical = ['maria205', 'Maria205', '@maria205', '  maria205  ', '  @Maria205 ']
          .map(AuthValidators.normalizeUsername)
          .toSet();
      expect(canonical, {'maria205'});
      // The malformed '@@' does not masquerade as 'maria205'.
      expect(AuthValidators.normalizeUsername(forms.last), isNot('maria205'));
    });

    test('strips exactly one leading @ and surrounding spaces, lowercases', () {
      expect(AuthValidators.normalizeUsername('@iamleizu'), 'iamleizu');
      expect(AuthValidators.normalizeUsername('IAMLEIZU'), 'iamleizu');
      expect(AuthValidators.normalizeUsername('  @IamLeizu  '), 'iamleizu');
    });

    test('does not alter internal characters', () {
      expect(AuthValidators.normalizeUsername('user.name_01'), 'user.name_01');
    });

    test('blank / @-only / whitespace normalize to empty and are unresolvable', () {
      for (final v in ['', '   ', '@', ' @ ']) {
        expect(AuthValidators.normalizeUsername(v), isEmpty, reason: 'input=<$v>');
        expect(AuthValidators.isResolvableUsername(v), isFalse);
      }
      expect(AuthValidators.isResolvableUsername('@maria205'), isTrue);
    });
  });
}
