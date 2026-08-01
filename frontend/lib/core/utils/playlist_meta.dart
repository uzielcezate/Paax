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

class PlaylistMeta {
  const PlaylistMeta._();

  static const String separator = ' · ';

  /// "1 song" / "N songs".
  static String songCount(int count) =>
      count == 1 ? '1 song' : '$count songs';

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

  /// Line 3: "Private · 6 songs · 22 min". Duration omitted when zero.
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
