// lib/presentation/widgets/create_action_sheet.dart
//
// Phase 3.4.1.1 §G — the "+" create menu. Presents two entries: "Create
// playlist" (preserves the existing playlist-creation flow verbatim) and "Start
// a Party". Party is an entry scaffold only (AppConfig.partyEnabled defaults
// OFF): choosing it opens an informational prep sheet that explains the concept
// and states it isn't available yet — it NEVER silently creates an ordinary
// playlist. This is the minimal nav seam for the future Party feature; no Party
// backend/migrations exist.

import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/track.dart';

/// Shows the create action sheet. [onCreatePlaylist] runs the existing playlist
/// creation flow. Party opens the prep sheet (or, once implemented and the flag
/// is on, the real start-a-party flow).
Future<void> showCreateActionSheet(
  BuildContext context, {
  required VoidCallback onCreatePlaylist,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetCtx) => _CreateActionSheet(
      onCreatePlaylist: () {
        Navigator.pop(sheetCtx);
        onCreatePlaylist();
      },
      onStartParty: () {
        Navigator.pop(sheetCtx);
        showPartyEntrySheet(context);
      },
    ),
  );
}

class _CreateActionSheet extends StatelessWidget {
  final VoidCallback onCreatePlaylist;
  final VoidCallback onStartParty;
  const _CreateActionSheet(
      {required this.onCreatePlaylist, required this.onStartParty});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          _ActionRow(
            icon: Icons.playlist_add_rounded,
            title: 'Create playlist',
            subtitle: 'A collection of songs you can share',
            onTap: onCreatePlaylist,
          ),
          // Party entry is gated by AppConfig.partyEnabled (default OFF) so it
          // is hidden in production — kept consistent with the track-menu entry.
          if (AppConfig.partyEnabled)
            _ActionRow(
              icon: Icons.celebration_rounded,
              title: 'Start a Party',
              subtitle: 'Listen together in a shared session',
              onTap: onStartParty,
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.mutedText, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Informational "Start a Party" prep sheet — the shared entry scaffold for BOTH
/// the Library "+" and the track-menu entry. [seedTrack] is the song a track-menu
/// entry would seed the Party with; it is carried here as the seam for the future
/// live flow. This sheet creates nothing (Party has no backend yet).
Future<void> showPartyEntrySheet(BuildContext context, {Track? seedTrack}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _PartyEntrySheet(seedTrack: seedTrack),
  );
}

class _PartyEntrySheet extends StatelessWidget {
  final Track? seedTrack;
  const _PartyEntrySheet({this.seedTrack});

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final seedTitle = seedTrack?.title.trim();
    // The flag gates the eventual live flow; while OFF this stays informational.
    final available = AppConfig.partyEnabled;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 18),
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          Row(
            children: const [
              Icon(Icons.celebration_rounded,
                  color: AppColors.primaryEnd, size: 26),
              SizedBox(width: 10),
              Text('Start a Party',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            (seedTitle != null && seedTitle.isNotEmpty)
                ? 'A Party is a temporary shared listening session — it would start '
                    'with “$seedTitle” and let friends listen together in sync, in real time.'
                : 'A Party is a temporary shared listening session — invite friends and '
                    'everyone hears the same songs in sync, in real time.',
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: const [
                Icon(Icons.hourglass_top_rounded,
                    color: AppColors.mutedText, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Parties aren’t available yet — coming soon.',
                      style: TextStyle(
                          color: AppColors.mutedText, fontSize: 13)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: available ? () => Navigator.pop(context) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryEnd,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: Colors.white38,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24)),
              ),
              child: Text(available ? 'Create Party' : 'Coming soon',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ),
        ],
      ),
    );
  }
}
