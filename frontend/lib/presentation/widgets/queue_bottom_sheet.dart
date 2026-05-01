import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import 'app_image.dart';

/// Shows the playback queue as a modal bottom sheet.
void showQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _QueueSheetContent(),
  );
}

class _QueueSheetContent extends StatelessWidget {
  const _QueueSheetContent();

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: height,
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A).withValues(alpha: 0.92),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
            ),
          ),
          child: Consumer<PlaybackController>(
            builder: (context, playback, _) {
              final currentTrack = playback.currentTrack;
              final upcoming = playback.upcomingQueue;

              return Column(
                children: [
                  // ── Handle ──
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // ── Header ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(
                      children: [
                        const Text(
                          'Cola',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        if (upcoming.isNotEmpty)
                          TextButton(
                            onPressed: () => _confirmClear(context, playback),
                            child: const Text(
                              'Limpiar cola',
                              style: TextStyle(
                                color: AppColors.primaryEnd,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),

                  // ── Content ──
                  Expanded(
                    child: currentTrack == null
                        ? _buildEmptyState()
                        : _buildQueue(context, playback, currentTrack, upcoming),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_music_rounded, size: 56, color: Colors.white24),
          SizedBox(height: 16),
          Text(
            'No hay canciones en la cola',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildQueue(
    BuildContext context,
    PlaybackController playback,
    Track currentTrack,
    List<Track> upcoming,
  ) {
    return CustomScrollView(
      slivers: [
        // ── Now Playing ──
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              'Reproduciendo',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryStart,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _NowPlayingTile(track: currentTrack, isPlaying: playback.isPlaying),
        ),

        // ── Upcoming ──
        if (upcoming.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'Siguiente',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.5),
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _UpcomingList(
              upcoming: upcoming,
              playback: playback,
            ),
          ),
        ],

        if (upcoming.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(
                child: Text(
                  'No hay más canciones',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _confirmClear(BuildContext context, PlaybackController playback) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Limpiar cola', style: TextStyle(color: Colors.white)),
        content: const Text(
          '¿Eliminar todas las canciones de la cola?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () {
              playback.clearUpcoming();
              Navigator.pop(ctx);
            },
            child: const Text('Limpiar', style: TextStyle(color: AppColors.primaryEnd)),
          ),
        ],
      ),
    );
  }
}

// ── Now Playing Tile ──────────────────────────────────────────────────────────

class _NowPlayingTile extends StatelessWidget {
  final Track track;
  final bool isPlaying;

  const _NowPlayingTile({required this.track, required this.isPlaying});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primaryStart.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primaryStart.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AppImage(
              url: track.artworkUrl,
              sizePx: Lh3UrlBuilder.listSize,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.displayArtist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          Icon(
            isPlaying ? Icons.graphic_eq_rounded : Icons.pause_rounded,
            color: AppColors.primaryStart,
            size: 24,
          ),
        ],
      ),
    );
  }
}

// ── Upcoming List (ReorderableListView) ─────────────────────────────────────

class _UpcomingList extends StatelessWidget {
  final List<Track> upcoming;
  final PlaybackController playback;

  const _UpcomingList({required this.upcoming, required this.playback});

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: upcoming.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex--;
        playback.reorderQueue(oldIndex, newIndex);
      },
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) => Material(
            color: Colors.transparent,
            elevation: 4,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(12),
            child: child,
          ),
          child: child,
        );
      },
      itemBuilder: (context, index) {
        final track = upcoming[index];
        final absoluteIndex = playback.currentIndex + 1 + index;

        return _QueueItemTile(
          key: ValueKey('${track.id}_$absoluteIndex'),
          track: track,
          index: index,
          onTap: () {
            playback.playFromQueue(absoluteIndex);
          },
          onRemove: () {
            playback.removeFromQueue(absoluteIndex);
          },
        );
      },
    );
  }
}

class _QueueItemTile extends StatelessWidget {
  final Track track;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _QueueItemTile({
    super.key,
    required this.track,
    required this.index,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Artwork
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AppImage(
                url: track.artworkUrl,
                sizePx: Lh3UrlBuilder.listSize,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),

            // Title + Artist
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.displayArtist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),

            // Remove button
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white38),
              onPressed: onRemove,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),

            // Drag handle
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.drag_handle_rounded, size: 22, color: Colors.white30),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
