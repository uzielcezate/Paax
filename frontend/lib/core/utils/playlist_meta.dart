// lib/core/utils/playlist_meta.dart
//
// Phase 3.3.6 — pure formatters for the 3-line Playlist Detail header metadata.
// No widgets, so fully unit-testable. Structure:
//
//   Line 1: playlist title            (rendered by the screen)
//   Line 2: owner + accepted collaborators, comma+space separated
//   Line 3: visibility · song count · total duration
//
// Collaboration is communicated by the participant line itself — there is NO
// separate "Collaborative" label. Visibility (Public/Private) and isCollaborative
// are independent; visibility is never replaced by "Collaborative".

import '../../domain/entities/playlist.dart';
import '../../domain/entities/playlist_activity.dart';

class PlaylistMeta {
  const PlaylistMeta._();

  static const String separator = ' · ';

  /// "1 song" / "N songs".
  static String songCount(int count) =>
      count == 1 ? '1 song' : '$count songs';

  /// "1 follower" / "N followers".
  static String followers(int count) =>
      count == 1 ? '1 follower' : '$count followers';

  /// Duration: "22 min" (< 60 min) or "1 hr 2 min" (>= 60 min). Returns null
  /// when zero/unavailable so the caller omits the segment entirely.
  static String? duration(int totalSeconds) {
    if (totalSeconds <= 0) return null;
    if (totalSeconds < 3600) return '${totalSeconds ~/ 60} min';
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    return '$hours hr $mins min';
  }

  /// 'public' → "Public", anything else → "Private".
  static String visibilityLabel(String? visibility) =>
      visibility == PlaylistVisibility.public ? 'Public' : 'Private';

  /// Line 3 (Phase 3.3.6): "Private · 6 songs · 22 min". Duration omitted at 0.
  static String detailLine({
    required String? visibility,
    required int trackCount,
    required int totalDurationSeconds,
  }) {
    final parts = <String>[
      visibilityLabel(visibility),
      songCount(trackCount),
    ];
    final d = duration(totalDurationSeconds);
    if (d != null) parts.add(d);
    return parts.join(separator);
  }

  /// Phase 3.4.1 stats line (spec §6, line 2):
  /// "Public · 6 songs · 22 min · 14 followers". Duration omitted at 0; the
  /// follower segment is omitted when [followerCount] is null (unknown/offline).
  static String statsLine({
    required String? visibility,
    required int trackCount,
    required int totalDurationSeconds,
    int? followerCount,
  }) {
    final parts = <String>[
      visibilityLabel(visibility),
      songCount(trackCount),
    ];
    final d = duration(totalDurationSeconds);
    if (d != null) parts.add(d);
    if (followerCount != null) parts.add(followers(followerCount));
    return parts.join(separator);
  }

  /// "Last modified 2 hours ago", or null when unknown. [now] is injectable.
  static String? lastModifiedText(DateTime? at, DateTime now) {
    if (at == null) return null;
    return 'Last modified ${ActivitySummary.relativeTime(at, now)}';
  }

  /// Phase 3.4.1 header line 1: "iamleizu, bren_arteaga · Last modified 2 hours
  /// ago" (the last-modified suffix omitted when unknown; contributors omitted
  /// when empty — never a leading/trailing separator).
  static String contributorsWithModified(
    Playlist playlist, {
    String? fallbackUsername,
    DateTime? lastModifiedAt,
    required DateTime now,
  }) {
    final contributors = contributorLine(playlist, fallbackUsername: fallbackUsername);
    final modified = lastModifiedText(lastModifiedAt, now);
    if (contributors.isEmpty) return modified ?? '';
    if (modified == null) return contributors;
    return '$contributors$separator$modified';
  }

  /// Line 2 as a list of names — owner first, then accepted collaborators,
  /// deduped by canonical user id, never repeating the owner. [fallbackUsername]
  /// is used only when the playlist has no stored owner username (legacy record).
  static List<String> contributorNames(
    Playlist playlist, {
    String? fallbackUsername,
  }) {
    return playlist
        .displayedContributors(fallbackOwnerUsername: fallbackUsername)
        .map((c) => c.username)
        .where((n) => n.trim().isNotEmpty)
        .toList();
  }

  /// Line 2: "iamleizu" / "iamleizu, bren_arteaga". Empty string when no owner
  /// name is available (caller must not render a blank line).
  static String contributorLine(
    Playlist playlist, {
    String? fallbackUsername,
  }) {
    return contributorNames(playlist, fallbackUsername: fallbackUsername)
        .join(', ');
  }
}
