// lib/presentation/widgets/party_actions.dart
//
// Phase 3.4.1.2C — the single "Add to Party" resolver shared by EVERY track
// overflow menu (album, playlist, search, artist popular, genre, library,
// full-player). Centralizing it here means all menus behave identically and the
// future multi-party / permission / session-race logic lives in one place.
//
// Behavior:
//  • Active Party (future runtime): add the track to the live queue and confirm
//    with "Added to Party", respecting queue-modify permission. Duplicates are
//    allowed (see PartyController.allowsDuplicates).
//  • No active Party (today's reality): offer to start one seeded with this
//    song via the Party scaffold, which communicates that Party isn't fully
//    available yet. Never creates a normal persistent playlist.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../domain/entities/track.dart';
import '../state/party_controller.dart';
import 'create_action_sheet.dart';

class PartyActions {
  const PartyActions._();

  /// Resolve an "Add to Party" tap for [track]. Pass a STABLE context (e.g. the
  /// page's `parentContext`), not the overflow sheet's context, since the sheet
  /// is popped before this runs.
  static Future<void> addToParty(BuildContext context, Track track) async {
    final party = context.read<PartyController>();

    if (party.hasActiveParty) {
      final result = await party.addToActiveParty(track);
      if (!context.mounted) return;
      switch (result) {
        case AddToPartyResult.added:
        case AddToPartyResult.duplicate:
          _snack(context, 'Added to Party');
          return;
        case AddToPartyResult.notPermitted:
          _snack(context, "You can't add songs to this Party");
          return;
        case AddToPartyResult.noActiveParty:
          // Race: the Party ended before the add completed → fall through and
          // offer to start a fresh one seeded with this track.
          break;
      }
    }

    if (!context.mounted) return;
    // No active Party → offer to start one seeded with this song. The scaffold
    // carries the full track identity and communicates the current availability
    // state. It never silently creates a persistent playlist.
    await showPartyEntrySheet(context, seedTrack: track);
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
