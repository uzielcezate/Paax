// test/unit/startup_controller_test.dart
//
// Phase 3.4.2 — AuthController startup integration.
//
// Exercises the controller against a real Hive-backed bootstrap cache and a
// fake profile repository, covering the scenarios that produced the production
// defect: remote success, authoritative 404, timeout, PostgREST 503/504,
// offline, expired token, stale responses, account switch, and restart.
//
// The single most important assertions here are the COUNTS: exactly one
// bootstrap and exactly one profile fetch per session. Those are what the
// production logs showed happening twice.

import 'dart:async';
import 'dart:io';

import 'package:beaty/core/network/bounded_retry.dart';
import 'package:beaty/core/network/remote_result.dart';
import 'package:beaty/core/startup/startup_diagnostics.dart';
import 'package:beaty/core/startup/startup_state.dart';
import 'package:beaty/data/local/profile_bootstrap_cache.dart';
import 'package:beaty/data/repositories/auth_repository.dart';
import 'package:beaty/data/repositories/profile_repository.dart';
import 'package:beaty/domain/entities/profile.dart';
import 'package:beaty/presentation/state/auth_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:beaty/data/local/pending_registration.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide AuthState;
import 'package:supabase_flutter/supabase_flutter.dart' as sb show AuthState;

// ── fakes ───────────────────────────────────────────────────────────────────

class _FakeAuthRepo implements AuthRepository {
  Session? session;
  bool verified;
  final _events = StreamController<sb.AuthState>.broadcast();
  int signOutCalls = 0;

  _FakeAuthRepo({this.session, this.verified = true});

  void emit(AuthChangeEvent e) => _events.add(sb.AuthState(e, session));

  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Stream<sb.AuthState> get onAuthStateChange => _events.stream;
  @override
  bool get isEmailVerified => verified;
  @override
  Future<void> signOut() async {
    signOutCalls++;
    session = null;
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async =>
      AuthResponse(session: session);
  @override
  Future<AuthResponse> signIn({required String email, required String password}) async =>
      AuthResponse(session: session);
  @override
  Future<ResendResponse> resendConfirmation(String email) async => ResendResponse();
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<UserResponse> updatePassword(String p) async => UserResponse.fromJson({});
  @override
  Future<void> refreshSession() async {}

  Future<void> close() => _events.close();
}

class _FakeProfileRepo implements ProfileRepository {
  /// Queue of outcomes; the last one repeats once exhausted.
  final List<RemoteResult<Profile?>> outcomes;
  int fetchCalls = 0;
  Duration delay = Duration.zero;
  final List<String> fetchedIds = [];

  _FakeProfileRepo(this.outcomes);

  @override
  Future<RemoteResult<Profile?>> fetchOwnResult(
    String userId, {
    RetryPolicy policy = RetryPolicy.startupProfile,
  }) async {
    fetchCalls++;
    fetchedIds.add(userId);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final i = (fetchCalls - 1).clamp(0, outcomes.length - 1);
    return outcomes[i];
  }

  @override
  Future<Profile?> fetchOwn(String userId) async =>
      (await fetchOwnResult(userId)).valueOrNull;
  @override
  Future<bool> isUsernameAvailable(String u) async => true;
  @override
  Future<Profile> updateOwn(String userId, Map<String, dynamic> fields) async =>
      _complete(id: userId);
}

/// Fails in an unexpected way (not via RemoteResult), to prove the controller
/// contains escaping exceptions instead of crashing the zone.
class _ThrowingProfileRepo extends _FakeProfileRepo {
  _ThrowingProfileRepo() : super(const []);

  @override
  Future<RemoteResult<Profile?>> fetchOwnResult(
    String userId, {
    RetryPolicy policy = RetryPolicy.startupProfile,
  }) async =>
      throw StateError('unexpected internal failure');
}

// ── helpers ─────────────────────────────────────────────────────────────────

Profile _complete({String id = 'user-A', bool onboarded = true}) => Profile(
      id: id,
      username: 'iamleizu',
      displayName: 'Uziel',
      firstName: 'Uziel',
      birthDate: DateTime(1998, 4, 12),
      countryCode: 'MX',
      onboardingCompleted: onboarded,
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
  // SharedPreferences (used by PendingRegistrationStore) needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late Box box;
  late ProfileBootstrapCache cache;
  late PendingRegistrationStore pending;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('paax_startup_test');
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
  });

  tearDown(() async => box.close());

  Future<AuthController> build(
    _FakeAuthRepo auth,
    _FakeProfileRepo profiles, {
    bool autoStart = true,
  }) async {
    final c = AuthController(
      authRepository: auth,
      profileRepository: profiles,
      bootstrapCache: cache,
      pendingStore: pending,
      autoStart: autoStart,
    );
    await pumpEventQueue();
    return c;
  }

  // ── the headline regression ────────────────────────────────────────────────

  group('remote failure NEVER routes to Complete Profile', () {
    for (final entry in {
      'HTTP 503 (the production failure)':
          const PostgrestException(message: 'unavailable', code: '503'),
      'HTTP 504 gateway timeout':
          const PostgrestException(message: 'gateway timeout', code: '504'),
      'offline / DNS': const SocketException('Failed host lookup'),
      'timeout': null, // handled via delay below
    }.entries) {
      test('${entry.key} with a cached complete profile → offlineReady', () async {
        await cache.write(_complete());
        final auth = _FakeAuthRepo(session: _session('user-A'));
        final profiles = _FakeProfileRepo([
          RemoteUnavailable<Profile?>(
            entry.value == null
                ? RemoteFailureKind.timeout
                : classifyRemoteError(entry.value!),
          )
        ]);
        final c = await build(auth, profiles);

        expect(c.phase, StartupPhase.offlineReady);
        expect(c.phase, isNot(StartupPhase.completeProfileRequired));
        expect(c.isOffline, isTrue);
        expect(c.profile?.username, 'iamleizu',
            reason: 'cached profile must still render');
        c.dispose();
        await auth.close();
      });
    }

    test('failure with NO cache → setupBlockedOffline, not Complete Profile',
        () async {
      final auth = _FakeAuthRepo(session: _session('user-new'));
      final profiles = _FakeProfileRepo([
        const RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable)
      ]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.setupBlockedOffline);
      expect(c.phase, isNot(StartupPhase.completeProfileRequired));
      c.dispose();
      await auth.close();
    });

    test('a hung server does not hang the splash forever', () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([const RemoteSuccess<Profile?>(null)])
        ..delay = const Duration(milliseconds: 300);
      final c = await build(auth, profiles);

      // The shell is ALREADY visible from cache while remote is still in flight.
      expect(c.phase.isShellVisible, isTrue);
      c.dispose();
      await auth.close();
    });
  });

  // ── authoritative answers ──────────────────────────────────────────────────

  group('authoritative results route correctly', () {
    test('remote success (complete) → onlineReady and caches the profile',
        () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.onlineReady);
      expect(c.isOffline, isFalse);
      expect(cache.read('user-A')?.profileCompleted, isTrue,
          reason: 'confirmed server state must be cached for next launch');
      c.dispose();
      await auth.close();
    });

    test('authoritative missing row (404-equivalent) → completeProfileRequired',
        () async {
      final auth = _FakeAuthRepo(session: _session('user-new'));
      final profiles = _FakeProfileRepo([const RemoteSuccess<Profile?>(null)]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.completeProfileRequired);
      c.dispose();
      await auth.close();
    });

    test('expired/revoked token → unauthenticated, never onboarding', () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo(
          [const RemoteUnavailable<Profile?>(RemoteFailureKind.unauthorized)]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.unauthenticated);
      c.dispose();
      await auth.close();
    });

    test('unverified email → unverified, no profile fetch at all', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'), verified: false);
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.unverified);
      expect(profiles.fetchCalls, 0, reason: 'no point querying before verification');
      c.dispose();
      await auth.close();
    });

    test('no session → unauthenticated, no profile fetch', () async {
      final auth = _FakeAuthRepo(session: null);
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      expect(c.phase, StartupPhase.unauthenticated);
      expect(profiles.fetchCalls, 0);
      c.dispose();
      await auth.close();
    });
  });

  // ── the duplicate-work regression ──────────────────────────────────────────

  group('exactly one resolution per session', () {
    test('constructor + initialSession collapse into ONE profile fetch', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      // The SDK emits initialSession after the constructor already bootstrapped.
      auth.emit(AuthChangeEvent.initialSession);
      await pumpEventQueue();

      expect(StartupDiagnostics.bootstrapExecutions, 1);
      expect(profiles.fetchCalls, 1,
          reason: 'production logs showed this happening twice, 3ms apart');
      c.dispose();
      await auth.close();
    });

    test('repeated bootstrap() calls do not re-resolve', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      await c.bootstrap();
      await c.bootstrap();
      await pumpEventQueue();

      expect(profiles.fetchCalls, 1);
      c.dispose();
      await auth.close();
    });

    test('tokenRefreshed does NOT trigger a profile fetch', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);
      final before = profiles.fetchCalls;

      auth.emit(AuthChangeEvent.tokenRefreshed);
      await pumpEventQueue();

      expect(profiles.fetchCalls, before,
          reason: 'a token refresh says nothing new about the profile');
      c.dispose();
      await auth.close();
    });

    test('a token refresh while offline reconciles exactly once', () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([
        const RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable),
        RemoteSuccess<Profile?>(_complete()),
      ]);
      final c = await build(auth, profiles);
      expect(c.phase, StartupPhase.offlineReady);

      auth.emit(AuthChangeEvent.tokenRefreshed);
      await pumpEventQueue();

      expect(c.phase, StartupPhase.onlineReady);
      expect(profiles.fetchCalls, 2);
      c.dispose();
      await auth.close();
    });
  });

  // ── isolation + staleness ──────────────────────────────────────────────────

  group('account isolation and stale responses', () {
    test('account B never sees account A profile', () async {
      await cache.write(_complete(id: 'user-A'));
      final auth = _FakeAuthRepo(session: _session('user-B'));
      final profiles = _FakeProfileRepo(
          [const RemoteUnavailable<Profile?>(RemoteFailureKind.offline)]);
      final c = await build(auth, profiles);

      expect(c.profile?.id, isNot('user-A'));
      expect(c.phase, StartupPhase.setupBlockedOffline,
          reason: 'B has no cache of its own, so it cannot open a shell');
      c.dispose();
      await auth.close();
    });

    test('a stale response from a signed-out session cannot route', () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([const RemoteSuccess<Profile?>(null)])
        ..delay = const Duration(milliseconds: 200);
      final c = AuthController(
        authRepository: auth,
        profileRepository: profiles,
        bootstrapCache: cache,
        pendingStore: pending,
      );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.logout(); // invalidates the in-flight fetch
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(c.phase, StartupPhase.unauthenticated,
          reason: 'the late "no profile" answer must not resurrect a session');
      expect(c.phase, isNot(StartupPhase.completeProfileRequired));
      c.dispose();
      await auth.close();
    });

    test('explicit logout while offline returns to auth, not cached Home',
        () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo(
          [const RemoteUnavailable<Profile?>(RemoteFailureKind.offline)]);
      final c = await build(auth, profiles);
      expect(c.phase, StartupPhase.offlineReady);

      await c.logout();
      expect(c.phase, StartupPhase.unauthenticated);
      expect(cache.activeUserId, isNull,
          reason: 'the active pointer must be cleared so restart lands on auth');
      expect(cache.read('user-A'), isNotNull,
          reason: 'the record is retained so re-login is still instant');
      c.dispose();
      await auth.close();
    });
  });

  // ── restart ────────────────────────────────────────────────────────────────

  group('restart behaviour', () {
    test('second launch with a warm cache opens the shell immediately', () async {
      // Launch 1: online, populates the cache.
      final auth1 = _FakeAuthRepo(session: _session('user-A'));
      final p1 = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c1 = await build(auth1, p1);
      expect(c1.phase, StartupPhase.onlineReady);
      c1.dispose();
      await auth1.close();

      // Launch 2: server is down.
      StartupDiagnostics.reset();
      final auth2 = _FakeAuthRepo(session: _session('user-A'));
      final p2 = _FakeProfileRepo([
        const RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable)
      ]);
      final c2 = await build(auth2, p2);

      expect(c2.phase, StartupPhase.offlineReady);
      expect(c2.profile?.username, 'iamleizu');
      expect(StartupDiagnostics.bootstrapExecutions, 1);
      c2.dispose();
      await auth2.close();
    });
  });

  // ── lifecycle hygiene ──────────────────────────────────────────────────────

  group('listener lifecycle', () {
    test('the auth listener is registered once and released on dispose', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      expect(StartupDiagnostics.live(StartupResource.authListener), 1);
      c.dispose();
      expect(StartupDiagnostics.live(StartupResource.authListener), 0,
          reason: 'a surviving listener would double every future auth event');
      await auth.close();
    });

    test('events after dispose are ignored', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);
      final before = profiles.fetchCalls;

      c.dispose();
      auth.emit(AuthChangeEvent.signedIn);
      await pumpEventQueue();

      expect(profiles.fetchCalls, before);
      await auth.close();
    });

    test('concurrent background triggers issue ONE profile read', () async {
      await cache.write(_complete());
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([
        const RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable),
        RemoteSuccess<Profile?>(_complete()),
      ])
        ..delay = const Duration(milliseconds: 80);
      final c = await build(auth, profiles);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final before = profiles.fetchCalls;

      // tokenRefreshed + userUpdated arriving together.
      auth.emit(AuthChangeEvent.tokenRefreshed);
      auth.emit(AuthChangeEvent.userUpdated);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(profiles.fetchCalls - before, 1,
          reason: 'concurrent triggers must coalesce into one read');
      c.dispose();
      await auth.close();
    });

    test('rapid retry taps do not launch parallel sequences', () async {
      final auth = _FakeAuthRepo(session: _session('user-new'));
      final profiles = _FakeProfileRepo(
          [const RemoteUnavailable<Profile?>(RemoteFailureKind.serverUnavailable)])
        ..delay = const Duration(milliseconds: 100);
      final c = await build(auth, profiles);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final before = profiles.fetchCalls;

      // Five impatient taps on a dead backend.
      final taps = List.generate(5, (_) => c.retryStartup());
      await Future.wait(taps);

      expect(profiles.fetchCalls - before, 1,
          reason: 'isSubmitting must gate concurrent manual retries');
      c.dispose();
      await auth.close();
    });

    test('an unexpected throw never escapes as an unhandled async error',
        () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _ThrowingProfileRepo();
      // Must not blow up the zone: bootstrap is fire-and-forget in production.
      final c = await build(auth, profiles);
      expect(c.phase, isNot(StartupPhase.completeProfileRequired));
      c.dispose();
      await auth.close();
    });

    test('no retry jobs leak after startup settles', () async {
      final auth = _FakeAuthRepo(session: _session('user-A'));
      final profiles = _FakeProfileRepo([RemoteSuccess<Profile?>(_complete())]);
      final c = await build(auth, profiles);

      expect(StartupDiagnostics.live(StartupResource.retryJob), 0);
      c.dispose();
      await auth.close();
    });
  });
}
