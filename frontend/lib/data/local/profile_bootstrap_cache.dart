// lib/data/local/profile_bootstrap_cache.dart
//
// Account-scoped local profile bootstrap record (Phase 3.4.2).
//
// PURPOSE
// -------
// Startup must be able to answer "who is signed in, and is their profile
// complete?" without touching the network. Before this phase there was no local
// answer at all, so every cold start blocked on Supabase and every Supabase
// failure became a routing decision.
//
// STORAGE SHAPE
// -------------
// A plain (untyped) Hive box holding JSON maps keyed by user UUID. Deliberately
// NOT a TypeAdapter: adapters are versioned by binary typeId and a schema change
// means a migration or a crash on old data. A JSON map with an explicit
// [schemaVersion] can evolve additively, and an unreadable/older record is
// simply discarded — a cache miss is always safe, because a miss routes to
// "ask the server", never to "assume incomplete".
//
// ACCOUNT ISOLATION
// -----------------
// Records are keyed by UUID and read only for the currently-authenticated id, so
// account B can never observe account A's profile. A separate `_activePointer`
// key records which account owns the device session; explicit logout clears the
// pointer (so the app returns to auth even offline) while leaving the per-user
// record intact, so re-login on the same device is still instant and offline.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../domain/entities/profile.dart';

/// One cached profile bootstrap record.
@immutable
class ProfileBootstrapRecord {
  /// Bumped only on a BREAKING shape change. Records with a different version
  /// are ignored (treated as a cache miss).
  static const int currentSchemaVersion = 1;

  final String userId;
  final String username;
  final String? displayName;
  final String? firstName;
  final String? lastName;
  final String? avatarUrl;
  final DateTime? birthDate;
  final String? countryCode;
  final String? stateRegion;
  final String? city;
  final String? genderIdentity;
  final bool profileCompleted;
  final bool onboardingCompleted;
  final DateTime lastSuccessfulSyncAt;
  final int schemaVersion;

  const ProfileBootstrapRecord({
    required this.userId,
    required this.username,
    required this.profileCompleted,
    required this.onboardingCompleted,
    required this.lastSuccessfulSyncAt,
    this.displayName,
    this.firstName,
    this.lastName,
    this.avatarUrl,
    this.birthDate,
    this.countryCode,
    this.stateRegion,
    this.city,
    this.genderIdentity,
    this.schemaVersion = currentSchemaVersion,
  });

  factory ProfileBootstrapRecord.fromProfile(Profile p, {DateTime? syncedAt}) {
    return ProfileBootstrapRecord(
      userId: p.id,
      username: p.username,
      displayName: p.displayName,
      firstName: p.firstName,
      lastName: p.lastName,
      avatarUrl: p.avatarUrl,
      birthDate: p.birthDate,
      countryCode: p.countryCode,
      stateRegion: p.stateRegion,
      city: p.city,
      genderIdentity: p.genderIdentity,
      profileCompleted: p.isComplete,
      onboardingCompleted: p.onboardingCompleted,
      lastSuccessfulSyncAt: syncedAt ?? DateTime.now(),
    );
  }

  /// Rebuilds a [Profile] for rendering.
  ///
  /// Privileged, server-owned fields (app_role, subscription_*) are intentionally
  /// NOT cached and reconstruct at their safe defaults: a stale local cache must
  /// never be able to grant a role or a paid tier. Those are re-read from the
  /// server on the background refresh.
  Profile toProfile() => Profile(
        id: userId,
        username: username,
        displayName: displayName,
        firstName: firstName,
        lastName: lastName,
        avatarUrl: avatarUrl,
        birthDate: birthDate,
        genderIdentity: genderIdentity,
        countryCode: countryCode,
        stateRegion: stateRegion,
        city: city,
        onboardingCompleted: onboardingCompleted,
      );

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'user_id': userId,
        'username': username,
        'display_name': displayName,
        'first_name': firstName,
        'last_name': lastName,
        'avatar_url': avatarUrl,
        'birth_date': birthDate?.toIso8601String(),
        'country_code': countryCode,
        'state_region': stateRegion,
        'city': city,
        'gender_identity': genderIdentity,
        'profile_completed': profileCompleted,
        'onboarding_completed': onboardingCompleted,
        'last_successful_sync_at': lastSuccessfulSyncAt.toIso8601String(),
      };

  /// Returns null for anything unreadable or from a different schema version.
  /// A null return is a cache miss, which is always safe.
  static ProfileBootstrapRecord? fromJson(Map<String, dynamic> m) {
    try {
      final v = m['schema_version'];
      if (v is! int || v != currentSchemaVersion) return null;
      final id = m['user_id'];
      if (id is! String || id.isEmpty) return null;
      final synced = DateTime.tryParse('${m['last_successful_sync_at']}');
      if (synced == null) return null;
      return ProfileBootstrapRecord(
        userId: id,
        username: (m['username'] ?? '') as String,
        displayName: m['display_name'] as String?,
        firstName: m['first_name'] as String?,
        lastName: m['last_name'] as String?,
        avatarUrl: m['avatar_url'] as String?,
        birthDate: m['birth_date'] == null
            ? null
            : DateTime.tryParse('${m['birth_date']}'),
        countryCode: m['country_code'] as String?,
        stateRegion: m['state_region'] as String?,
        city: m['city'] as String?,
        genderIdentity: m['gender_identity'] as String?,
        profileCompleted: (m['profile_completed'] ?? false) as bool,
        onboardingCompleted: (m['onboarding_completed'] ?? false) as bool,
        lastSuccessfulSyncAt: synced,
        schemaVersion: v,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Account-scoped persistence for [ProfileBootstrapRecord].
///
/// Every method is failure-tolerant: a storage error degrades to a cache miss
/// rather than propagating, because startup must never fail on a cache problem.
class ProfileBootstrapCache {
  static const String boxName = 'profile_bootstrap';
  static const String _activePointerKey = '__active_user__';

  final Box _box;

  ProfileBootstrapCache([Box? box]) : _box = box ?? Hive.box(boxName);

  /// Opened by [HiveStorage.init]; separate so tests can open it standalone.
  static Future<void> open() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  /// The account whose session this device last held, or null after logout.
  String? get activeUserId {
    final v = _box.get(_activePointerKey);
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Reads the record for [userId] only. Never returns another account's data.
  ProfileBootstrapRecord? read(String userId) {
    if (userId.isEmpty) return null;
    try {
      final raw = _box.get(userId);
      if (raw == null) return null;
      final map = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      final rec = ProfileBootstrapRecord.fromJson(map);
      // Defence in depth: a record whose payload disagrees with its key is
      // corrupt or mis-keyed and must not be trusted.
      if (rec != null && rec.userId != userId) return null;
      return rec;
    } catch (_) {
      return null;
    }
  }

  /// Persists [profile] and marks it the active account.
  ///
  /// Called ONLY after an authoritative remote success, so the cache can never
  /// contain a profile the server did not confirm.
  Future<void> write(Profile profile) async {
    try {
      final rec = ProfileBootstrapRecord.fromProfile(profile);
      await _box.put(profile.id, jsonEncode(rec.toJson()));
      await _box.put(_activePointerKey, profile.id);
    } catch (_) {
      // Best-effort: a failed cache write must not break a working session.
    }
  }

  /// Marks [userId] active without altering its record (session restore).
  Future<void> markActive(String userId) async {
    try {
      await _box.put(_activePointerKey, userId);
    } catch (_) {/* best-effort */}
  }

  /// Clears the active pointer on explicit logout.
  ///
  /// The per-user record is intentionally RETAINED so re-login on this device is
  /// instant and works offline. Because routing reads the pointer (not the
  /// record), an offline logout correctly lands on the auth screen.
  Future<void> clearActivePointer() async {
    try {
      await _box.delete(_activePointerKey);
    } catch (_) {/* best-effort */}
  }

  /// Erases one account's record — account deletion / "forget this device".
  Future<void> forget(String userId) async {
    try {
      await _box.delete(userId);
      if (activeUserId == userId) await clearActivePointer();
    } catch (_) {/* best-effort */}
  }

  @visibleForTesting
  Future<void> clearAll() => _box.clear();
}
