// test/live/auth_live_test.dart
//
// LIVE integration tests for Paax auth (Phase 3.1).
//
// These hit the REAL Supabase project using ONLY the public anon key — the
// exact surface the shipping Flutter client exposes. They assert the
// anon-facing auth contract WITHOUT sending any email (so the suite is
// repeatable and never trips the project's email-send rate limit):
//
//   * username_available RPC is reachable and returns the right boolean
//   * the anon role cannot read the profiles table (RLS is enforced)
//   * the server rejects a weak password before creating anything
//   * signing in with unknown credentials fails closed (invalid_credentials)
//
// The account-lifecycle half of the contract — the on_auth_user_created trigger
// creating a profile, username derivation, email-confirmation gating, RLS
// SELECT/UPDATE as the authenticated role, and the privileged-column guard
// trigger — is verified against a disposable account with no email side
// effects; see docs/features/authentication.md → "Phase 3.1 verification".
//
// Run explicitly (not part of the default unit suite):
//
//   flutter test test/live/auth_live_test.dart
//
// Uses the pure `package:supabase` client (no Flutter binding / local storage),
// so it runs headless under `flutter test`.

import 'package:flutter_test/flutter_test.dart';
// supabase_flutter re-exports the pure `supabase`/`gotrue` symbols used here
// (SupabaseClient, AuthClientOptions, GotrueAsyncStorage, AuthException). We
// construct the bare client directly — no Supabase.initialize, no Flutter
// binding — so this runs headless under `flutter test`.
import 'package:supabase_flutter/supabase_flutter.dart';

// Public project URL + anon key — identical to lib/core/config/supabase_config.dart
// defaults. Safe to embed (RLS-gated); NEVER the service-role key.
const String _url = 'https://jecgmiuypuathhvjuhea.supabase.co';
const String _anonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImplY2dtaXV5cHVhdGhodmp1aGVhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQxNjM2NDIsImV4cCI6MjA5OTczOTY0Mn0.DXC37LMDUTEjk6GD195iEk2d723uGhOxORel63pkwwo';

const String _strongButUnknownPassword = 'Paax!Test8x';

/// In-memory PKCE store. `supabase_flutter` provides this automatically in the
/// app; the headless pure-`supabase` client needs one to run the PKCE flow.
class _MemoryPkceStore extends GotrueAsyncStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
}

void main() {
  final client = SupabaseClient(
    _url,
    _anonKey,
    authOptions: AuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      pkceAsyncStorage: _MemoryPkceStore(),
    ),
  );

  final stamp = DateTime.now().microsecondsSinceEpoch;

  tearDownAll(() async {
    await client.dispose();
  });

  test('username_available RPC is reachable and true for an unused username',
      () async {
    final free = await client
        .rpc('username_available', params: {'p_username': 'free_$stamp'});
    expect(free, isTrue);
  });

  test('anon role cannot read the profiles table (RLS enforced)', () async {
    final rows = await client.from('profiles').select();
    expect(rows, isEmpty);
  });

  test('weak password is rejected before any account is created', () async {
    // Password policy is validated ahead of user creation / email send, so this
    // is deterministic and sends no email.
    await expectLater(
      client.auth.signUp(email: 'weak_$stamp@gmail.com', password: 'weak'),
      throwsA(isA<AuthException>()),
    );
  });

  test('sign-in with unknown credentials fails closed', () async {
    await expectLater(
      client.auth.signInWithPassword(
        email: 'nobody_$stamp@gmail.com',
        password: _strongButUnknownPassword,
      ),
      throwsA(isA<AuthException>().having(
        (e) => e.message.toLowerCase(),
        'message',
        contains('invalid'),
      )),
    );
  });
}
