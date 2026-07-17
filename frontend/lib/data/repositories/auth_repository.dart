// lib/data/repositories/auth_repository.dart
//
// Thin wrapper over Supabase Auth (anon key). Injectable so the controller can
// be unit-tested with a fake. No service-role usage; no manual token storage.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/supabase_config.dart';

class AuthRepository {
  final SupabaseClient _client;
  AuthRepository([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  Session? get currentSession => _client.auth.currentSession;
  User? get currentUser => _client.auth.currentUser;
  Stream<AuthState> get onAuthStateChange => _client.auth.onAuthStateChange;

  bool get isEmailVerified {
    final u = _client.auth.currentUser;
    return u?.emailConfirmedAt != null || u?.confirmedAt != null;
  }

  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) {
    return _client.auth.signUp(
      email: email,
      password: password,
      data: data,
      emailRedirectTo: SupabaseConfig.emailConfirmRedirect,
    );
  }

  Future<AuthResponse> signIn({required String email, required String password}) {
    return _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() => _client.auth.signOut();

  Future<ResendResponse> resendConfirmation(String email) {
    return _client.auth.resend(
      type: OtpType.signup,
      email: email,
      emailRedirectTo: SupabaseConfig.emailConfirmRedirect,
    );
  }

  Future<void> sendPasswordReset(String email) {
    return _client.auth.resetPasswordForEmail(
      email,
      redirectTo: SupabaseConfig.passwordResetRedirect,
    );
  }

  Future<UserResponse> updatePassword(String newPassword) {
    return _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> refreshSession() async {
    if (_client.auth.currentSession != null) {
      await _client.auth.refreshSession();
    }
  }
}
