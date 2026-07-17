// lib/domain/entities/profile.dart
//
// Supabase `public.profiles` row (Phase 1 schema) as consumed by the app.
// This is NOT a Hive model — it mirrors the server row. Privileged fields
// (app_role, subscription_*) are read-only to the client and never written back.

class Profile {
  final String id;
  final String username;
  final String? displayName;
  final String? firstName;
  final String? lastName;
  final String? avatarUrl;
  final DateTime? birthDate;
  final String? genderIdentity;
  final String? countryCode;
  final String? stateRegion;
  final String? city;
  // Read-only (server/trigger-managed).
  final String appRole;
  final String subscriptionTier;
  final String subscriptionStatus;
  final bool isPrivate;
  final bool onboardingCompleted;

  const Profile({
    required this.id,
    required this.username,
    this.displayName,
    this.firstName,
    this.lastName,
    this.avatarUrl,
    this.birthDate,
    this.genderIdentity,
    this.countryCode,
    this.stateRegion,
    this.city,
    this.appRole = 'user',
    this.subscriptionTier = 'free',
    this.subscriptionStatus = 'inactive',
    this.isPrivate = false,
    this.onboardingCompleted = false,
  });

  factory Profile.fromMap(Map<String, dynamic> m) {
    DateTime? parseDate(dynamic v) =>
        (v == null) ? null : DateTime.tryParse(v.toString());
    return Profile(
      id: m['id'] as String,
      username: (m['username'] ?? '') as String,
      displayName: m['display_name'] as String?,
      firstName: m['first_name'] as String?,
      lastName: m['last_name'] as String?,
      avatarUrl: (m['avatar_url'] ?? m['avatar_original_url']) as String?,
      birthDate: parseDate(m['birth_date']),
      genderIdentity: m['gender_identity'] as String?,
      countryCode: m['country_code'] as String?,
      stateRegion: m['state_region'] as String?,
      city: m['city'] as String?,
      appRole: (m['app_role'] ?? 'user') as String,
      subscriptionTier: (m['subscription_tier'] ?? 'free') as String,
      subscriptionStatus: (m['subscription_status'] ?? 'inactive') as String,
      isPrivate: (m['is_private'] ?? false) as bool,
      onboardingCompleted: (m['onboarding_completed'] ?? false) as bool,
    );
  }

  /// The required fields collected at registration. Determines whether the
  /// user must pass through the Complete-Profile step.
  bool get isComplete =>
      username.trim().isNotEmpty &&
      (displayName ?? '').trim().isNotEmpty &&
      birthDate != null &&
      (countryCode ?? '').trim().isNotEmpty;

  /// First token of the given name — for the (future) Home greeting.
  String get greetingName {
    final first = (firstName ?? '').trim();
    if (first.isNotEmpty) return first.split(RegExp(r'\s+')).first;
    final dn = (displayName ?? '').trim();
    if (dn.isNotEmpty) return dn.split(RegExp(r'\s+')).first;
    return username;
  }

  bool get isPremium => subscriptionTier != 'free';
  bool get isOwner => appRole == 'owner';

  Profile copyWith({
    String? username,
    String? displayName,
    String? firstName,
    String? lastName,
    DateTime? birthDate,
    String? genderIdentity,
    String? countryCode,
    String? stateRegion,
    String? city,
    bool? onboardingCompleted,
  }) {
    return Profile(
      id: id,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      avatarUrl: avatarUrl,
      birthDate: birthDate ?? this.birthDate,
      genderIdentity: genderIdentity ?? this.genderIdentity,
      countryCode: countryCode ?? this.countryCode,
      stateRegion: stateRegion ?? this.stateRegion,
      city: city ?? this.city,
      appRole: appRole,
      subscriptionTier: subscriptionTier,
      subscriptionStatus: subscriptionStatus,
      isPrivate: isPrivate,
      onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    );
  }
}
