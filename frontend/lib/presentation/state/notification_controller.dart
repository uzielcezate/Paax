// lib/presentation/state/notification_controller.dart
//
// Phase 3.4.1.1 — app-scoped inbox state for the Home bell + Notifications
// screen. Supabase is authoritative; this holds the caller's own rows, keeps the
// unread badge live via the realtime service, and drives loading/empty/error
// states. Account-switch safe: onUserSession rebinds realtime and reloads for
// the new identity, discarding the previous user's rows so nothing leaks.
//
// Responding to an invite is delegated to the playlist RPC (which also marks the
// invite notification acted server-side); realtime then reconciles this list.

import 'package:flutter/foundation.dart';

import '../../data/remote/notification_realtime_service.dart';
import '../../data/remote/notification_remote_data_source.dart';
import '../../domain/entities/app_notification.dart';

enum NotificationLoadState { idle, loading, loaded, error }

/// Accept/decline delegate — the playlist RPC that resolves an invite (and marks
/// the invite notification acted server-side). Injected so the controller stays
/// decoupled from PlaylistRepository and unit-testable.
typedef InviteResponder = Future<void> Function(String playlistId, bool accept);

class NotificationController extends ChangeNotifier {
  final NotificationInbox _remote;
  final NotificationRealtimeService _realtime;
  final InviteResponder _respondInvitation;

  NotificationController({
    NotificationInbox? remote,
    required NotificationRealtimeService realtime,
    required InviteResponder respondInvitation,
  })  : _remote = remote ?? NotificationRemoteDataSource(),
        _realtime = realtime,
        _respondInvitation = respondInvitation {
    _realtime.addListener(_onRealtime);
  }

  List<AppNotification> _items = const [];
  NotificationLoadState _state = NotificationLoadState.idle;
  String? _uid;
  bool _sessionSet = false;
  final Set<String> _acting = {}; // invite ids with an in-flight response

  List<AppNotification> get items => _items;
  NotificationLoadState get state => _state;
  int get unreadCount => _items.where((n) => !n.isRead).length;
  bool get hasError => _state == NotificationLoadState.error;
  bool get isLoading => _state == NotificationLoadState.loading;
  bool isActing(String id) => _acting.contains(id);

  /// Rebind + reload for the active identity. Idempotent per uid, so it is safe
  /// to call on every AuthController notification. On sign-out (uid == null) it
  /// clears state and drops the realtime channel.
  Future<void> onUserSession(String? uid) async {
    if (_sessionSet && uid == _uid) return;
    _sessionSet = true;
    _uid = uid;
    _items = const [];
    _acting.clear();
    _state = uid == null ? NotificationLoadState.idle : NotificationLoadState.loading;
    notifyListeners();
    // ignore: discarded_futures
    await _realtime.bind(uid);
    if (uid != null) await load();
  }

  Future<void> load() async {
    if (_uid == null) return;
    if (_items.isEmpty) {
      _state = NotificationLoadState.loading;
      notifyListeners();
    }
    try {
      final rows = await _remote.fetchNotifications();
      // Guard against a late response after an account switch.
      if (_uid == null) return;
      _items = rows.map(AppNotification.fromMap).toList();
      _state = NotificationLoadState.loaded;
    } catch (_) {
      _state = _items.isEmpty
          ? NotificationLoadState.error
          : NotificationLoadState.loaded;
    }
    notifyListeners();
  }

  Future<void> refresh() => load();

  void _onRealtime(NotificationRealtimeEvent e) {
    final rec = e.record;
    if (rec == null) return;
    final n = AppNotification.fromMap(rec);
    if (n.userId != _uid) return; // defense-in-depth against a stale channel
    final next = List<AppNotification>.from(_items);
    switch (e.kind) {
      case 'insert':
        next.removeWhere((x) => x.id == n.id);
        if (n.actedAt == null && !_isSoftDeleted(rec)) next.insert(0, n);
        break;
      case 'update':
        final i = next.indexWhere((x) => x.id == n.id);
        if (_isSoftDeleted(rec)) {
          if (i >= 0) next.removeAt(i);
        } else if (i >= 0) {
          next[i] = n;
        } else {
          next.insert(0, n);
        }
        break;
      case 'delete':
        next.removeWhere((x) => x.id == n.id);
        break;
    }
    next.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _items = next;
    if (_state != NotificationLoadState.loading) {
      _state = NotificationLoadState.loaded;
    }
    notifyListeners();
  }

  static bool _isSoftDeleted(Map<String, dynamic> rec) =>
      rec['deleted_at'] != null;

  Future<void> markRead(String id) async {
    final i = _items.indexWhere((n) => n.id == id);
    if (i < 0 || _items[i].isRead) return;
    _items = List.of(_items)..[i] = _items[i].copyWith(readAt: DateTime.now());
    notifyListeners();
    try {
      await _remote.markRead(id);
    } catch (_) {/* realtime/next load reconciles */}
  }

  Future<void> markAllRead() async {
    if (unreadCount == 0) return;
    final now = DateTime.now();
    _items = _items
        .map((n) => n.isRead ? n : n.copyWith(readAt: now))
        .toList();
    notifyListeners();
    try {
      await _remote.markAllRead();
    } catch (_) {}
  }

  /// Accept/decline a still-pending invite. Re-checks actionability (a revoked
  /// or already-answered invite is a no-op). Returns an error message on failure
  /// so the screen can surface it; null on success.
  Future<String?> respondToInvite(AppNotification n, bool accept) async {
    final pid = n.playlistId;
    if (!n.isActionable || pid == null || _acting.contains(n.id)) return null;
    _acting.add(n.id);
    notifyListeners();
    try {
      await _respondInvitation(pid, accept);
      // Optimistically resolve; realtime will confirm with the server row.
      final i = _items.indexWhere((x) => x.id == n.id);
      if (i >= 0) {
        _items = List.of(_items)
          ..[i] = _items[i].copyWith(actedAt: DateTime.now(), readAt: DateTime.now());
      }
      return null;
    } catch (_) {
      return accept
          ? "Couldn't accept the invitation. Please try again."
          : "Couldn't decline the invitation. Please try again.";
    } finally {
      _acting.remove(n.id);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _realtime.removeListener(_onRealtime);
    super.dispose();
  }
}
