// lib/data/remote/follower_count_service.dart
//
// Phase 3.3.5 — Real-Time Global Artist Follower Counts.
//
// Renders the AUTHORITATIVE global follower count for an artist, kept in sync
// across users via Supabase Realtime. This replaces the old
// `reconcileFollowerCount(cachedBase + sessionDelta)` scheme, which combined a
// stale 24h API-cached baseline with the current user's local toggle and so
// showed the wrong number after another user followed/unfollowed.
//
// Two strictly separate values (see [FollowerCountService] vs LibraryController):
//   * `platformFollowersCount` — the GLOBAL total (this service). Sourced only
//     from the authoritative `artists.platform_followers_count` row (a direct
//     read or a realtime UPDATE event) — NEVER inferred from local follow state.
//   * `isFollowing` — whether the CURRENT user follows (LibraryController). The
//     checkmark belongs to the user; the number belongs to the community.
//
// Source priority (stale-overwrite guard): an authoritative value (direct DB
// read or realtime event) always wins and, once seen for an artist, can never
// be overwritten by a lower-priority cached API payload (`seedFromApi`). This
// is the "treat realtime/server as newer than a cached API payload" rule.
//
// The service is backend-agnostic ([FollowerCountBackend]) so it is fully
// unit-testable headless; the production backend uses Supabase Realtime.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A live subscription to one artist's authoritative count. `close()` tears the
/// underlying channel down.
abstract class FollowerSubscription {
  Future<void> close();
}

/// Transport for authoritative follower counts. Implemented by
/// [SupabaseFollowerCountBackend] in production; faked in tests.
abstract class FollowerCountBackend {
  /// One-shot authoritative read of `artists.platform_followers_count`.
  /// Returns null on error / missing row (caller keeps the last known value).
  Future<int?> fetchCount(String artistUuid);

  /// Subscribe to authoritative count changes for [artistUuid]. [onCount] is
  /// called with each new authoritative value. Returns a handle to close it.
  FollowerSubscription subscribe(
    String artistUuid,
    void Function(int count) onCount,
  );
}

class FollowerCountService {
  final FollowerCountBackend _backend;

  FollowerCountService(this._backend);

  // uuid -> best-known count (may be a seed, optimistic, or authoritative value)
  final Map<String, int> _counts = {};
  // uuids for which we've seen an authoritative value (DB read / realtime)
  final Set<String> _authoritative = {};
  // uuid -> listenable the UI binds to
  final Map<String, ValueNotifier<int?>> _notifiers = {};
  // uuid -> live subscription (one shared channel per artist, ref-counted)
  final Map<String, FollowerSubscription> _subs = {};
  final Map<String, int> _refCounts = {};

  String? _sessionUid;
  bool _sessionSet = false;

  /// The listenable the follower pill binds to. `null` until a value is known.
  ValueListenable<int?> listenable(String uuid) =>
      _notifiers.putIfAbsent(uuid, () => ValueNotifier<int?>(_counts[uuid]));

  /// Best-known count for [uuid], or null if unknown.
  int? countOf(String uuid) => _counts[uuid];

  void _emit(String uuid, int value) {
    _counts[uuid] = value;
    final n = _notifiers.putIfAbsent(uuid, () => ValueNotifier<int?>(value));
    n.value = value;
  }

  /// Low-priority seed from a possibly-stale cached API payload. Never
  /// overwrites an authoritative value already seen for this artist (stale
  /// `/v2/artists/deezer/{id}` can't clobber a newer realtime/server count).
  void seedFromApi(String uuid, int? count) {
    if (count == null) return;
    if (_authoritative.contains(uuid)) return;
    if (_counts[uuid] == count) return;
    _emit(uuid, count);
  }

  /// Authoritative value from a direct DB read or a realtime event. Always wins.
  void _applyAuthoritative(String uuid, int count) {
    _authoritative.add(uuid);
    if (_counts[uuid] == count) return;
    _emit(uuid, count);
  }

  /// Optimistic adjustment after the CURRENT user's own follow/unfollow. Shown
  /// immediately; reconciled by the subsequent realtime event our own write
  /// triggers (artists UPDATE), or by [refresh] on the next screen entry/resume.
  /// Deliberately NOT marked authoritative, so realtime can correct it.
  void applyOptimistic(String uuid, int delta) {
    final next = (_counts[uuid] ?? 0) + delta;
    _emit(uuid, next < 0 ? 0 : next);
  }

  /// Authoritative one-shot reconciliation. Safe to call any time; fills gaps
  /// left by a dropped realtime connection (reconnect / app resume / entry).
  Future<int?> refresh(String uuid) async {
    final c = await _backend.fetchCount(uuid);
    if (c != null) _applyAuthoritative(uuid, c);
    return c;
  }

  /// Begin watching [uuid] while a screen showing it is mounted. Ref-counted so
  /// multiple live screens for the same artist (e.g. via Related Artists) share
  /// ONE realtime channel — preventing duplicate subscriptions. Always triggers
  /// an authoritative [refresh] on entry to reconcile any stale seed/optimistic.
  Future<void> subscribe(String uuid) async {
    _refCounts[uuid] = (_refCounts[uuid] ?? 0) + 1;
    if (!_subs.containsKey(uuid)) {
      _subs[uuid] =
          _backend.subscribe(uuid, (count) => _applyAuthoritative(uuid, count));
    }
    await refresh(uuid);
  }

  /// Release one watcher. When the last watcher for [uuid] leaves, its realtime
  /// channel is closed.
  Future<void> unsubscribe(String uuid) async {
    final remaining = (_refCounts[uuid] ?? 1) - 1;
    if (remaining > 0) {
      _refCounts[uuid] = remaining;
      return;
    }
    _refCounts.remove(uuid);
    final sub = _subs.remove(uuid);
    await sub?.close();
  }

  /// Wire to the auth session. The global count is user-independent, but on a
  /// real account switch we drop every channel and all cached/optimistic state
  /// so the new session re-reads authoritative values cleanly (multi-account
  /// isolation). Idempotent per uid.
  Future<void> onUserSession(String? uid) async {
    if (_sessionSet && uid == _sessionUid) return;
    _sessionSet = true;
    _sessionUid = uid;
    await _closeAll();
  }

  Future<void> _closeAll() async {
    final subs = List<FollowerSubscription>.of(_subs.values);
    _subs.clear();
    _refCounts.clear();
    _authoritative.clear();
    _counts.clear();
    for (final n in _notifiers.values) {
      n.value = null;
    }
    for (final s in subs) {
      await s.close();
    }
  }

  /// Tear everything down (provider disposal).
  Future<void> dispose() async {
    await _closeAll();
    for (final n in _notifiers.values) {
      n.dispose();
    }
    _notifiers.clear();
  }
}

/// Production backend: authoritative reads + Realtime UPDATE subscription on the
/// public `artists` row. Exposes only the aggregate count — no user identity.
class SupabaseFollowerCountBackend implements FollowerCountBackend {
  final SupabaseClient _client;

  SupabaseFollowerCountBackend([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  @override
  Future<int?> fetchCount(String artistUuid) async {
    try {
      final row = await _client
          .from('artists')
          .select('platform_followers_count')
          .eq('id', artistUuid)
          .maybeSingle();
      return _asInt(row?['platform_followers_count']);
    } catch (_) {
      return null;
    }
  }

  @override
  FollowerSubscription subscribe(
    String artistUuid,
    void Function(int count) onCount,
  ) {
    final channel = _client
        .channel('followers:$artistUuid')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'artists',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: artistUuid,
          ),
          callback: (payload) {
            final c = _asInt(payload.newRecord['platform_followers_count']);
            if (c != null) onCount(c);
          },
        )
        .subscribe();
    return _SupabaseFollowerSubscription(_client, channel);
  }
}

class _SupabaseFollowerSubscription implements FollowerSubscription {
  final SupabaseClient _client;
  final RealtimeChannel _channel;

  _SupabaseFollowerSubscription(this._client, this._channel);

  @override
  Future<void> close() async {
    try {
      await _client.removeChannel(_channel);
    } catch (_) {
      // Best-effort teardown.
    }
  }
}
