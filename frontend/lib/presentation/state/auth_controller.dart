// lib/presentation/state/auth_controller.dart
//
// Centralized Supabase auth + session + profile state (Phase 3.1).
// Single source of truth for routing. Replaces the previous demo controller.
//
// Responsibilities: session restore, auth-event subscription, email-verification
// state, profile load/completeness, onboarding state, register/login/resend/
// recovery/update-password/logout, pending-registration auto-apply, and
// friendly error mapping (via AuthFailure).

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/auth_errors.dart';
import '../../core/auth/validators.dart';
import '../../data/local/pending_registration.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../domain/entities/profile.dart';
import '../../domain/entities/user_profile.dart';

/// Deterministic routing state.
enum AppAuthState {
  initializing,
  unauthenticated,
  unverified,
  profileLoading,
  completeProfile,
  onboarding, // 5-artist selection (Phase 3.2) — prepared route
  ready,
  recovery, // password-recovery deep link → Set New Password
}

class AuthController extends ChangeNotifier {
  final AuthRepository _auth;
  final ProfileRepository _profiles;
  final PendingRegistrationStore _pending;

  AppAuthState _state = AppAuthState.initializing;
  Profile? _profile;
  bool _submitting = false;
  String? _pendingVerificationEmail;
  bool _recovery = false;

  AuthController({
    AuthRepository? authRepository,
    ProfileRepository? profileRepository,
    PendingRegistrationStore? pendingStore,
    bool autoStart = true,
  })  : _auth = authRepository ?? AuthRepository(),
        _profiles = profileRepository ?? ProfileRepository(),
        _pending = pendingStore ?? PendingRegistrationStore() {
    if (autoStart) {
      _auth.onAuthStateChange.listen(_onAuthEvent);
      // ignore: discarded_futures
      bootstrap();
    }
  }

  // ── getters ─────────────────────────────────────────────────────────────

  AppAuthState get state => _state;
  Profile? get profile => _profile;
  bool get isSubmitting => _submitting;
  bool get isAuthenticated => _auth.currentSession != null;
  bool get isEmailVerified => _auth.isEmailVerified;
  bool get onboardingCompleted => _profile?.onboardingCompleted ?? false;
  String? get pendingVerificationEmail =>
      _pendingVerificationEmail ?? _auth.currentUser?.email;

  /// Backward-compatible view for existing Home/Profile screens (unchanged).
  UserProfile? get currentUser {
    final p = _profile;
    if (p == null) return null;
    final name = (p.displayName?.trim().isNotEmpty ?? false)
        ? p.displayName!.trim()
        : p.greetingName;
    return UserProfile(name: name, email: _auth.currentUser?.email ?? '');
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────

  Future<void> bootstrap() async {
    _recovery = false;
    await _resolve();
  }

  void _onAuthEvent(AuthState data) {
    switch (data.event) {
      case AuthChangeEvent.passwordRecovery:
        _recovery = true;
        _set(AppAuthState.recovery);
        break;
      case AuthChangeEvent.signedOut:
        _profile = null;
        _pendingVerificationEmail = null;
        _set(AppAuthState.unauthenticated);
        break;
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.userUpdated:
        // ignore: discarded_futures
        _resolve();
        break;
      default:
        break;
    }
  }

  Future<void> _resolve() async {
    if (_recovery) {
      _set(AppAuthState.recovery);
      return;
    }
    final session = _auth.currentSession;
    if (session == null) {
      _profile = null;
      _set(AppAuthState.unauthenticated);
      return;
    }
    if (!_auth.isEmailVerified) {
      _set(AppAuthState.unverified);
      return;
    }
    _set(AppAuthState.profileLoading);
    try {
      var profile = await _profiles.fetchOwn(session.user.id);
      profile = await _maybeApplyPending(session, profile);
      _profile = profile;
      if (profile == null || !profile.isComplete) {
        _set(AppAuthState.completeProfile);
      } else if (!profile.onboardingCompleted) {
        _set(AppAuthState.onboarding);
      } else {
        _set(AppAuthState.ready);
      }
    } catch (_) {
      // Profile load failed — allow the user to retry via Complete Profile.
      _set(AppAuthState.completeProfile);
    }
  }

  /// Applies a locally-stored pending registration to the freshly-created
  /// profile, but ONLY when it belongs to the authenticated email.
  Future<Profile?> _maybeApplyPending(Session session, Profile? profile) async {
    final pending = await _pending.load(); // auto-drops corrupt/expired
    if (pending == null) return profile;
    final email = session.user.email ?? '';
    if (!pending.matchesEmail(email)) return profile; // different account — never apply
    if (profile != null && profile.isComplete) {
      await _pending.clear();
      return profile;
    }
    try {
      final updated =
          await _profiles.updateOwn(session.user.id, pending.toProfileUpdate());
      await _pending.clear(); // clear ONLY after confirmed DB success
      return updated;
    } catch (_) {
      return profile; // keep pending for retry
    }
  }

  // ── actions (throw AuthFailure on error; screens catch + display) ─────────

  Future<void> register({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    required String username,
    String? birthDateIso,
    String? genderIdentity,
    String? countryCode,
    String? stateRegion,
    String? city,
  }) async {
    _setSubmitting(true);
    final normEmail = AuthValidators.normalizeEmail(email);
    final normUsername = AuthValidators.normalizeUsername(username);
    final displayName = AuthValidators.buildDisplayName(firstName, lastName);
    try {
      final res = await _auth.signUp(
        email: normEmail,
        password: password,
        data: {'username': normUsername, 'display_name': displayName},
      );
      await _pending.save(PendingRegistration(
        targetEmail: normEmail,
        createdAt: DateTime.now(),
        username: normUsername,
        displayName: displayName,
        firstName: firstName.trim(),
        lastName: lastName.trim(),
        birthDate: birthDateIso,
        genderIdentity: genderIdentity,
        countryCode: countryCode,
        stateRegion: stateRegion,
        city: city,
      ));
      _pendingVerificationEmail = normEmail;
      // With email confirmation ON, signUp issues NO session → route straight to
      // the Verify-Email screen (previously this fell through _resolve to
      // Welcome, skipping verification). If confirmation is OFF (autoconfirm), a
      // session exists and we resolve on into the app.
      if (res.session == null) {
        _set(AppAuthState.unverified);
      } else {
        await _resolve();
      }
    } catch (e) {
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  Future<void> login({required String email, required String password}) async {
    _setSubmitting(true);
    final normEmail = AuthValidators.normalizeEmail(email);
    try {
      await _auth.signIn(email: normEmail, password: password);
      await _resolve();
    } catch (e) {
      final failure = AuthErrorMapper.map(e);
      if (failure.kind == AuthErrorKind.emailNotConfirmed) {
        _pendingVerificationEmail = normEmail;
        _set(AppAuthState.unverified);
      }
      throw failure;
    } finally {
      _setSubmitting(false);
    }
  }

  Future<void> resendVerification() async {
    final email = pendingVerificationEmail;
    if (email == null) throw const AuthFailure(AuthErrorKind.unknown, 'No email to verify');
    try {
      await _auth.resendConfirmation(email);
    } catch (e) {
      throw AuthErrorMapper.map(e);
    }
  }

  /// "I already verified" — refresh session/user and re-resolve.
  Future<void> refreshVerificationStatus() async {
    try {
      await _auth.refreshSession();
    } catch (_) {/* keep going; resolve reflects current state */}
    // Without a session there is nothing to resolve — the user must open the
    // confirmation link on THIS device to establish one. Stay on the verify
    // screen (with its "open the link" hint) rather than bouncing to Welcome.
    if (_auth.currentSession == null && _pendingVerificationEmail != null) {
      _set(AppAuthState.unverified);
      return;
    }
    await _resolve();
  }

  Future<void> sendPasswordReset(String email) async {
    _setSubmitting(true);
    try {
      await _auth.sendPasswordReset(AuthValidators.normalizeEmail(email));
      // Neutral outcome — never reveal whether the email exists.
    } catch (e) {
      final f = AuthErrorMapper.map(e);
      // Rate-limit/network are surfaced; otherwise stay neutral.
      if (f.kind == AuthErrorKind.rateLimited || f.kind == AuthErrorKind.network) {
        throw f;
      }
    } finally {
      _setSubmitting(false);
    }
  }

  Future<void> updatePassword(String newPassword) async {
    _setSubmitting(true);
    try {
      await _auth.updatePassword(newPassword);
      _recovery = false;
      await _resolve(); // recovery session persists → route into the app
    } catch (e) {
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  /// Complete-profile / retry path (RLS-safe fields only).
  Future<void> completeProfile(Map<String, dynamic> fields) async {
    final session = _auth.currentSession;
    if (session == null) throw const AuthFailure(AuthErrorKind.unknown, 'Not signed in');
    _setSubmitting(true);
    try {
      _profile = await _profiles.updateOwn(session.user.id, fields);
      await _pending.clear();
      await _resolve();
    } catch (e) {
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  Future<bool> isUsernameAvailable(String username) =>
      _profiles.isUsernameAvailable(AuthValidators.normalizeUsername(username));

  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (_) {/* signedOut event / resolve will still clear state */}
    _profile = null;
    _recovery = false;
    _pendingVerificationEmail = null;
    // Pending registration is email-scoped and intentionally NOT cleared here,
    // so a genuine re-login with the same email still completes; a different
    // account can never receive it (email match is enforced).
    _set(AppAuthState.unauthenticated);
  }

  /// Deprecated (old intro onboarding). Kept so the legacy screen compiles;
  /// the new flow routes via AppAuthState, not this flag.
  Future<void> completeOnboarding() async {}

  // ── internals ─────────────────────────────────────────────────────────────

  void _set(AppAuthState s) {
    _state = s;
    notifyListeners();
  }

  void _setSubmitting(bool v) {
    _submitting = v;
    notifyListeners();
  }
}
