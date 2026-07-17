import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../screens/main_wrapper.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';
import 'marquee_text.dart';
import 'explicit_badge.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  final MarqueeController _marqueeSync = MarqueeController();

  @override
  void dispose() {
    _marqueeSync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = context.select<PlaybackController, Track?>((c) => c.currentTrack);
    if (track == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => MainWrapper.shellKey.currentState?.openPlayer(),
      child: Container(
        // Full-width, edge-to-edge with small horizontal margin
        margin: const EdgeInsets.symmetric(horizontal: 8),
        height: 67,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            // ── Content row ──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    // Cover art
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: AppImage(
                        url: track.artworkUrl,
                        sizePx: Lh3UrlBuilder.miniPlayerSize,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        borderRadius: 6,
                        forceLoad: true,
                      ),
                    ),
                    const SizedBox(width: 10),

                    // Title & Artist
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarqueeText(
                            text: track.title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                              color: Colors.white,
                            ),
                            controller: _marqueeSync,
                            prefix: track.isExplicit
                                ? const ExplicitBadge(foregroundColor: Colors.white, scale: 0.85)
                                : null,
                          ),
                          MarqueeText(
                            text: track.displayArtist,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                            ),
                            controller: _marqueeSync,
                          ),
                        ],
                      ),
                    ),

                    // Like button
                    Consumer<LibraryController>(
                      builder: (context, lib, _) => IconButton(
                        icon: Icon(
                          lib.isLiked(track) ? Icons.favorite : Icons.favorite_border,
                          size: 23,
                        ),
                        color: lib.isLiked(track) ? Colors.white : Colors.white70,
                        onPressed: () => lib.toggleLike(track),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      ),
                    ),

                    // Play/Pause button
                    Selector<PlaybackController, bool>(
                      selector: (_, c) => c.isPlaying,
                      builder: (context, isPlaying, _) => IconButton(
                        icon: Icon(
                          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          size: 30,
                        ),
                        color: Colors.white,
                        onPressed: () => context.read<PlaybackController>().togglePlayPause(),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Progress bar — bottom edge, full width ──
            SizedBox(
              height: 2,
              child: Builder(
                builder: (context) {
                  final controller = context.read<PlaybackController>();
                  return ValueListenableBuilder<Duration>(
                    valueListenable: controller.positionNotifier,
                    builder: (context, position, _) {
                      int durationMs = controller.duration.inMilliseconds;
                      if (durationMs <= 0) durationMs = 1;
                      final progress = (position.inMilliseconds / durationMs).clamp(0.0, 1.0);

                      return ClipRRect(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: const AlwaysStoppedAnimation(Colors.white70),
                          minHeight: 2,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
