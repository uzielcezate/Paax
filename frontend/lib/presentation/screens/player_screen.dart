import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';

import '../widgets/overflow_menu.dart';
import '../widgets/app_image.dart';
import '../widgets/smooth_audio_progress_bar.dart';
import '../widgets/queue_bottom_sheet.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';
import '../screens/main_wrapper.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/track.dart';

import '../../core/utils/responsive.dart';
import '../../core/utils/string_utils.dart';
import '../../core/image/lh3_url_builder.dart';

const kPlayerHorizontalPadding = 24.0;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  @override
  Widget build(BuildContext context) {
    return Selector<PlaybackController, Track?>(
      selector: (_, c) => c.currentTrack,
      builder: (context, track, _) {
          if (track == null) return const Scaffold(body: Center(child: Text("No track playing")));

          final screenHeight = MediaQuery.of(context).size.height;
          final screenWidth = MediaQuery.of(context).size.width;
          final safePadding = MediaQuery.of(context).padding;

          // ── Artwork sizing ──
          // Use most of the width minus padding, clamped for tablets
          final contentWidth = screenWidth - 2 * kPlayerHorizontalPadding;
          // Slightly wider artwork — use full content width up to max
          const maxArtworkWidth = 440.0;
          final availableHeight = screenHeight - safePadding.top - safePadding.bottom - 340;
          final maxByHeight = availableHeight * 0.85;
          double artworkSize = contentWidth.clamp(240.0, maxArtworkWidth);
          if (maxByHeight > 200) {
            artworkSize = artworkSize.clamp(240.0, maxByHeight);
          }

          return Scaffold(
            backgroundColor: AppColors.background,
            body: Stack(
              children: [
                // Background Image (Static & Blurred)
                RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AppImage(
                        url: track.artworkUrl,
                        sizePx: Lh3UrlBuilder.headerSize,
                        fit: BoxFit.cover,
                        forceLoad: true,
                      ),
                      BackdropFilter(
                         filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                         child: Container(
                           color: Colors.black.withValues(alpha: 0.55),
                         ),
                       ),
                    ],
                  ),
                ),
                
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: kPlayerHorizontalPadding),
                    child: Column(
                      children: [
                        // ── Header ──
                        SizedBox(
                          height: 52,
                          child: Row(
                            children: [
                              IconButton(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 32)
                              ),
                              const Spacer(),
                              const Text("Now Playing", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.white70)),
                              const Spacer(),
                              OverflowMenu(
                                type: MenuType.track, 
                                track: track,
                                onNavigation: () => Navigator.pop(context), 
                                isNowPlaying: true,
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 8),

                        // ── Artwork ──
                        SizedBox(
                          width: artworkSize,
                          height: artworkSize,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width: artworkSize,
                                height: artworkSize,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.5),
                                      blurRadius: 30,
                                      offset: const Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: AppImage(
                                  url: track.artworkUrl,
                                  sizePx: Lh3UrlBuilder.fullPlayerSize,
                                  width: artworkSize,
                                  height: artworkSize,
                                  fit: BoxFit.cover,
                                  borderRadius: 20,
                                  forceLoad: true,
                                ),
                              ),
                              // Loading overlay
                              Selector<PlaybackController, bool>(
                                selector: (_, c) => c.isLoadingTrack,
                                builder: (_, isLoading, __) => isLoading
                                    ? Container(
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.45),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: const Center(
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 3,
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                        
                        const Spacer(flex: 2),

                        // ── Track Info ──
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                       if (track.albumId.isNotEmpty) {
                                          Navigator.pop(context);
                                          MainWrapper.shellKey.currentState?.navigateTo(
                                             MaterialPageRoute(
                                               builder: (_) => AlbumDetailScreen(
                                                  album: SavedAlbum(
                                                     albumId: track.albumId,
                                                     title: track.albumTitle.isNotEmpty
                                                         ? track.albumTitle
                                                         : '${track.title} Album',
                                                     artworkUrl: track.artworkUrl,
                                                     artistName: track.artistName,
                                                     artistId: track.artistId ?? '',
                                                  ),
                                               ),
                                             ),
                                          );
                                       }
                                    },
                                    child: Text(
                                      track.title, 
                                      style: TextStyle(
                                        fontSize: Responsive.fontSize(context, 24, min: 20, max: 28), 
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ), 
                                      maxLines: 1, 
                                      overflow: TextOverflow.ellipsis
                                    ),
                                  ),
                                   const SizedBox(height: 4),
                                  GestureDetector(
                                     behavior: HitTestBehavior.opaque,
                                     onTap: () {
                                        if (isPlaceholderArtist(track.artistName)) return;
                                        final firstArtist = (track.artists != null && track.artists!.isNotEmpty)
                                            ? track.artists!.first
                                            : null;
                                        final artistId = (firstArtist?['id'] ?? track.artistId ?? '').toString();
                                        final artistName = firstArtist?['name'] ?? track.artistName;
                                        if (artistId.isEmpty) return;
                                        Navigator.pop(context);
                                        MainWrapper.shellKey.currentState?.navigateTo(
                                          MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                                            artistId: artistId,
                                            artistName: artistName,
                                          )),
                                        );
                                     },
                                     child: Text(
                                       track.displayArtist,
                                       style: TextStyle(
                                         fontSize: Responsive.fontSize(context, 16, min: 14, max: 18),
                                         color: AppColors.textSecondary,
                                       ),
                                       maxLines: 1,
                                       overflow: TextOverflow.ellipsis,
                                     ),
                                  ),
                                ],
                              ),
                            ),
                            // Add to Playlist Button
                            IconButton(
                              onPressed: () {
                                showModalBottomSheet(
                                  context: context,
                                  useRootNavigator: true,
                                  isScrollControlled: true,
                                  backgroundColor: Colors.transparent,
                                  builder: (ctx) => AddToPlaylistSheet(tracks: [track]),
                                );
                              },
                              icon: Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white54, width: 1.5),
                                ),
                                child: const Icon(Icons.add, color: Colors.white, size: 18),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Like Button
                            Consumer<LibraryController>(
                              builder: (context, lib, _) {
                                  final isLiked = lib.isLiked(track);
                                  return IconButton(
                                      onPressed: () => lib.toggleLike(track), 
                                      icon: Icon(
                                          isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, 
                                          color: isLiked ? AppColors.primaryEnd : Colors.white,
                                          size: 26,
                                      )
                                  );
                              }
                            )
                          ],
                        ),
                        
                        const SizedBox(height: 20),
                        
                        // ── Progress Bar ──
                        const SmoothAudioProgressBar(), 
                        
                        const SizedBox(height: 16),

                        // ── Controls ──
                        const _PlayerControls(),
                        
                        const Spacer(flex: 1),

                        // ── Lower Actions (device output + queue) ──
                        const _LowerActions(),
                        
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
      }
    );
  }
}

// ── Player Controls ─────────────────────────────────────────────────────────

class _PlayerControls extends StatefulWidget {
  const _PlayerControls();

  @override
  State<_PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<_PlayerControls> {

  @override
  Widget build(BuildContext context) {
    final controller = context.read<PlaybackController>();

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
           // Shuffle
           Selector<PlaybackController, bool>(
             selector: (_, c) => c.isShuffle,
             builder: (_, isShuffle, __) => IconButton(
               icon: Icon(Icons.shuffle, color: isShuffle ? AppColors.primaryEnd : Colors.white54, size: 24),
               onPressed: controller.toggleShuffle,
             ),
           ),
           const SizedBox(width: 12),
           // Prev
           IconButton(
             icon: const Icon(Icons.skip_previous_rounded, size: 40, color: Colors.white),
             onPressed: () => controller.playPrevious(),
           ),
           const SizedBox(width: 8),
           // Play/Pause — scale transition (no rotation)
           Selector<PlaybackController, bool>(
             selector: (_, c) => c.isPlaying,
             builder: (_, isPlaying, __) => GestureDetector(
               onTap: () {
                 controller.togglePlayPause();
               },
               child: AnimatedSwitcher(
                 duration: const Duration(milliseconds: 100),
                 transitionBuilder: (child, animation) {
                   return ScaleTransition(scale: animation, child: child);
                 },
                 child: Icon(
                   isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                   key: ValueKey<bool>(isPlaying),
                   size: 76,
                   color: Colors.white,
                 ),
               ),
             ),
           ),
           const SizedBox(width: 8),
           // Next
           IconButton(
             icon: const Icon(Icons.skip_next_rounded, size: 40, color: Colors.white),
             onPressed: () => controller.playNext(),
           ),
           const SizedBox(width: 12),
           // Loop
           Selector<PlaybackController, LoopMode>(
             selector: (_, c) => c.loopMode,
             builder: (_, loopMode, __) => IconButton(
               icon: Icon(
                   loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                   color: loopMode != LoopMode.off ? AppColors.primaryEnd : Colors.white54,
                   size: 24,
               ),
               onPressed: controller.toggleLoop,
             ),
           ),
        ],
      ),
    );
  }
}

// ── Lower Actions (Device Output + Queue) ───────────────────────────────────

class _LowerActions extends StatelessWidget {
  const _LowerActions();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Device output (placeholder)
          IconButton(
            icon: const Icon(Icons.cast_rounded, size: 18, color: Colors.white38),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Coming soon'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
          // Queue button
          IconButton(
            icon: const Icon(Icons.queue_music_rounded, size: 20, color: Colors.white38),
            onPressed: () => showQueueSheet(context),
          ),
        ],
      ),
    );
  }
}
