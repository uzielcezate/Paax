// test/unit/password_recovery_test.dart
//
// Phase 3.4.13 — the password-recovery deep link opened the wrong screen, and a
// stale recovery flag could later hijack a normal sign-in.
//
// THREE DISTINCT DEFECTS, all exercised here against the REAL AuthController:
//
//   1. COLD START LOST THE RECOVERY CONTEXT. `bootstrap()` is launched from the
//      constructor; its async continuation landed AFTER the deep link's
//      `passwordRecovery` event and dispatched `SessionRestored`, moving the
//      phase straight back off `recovery`. Tapping the link opened the normal
//      destination instead of the new-password screen.
//
//   2. RECOVERY WAS A STICKY LOCAL BOOLEAN. `_recovery` was never cleared by a
//      later normal sign-in, so signing in with the OLD password re-entered
//      `_doResolveInner`, saw the flag, and routed to the new-password screen.
//
//   3. THE FLAG ALONE AUTHORISED THE ROUTE. Recovery now requires a live
//      Supabase session belonging to the recovering user — there is otherwise
//      nothing that could authorise the password update.
//
// (The fourth part of the fix — popping the pushed Forgot-password route so the
// gate's destination is actually visible — lives in AuthRoutes.popToGate and is
// a navigator concern, exercised by manual QA items J/K.)

import 'dart:async';
import 'dart:io';

import 'package:beaty/core/network/bounded_retry.dart';
import 'package:beaty/core/network/remote_result.dart';
import 'package:beaty/core/startup/startup_diagnostics.dart';
import 'package:beaty/core/startup/startup_state.dart';
import 'package:beaty/data/local/pending_registration.dart';
import 'package:beaty/data/local/profile_bootstrap_cache.dart';
import 'package:beaty/data/repositories/auth_repository.dart';
import 'package:beaty/data/repositories/profile_repository.dart';
import 'package:beaty/domain/entities/profile.dart';
import 'package:beaty/presentation/screens/auth/auth_gate.dart';
import 'package:beaty/presentation/state/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:supabase_flutter/supabase_flutter.dart' as sb show AuthState;

class _FakeAuthRepo implements AuthRepository {
  Session? session;
  final _events = StreamController<sb.AuthState>.broadcast();
  int updatePasswordCalls = 0;

  _FakeAuthRepo({this.session});

  /// Emits an auth event. [withSession] models what Supabase attaches: the
  /// recovery event carries the short-lived recovery session.
  void emit(AuthChangeEvent e, {Session? withSession, bool attach = true}) =>
      _events.add(sb.AuthState(e, attach ? (withSession ?? session) : null));

  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Stream<sb.AuthState> get onAuthStateChange => _events.stream;
  @override
  bool get isEmailVerified => true;
  @override
  Future<void> signOut() async => session = null;
  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async =>
      AuthResponse(session: session);
  @override
  Future<AuthResponse> signIn(
      {required String email, required String password}) async =>
      AuthResponse(session: session);
  @override
  Future<ResendResponse> resendConfirmation(String email) async =>
      ResendResponse();
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<UserResponse> updatePassword(String p) async {
    updatePasswordCalls++;
    return UserResponse.fromJson({});
  }

  @override
  Future<void> refreshSession() async {}

  Future<void> close() => _events.close();
}

class _FakeProfileRepo implements ProfileRepository {
  _FakeProfileRepo(this.profile);
  final Profile profile;
  Duration delay = Duration.zero;
  int fetchCalls = 0;

  @override
  Future<RemoteResult<Profile?>> fetchOwnResult(
    String userId, {
    RetryPolicy policy = RetryPolicy.startupProfile,
  }) async {
    fetchCalls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return RemoteSuccess<Profile?>(profile);
  }

  @override
  Future<Profile?> fetchOwn(String userId) async => profile;
  @override
  Future<bool> isUsernameAvailable(String u) async => true;
  @override
  Future<Profile> updateOwn(String userId, Map<String, dynamic> f) async =>
      profile;
}

Profile _profile(String id) => Profile(
      id: id,
      username: 'iamleizu',
      displayName: 'Uziel',
      firstName: 'Uziel',
      birthDate: DateTime(1998, 4, 12),
      countryCode: 'MX',
      onboardingCompleted: true,
    );

Session _session(String uid) => Session(
      accessToken: 'token',
      tokenType: 'bearer',
      user: User(
        id: uid,
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: DateTime(2026).toIso8601String(),
        email: 'iamleizu@gmail.com',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Box box;
  late ProfileBootstrapCache cache;
  late PendingRegistrationStore pending;
  late _FakeAuthRepo auth;
  late _FakeProfileRepo profiles;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_recovery_test');
    Hive.init(dir.path);
    SharedPreferences.setMockInitialValues({});
    pending = PendingRegistrationStore(prefs: SharedPreferences.getInstance());
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    StartupDiagnostics.reset();
    box = await Hive.openBox(ProfileBootstrapCache.boxName);
    await box.clear();
    cache = ProfileBootstrapCache(box);
    auth = _FakeAuthRepo(session: _session('user-A'));
    profiles = _FakeProfileRepo(_profile('user-A'));
  });

  tearDown(() async => auth.close());

  AuthController controller({bool autoStart = true}) => AuthController(
        authRepository: auth,
        profileRepository: profiles,
        pendingStore: pending,
        bootstrapCache: cache,
        autoStart: autoStart,
      );

  /// Lets queued microtasks and the auth stream drain.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  group('the recovery deep link routes to the new-password screen', () {
    test('a recovery event with a session enters the recovery phase', () async {
      final c = controller();
      await settle();

      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();

      expect(c.phase, StartupPhase.recovery);
      expect(c.isRecoveryActive, isTrue);
      c.dispose();
    });

    test('the recovery phase maps to the set-a-new-password destination', () {
      expect(destinationFor(StartupPhase.recovery),
          StartupDestination.resetPassword);
    });

    test('COLD START: an in-flight bootstrap cannot overwrite recovery',
        () async {
      // The exact production timing: the profile fetch is still running when
      // the deep link is processed.
      profiles.delay = const Duration(milliseconds: 60);
      final c = controller(); // constructor starts bootstrap
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();
      expect(c.phase, StartupPhase.recovery, reason: 'immediately after');

      // Let the bootstrap resolution finish — it used to land here and
      // dispatch SessionRestored, dropping the user out of recovery.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(c.phase, StartupPhase.recovery,
          reason: 'the completed bootstrap must not preempt recovery');
      c.dispose();
    });

    test('FOREGROUND: recovery wins while the app is already resolved',
        () async {
      final c = controller();
      await settle();
      expect(c.phase, isNot(StartupPhase.recovery));

      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();
      expect(c.phase, StartupPhase.recovery);
      c.dispose();
    });

    test('a DUPLICATE recovery callback is idempotent', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();

      expect(c.phase, StartupPhase.recovery);
      expect(c.isRecoveryActive, isTrue);
      c.dispose();
    });

    test('a later token refresh does not knock the user out of recovery',
        () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();

      auth.emit(AuthChangeEvent.tokenRefreshed);
      await settle();
      expect(c.phase, StartupPhase.recovery);
      c.dispose();
    });
  });

  group('a recovery context is required — never a bare flag', () {
    test('an EXPIRED/INVALID link (no session) does not route to recovery',
        () async {
      auth.session = null;
      final c = controller();
      await settle();

      auth.emit(AuthChangeEvent.passwordRecovery, attach: false);
      await settle();

      expect(c.phase, isNot(StartupPhase.recovery),
          reason: 'nothing would authorise a password update');
      expect(c.isRecoveryActive, isFalse);
      c.dispose();
    });

    test('recovery lapses if the session disappears afterwards', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();
      expect(c.isRecoveryActive, isTrue);

      auth.session = null; // token expired / signed out elsewhere
      expect(c.isRecoveryActive, isFalse,
          reason: 'a stale flag must never survive its session');
      c.dispose();
    });

    test('a recovery context for another account does not apply', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery,
          withSession: _session('user-B'));
      await settle();

      auth.session = _session('user-A'); // a different account is signed in
      expect(c.isRecoveryActive, isFalse);
      c.dispose();
    });
  });

  group('recovery is consumed exactly once', () {
    test('a successful password update clears it', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();
      expect(c.phase, StartupPhase.recovery);

      await c.updatePassword('a-new-strong-password');
      await settle();

      expect(auth.updatePasswordCalls, 1);
      expect(c.isRecoveryActive, isFalse);
      expect(c.phase, isNot(StartupPhase.recovery),
          reason: 'the user must leave the screen after succeeding');
      c.dispose();
    });

    test('THE HIJACK: a normal sign-in after an ABANDONED recovery', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();
      expect(c.phase, StartupPhase.recovery);

      // The user gives up, goes back and signs in with their OLD password.
      await c.login(email: 'iamleizu@gmail.com', password: 'old-password');
      await settle();

      expect(c.isRecoveryActive, isFalse,
          reason: 'an explicit sign-in is not a recovery flow');
      expect(c.phase, isNot(StartupPhase.recovery),
          reason: 'this is the bug: signing in landed on Set a new password');
      c.dispose();
    });

    test('signing out clears the recovery context', () async {
      final c = controller();
      await settle();
      auth.emit(AuthChangeEvent.passwordRecovery);
      await settle();

      await c.logout();
      await settle();

      expect(c.isRecoveryActive, isFalse);
      expect(c.phase, isNot(StartupPhase.recovery));
      c.dispose();
    });

    test('a failed password update KEEPS the context so the user can retry',
        () async {
      final failing = _FailingAuthRepo(session: _session('user-A'));
      final c = AuthController(
        authRepository: failing,
        profileRepository: profiles,
        pendingStore: pending,
        bootstrapCache: cache,
      );
      await settle();
      failing.emit(AuthChangeEvent.passwordRecovery);
      await settle();

      await expectLater(c.updatePassword('weak'), throwsA(anything));
      expect(c.isRecoveryActive, isTrue,
          reason: 'a rejected password must not eject the user mid-flow');
      c.dispose();
      await failing.close();
    });
  });
}

class _FailingAuthRepo extends _FakeAuthRepo {
  _FailingAuthRepo({super.session});
  @override
  Future<UserResponse> updatePassword(String p) async =>
      throw AuthException('Password should be at least 6 characters');
}
