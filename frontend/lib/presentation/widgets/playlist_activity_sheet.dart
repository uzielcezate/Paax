// lib/presentation/widgets/playlist_activity_sheet.dart
//
// Phase 3.4.1 — the compact "Last modified…" detail sheet (spec §7). Shows who
// made the latest grouped change, what changed (track titles for add/remove,
// bounded with "and N more"), and when. Uses the existing Paax dark sheet style.
// Never renders raw ids. This is NOT a full activity feed — only the latest event.

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/playlist_activity.dart';

Future<void> showPlaylistActivitySheet(
    BuildContext context, PlaylistActivity activity) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => PlaylistActivitySheet(activity: activity),
  );
}

class PlaylistActivitySheet extends StatelessWidget {
  final PlaylistActivity activity;
  const PlaylistActivitySheet({super.key, required this.activity});

  @override
  Widget build(BuildContext context) {
    final headline = ActivitySummary.headline(activity);
    final details = ActivitySummary.detailLines(activity);
    final overflow = ActivitySummary.overflowCount(activity);
    final when = ActivitySummary.relativeTime(activity.createdAt, DateTime.now());
    final bottomInset = MediaQuery.of(context).padding.bottom;

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
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            headline,
            style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...details.map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  ', style: TextStyle(color: Colors.white38, fontSize: 13)),
                      Expanded(
                        child: Text(
                          t,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                )),
            if (overflow > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('and $overflow more',
                    style: const TextStyle(color: Colors.white38, fontSize: 13)),
              ),
          ],
          const SizedBox(height: 14),
          Text(when,
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }
}
