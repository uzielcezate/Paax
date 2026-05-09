import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../state/theme_state.dart';
import '../screens/player_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';
import 'glass_surface.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Select only the current track to avoid rebuilding on position change
    final track = context.select<PlaybackController, Track?>((controller) => controller.currentTrack);
    final fgColor = context.watch<ThemeState>().foregroundColor;

    if (track == null) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            pageBuilder: (context, animation, secondaryAnimation) => const PlayerScreen(),
            transitionsBuilder: (context, animation, secondaryAnimation, child) {
              const begin = Offset(0.0, 1.0);
              const end = Offset.zero;
              const curve = Curves.ease;
              var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
              return SlideTransition(position: animation.drive(tween), child: child);
            },
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: GlassSurface(
          height: 52,
          borderRadius: BorderRadius.circular(26),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Stack(
            children: [
              // Progress Bar (Top Edge)
              Positioned(
                top: 0,
                left: 16,
                right: 16,
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
                           borderRadius: BorderRadius.circular(1),
                           child: LinearProgressIndicator(
                             value: progress,
                             backgroundColor: Colors.white10,
                             valueColor: const AlwaysStoppedAnimation(AppColors.primaryEnd),
                             minHeight: 2,
                           ),
                         );
                       }
                     );
                  }
                ),
              ),

              // Content Row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: [
                    // Artwork
                    Hero(
                      tag: "mini_player_art_${track.id}",
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: AppImage(
                          url: track.artworkUrl,
                          sizePx: Lh3UrlBuilder.miniPlayerSize,
                          width: 36,
                          height: 36,
                          fit: BoxFit.cover,
                          borderRadius: 18,
                          forceLoad: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    
                    // Title & Artist
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: fgColor),
                          ),
                          Text(
                            track.displayArtist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: fgColor.withValues(alpha: 0.55), fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    
                    // Like Button
                    Consumer<LibraryController>(
                      builder: (context, lib, _) => IconButton(
                        icon: Icon(
                          lib.isLiked(track) ? Icons.favorite : Icons.favorite_border,
                          size: 22,
                        ),
                        color: lib.isLiked(track) ? AppColors.primaryEnd : fgColor.withValues(alpha: 0.7),
                        onPressed: () => lib.toggleLike(track),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    ),
                    
                    // Play/Pause Button
                    Selector<PlaybackController, bool>(
                      selector: (_, controller) => controller.isPlaying,
                      builder: (context, isPlaying, _) {
                        return IconButton(
                          icon: Icon(
                            isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 26,
                          ),
                          color: fgColor,
                          onPressed: () {
                            context.read<PlaybackController>().togglePlayPause();
                          },
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        );
                      }
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
