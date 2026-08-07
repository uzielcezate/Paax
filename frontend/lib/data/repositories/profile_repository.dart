// lib/data/repositories/profile_repository.dart
//
// Reads/updates the authenticated user's own profile via RLS-safe operations.
// The client only ever writes NON-privileged fields; app_role / subscription_*
// are protected by a DB trigger AND excluded here as defense-in-depth.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/network/bounded_retry.dart';
import '../../core/network/remote_result.dart';
import '../../core/startup/startup_diagnostics.dart';
import '../../domain/entities/profile.dart';

class ProfileRepository {
  final SupabaseClient _client;
  ProfileRepository([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  /// Non-privileged, client-writable columns. Intentionally excludes app_role,
  /// subscription_*, counters, and onboarding_completed (onboarding is Phase 3.2
  /// — never falsely mark it complete here).
  static const Set<String> writableFields = {
    'username',
    'display_name',
    'first_name',
    'last_name',
    'birth_date',
    'gender_identity',
    'country_code',
    'state_region',
    'city',
    'latitude_approx',
    'longitude_approx',
    'is_private',
    'avatar_url',
    'avatar_original_url',
  };

  Future<Profile?> fetchOwn(String userId) async {
    final data =
        await _client.from('profiles').select().eq('id', userId).maybeSingle();
    return data == null ? null : Profile.fromMap(data);
  }

  /// Result-typed profile read — the ONLY read startup routing may use.
  ///
  /// Returns [RemoteSuccess] with a null value ONLY when the server was reached
  /// and genuinely has no row for [userId]. Every failure — timeout, 503/504,
  /// DNS failure, offline, PostgREST error — returns [RemoteUnavailable], which
  /// carries no value and therefore cannot be mistaken for "profile missing".
  /// That distinction is the fix for the false Complete-Profile routing; see
  /// `core/network/remote_result.dart`.
  ///
  /// Bounded by [policy]: never more than a few attempts, never longer than the
  /// policy's total budget, and only transient failures are retried.
  Future<RemoteResult<Profile?>> fetchOwnResult(
    String userId, {
    RetryPolicy policy = RetryPolicy.startupProfile,
  }) {
    return runBounded<Profile?>(
      () async {
        StartupDiagnostics.recordProfileFetch();
        final data = await _client
            .from('profiles')
            .select()
            .eq('id', userId)
            .maybeSingle();
        return data == null ? null : Profile.fromMap(data);
      },
      policy: policy,
      label: 'profile:$userId',
    );
  }

  /// Debounced availability check via the bool-only RPC (RLS-safe).
  Future<bool> isUsernameAvailable(String username) async {
    final res =
        await _client.rpc('username_available', params: {'p_username': username});
    return res == true;
  }

  /// Update only permitted fields; returns the fresh row. Throws
  /// PostgrestException on username conflict (23505) — mapped by AuthErrorMapper.
  Future<Profile> updateOwn(String userId, Map<String, dynamic> fields) async {
    final permitted = <String, dynamic>{
      for (final e in fields.entries)
        if (writableFields.contains(e.key)) e.key: e.value,
    };
    if (permitted.isEmpty) {
      final current = await fetchOwn(userId);
      if (current == null) {
        throw StateError('Profile row not found for $userId');
      }
      return current;
    }
    final data = await _client
        .from('profiles')
        .update(permitted)
        .eq('id', userId)
        .select()
        .single();
    return Profile.fromMap(data);
  }
}
