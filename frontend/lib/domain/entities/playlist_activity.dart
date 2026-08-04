// lib/domain/entities/playlist_activity.dart
//
// Phase 3.4.1 — playlist activity (audit/event) model + the "Last modified…"
// summary shown in the compact detail sheet. Pure/testable: the repository
// fetches rows; ActivitySummary turns one grouped event into a headline +
// bounded detail lines + relative time. Never renders raw UUIDs.

class PlaylistActivity {
  final String id;
  final String playlistId;
  final String? actorId;
  final String? actorUsername; // resolved snapshot for display
  final String eventType;
  final DateTime createdAt;
  final int? playlistVersion;
  final Map<String, dynamic> metadata;
  final String? groupedChangeId;

  const PlaylistActivity({
    required this.id,
    required this.playlistId,
    this.actorId,
    this.actorUsername,
    required this.eventType,
    required this.createdAt,
    this.playlistVersion,
    this.metadata = const {},
    this.groupedChangeId,
  });

  factory PlaylistActivity.fromMap(Map<String, dynamic> m, {String? actorUsername}) {
    return PlaylistActivity(
      id: m['id']?.toString() ?? '',
      playlistId: m['playlist_id']?.toString() ?? '',
      actorId: m['actor_id']?.toString(),
      actorUsername: actorUsername,
      eventType: m['event_type']?.toString() ?? '',
      createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      playlistVersion: m['playlist_version'] is int
          ? m['playlist_version'] as int
          : int.tryParse('${m['playlist_version'] ?? ''}'),
      metadata: (m['metadata'] is Map)
          ? (m['metadata'] as Map).cast<String, dynamic>()
          : const {},
      groupedChangeId: m['grouped_change_id']?.toString(),
    );
  }

  PlaylistActivity copyWith({String? actorUsername}) => PlaylistActivity(
        id: id,
        playlistId: playlistId,
        actorId: actorId,
        actorUsername: actorUsername ?? this.actorUsername,
        eventType: eventType,
        createdAt: createdAt,
        playlistVersion: playlistVersion,
        metadata: metadata,
        groupedChangeId: groupedChangeId,
      );
}

/// Turns a grouped activity event into human-readable text. Never shows raw ids.
class ActivitySummary {
  const ActivitySummary._();

  static const int maxDetailLines = 6;

  static String _songs(int n) => n == 1 ? '1 song' : '$n songs';

  static int _count(PlaylistActivity a) {
    final c = a.metadata['count'];
    if (c is int) return c;
    return int.tryParse('$c') ?? 0;
  }

  static String _actor(PlaylistActivity a, {String? fallback}) {
    final n = (a.actorUsername ?? '').trim();
    if (n.isNotEmpty) return n;
    return (fallback ?? 'Someone');
  }

  /// One-line headline, e.g. "bren_arteaga added 3 songs".
  static String headline(PlaylistActivity a, {String? actorFallback}) {
    final actor = _actor(a, fallback: actorFallback);
    switch (a.eventType) {
      case 'tracks_added':
        return '$actor added ${_songs(_count(a))}';
      case 'tracks_removed':
        return '$actor removed ${_songs(_count(a))}';
      case 'tracks_reordered':
        return '$actor reordered ${_songs(_count(a))}';
      case 'playlist_renamed':
        final to = a.metadata['to']?.toString();
        return to == null
            ? '$actor renamed the playlist'
            : '$actor renamed the playlist to "$to"';
      case 'description_changed':
        return '$actor updated the description';
      case 'visibility_changed':
        final to = a.metadata['to']?.toString();
        if (to == 'public') return '$actor made this playlist public';
        if (to == 'private') return '$actor made this playlist private';
        return '$actor changed the playlist visibility';
      case 'cover_changed':
        return '$actor changed the cover';
      case 'playlist_created':
        return '$actor created the playlist';
      case 'playlist_imported':
        return '$actor imported the playlist';
      case 'collaborator_invited':
        return '$actor invited a collaborator';
      case 'collaborator_joined':
        return '$actor joined as a collaborator';
      case 'collaborator_removed':
        return '$actor removed a collaborator';
      case 'collaborator_left':
        return '$actor left the playlist';
      case 'ownership_transferred':
        return 'Ownership was transferred';
      case 'playlist_cloned':
        return '$actor created this playlist from another';
      case 'playlist_deleted':
        return '$actor deleted the playlist';
      default:
        return '$actor updated the playlist';
    }
  }

  /// Bounded detail lines (track titles for add/remove). Returns at most
  /// [maxDetailLines]; the caller appends an "and N more" line via [overflowCount].
  static List<String> detailLines(PlaylistActivity a) {
    if (a.eventType != 'tracks_added' && a.eventType != 'tracks_removed') {
      return const [];
    }
    final tracks = a.metadata['tracks'];
    if (tracks is! List) return const [];
    final titles = tracks
        .whereType<Map>()
        .map((m) => (m['title'] ?? '').toString().trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return titles.take(maxDetailLines).toList();
  }

  /// All track titles carried by the event (bounded by the emitter payload).
  static List<String> _allTrackTitles(PlaylistActivity a) {
    final tracks = a.metadata['tracks'];
    if (tracks is! List) return const [];
    return tracks
        .whereType<Map>()
        .map((m) => (m['title'] ?? '').toString().trim())
        .where((t) => t.isNotEmpty)
        .toList();
  }

  /// Compact inline summary for add/remove events, e.g.
  /// "Duro, offline, WASSUP and 3 more". Bounded to [max] titles. Empty for
  /// non-track events. Never renders a raw id.
  static String inlineTrackSummary(PlaylistActivity a, {int max = 3}) {
    if (a.eventType != 'tracks_added' && a.eventType != 'tracks_removed') {
      return '';
    }
    final titles = _allTrackTitles(a);
    final total = _count(a) > titles.length ? _count(a) : titles.length;
    if (titles.isEmpty) return '';
    final shown = titles.take(max).toList();
    final remaining = total - shown.length;
    final head = shown.join(', ');
    return remaining > 0 ? '$head and $remaining more' : head;
  }

  /// Number of tracks beyond the shown detail lines (for "and N more").
  static int overflowCount(PlaylistActivity a) {
    if (a.eventType != 'tracks_added' && a.eventType != 'tracks_removed') return 0;
    final total = _count(a);
    final shown = detailLines(a).length;
    return total > shown ? total - shown : 0;
  }

  /// Compact relative time, e.g. "just now", "2 minutes ago", "2 hours ago",
  /// "3 days ago". [now] is injectable for testing.
  static String relativeTime(DateTime t, DateTime now) {
    var diff = now.difference(t);
    if (diff.isNegative) diff = Duration.zero;
    final secs = diff.inSeconds;
    if (secs < 45) return 'just now';
    final mins = diff.inMinutes;
    if (mins < 60) return mins == 1 ? '1 minute ago' : '$mins minutes ago';
    final hours = diff.inHours;
    if (hours < 24) return hours == 1 ? '1 hour ago' : '$hours hours ago';
    final days = diff.inDays;
    if (days < 7) return days == 1 ? '1 day ago' : '$days days ago';
    if (days < 30) {
      final w = (days / 7).floor();
      return w == 1 ? '1 week ago' : '$w weeks ago';
    }
    if (days < 365) {
      final mo = (days / 30).floor();
      return mo == 1 ? '1 month ago' : '$mo months ago';
    }
    final yr = (days / 365).floor();
    return yr == 1 ? '1 year ago' : '$yr years ago';
  }
}
