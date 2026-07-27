// test/unit/auth_errors_test.dart
//
// Regression coverage for AuthErrorMapper — in particular the Phase 3.2A fix
// that maps "reused current password" to a specific, correct message instead of
// the generic password-policy error.

import 'dart:async';
import 'dart:io' show SocketException;

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

  // Phase 3.3 §12: a temporary Supabase/network failure must show a safe
  // retryable message and must NEVER be mislabeled as invalid credentials
  // (the paused-project "Service temporarily unavailable" case).
  group('AuthErrorMapper — transient failures (§12)', () {
    test('network error is retryable, not invalid credentials', () {
      final f = AuthErrorMapper.map(const SocketException('failed host lookup'));
      expect(f.kind, AuthErrorKind.network);
      expect(f.kind, isNot(AuthErrorKind.invalidCredentials));
    });

    test('timeout maps to network (retryable)', () {
      final f = AuthErrorMapper.map(TimeoutException('deadline'));
      expect(f.kind, AuthErrorKind.network);
    });

    test('5xx maps to unavailable with the safe retry message', () {
      final f = AuthErrorMapper.map(
        AuthException('internal error', statusCode: '503'),
      );
      expect(f.kind, AuthErrorKind.unavailable);
      expect(f.message, contains('temporarily unavailable'));
      expect(f.kind, isNot(AuthErrorKind.invalidCredentials));
    });
  });
}
