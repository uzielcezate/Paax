// lib/domain/entities/playlist_activity_grouping.dart
//
// Phase 3.4.1.2A — PRESENTATION-ONLY grouping for the activity timeline. The DB
// persists every action immediately and independently; this collapses adjacent
// UI rows without touching storage. Two events group only when ALL hold:
//   * same playlist (always — the query is per-playlist),
//   * same actor,
//   * same activity type,
//   * the type is a track add/remove (create/rename/visibility/ownership/… never
//     group — they are distinct, singular events),
//   * their timestamps are within 5 minutes of the adjacent event,
//   * no conflicting event occurred between them (guaranteed by adjacency on a
//     newest-first list — a different type/actor breaks the run).
//
// A single add/remove RPC already emits ONE event carrying all its tracks, so
// grouping never depends on the UI to be correct; it only merges a burst of
// separate one-by-one operations by the same user. Merged groups are returned
// as a synthetic PlaylistActivity (same type, combined count + titles, newest
// timestamp) so the existing presentation mapper renders them unchanged.

import 'playlist_activity.dart';

class ActivityGrouper {
  const ActivityGrouper._();

  static const Duration window = Duration(minutes: 5);

  static const _groupable = {'tracks_added', 'tracks_removed'};

  /// [events] MUST be newest-first. Returns newest-first presentation rows.
  static List<PlaylistActivity> group(List<PlaylistActivity> events) {
    final out = <PlaylistActivity>[];
    // Accumulator for the run currently being built.
    List<PlaylistActivity>? run;

    void flush() {
      if (run == null) return;
      out.add(run!.length == 1 ? run!.first : _merge(run!));
      run = null;
    }

    for (final e in events) {
      if (run == null) {
        run = [e];
        continue;
      }
      final head = run!.first; // newest in the run
      final tail = run!.last; // oldest so far
      final sameRun = _groupable.contains(e.eventType) &&
          e.eventType == head.eventType &&
          (e.actorId ?? '') == (head.actorId ?? '') &&
          (e.actorId ?? '').isNotEmpty &&
          tail.createdAt.difference(e.createdAt).abs() <= window;
      if (sameRun) {
        run!.add(e);
      } else {
        flush();
        run = [e];
      }
    }
    flush();
    return out;
  }

  /// Merge a run (newest-first) of same-type track events into one synthetic
  /// event: combined count + titles in chronological (oldest-first) order,
  /// stamped with the newest timestamp/actor.
  static PlaylistActivity _merge(List<PlaylistActivity> run) {
    final newest = run.first;
    var count = 0;
    final titles = <Map<String, dynamic>>[];
    // Oldest-first so titles read in the order they were actually added.
    for (final e in run.reversed) {
      final c = e.metadata['count'];
      count += (c is int) ? c : (int.tryParse('$c') ?? 0);
      final t = e.metadata['tracks'];
      if (t is List) {
        for (final item in t) {
          if (item is Map) titles.add(item.cast<String, dynamic>());
        }
      }
    }
    return newest.copyWith(
      metadata: {
        ...newest.metadata,
        'count': count,
        'tracks': titles,
      },
    );
  }

  /// De-dupe by activity id, keeping the first occurrence, preserving order.
  static List<PlaylistActivity> dedupeById(List<PlaylistActivity> events) {
    final seen = <String>{};
    final out = <PlaylistActivity>[];
    for (final e in events) {
      if (e.id.isEmpty || seen.add(e.id)) out.add(e);
    }
    return out;
  }
}
