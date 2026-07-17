// lib/core/auth/auth_errors.dart
//
// Maps Supabase / network errors to friendly, specific user messages.
// Never surfaces raw API payloads or internal provider details. English UI.

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:supabase_flutter/supabase_flutter.dart';

/// Distinct auth failure kinds the UI may branch on (beyond the message).
enum AuthErrorKind {
  invalidCredentials,
  emailNotConfirmed,
  emailAlreadyRegistered,
  weakPassword,
  usernameTaken,
  rateLimited,
  expiredLink,
  network,
  unavailable,
  profileUpdateFailed,
  unknown,
}

class AuthFailure implements Exception {
  final AuthErrorKind kind;
  final String message;
  const AuthFailure(this.kind, this.message);

  @override
  String toString() => 'AuthFailure($kind): $message';
}

class AuthErrorMapper {
  AuthErrorMapper._();

  static AuthFailure map(Object error) {
    // Network first.
    if (error is SocketException || error is TimeoutException) {
      return const AuthFailure(AuthErrorKind.network, 'No internet connection');
    }

    if (error is AuthException) {
      final msg = error.message.toLowerCase();
      final code = error.statusCode;

      if (code == '429' || msg.contains('rate limit') || msg.contains('for security purposes')) {
        return const AuthFailure(
            AuthErrorKind.rateLimited, 'Too many attempts. Please try again in a moment');
      }
      if (msg.contains('invalid login credentials') || msg.contains('invalid credentials')) {
        return const AuthFailure(
            AuthErrorKind.invalidCredentials, 'Incorrect email or password');
      }
      if (msg.contains('email not confirmed') || msg.contains('not confirmed')) {
        return const AuthFailure(
            AuthErrorKind.emailNotConfirmed, 'Please verify your email to continue');
      }
      if (msg.contains('already registered') ||
          msg.contains('already been registered') ||
          msg.contains('user already exists')) {
        return const AuthFailure(
            AuthErrorKind.emailAlreadyRegistered, 'This email is already registered');
      }
      if (msg.contains('password') && (msg.contains('weak') || msg.contains('should') || msg.contains('at least'))) {
        return const AuthFailure(AuthErrorKind.weakPassword,
            'Password must be 8+ chars with upper, lower, number and symbol');
      }
      // Stale/used email confirmation or recovery LINK. Scope to link/token
      // context so a generic "session/JWT expired" isn't mislabeled as a link
      // error (invalid-credentials / not-confirmed are already handled above).
      final looksLikeLink = msg.contains('link') ||
          msg.contains('token') ||
          msg.contains('otp') ||
          msg.contains('code');
      if (looksLikeLink && (msg.contains('expired') || msg.contains('invalid'))) {
        return const AuthFailure(
            AuthErrorKind.expiredLink, 'This link has expired or was already used');
      }
      if (code != null && code.startsWith('5')) {
        return const AuthFailure(
            AuthErrorKind.unavailable, 'Service temporarily unavailable. Try again later');
      }
      return AuthFailure(AuthErrorKind.unknown, error.message);
    }

    if (error is PostgrestException) {
      // 23505 = unique_violation (username already taken).
      if (error.code == '23505' || (error.message.toLowerCase().contains('duplicate') &&
          error.message.toLowerCase().contains('username'))) {
        return const AuthFailure(AuthErrorKind.usernameTaken, 'That username is taken');
      }
      return const AuthFailure(
          AuthErrorKind.profileUpdateFailed, "Couldn't save your profile. Please try again");
    }

    return const AuthFailure(AuthErrorKind.unknown, 'Something went wrong. Please try again');
  }

  static String message(Object error) => map(error).message;
}
