// lib/core/auth/validators.dart
//
// Pure, testable form validators for Paax auth (Phase 3.1).
// Messages are English to match the app's existing UI language.
//
// Password + username policies mirror the Supabase / Phase 1 schema exactly:
//   password : >=8, upper, lower, digit, special
//   username : ^[a-z0-9_.]{3,30}$

class AuthValidators {
  AuthValidators._();

  // ── Email ─────────────────────────────────────────────────────────────────

  static final RegExp _emailRe =
      RegExp(r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$");

  static String normalizeEmail(String value) => value.trim().toLowerCase();

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter your email';
    if (!_emailRe.hasMatch(v)) return 'Enter a valid email';
    return null;
  }

  // ── Password ───────────────────────────────────────────────────────────────

  static bool hasMinLength(String v) => v.length >= 8;
  static bool hasUpper(String v) => RegExp(r'[A-Z]').hasMatch(v);
  static bool hasLower(String v) => RegExp(r'[a-z]').hasMatch(v);
  static bool hasDigit(String v) => RegExp(r'\d').hasMatch(v);
  static bool hasSpecial(String v) => RegExp(r'[^A-Za-z0-9]').hasMatch(v);

  static bool isPasswordStrong(String v) =>
      hasMinLength(v) && hasUpper(v) && hasLower(v) && hasDigit(v) && hasSpecial(v);

  static String? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return 'Enter a password';
    if (!hasMinLength(v)) return 'At least 8 characters';
    if (!hasUpper(v)) return 'Add an uppercase letter';
    if (!hasLower(v)) return 'Add a lowercase letter';
    if (!hasDigit(v)) return 'Add a number';
    if (!hasSpecial(v)) return 'Add a special character';
    return null;
  }

  static String? confirmPassword(String? password, String? confirm) {
    if ((confirm ?? '').isEmpty) return 'Confirm your password';
    if (password != confirm) return 'Passwords do not match';
    return null;
  }

  // ── Username ───────────────────────────────────────────────────────────────

  static final RegExp _usernameRe = RegExp(r'^[a-z0-9_.]{3,30}$');

  /// Canonical form: trimmed + lowercased (case-insensitive uniqueness).
  static String normalizeUsername(String value) => value.trim().toLowerCase();

  static String? username(String? value) {
    final v = normalizeUsername(value ?? '');
    if (v.isEmpty) return 'Choose a username';
    if (v.length < 3) return 'At least 3 characters';
    if (v.length > 30) return 'At most 30 characters';
    if (!_usernameRe.hasMatch(v)) {
      return 'Only lowercase letters, numbers, "." and "_"';
    }
    if (v.startsWith('.') || v.startsWith('_') || v.endsWith('.') || v.endsWith('_')) {
      return 'Cannot start or end with "." or "_"';
    }
    if (RegExp(r'[._]{2,}').hasMatch(v)) {
      return 'Avoid repeated "." or "_"';
    }
    return null;
  }

  // ── Names / required text ────────────────────────────────────────────────

  static String? requiredText(String? value, String label) {
    if ((value ?? '').trim().isEmpty) return 'Enter your $label';
    if ((value ?? '').trim().length > 80) return '$label is too long';
    return null;
  }

  /// display_name defaults to the trimmed "first last" combination.
  static String buildDisplayName(String first, String last) =>
      [first.trim(), last.trim()].where((s) => s.isNotEmpty).join(' ').trim();

  // ── Date of birth ─────────────────────────────────────────────────────────
  // Not in the future; plausible year. No hard legal minimum age is enforced
  // here — that is a product/legal decision (none is documented yet). See
  // docs/features/authentication.md.

  static String? birthDate(DateTime? value) {
    if (value == null) return 'Select your date of birth';
    final now = DateTime.now();
    if (value.isAfter(now)) return 'Date cannot be in the future';
    if (value.year < 1900) return 'Enter a valid date';
    final age = _ageFrom(value, now);
    if (age > 120) return 'Enter a valid date';
    return null;
  }

  static int _ageFrom(DateTime birth, DateTime now) {
    var age = now.year - birth.year;
    if (now.month < birth.month || (now.month == birth.month && now.day < birth.day)) {
      age--;
    }
    return age;
  }

  // ── Country / region ──────────────────────────────────────────────────────

  static final RegExp _countryRe = RegExp(r'^[A-Z]{2}$');

  static String? countryCode(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    if (v.isEmpty) return 'Select your country';
    if (!_countryRe.hasMatch(v)) return 'Invalid country';
    return null;
  }
}
