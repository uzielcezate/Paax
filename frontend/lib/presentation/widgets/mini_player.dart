import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../screens/player_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Select only the current track to avoid rebuilding on position change
    final track = context.select<PlaybackController, Track?>((controller) => controller.currentTrack);

    if (track == null) return const SizedBox.shrink();

    // Bottom padding to avoid nav bar overlap if needed, but usually handled by parent Stack
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
      child: Container(
        height: 64,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surfaceLight, 
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
             BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))
          ]
        ),
        child: ClipRRect( 
           borderRadius: BorderRadius.circular(12),
           child: Stack(
            children: [
              Container(color: AppColors.surface),
              
              // Progress Bar (Top Edge) - ISOLATED BLUIDER
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 2,
                child: Builder(
                  builder: (context) {
                     final controller = context.read<PlaybackController>();
                     return ValueListenableBuilder<Duration>(
                       valueListenable: controller.positionNotifier,
                       builder: (context, position, _) {
                         // Safely calculate progress
                         // We read duration directly from controller property or notifier if needed
                         // But duration shouldn't change often, so reading property is fine or listen to durationNotifier nested
                         
                         int durationMs = controller.duration.inMilliseconds;
                         if (durationMs <= 0) durationMs = 1;
                         
                         final progress = (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
                         
                         return LinearProgressIndicator(
                           value: progress,
                           backgroundColor: Colors.transparent,
                           valueColor: const AlwaysStoppedAnimation(AppColors.primaryEnd),
                           minHeight: 2,
                         );
                       }
                     );
                  }
                ),
              ),

              // Content Row
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // Artwork
                    Hero(
                      tag: "mini_player_art_${track.id}",
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: AppImage(
                          url: track.artworkUrl,
                          sizePx: Lh3UrlBuilder.miniPlayerSize,
                          width: 48,
                          height: 48,
                          fit: BoxFit.cover,
                          borderRadius: 8,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    
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
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white),
                          ),
                          Text(
                            track.artistName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    
                    // Like Button
                    Consumer<LibraryController>(
                      builder: (context, lib, _) => IconButton(
                        icon: Icon(lib.isLiked(track) ? Icons.favorite : Icons.favorite_border, size: 24),
                        color: lib.isLiked(track) ? AppColors.primaryEnd : Colors.white,
                        onPressed: () => lib.toggleLike(track),
                      ),
                    ),
                    
                    // Play/Pause Button - Using Selector to avoid rebuilds on position/duration changes
                    Selector<PlaybackController, bool>(
                      selector: (_, controller) => controller.isPlaying,
                      builder: (context, isPlaying, _) {
                        return IconButton(
                          icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 32),
                          color: Colors.white,
                          onPressed: () {
                            context.read<PlaybackController>().togglePlayPause();
                          },
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
