// lib/core/network/remote_result.dart
//
// Typed outcome for a remote read (Phase 3.4.2).
//
// WHY THIS TYPE EXISTS
// --------------------
// The production defect this phase fixes was a category error, not a coding
// mistake. `ProfileRepository.fetchOwn` returned `Profile?`, so two completely
// different facts collapsed into the same value:
//
//   • "the server answered, and this user genuinely has no profile row"   → null
//   • "the server returned 503 / timed out / DNS failed / we are offline" → threw
//
// The caller's `catch (_)` then treated the second as the first and routed a
// fully-configured user into Complete Profile.
//
// `RemoteResult<T>` makes that collapse unrepresentable. `RemoteSuccess<Profile?>`
// with a null value is an AUTHORITATIVE absence — the server was reached, RLS
// was applied, and there is no row. `RemoteUnavailable` carries no value at all,
// so no amount of pattern matching can turn a network failure into a claim about
// the user's profile. The invariant is enforced by the type system rather than
// by reviewer discipline.
//
// The class is `sealed`, so a `switch` over it must be exhaustive: adding a new
// failure mode later becomes a compile error at every decision point instead of
// a silent fallthrough.

import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Why a remote read could not produce an authoritative answer.
enum RemoteFailureKind {
  /// No usable network interface, or DNS/socket failure.
  offline,

  /// The request exceeded its deadline.
  timeout,

  /// Reached the server, but it declined to serve (5xx, 503, 504, maintenance).
  serverUnavailable,

  /// Transport-level failure (TLS, connection reset, malformed response).
  transport,

  /// The session is invalid/expired/revoked. The ONLY failure kind that may
  /// affect authentication state.
  unauthorized,

  /// Anything unclassified. Treated as "unknown", never as "absent".
  unknown,
}

extension RemoteFailureKindX on RemoteFailureKind {
  /// True when retrying the identical request could plausibly succeed.
  ///
  /// `unauthorized` is excluded deliberately: retrying a revoked token just
  /// burns requests, which is precisely the retry-storm shape this phase
  /// exists to prevent.
  bool get isTransient =>
      this == RemoteFailureKind.offline ||
      this == RemoteFailureKind.timeout ||
      this == RemoteFailureKind.serverUnavailable ||
      this == RemoteFailureKind.transport;
}

/// The outcome of a remote read: either an authoritative answer, or a reason
/// no answer could be obtained. Never both, never neither.
sealed class RemoteResult<T> {
  const RemoteResult();

  /// True only when the server answered authoritatively.
  bool get isAuthoritative => this is RemoteSuccess<T>;

  /// The value if authoritative, otherwise null.
  ///
  /// Callers deciding anything about profile completeness must NOT use this —
  /// it cannot distinguish "authoritative null" from "no answer". Switch on the
  /// result instead. It exists for display-only paths.
  T? get valueOrNull => switch (this) {
        RemoteSuccess<T>(value: final v) => v,
        RemoteUnavailable<T>() => null,
      };
}

/// The server was reached and returned [value]. A null [value] is a positive
/// statement that the resource does not exist.
final class RemoteSuccess<T> extends RemoteResult<T> {
  final T value;
  const RemoteSuccess(this.value);

  @override
  String toString() => 'RemoteSuccess($value)';
}

/// No authoritative answer. Carries no value by construction.
final class RemoteUnavailable<T> extends RemoteResult<T> {
  final RemoteFailureKind kind;
  final Object? error;

  const RemoteUnavailable(this.kind, [this.error]);

  bool get isTransient => kind.isTransient;

  @override
  String toString() => 'RemoteUnavailable(${kind.name}, $error)';
}

/// Classifies a thrown error into a [RemoteFailureKind].
///
/// Deliberately conservative: anything not positively recognised becomes
/// [RemoteFailureKind.unknown], which is still a failure and therefore still
/// never means "the profile is missing".
RemoteFailureKind classifyRemoteError(Object e) {
  if (e is TimeoutException) return RemoteFailureKind.timeout;
  if (e is SocketException) return RemoteFailureKind.offline;
  if (e is HttpException) return RemoteFailureKind.transport;
  if (e is HandshakeException) return RemoteFailureKind.transport;

  if (e is AuthException) return RemoteFailureKind.unauthorized;

  if (e is PostgrestException) {
    final raw = e.code ?? '';

    // `code` carries EITHER an HTTP status (3 digits, for gateway-level errors)
    // OR a 5-character SQLSTATE. Both parse as ints, so length must disambiguate
    // them first — otherwise SQLSTATE 42501 (insufficient_privilege) reads as
    // "HTTP 42501 >= 500" and a permission denial is misreported as an outage.
    if (raw.length == 3) {
      final status = int.tryParse(raw);
      if (status != null) {
        if (status == 401 || status == 403) return RemoteFailureKind.unauthorized;
        if (status >= 500) return RemoteFailureKind.serverUnavailable;
        // 4xx other than auth is a malformed request on our side — a real bug,
        // but still not evidence about whether a profile row exists.
        return RemoteFailureKind.unknown;
      }
    }

    // SQLSTATE: 57xxx = operator intervention / shutdown; 08xxx = connection
    // exception; 53xxx = insufficient resources (out of memory/connections).
    if (raw.length == 5) {
      if (raw.startsWith('57') || raw.startsWith('08') || raw.startsWith('53')) {
        return RemoteFailureKind.serverUnavailable;
      }
      if (raw == '42501') return RemoteFailureKind.unauthorized;
    }
    return RemoteFailureKind.unknown;
  }

  // supabase_flutter wraps some transport errors in ClientException, whose type
  // lives in package:http. Match on the message rather than adding a dependency.
  final s = e.toString().toLowerCase();
  if (s.contains('failed host lookup') ||
      s.contains('no address associated') ||
      s.contains('network is unreachable') ||
      s.contains('connection refused') ||
      s.contains('connection closed') ||
      s.contains('connection reset')) {
    return RemoteFailureKind.offline;
  }
  if (s.contains('timed out') || s.contains('timeout')) {
    return RemoteFailureKind.timeout;
  }
  if (s.contains('503') ||
      s.contains('504') ||
      s.contains('502') ||
      s.contains('service unavailable') ||
      s.contains('gateway')) {
    return RemoteFailureKind.serverUnavailable;
  }
  return RemoteFailureKind.unknown;
}
