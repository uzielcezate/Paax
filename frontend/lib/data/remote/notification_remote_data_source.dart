// lib/data/remote/notification_remote_data_source.dart
//
// Phase 3.4.1.1 — thin Supabase wrapper for the in-app notification inbox.
// Reads are RLS-scoped to the caller's own rows (SELECT policy: auth.uid() =
// user_id); mark-read is an RLS-guarded UPDATE. Notifications are never created
// from the client — there is no INSERT policy; they are emitted only inside
// trusted collaboration RPCs. Responding to an invite goes through the existing
// playlist_respond_invitation RPC (which also marks the invite notif acted),
// not through this data source.

import 'package:supabase_flutter/supabase_flutter.dart';

/// Read/mark surface for the notification inbox. Extracted so the controller can
/// be unit-tested without a live Supabase connection.
abstract class NotificationInbox {
  Future<List<Map<String, dynamic>>> fetchNotifications({int limit});
  Future<void> markRead(String id);
  Future<void> markAllRead();
}

class NotificationRemoteDataSource implements NotificationInbox {
  final SupabaseClient _client;

  NotificationRemoteDataSource([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  /// The caller's most recent notifications, newest first. RLS restricts this to
  /// the caller's own rows regardless of the filter, but we filter explicitly so
  /// a stale session never over-fetches. Soft-deleted rows are excluded.
  @override
  Future<List<Map<String, dynamic>>> fetchNotifications({int limit = 100}) async {
    final uid = currentUserId;
    if (uid == null) return const [];
    final rows = await _client
        .from('notifications')
        .select()
        .eq('user_id', uid)
        .filter('deleted_at', 'is', null)
        .order('created_at', ascending: false)
        .limit(limit);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Mark a single notification read. RLS ensures only the owner can update it.
  @override
  Future<void> markRead(String id) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', id)
        .eq('user_id', uid)
        .filter('read_at', 'is', null);
  }

  /// Mark every unread notification for the caller read.
  @override
  Future<void> markAllRead() async {
    final uid = currentUserId;
    if (uid == null) return;
    await _client
        .from('notifications')
        .update({'read_at': DateTime.now().toUtc().toIso8601String()})
        .eq('user_id', uid)
        .filter('read_at', 'is', null);
  }
}
