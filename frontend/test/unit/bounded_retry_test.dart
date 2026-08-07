// test/unit/bounded_retry_test.dart
//
// Phase 3.4.2 — error classification + bounded retry.
//
// These tests exist because this phase ADDS retries to a system that was, days
// earlier, the victim of a 2,344 req/s storm. The point is not that retry works;
// it is that retry is incapable of running away.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:beaty/core/network/bounded_retry.dart';
import 'package:beaty/core/network/remote_result.dart';
import 'package:beaty/core/startup/startup_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Deterministic "random" so backoff sequences are assertable.
class _ZeroRandom implements Random {
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
  @override
  int nextInt(int max) => 0; // zero jitter ⇒ instant retries in tests
}

void main() {
  setUp(StartupDiagnostics.reset);

  group('error classification', () {
    test('socket / DNS failures are offline, never "missing"', () {
      expect(classifyRemoteError(const SocketException('Failed host lookup')),
          RemoteFailureKind.offline);
      expect(classifyRemoteError(Exception('Failed host lookup: api.supabase.co')),
          RemoteFailureKind.offline);
      expect(classifyRemoteError(Exception('Network is unreachable')),
          RemoteFailureKind.offline);
    });

    test('timeouts are timeouts', () {
      expect(classifyRemoteError(TimeoutException('x')), RemoteFailureKind.timeout);
      expect(classifyRemoteError(Exception('Connection timed out')),
          RemoteFailureKind.timeout);
    });

    test('the exact production failures: 503 and 504 → serverUnavailable', () {
      expect(
        classifyRemoteError(const PostgrestException(message: 'unavailable', code: '503')),
        RemoteFailureKind.serverUnavailable,
      );
      expect(
        classifyRemoteError(const PostgrestException(message: 'gateway timeout', code: '504')),
        RemoteFailureKind.serverUnavailable,
      );
      expect(classifyRemoteError(Exception('503 Service Unavailable')),
          RemoteFailureKind.serverUnavailable);
    });

    test('SQLSTATE 57xxx/08xxx (shutdown, connection) → serverUnavailable', () {
      expect(
        classifyRemoteError(const PostgrestException(message: 'admin shutdown', code: '57P01')),
        RemoteFailureKind.serverUnavailable,
      );
      expect(
        classifyRemoteError(const PostgrestException(message: 'conn failure', code: '08006')),
        RemoteFailureKind.serverUnavailable,
      );
    });

    test('auth failures are unauthorized', () {
      expect(classifyRemoteError(const AuthException('jwt expired')),
          RemoteFailureKind.unauthorized);
      expect(
        classifyRemoteError(const PostgrestException(message: 'denied', code: '42501')),
        RemoteFailureKind.unauthorized,
      );
    });

    test('PGRST200 (the Phase 3.4.1.2C embed bug) is unknown, NOT missing', () {
      // A malformed request is a real bug, but it still says nothing about
      // whether the user has a profile row.
      final k = classifyRemoteError(
          const PostgrestException(message: 'could not find relationship', code: 'PGRST200'));
      expect(k, RemoteFailureKind.unknown);
      expect(k.isTransient, isFalse, reason: 'retrying a malformed request is waste');
    });

    test('transience is correctly assigned', () {
      expect(RemoteFailureKind.offline.isTransient, isTrue);
      expect(RemoteFailureKind.timeout.isTransient, isTrue);
      expect(RemoteFailureKind.serverUnavailable.isTransient, isTrue);
      expect(RemoteFailureKind.transport.isTransient, isTrue);
      expect(RemoteFailureKind.unauthorized.isTransient, isFalse);
      expect(RemoteFailureKind.unknown.isTransient, isFalse);
    });
  });

  group('bounded retry cannot become a storm', () {
    test('succeeds without retrying', () async {
      var calls = 0;
      final r = await runBounded<int>(() async {
        calls++;
        return 42;
      }, random: _ZeroRandom());
      expect(r, isA<RemoteSuccess<int>>());
      expect((r as RemoteSuccess<int>).value, 42);
      expect(calls, 1);
    });

    test('retries a transient failure, then succeeds', () async {
      var calls = 0;
      final r = await runBounded<int>(
        () async {
          calls++;
          if (calls < 3) throw const SocketException('offline');
          return 7;
        },
        policy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration.zero),
        random: _ZeroRandom(),
      );
      expect(r, isA<RemoteSuccess<int>>());
      expect(calls, 3);
    });

    test('HARD CAP: never exceeds maxAttempts', () async {
      var calls = 0;
      final r = await runBounded<int>(
        () async {
          calls++;
          throw const SocketException('always down');
        },
        policy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration.zero),
        random: _ZeroRandom(),
      );
      expect(calls, 3, reason: 'this is the anti-storm guarantee');
      expect(r, isA<RemoteUnavailable<int>>());
      expect((r as RemoteUnavailable<int>).kind, RemoteFailureKind.offline);
    });

    test('non-transient failures fail FAST — exactly one attempt', () async {
      for (final e in [
        const AuthException('jwt expired'),
        const PostgrestException(message: 'bad', code: 'PGRST200'),
      ]) {
        var calls = 0;
        await runBounded<int>(
          () async {
            calls++;
            throw e;
          },
          policy: const RetryPolicy(maxAttempts: 5, baseDelay: Duration.zero),
          random: _ZeroRandom(),
        );
        expect(calls, 1, reason: 'retrying $e adds load and cannot help');
      }
    });

    test('a hung operation is cut off by attemptTimeout — splash cannot hang',
        () async {
      final r = await runBounded<int>(
        () => Completer<int>().future, // never completes
        policy: const RetryPolicy(
          maxAttempts: 1,
          attemptTimeout: Duration(milliseconds: 60),
          totalBudget: Duration(milliseconds: 500),
        ),
        random: _ZeroRandom(),
      );
      expect(r, isA<RemoteUnavailable<int>>());
      expect((r as RemoteUnavailable<int>).kind, RemoteFailureKind.timeout);
    });

    test('total budget bounds the whole sequence', () async {
      final sw = Stopwatch()..start();
      await runBounded<int>(
        () => Completer<int>().future,
        policy: const RetryPolicy(
          maxAttempts: 5,
          attemptTimeout: Duration(milliseconds: 50),
          totalBudget: Duration(milliseconds: 120),
          baseDelay: Duration(milliseconds: 10),
        ),
        random: _ZeroRandom(),
      );
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('runBounded never throws, for any error', () async {
      for (final e in <Object>[
        const SocketException('x'),
        TimeoutException('x'),
        const AuthException('x'),
        StateError('x'),
        'a bare string',
      ]) {
        final r = await runBounded<int>(
          () async => throw e,
          policy: const RetryPolicy(maxAttempts: 1),
          random: _ZeroRandom(),
        );
        expect(r, isA<RemoteUnavailable<int>>());
      }
    });

    test('startup policy is tightly bounded by construction', () {
      const p = RetryPolicy.startupProfile;
      expect(p.maxAttempts, lessThanOrEqualTo(3));
      expect(p.totalBudget, lessThanOrEqualTo(const Duration(seconds: 15)));
    });

    test('retry jobs are released — no leak after completion', () async {
      await runBounded<int>(() async => 1, random: _ZeroRandom());
      expect(StartupDiagnostics.live(StartupResource.retryJob), 0);
    });
  });

  group('RemoteResult typing', () {
    test('authoritative null is distinguishable from unavailable', () {
      const ok = RemoteSuccess<String?>(null);
      const bad = RemoteUnavailable<String?>(RemoteFailureKind.offline);
      expect(ok.isAuthoritative, isTrue);
      expect(bad.isAuthoritative, isFalse);
      // Both have a null value — only the TYPE separates them, which is exactly
      // why the old `Profile?` return type could not.
      expect(ok.valueOrNull, isNull);
      expect(bad.valueOrNull, isNull);
    });
  });
}
