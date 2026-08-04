// lib/presentation/widgets/playlist_activity_timeline_sheet.dart
//
// Phase 3.4.1.2A — the paginated, realtime activity timeline shown from
// "Last modified…". Newest-first, ≥30 initial events, load-more on scroll,
// grouped song add/remove bursts, distinct icons (via PlaylistActivityPresentation),
// actor avatar + username (never a UUID), relative time. Replaces the old
// single-event sheet. Read-only: opening it never mutates the playlist.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../data/remote/playlist_realtime_service.dart';
import '../../data/repositories/playlist_repository.dart';
import '../../domain/entities/playlist_activity.dart';
import '../state/playlist_activity_timeline_controller.dart';
import '../util/playlist_activity_presentation.dart';
import 'actor_avatar.dart';

Future<void> showPlaylistActivityTimeline(
    BuildContext context, String playlistId) {
  final repo = context.read<PlaylistRepository>();
  final realtime = context.read<PlaylistRealtimeService>();
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => ChangeNotifierProvider(
      create: (_) => PlaylistActivityTimelineController(
        fetchPage: ({int limit = 30, DateTime? before}) =>
            repo.fetchActivityTimeline(playlistId, limit: limit, before: before),
        realtime: realtime,
        playlistId: playlistId,
      )..load(),
      child: const _TimelineSheet(),
    ),
  );
}

class _TimelineSheet extends StatelessWidget {
  const _TimelineSheet();

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Activity',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
              ),
            ),
            Expanded(child: _Body(scrollController: scrollController)),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  final ScrollController scrollController;
  const _Body({required this.scrollController});
  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final c = widget.scrollController;
    if (c.position.pixels > c.position.maxScrollExtent - 240) {
      // ignore: discarded_futures
      context.read<PlaylistActivityTimelineController>().loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PlaylistActivityTimelineController>();

    if (c.isLoading && c.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primaryEnd));
    }
    if (c.hasError && c.isEmpty) {
      return _ErrorState(onRetry: c.load);
    }
    if (c.isEmpty) {
      return const Center(
        child: Text('No activity yet',
            style: TextStyle(color: AppColors.mutedText, fontSize: 14)),
      );
    }

    final rows = c.rows;
    return ListView.builder(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      itemCount: rows.length + (c.hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= rows.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primaryEnd))),
          );
        }
        return _ActivityRow(activity: rows[i]);
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final PlaylistActivity activity;
  const _ActivityRow({required this.activity});

  @override
  Widget build(BuildContext context) {
    final p = PlaylistActivityPresentation.of(activity, actorFallback: 'A user');
    final titles = ActivitySummary.detailLines(activity).take(3).toList();
    final overflow = ActivitySummary.overflowCount(activity);
    final when = ActivitySummary.relativeTime(activity.createdAt, DateTime.now());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ActorAvatar(
                  imageUrl: activity.actorAvatarUrl,
                  displayName: activity.actorLabel,
                  size: 40),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: ExcludeSemantics(
                    child: Icon(p.icon,
                        size: 13,
                        color: p.destructive
                            ? AppColors.primaryEnd
                            : Colors.white70),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: p.semanticLabel,
                  child: Text(p.title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3)),
                ),
                if (titles.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  ...titles.map((t) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('•  $t',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                      )),
                  if (overflow > 0)
                    Text('and $overflow more',
                        style: const TextStyle(
                            color: AppColors.mutedText, fontSize: 12)),
                ],
                const SizedBox(height: 5),
                Text(when,
                    style: const TextStyle(
                        color: AppColors.mutedText, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Couldn't load activity",
                style: TextStyle(color: Colors.white, fontSize: 14)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
              ),
              child: const Text('Try Again'),
            ),
          ],
        ),
      );
}
