// lib/domain/entities/edit_order_diff.dart
//
// Pure diff between the membership/order captured when Edit Order opened and
// the state the user pressed Save on (Phase 3.4.4).
//
// WHY A DIFF, AND WHY PURE
// ------------------------
// Edit Order previously committed through `playlist_save_order` alone, which
// logs exactly one `tracks_reordered` event — so removing a song in Edit Order
// was invisible in Activity, and a Save that only reordered was indistinguishable
// from one that also removed. Worse, `playlist_save_order` REJECTS a changed
// membership (`ORDER_SET_MISMATCH`), so removals could not go through it at all.
//
// The commit therefore has to be decomposed: removals via `playlist_remove_tracks`,
// additions via `playlist_add_tracks`, and a reorder ONLY if the relative order
// of the surviving tracks actually changed. Deciding that is pure set/sequence
// logic, so it lives here where it can be exhaustively tested without a network,
// a database, or a widget.
//
// Nothing in this file performs I/O or emits activity — it only describes what
// changed. Emission happens on Save, never before.

import 'track.dart';

class EditOrderDiff {
  /// Tracks present at open, absent at save.
  final List<Track> removed;

  /// Tracks absent at open, present at save.
  final List<Track> added;

  /// True when the relative order of the tracks common to BOTH states changed.
  ///
  /// Computed on the common subsequence so that removing a song does not, by
  /// itself, count as a reorder — otherwise every removal would emit a spurious
  /// `tracks_reordered` alongside `tracks_removed`.
  final bool reordered;

  const EditOrderDiff({
    required this.removed,
    required this.added,
    required this.reordered,
  });

  bool get isEmpty => removed.isEmpty && added.isEmpty && !reordered;
  bool get hasMembershipChange => removed.isNotEmpty || added.isNotEmpty;

  /// Diffs [original] (captured when Edit Order opened) against [saved].
  ///
  /// Identity is `Track.id`. Duplicates are not expected in a playlist and are
  /// treated as one logical membership entry.
  static EditOrderDiff between(List<Track> original, List<Track> saved) {
    final originalIds = original.map((t) => t.id).toList();
    final savedIds = saved.map((t) => t.id).toList();
    final originalSet = originalIds.toSet();
    final savedSet = savedIds.toSet();

    final removed = original.where((t) => !savedSet.contains(t.id)).toList();
    final added = saved.where((t) => !originalSet.contains(t.id)).toList();

    // Relative order of the survivors, in each state.
    final commonBefore =
        originalIds.where(savedSet.contains).toList(growable: false);
    final commonAfter =
        savedIds.where(originalSet.contains).toList(growable: false);

    var reordered = commonBefore.length != commonAfter.length;
    if (!reordered) {
      for (var i = 0; i < commonBefore.length; i++) {
        if (commonBefore[i] != commonAfter[i]) {
          reordered = true;
          break;
        }
      }
    }

    return EditOrderDiff(removed: removed, added: added, reordered: reordered);
  }

  @override
  String toString() =>
      'EditOrderDiff(removed=${removed.length}, added=${added.length}, reordered=$reordered)';
}
