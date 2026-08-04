// lib/domain/entities/app_notification.dart
//
// Phase 3.4.1.1 — in-app notification model. Rows are produced server-side by
// trusted SECURITY DEFINER RPCs (collaboration invites/accepts/declines/leaves/
// removals/ownership transfers); the client only reads its own rows and marks
// them read. Title/body are pre-rendered by the emitter, so display never has to
// reconstruct meaning from raw ids. `data` carries a bounded, display-safe
// payload (playlist id/title/cover, actor username) for tap-through + avatars.

/// Notification type slugs emitted by the backend. Kept as constants so UI code
/// can branch without stringly-typos.
class NotificationType {
  const NotificationType._();
  static const invited = 'playlist_collaboration_invited';
  static const accepted = 'playlist_collaboration_accepted';
  static const declined = 'playlist_collaboration_declined';
  static const removed = 'playlist_collaborator_removed';
  static const left = 'playlist_collaborator_left';
  static const ownershipTransferred = 'playlist_ownership_transferred';
}

class AppNotification {
  final String id;
  final String userId;
  final String? actorUserId;
  final String type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final String? entityType;
  final String? entityId;
  final DateTime createdAt;
  final DateTime? readAt;
  final DateTime? actedAt;

  const AppNotification({
    required this.id,
    required this.userId,
    this.actorUserId,
    required this.type,
    required this.title,
    required this.body,
    this.data = const {},
    this.entityType,
    this.entityId,
    required this.createdAt,
    this.readAt,
    this.actedAt,
  });

  bool get isRead => readAt != null;

  /// Only a still-pending collaboration invite can be accepted/declined inline.
  /// Once acted on (accepted/declined/revoked) the row carries `acted_at`.
  bool get isActionable =>
      type == NotificationType.invited && actedAt == null;

  String? get playlistId =>
      (data['playlist_id'] ?? entityId)?.toString();
  String? get playlistTitle => data['playlist_title']?.toString();
  String? get playlistCover => data['playlist_cover']?.toString();
  String? get actorUsername => data['actor_username']?.toString();

  static DateTime? _ts(Object? v) =>
      v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

  factory AppNotification.fromMap(Map<String, dynamic> m) {
    return AppNotification(
      id: m['id']?.toString() ?? '',
      userId: m['user_id']?.toString() ?? '',
      actorUserId: m['actor_user_id']?.toString(),
      type: m['type']?.toString() ?? '',
      title: m['title']?.toString() ?? 'Paax',
      body: m['body']?.toString() ?? '',
      data: (m['data'] is Map)
          ? (m['data'] as Map).cast<String, dynamic>()
          : const {},
      entityType: m['entity_type']?.toString(),
      entityId: m['entity_id']?.toString(),
      createdAt: _ts(m['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      readAt: _ts(m['read_at']),
      actedAt: _ts(m['acted_at']),
    );
  }

  AppNotification copyWith({DateTime? readAt, DateTime? actedAt}) =>
      AppNotification(
        id: id,
        userId: userId,
        actorUserId: actorUserId,
        type: type,
        title: title,
        body: body,
        data: data,
        entityType: entityType,
        entityId: entityId,
        createdAt: createdAt,
        readAt: readAt ?? this.readAt,
        actedAt: actedAt ?? this.actedAt,
      );
}
