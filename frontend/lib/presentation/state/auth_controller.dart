// lib/presentation/state/auth_controller.dart
//
// Supabase auth + offline-first startup orchestration (Phase 3.1 → 3.4.2).
//
// WHAT CHANGED IN 3.4.2 AND WHY
// -----------------------------
// This controller previously routed by exception: `_resolve()` fetched the
// profile and a bare `catch (_)` sent the user to Complete Profile. In
// production, Supabase returned 503/504 (a wedged PostgREST instance), so
// fully-configured users were routed into onboarding, and a slow response left
// the splash spinning with no deadline.
//
// The controller no longer decides anything. It is now an *effect runner*:
// it performs I/O, converts each outcome into a named [StartupEvent], and hands
// it to the pure [startupReducer], which owns every routing decision. The
// controller cannot route to Complete Profile even if it wanted to — it has no
// branch that does so.
//
// Three structural guarantees, each independently enforced:
//
//   1. EXACTLY ONE RESOLUTION PER SESSION. `_resolveSession` deduplicates by
//      user id against an in-flight future, so the constructor, the SDK's
//      `initialSession` event and a `login()` call collapse into ONE run and ONE
//      profile fetch. (Previously these produced two of everything — visible in
//      production logs as paired requests 3 ms apart.)
//
//   2. STALE RESPONSES CANNOT ROUTE. Every async continuation re-checks a
//      generation counter and the account it started for. A response belonging
//      to a previous account or a disposed controller is dropped.
//
//   3. THE AUTH LISTENER HAS A LIFECYCLE. The subscription is retained and
//      cancelled in [dispose], and registers with [StartupDiagnostics] so a
//      second registration trips an assertion in development.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:supabase_flutter/supabase_flutter.dart' as sb show AuthState;

import '../../core/auth/auth_errors.dart';
import '../../core/auth/validators.dart';
import '../../core/network/bounded_retry.dart';
import '../../core/network/remote_result.dart';
import '../../core/startup/startup_diagnostics.dart';
import '../../core/startup/startup_state.dart';
import '../../data/local/onboarding_selection_store.dart';
import '../../data/local/pending_registration.dart';
import '../../data/local/profile_bootstrap_cache.dart';
import '../../data/repositories/auth_repository.dart';
import '../../data/repositories/profile_repository.dart';
import '../../domain/entities/profile.dart';
import '../../domain/entities/user_profile.dart';
import '../screens/auth/auth_gate.dart' show AuthRoutes;

class AuthController extends ChangeNotifier {
  final AuthRepository _auth;
  final ProfileRepository _profiles;
  final PendingRegistrationStore _pending;
  final ProfileBootstrapCache? _cacheOverride;

  StartupState _startup = StartupState.initial;
  bool _submitting = false;
  String? _pendingVerificationEmail;
  bool _recovery = false;

  /// The user the recovery session belongs to. In memory only — a recovery
  /// context must never survive a process restart.
  String? _recoveryUserId;
  bool _disposed = false;

  StreamSubscription<sb.AuthState>? _authSub;

  /// Set synchronously on the first [bootstrap] call. Because Dart delivers
  /// stream events asynchronously, the constructor's call always sets this
  /// before `initialSession` can arrive — making the winner deterministic
  /// rather than a race.
  bool _bootstrapStarted = false;

  /// Bumped on every resolution. Async continuations compare against it and
  /// abandon themselves if it moved (account switch, sign-out, dispose).
  int _generation = 0;

  Future<void>? _inFlight;
  String? _inFlightUser;

  /// Set by `main()` when Hive failed to initialize. Startup then resolves to
  /// [StartupPhase.fatalStartupError] instead of pretending local data exists.
  final bool localStorageFailed;

  AuthController({
    AuthRepository? authRepository,
    ProfileRepository? profileRepository,
    PendingRegistrationStore? pendingStore,
    ProfileBootstrapCache? bootstrapCache,
    this.localStorageFailed = false,
    bool autoStart = true,
  })  : _auth = authRepository ?? AuthRepository(),
        _profiles = profileRepository ?? ProfileRepository(),
        _pending = pendingStore ?? PendingRegistrationStore(),
        _cacheOverride = bootstrapCache {
    if (autoStart) {
      _authSub = _auth.onAuthStateChange.listen(_onAuthEvent);
      StartupDiagnostics.register(StartupResource.authListener,
          owner: 'AuthController');
      // ignore: discarded_futures
      bootstrap();
    }
  }

  /// Lazily resolved so tests can construct the controller before Hive opens.
  ProfileBootstrapCache? get _cache {
    if (_cacheOverride != null) return _cacheOverride;
    try {
      return ProfileBootstrapCache();
    } catch (_) {
      return null; // box not open → cache miss, which is always safe
    }
  }

  // ── getters ─────────────────────────────────────────────────────────────

  /// The authoritative startup state. Routing reads this.
  StartupState get startup => _startup;
  StartupPhase get phase => _startup.phase;

  Profile? get profile => _startup.profile;
  bool get isSubmitting => _submitting;
  bool get isAuthenticated => _auth.currentSession != null;
  bool get isEmailVerified => _auth.isEmailVerified;
  bool get onboardingCompleted => _startup.profile?.onboardingCompleted ?? false;

  /// True when the shell is running on cached data because remote is unreachable.
  /// Drives the subtle offline indicator — never a blocking error screen.
  bool get isOffline => _startup.phase.isOffline;

  /// Why remote data is unavailable, when it is.
  RemoteFailureKind? get failureKind => _startup.failureKind;

  String? get pendingVerificationEmail =>
      _pendingVerificationEmail ?? _auth.currentUser?.email;

  /// Backward-compatible view for existing Home/Profile screens (unchanged).
  UserProfile? get currentUser {
    final p = _startup.profile;
    if (p == null) return null;
    final name = (p.displayName?.trim().isNotEmpty ?? false)
        ? p.displayName!.trim()
        : p.greetingName;
    return UserProfile(name: name, email: _auth.currentUser?.email ?? '');
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────

  /// Runs the startup sequence. Idempotent: subsequent calls return the
  /// in-flight future rather than starting a second resolution.
  Future<void> bootstrap() {
    if (_bootstrapStarted) return _inFlight ?? Future<void>.value();
    _bootstrapStarted = true;
    StartupDiagnostics.recordBootstrap();
    // Deliberately does NOT clear recovery: on a cold start the deep link can
    // be processed before this runs, and wiping the context here sent the user
    // to the normal destination instead of the new-password screen.
    return _resolveSession('bootstrap');
  }

  /// User-initiated retry from the offline/error screens.
  ///
  /// Forces a fresh resolution (bypasses in-flight dedupe) because the user
  /// explicitly asked. Sets [isSubmitting] for its duration so the retry button
  /// disables — without that, repeated taps on a dead backend would each launch
  /// a fresh bounded sequence, which is a slow-motion version of exactly the
  /// request storm this phase exists to prevent.
  Future<void> retryStartup() async {
    if (_submitting) return;
    _setSubmitting(true);
    try {
      await _resolveSession('manual-retry', force: true);
    } finally {
      _setSubmitting(false);
    }
  }

  void _onAuthEvent(sb.AuthState data) {
    if (_disposed) return;
    switch (data.event) {
      case AuthChangeEvent.passwordRecovery:
        // A RECOVERY CONTEXT, NOT A FLAG (Phase 3.4.13). Supabase emits this
        // with the short-lived recovery session attached. Requiring that
        // session is what stops a stale local boolean from ever routing to the
        // set-a-new-password screen: without a session there is nothing to
        // authorise the password update, so there is nothing to route to.
        final session = data.session ?? _auth.currentSession;
        if (session == null) break;
        _recovery = true;
        _recoveryUserId = session.user.id;
        // Invalidate any resolution already in flight. On a COLD START,
        // bootstrap() is launched from the constructor and its async
        // continuation used to land AFTER this event, dispatching
        // SessionRestored and moving the phase straight back off `recovery` —
        // which is why tapping the link opened the normal destination instead
        // of the new-password screen.
        _generation++;
        _dispatch(const RecoveryRequested());
        // The Forgot-password screen is PUSHED on top of the gate, so flipping
        // the gate's destination underneath leaves the user looking at the
        // resend form. Returning to the gate is what actually shows them the
        // new-password screen.
        AuthRoutes.popToGate();
        break;

      case AuthChangeEvent.signedOut:
        _pendingVerificationEmail = null;
        _generation++; // invalidate any in-flight resolution
        _dispatch(const SignedOut());
        break;

      case AuthChangeEvent.signedIn:
        // ignore: discarded_futures
        _resolveSession('signedIn');
        break;

      case AuthChangeEvent.initialSession:
        // `initialSession` means "the SDK restored the persisted session" —
        // exactly what bootstrap() already handled. Once bootstrap has run it is
        // pure duplication, and the SDK may emit it AFTER bootstrap completes,
        // so in-flight deduplication alone does not catch it. Dropping it here
        // is what makes the "one profile fetch per session" guarantee hold
        // regardless of emission timing. (This event, racing bootstrap, is what
        // produced the paired requests 3 ms apart in the production logs.)
        if (_bootstrapStarted) break;
        // ignore: discarded_futures
        _resolveSession('initialSession');
        break;

      case AuthChangeEvent.tokenRefreshed:
        // Deliberately does NOT re-resolve. A token refresh says nothing new
        // about the profile; re-fetching here meant a profile read every ~50
        // minutes forever. If we were offline, treat a successful refresh as
        // proof connectivity returned and reconcile in the background.
        if (_startup.phase == StartupPhase.offlineReady) {
          _dispatch(const ConnectivityRestored());
          // ignore: discarded_futures
          _refreshInBackground();
        }
        break;

      case AuthChangeEvent.userUpdated:
        // ignore: discarded_futures
        _refreshInBackground();
        break;

      default:
        break;
    }
  }

  /// Single entry point for resolution. Deduplicates by user id.
  Future<void> _resolveSession(String reason, {bool force = false}) {
    final uid = _auth.currentSession?.user.id;
    final existing = _inFlight;
    if (!force && existing != null && _inFlightUser == uid) {
      // Collapses bootstrap + initialSession + login into ONE run.
      return existing;
    }
    final future = _doResolve(uid, reason);
    _inFlight = future;
    _inFlightUser = uid;
    // ignore: discarded_futures
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightUser = null;
      }
    });
    return future;
  }

  /// Wrapper guaranteeing the resolution future NEVER completes with an error.
  ///
  /// `bootstrap()` is fired-and-forgotten from the constructor, so an escaping
  /// exception would surface as an unhandled async error (a crash in release).
  /// Any unexpected throw is contained and, if we have no usable state yet,
  /// converted into a recoverable screen rather than a blank/hung splash.
  Future<void> _doResolve(String? uid, String reason) async {
    try {
      await _doResolveInner(uid, reason);
    } catch (e) {
      if (_disposed) return;
      if (!_startup.phase.isShellVisible) {
        _dispatch(LocalStorageFailed(e));
      }
    }
  }

  Future<void> _doResolveInner(String? uid, String reason) async {
    final gen = ++_generation;

    if (localStorageFailed) {
      _dispatch(const LocalStorageFailed('Hive initialization failed'));
      return;
    }

    if (isRecoveryActive) {
      _dispatch(const RecoveryRequested());
      return;
    }

    final session = _auth.currentSession;
    if (session == null) {
      _dispatch(const NoSessionFound());
      return;
    }

    final userId = session.user.id;
    final verified = _auth.isEmailVerified;
    _dispatch(SessionRestored(userId, emailVerified: verified));
    if (!verified) return;

    // ── local first: no network, no deadline, no failure mode that routes ──
    final cache = _cache;
    await cache?.markActive(userId);
    if (_isStale(gen)) return;

    Profile? cachedProfile;
    try {
      cachedProfile = cache?.read(userId)?.toProfile();
    } catch (e) {
      // Local storage unreadable — the only path to fatalStartupError.
      _dispatch(LocalStorageFailed(e));
      return;
    }
    if (_isStale(gen)) return;
    _dispatch(LocalProfileLoaded(cachedProfile));

    // If the cache opened the shell, the remote read is now a BACKGROUND
    // refresh: the user is already in Home and nothing waits on it.
    await _fetchAndApplyRemote(
      userId: userId,
      gen: gen,
      hasCachedProfile: isShellReady(cachedProfile),
      session: session,
    );
  }

  Future<void> _fetchAndApplyRemote({
    required String userId,
    required int gen,
    required bool hasCachedProfile,
    required Session session,
  }) async {
    final result = await _profiles.fetchOwnResult(
      userId,
      // Behind a visible shell we can afford to be patient; blocking startup
      // must stay tight so the splash has a hard ceiling.
      policy: hasCachedProfile
          ? RetryPolicy.backgroundRefresh
          : RetryPolicy.startupProfile,
    );
    if (_isStale(gen)) return;

    var applied = result;
    if (result is RemoteSuccess<Profile?>) {
      // Apply a locally-stored pending registration only on an authoritative
      // answer — never against a failed read.
      try {
        final merged = await _maybeApplyPending(session, result.value);
        if (_isStale(gen)) return;
        applied = RemoteSuccess<Profile?>(merged);
      } catch (_) {
        applied = result; // keep the authoritative answer we already have
      }
    }

    _dispatch(RemoteProfileResolved(applied, hasCachedProfile: hasCachedProfile));

    // Persist ONLY confirmed server state, so the cache can never contain a
    // profile the server did not vouch for.
    if (applied is RemoteSuccess<Profile?>) {
      final p = applied.value;
      if (p != null) await _cache?.write(p);
    }
  }

  /// Guards against concurrent background refreshes. `tokenRefreshed` and
  /// `userUpdated` can arrive together; without this each would issue its own
  /// profile read.
  bool _backgroundRefreshInFlight = false;

  /// Background reconciliation behind an already-visible shell.
  Future<void> _refreshInBackground() async {
    final session = _auth.currentSession;
    if (session == null || !_startup.phase.isShellVisible) return;
    if (_backgroundRefreshInFlight) return;
    _backgroundRefreshInFlight = true;
    final gen = _generation;
    _dispatch(const BackgroundSyncStarted());
    try {
      await _fetchAndApplyRemote(
        userId: session.user.id,
        gen: gen,
        hasCachedProfile: true,
        session: session,
      );
    } finally {
      _backgroundRefreshInFlight = false;
    }
  }

  /// True when this continuation no longer owns the controller's state.
  bool _isStale(int gen) => _disposed || gen != _generation;

  /// Applies a locally-stored pending registration to the freshly-created
  /// profile, but ONLY when it belongs to the authenticated email.
  Future<Profile?> _maybeApplyPending(Session session, Profile? profile) async {
    final pending = await _pending.load(); // auto-drops corrupt/expired
    if (pending == null) return profile;
    final email = session.user.email ?? '';
    if (!pending.matchesEmail(email)) return profile; // different account
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
    _dispatch(const AuthenticationStarted());
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
      if (res.session == null) {
        _dispatch(SessionRestored(res.user?.id ?? '', emailVerified: false));
      } else {
        await _resolveSession('register', force: true);
      }
    } catch (e) {
      // A failed sign-up must not leave the machine stuck in `authenticating`.
      _dispatch(const NoSessionFound());
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  Future<void> login({required String email, required String password}) async {
    // An explicit password sign-in is NOT a recovery flow. Clearing here is what
    // stops an abandoned recovery attempt from dropping a later, normal sign-in
    // onto the set-a-new-password screen.
    _recovery = false;
    _recoveryUserId = null;
    _setSubmitting(true);
    _dispatch(const AuthenticationStarted());
    final normEmail = AuthValidators.normalizeEmail(email);
    try {
      await _auth.signIn(email: normEmail, password: password);
      // The `signedIn` event fires too; both collapse into one resolution.
      await _resolveSession('login');
    } catch (e) {
      final failure = AuthErrorMapper.map(e);
      if (failure.kind == AuthErrorKind.emailNotConfirmed) {
        _pendingVerificationEmail = normEmail;
        _dispatch(SessionRestored('', emailVerified: false));
      } else {
        _dispatch(const NoSessionFound());
      }
      throw failure;
    } finally {
      _setSubmitting(false);
    }
  }

  Future<void> resendVerification() async {
    final email = pendingVerificationEmail;
    if (email == null) {
      throw const AuthFailure(AuthErrorKind.unknown, 'No email to verify');
    }
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
    if (_auth.currentSession == null && _pendingVerificationEmail != null) {
      _dispatch(SessionRestored('', emailVerified: false));
      return;
    }
    await _resolveSession('verify-refresh', force: true);
  }

  Future<void> sendPasswordReset(String email) async {
    _setSubmitting(true);
    try {
      await _auth.sendPasswordReset(AuthValidators.normalizeEmail(email));
    } catch (e) {
      final f = AuthErrorMapper.map(e);
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
      // Recovery is consumed exactly once, on success only. A failed update
      // keeps the context so the user can retry on the same screen.
      _recovery = false;
      _recoveryUserId = null;
      await _resolveSession('password-updated', force: true);
    } catch (e) {
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  /// Complete-profile / retry path (RLS-safe fields only).
  Future<void> completeProfile(Map<String, dynamic> fields) async {
    final session = _auth.currentSession;
    if (session == null) {
      throw const AuthFailure(AuthErrorKind.unknown, 'Not signed in');
    }
    _setSubmitting(true);
    try {
      final updated = await _profiles.updateOwn(session.user.id, fields);
      await _pending.clear();
      await _cache?.write(updated); // server-confirmed → safe to cache
      _dispatch(RemoteProfileResolved(
        RemoteSuccess<Profile?>(updated),
        hasCachedProfile: true,
      ));
    } catch (e) {
      throw AuthErrorMapper.map(e);
    } finally {
      _setSubmitting(false);
    }
  }

  Future<bool> isUsernameAvailable(String username) =>
      _profiles.isUsernameAvailable(AuthValidators.normalizeUsername(username));

  Future<void> logout() async {
    // Invalidate in-flight work FIRST so a late response cannot re-open a
    // session the user just ended.
    _generation++;
    try {
      await _auth.signOut();
    } catch (_) {/* signedOut event / dispatch below still clears state */}
    _recovery = false;
    _recoveryUserId = null;
    _pendingVerificationEmail = null;
    // Clearing the active pointer is what makes an OFFLINE logout return to the
    // auth screen instead of restoring the cached Home. The per-account record
    // is retained so a re-login on this device is still instant and offline.
    await _cache?.clearActivePointer();
    try {
      await OnboardingSelectionStore().clear();
    } catch (_) {/* best-effort */}
    _dispatch(const SignedOut());
  }

  /// Deprecated (old intro onboarding). Kept so the legacy screen compiles.
  Future<void> completeOnboarding() async {}

  // ── internals ─────────────────────────────────────────────────────────────

  /// The ONLY way state changes. Every transition goes through the pure reducer.
  /// True only when BOTH a recovery event arrived AND a live Supabase session
  /// backs it. Routing reads this, never the raw flag.
  bool get isRecoveryActive {
    if (!_recovery) return false;
    final session = _auth.currentSession;
    if (session == null) {
      // The recovery session expired or was signed out — drop the context
      // rather than leaving a flag that could route later.
      _recovery = false;
      _recoveryUserId = null;
      return false;
    }
    // A different account signed in since; that sign-in is not this recovery.
    if (_recoveryUserId != null && _recoveryUserId != session.user.id) {
      _recovery = false;
      _recoveryUserId = null;
      return false;
    }
    return true;
  }

  void _dispatch(StartupEvent e) {
    if (_disposed) return;
    // RECOVERY IS NOT PREEMPTIBLE. Bootstrap and session-restore resolutions run
    // concurrently with the deep link and used to overwrite the recovery phase
    // the moment they finished. Only finishing recovery (updatePassword), losing
    // the session, or a fatal local failure may move off it.
    if (isRecoveryActive &&
        e is! RecoveryRequested &&
        e is! SignedOut &&
        e is! LocalStorageFailed) {
      return;
    }
    final next = startupReducer(_startup, e);
    if (next == _startup) return; // no spurious rebuilds / route thrash
    _startup = next;
    notifyListeners();
  }

  void _setSubmitting(bool v) {
    if (_submitting == v) return;
    _submitting = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    if (_authSub != null) {
      // ignore: discarded_futures
      _authSub!.cancel();
      _authSub = null;
      StartupDiagnostics.unregister(StartupResource.authListener);
    }
    super.dispose();
  }
}
