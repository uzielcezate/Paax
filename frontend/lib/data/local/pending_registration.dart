// lib/data/local/pending_registration.dart
//
// Versioned, non-sensitive pending-registration payload persisted locally
// (SharedPreferences) between signup and email verification, then auto-applied
// to the profile on the first verified session and cleared.
//
// NEVER persisted here: password, confirm password, access/refresh tokens,
// service-role credentials, or raw auth response payloads.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class PendingRegistration {
  static const int schemaVersion = 1;
  static const String _key = 'paax_pending_registration_v1';
  static const Duration ttl = Duration(days: 7);

  final int version;
  final String targetEmail; // lowercased
  final DateTime createdAt;
  final String status; // 'pending'
  // Non-sensitive profile fields:
  final String? firstName;
  final String? lastName;
  final String? displayName;
  final String username;
  final String? birthDate; // ISO yyyy-MM-dd
  final String? genderIdentity;
  final String? countryCode;
  final String? stateRegion;
  final String? city;

  const PendingRegistration({
    required this.targetEmail,
    required this.createdAt,
    required this.username,
    this.status = 'pending',
    this.version = schemaVersion,
    this.firstName,
    this.lastName,
    this.displayName,
    this.birthDate,
    this.genderIdentity,
    this.countryCode,
    this.stateRegion,
    this.city,
  });

  bool get isExpired => DateTime.now().difference(createdAt) > ttl;

  bool matchesEmail(String email) =>
      email.trim().toLowerCase() == targetEmail.trim().toLowerCase();

  /// Only RLS-allowed, non-privileged profile columns (no app_role/tier/etc.).
  Map<String, dynamic> toProfileUpdate() => {
        'username': username,
        if (displayName != null) 'display_name': displayName,
        if (firstName != null) 'first_name': firstName,
        if (lastName != null) 'last_name': lastName,
        if (birthDate != null) 'birth_date': birthDate,
        if (genderIdentity != null) 'gender_identity': genderIdentity,
        if (countryCode != null) 'country_code': countryCode,
        if (stateRegion != null) 'state_region': stateRegion,
        if (city != null) 'city': city,
      };

  Map<String, dynamic> _toJson() => {
        'schema_version': version,
        'target_email': targetEmail,
        'created_at': createdAt.toIso8601String(),
        'status': status,
        'first_name': firstName,
        'last_name': lastName,
        'display_name': displayName,
        'username': username,
        'birth_date': birthDate,
        'gender_identity': genderIdentity,
        'country_code': countryCode,
        'state_region': stateRegion,
        'city': city,
      };

  static PendingRegistration? _fromJson(Map<String, dynamic> j) {
    try {
      if ((j['schema_version'] as num?)?.toInt() != schemaVersion) return null;
      final email = (j['target_email'] as String?)?.trim();
      final username = (j['username'] as String?)?.trim();
      final created = DateTime.tryParse((j['created_at'] ?? '') as String);
      if (email == null || email.isEmpty || username == null || username.isEmpty || created == null) {
        return null;
      }
      return PendingRegistration(
        targetEmail: email,
        createdAt: created,
        status: (j['status'] ?? 'pending') as String,
        username: username,
        firstName: j['first_name'] as String?,
        lastName: j['last_name'] as String?,
        displayName: j['display_name'] as String?,
        birthDate: j['birth_date'] as String?,
        genderIdentity: j['gender_identity'] as String?,
        countryCode: j['country_code'] as String?,
        stateRegion: j['state_region'] as String?,
        city: j['city'] as String?,
      );
    } catch (_) {
      return null; // corrupt payload
    }
  }
}

/// Thin persistence wrapper (SharedPreferences). Injectable via [prefs] for tests.
class PendingRegistrationStore {
  final Future<SharedPreferences> _prefs;
  PendingRegistrationStore({Future<SharedPreferences>? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance();

  Future<void> save(PendingRegistration reg) async {
    final p = await _prefs;
    await p.setString(PendingRegistration._key, jsonEncode(reg._toJson()));
  }

  /// Loads a valid, non-expired payload; auto-clears corrupt/expired ones.
  Future<PendingRegistration?> load() async {
    final p = await _prefs;
    final raw = p.getString(PendingRegistration._key);
    if (raw == null) return null;
    Map<String, dynamic>? map;
    try {
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await clear();
      return null;
    }
    final reg = PendingRegistration._fromJson(map);
    if (reg == null) {
      await clear(); // corrupt
      return null;
    }
    if (reg.isExpired) {
      await clear(); // expired
      return null;
    }
    return reg;
  }

  Future<void> clear() async {
    final p = await _prefs;
    await p.remove(PendingRegistration._key);
  }
}
