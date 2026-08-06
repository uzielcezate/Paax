// lib/presentation/state/party_controller.dart
//
// Phase 3.4.1.2C — single source of truth for (future) live Party session
// state. There is no Party runtime backend yet, so [hasActiveParty] is always
// false today and every "Add to Party" resolves to the start-a-party flow.
//
// This is deliberately the ONE resolver all track menus share (via
// PartyActions), so a real runtime — multiple parties, host/guest permissions,
// live queue sync, session end/race handling — can drop in behind this class
// without touching any caller. Track identity/metadata is preserved verbatim so
// future Party playback can resolve the song.

import 'package:flutter/foundation.dart';

import '../../domain/entities/track.dart';

/// Outcome of attempting to add a track to the active Party queue.
enum AddToPartyResult {
  /// Added to the live queue.
  added,

  /// Already present; per the ALLOW-duplicates product rule this is still a
  /// success (kept distinct so a future UI could message it if the rule flips).
  duplicate,

  /// The Party ended between the menu opening and this call (race) — caller
  /// should offer to start a new Party seeded with the track.
  noActiveParty,

  /// The current user isn't permitted to modify this Party's queue.
  notPermitted,
}

class PartyController extends ChangeNotifier {
  final List<Track> _queue = [];
  // Flipped by the future Party runtime when a live session starts/ends.
  // ignore: prefer_final_fields
  bool _active = false;

  /// Whether a live Party session is currently active. Always false until the
  /// Party runtime ships.
  bool get hasActiveParty => _active;

  /// Whether the current user may modify the active Party's queue. A real
  /// runtime checks host/guest permissions; with no runtime this is false.
  bool get canModifyQueue => _active;

  /// A read-only view of the active Party queue (empty until the runtime ships).
  List<Track> get queue => List.unmodifiable(_queue);

  /// Product rule (documented): Party ALLOWS duplicate tracks — a Party is a
  /// live shared queue, so re-queuing the same song is legitimate. There is no
  /// "Already in Party" rejection.
  bool get allowsDuplicates => true;

  /// Attempt to add [track] to the active Party queue. Preserves the track's
  /// full identity/metadata. Handles the race where the Party ended just before
  /// this call by returning [AddToPartyResult.noActiveParty] so the caller can
  /// fall back to starting a fresh Party.
  Future<AddToPartyResult> addToActiveParty(Track track) async {
    if (!_active) return AddToPartyResult.noActiveParty;
    if (!canModifyQueue) return AddToPartyResult.notPermitted;
    final isDuplicate = _queue.any((t) => t.id == track.id);
    if (isDuplicate && !allowsDuplicates) return AddToPartyResult.duplicate;
    _queue.add(track);
    notifyListeners();
    return isDuplicate ? AddToPartyResult.duplicate : AddToPartyResult.added;
  }
}
