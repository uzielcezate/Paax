// test/unit/auth_errors_test.dart
//
// Regression coverage for AuthErrorMapper — in particular the Phase 3.2A fix
// that maps "reused current password" to a specific, correct message instead of
// the generic password-policy error.

import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/core/auth/auth_errors.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('AuthErrorMapper — password reuse on reset', () {
    test('same_password code maps to the specific message', () {
      final f = AuthErrorMapper.map(
        AuthApiException('New password should be different from the old password.',
            code: 'same_password'),
      );
      expect(f.kind, AuthErrorKind.samePassword);
      expect(f.message,
          'Your new password must be different from your current password.');
    });

    test('"should be different" message maps to samePassword, not weakPassword',
        () {
      final f = AuthErrorMapper.map(
        AuthApiException('New password should be different from the old password.'),
      );
      expect(f.kind, AuthErrorKind.samePassword);
      expect(f.message, contains('different from your current password'));
    });

    test('a genuine weak-password error still maps to weakPassword', () {
      final f = AuthErrorMapper.map(
        AuthApiException('Password should be at least 8 characters.'),
      );
      expect(f.kind, AuthErrorKind.weakPassword);
    });
  });

  group('AuthErrorMapper — other cases', () {
    test('invalid credentials', () {
      final f = AuthErrorMapper.map(AuthApiException('Invalid login credentials'));
      expect(f.kind, AuthErrorKind.invalidCredentials);
    });

    test('email not confirmed', () {
      final f = AuthErrorMapper.map(AuthApiException('Email not confirmed'));
      expect(f.kind, AuthErrorKind.emailNotConfirmed);
    });
  });
}
