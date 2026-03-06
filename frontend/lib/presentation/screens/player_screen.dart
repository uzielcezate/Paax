import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';

import '../widgets/overflow_menu.dart';
import '../widgets/app_image.dart';
import '../widgets/smooth_audio_progress_bar.dart';
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

          return Scaffold(
            backgroundColor: AppColors.background,
            body: Stack(
              children: [
                // Background Image (Static & Blurred) - Wrapped in RepaintBoundary
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
                           color: Colors.black.withOpacity(0.6),
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
                        // Header
                        SizedBox(
                          height: 60,
                          child: Row(
                            children: [
                              IconButton(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 32)
                              ),
                              const Spacer(),
                              const Text("Now Playing", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white)),
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
                        
                        // Artwork (Clamped Size, Centered)
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: Responsive.verticalSpacing(context) * 2),
                              child: SizedBox(
                                width: Responsive.artworkSize(context),
                                height: Responsive.artworkSize(context),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    _ArtworkWidget(url: track.artworkUrl),
                                    // Loading overlay while stream URL resolves
                                    Selector<PlaybackController, bool>(
                                      selector: (_, c) => c.isLoadingTrack,
                                      builder: (_, isLoading, __) => isLoading
                                          ? Container(
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(0.45),
                                                borderRadius: BorderRadius.circular(24),
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
                            ),
                          ),
                        ),
                        
                        // Track Info
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  GestureDetector(
                                    onTap: () { 
                                       if (track.albumId.isNotEmpty) {
                                          Navigator.push(context, MaterialPageRoute(
                                             builder: (_) => AlbumDetailScreen(
                                                album: SavedAlbum(
                                                   albumId: track.albumId, 
                                                   title: track.albumTitle.isNotEmpty ? track.albumTitle : track.title + " Album", 
                                                   artworkUrl: track.artworkUrl,
                                                   artistName: track.artistName,
                                                   artistId: track.artistId ?? '',
                                                )
                                             )
                                          ));
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
                                  // Artist(s)
                                  if (track.artists != null && track.artists!.isNotEmpty)
                                     SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                           children: track.artists!.map((artist) {
                                               final isLast = artist == track.artists!.last;
                                               return Row(
                                                  children: [
                                                     GestureDetector(
                                                        onTap: () {
                                                            // Guard against placeholder artist
                                                            if (isPlaceholderArtist(artist['name'])) return;

                                                            if (artist['id'] != null && artist['id']!.isNotEmpty) {
                                                                Navigator.pop(context); // Close Player
                                                                MainWrapper.shellKey.currentState?.navigateTo(
                                                                   MaterialPageRoute(
                                                                      builder: (_) => ArtistDetailScreen(
                                                                          artistId: artist['id']!,
                                                                          artistName: artist['name'] ?? 'Artist',
                                                                          pictureUrl: '', // FIX: Empty to force fetch
                                                                      )
                                                                   )
                                                                );
                                                            }
                                                        },
                                                        child: Text(
                                                            artist['name'] ?? '',
                                                            style: TextStyle(
                                                              fontSize: Responsive.fontSize(context, 18, min: 14, max: 18), 
                                                              color: Colors.white
                                                            ),
                                                        ),
                                                     ),
                                                     if (!isLast)
                                                        Text(" • ", style: TextStyle(
                                                          fontSize: Responsive.fontSize(context, 18, min: 14, max: 18), 
                                                          color: Colors.white
                                                        )),
                                                  ],
                                               );
                                           }).toList(),
                                        ),
                                     )
                                  else
                                    GestureDetector(
                                       onTap: () { 
                                          // Guard against placeholder artist
                                          if (isPlaceholderArtist(track.artistName)) return;

                                          if (track.artistId != null && track.artistId!.isNotEmpty) {
                                              Navigator.pop(context); // Close Player
                                              MainWrapper.shellKey.currentState?.navigateTo(
                                                 MaterialPageRoute(
                                                   builder: (_) => ArtistDetailScreen(
                                                      artistId: track.artistId!,
                                                      artistName: track.artistName,
                                                      pictureUrl: '', // FIX: Empty prevents using track artwork
                                                   )
                                                 )
                                              );
                                          }
                                       },
                                       child: Text(
                                         track.artistName, 
                                         style: TextStyle(
                                           fontSize: Responsive.fontSize(context, 18, min: 14, max: 18), 
                                           color: Colors.white
                                         ), 
                                         maxLines: 1, 
                                         overflow: TextOverflow.ellipsis
                                       ),
                                    ),
                                ],
                              ),
                            ),
                            // Like Button (Needs LibraryController)
                            Consumer<LibraryController>(
                              builder: (context, lib, _) {
                                  final isLiked = lib.isLiked(track);
                                  return IconButton(
                                      onPressed: () => lib.toggleLike(track), 
                                      icon: Icon(
                                          isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, 
                                          color: isLiked ? AppColors.primaryEnd : Colors.white
                                      )
                                  );
                              }
                            )
                          ],
                        ),
                        
                        SizedBox(height: Responsive.verticalSpacing(context) * 2),
                        
                        // Progress Bar (Isolated)
                        const SmoothAudioProgressBar(), 
                        
                        SizedBox(height: Responsive.verticalSpacing(context) * 2),
                        
                        // Controls
                        const _PlayerControls(),
                        
                        SizedBox(height: Responsive.verticalSpacing(context) * 3),
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

class _ArtworkWidget extends StatelessWidget {
  final String url;
  const _ArtworkWidget({required this.url});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    
    // Content width = screen width - 2 * horizontal padding (matches progress bar)
    final contentWidth = screenWidth - 2 * kPlayerHorizontalPadding;
    
    // Max artwork width for tablets/web
    const maxArtworkWidth = 480.0;
    
    // Responsive height handling: shrink artwork on short devices
    final availableHeight = screenHeight - 300;
    final maxByHeight = availableHeight * 0.75;
    
    // Final artwork size
    double artworkSize = contentWidth.clamp(200.0, maxArtworkWidth);
    if (maxByHeight > 200) {
      artworkSize = artworkSize.clamp(200.0, maxByHeight);
    }

    return Container(
      width: artworkSize,
      height: artworkSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: AppImage(
        url: url,
        sizePx: Lh3UrlBuilder.fullPlayerSize,
        width: artworkSize,
        height: artworkSize,
        fit: BoxFit.cover,
        borderRadius: 24,
        forceLoad: true,
      ),
    );
  }
}



class _PlayerControls extends StatelessWidget {
  const _PlayerControls();

  @override
  Widget build(BuildContext context) {
    // We use Selector to only rebuild when specific state changes
    final controller = context.read<PlaybackController>();

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
         // Shuffle
         Selector<PlaybackController, bool>(
           selector: (_, c) => c.isShuffle,
           builder: (_, isShuffle, __) => IconButton(
             icon: Icon(Icons.shuffle, color: isShuffle ? AppColors.primaryStart : Colors.white),
             onPressed: controller.toggleShuffle,
           ),
         ),
         // Prev
         IconButton(
           icon: const Icon(Icons.skip_previous_rounded, size: 40),
           onPressed: () => controller.playPrevious(),
         ),
         // Play/Pause
         Container(
           width: 72, height: 72,
           decoration: const BoxDecoration(
             shape: BoxShape.circle,
             gradient: AppColors.primaryGradient,
           ),
           child: Selector<PlaybackController, bool>(
             selector: (_, c) => c.isPlaying,
             builder: (_, isPlaying, __) => IconButton(
               icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40),
               onPressed: () => controller.togglePlayPause(),
             ),
           ),
         ),
         // Next
         IconButton(
           icon: const Icon(Icons.skip_next_rounded, size: 40),
           onPressed: () => controller.playNext(),
         ),
         // Loop
         Selector<PlaybackController, LoopMode>(
           selector: (_, c) => c.loopMode,
           builder: (_, loopMode, __) => IconButton(
             icon: Icon(
                 loopMode == LoopMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                 color: loopMode != LoopMode.off ? AppColors.primaryStart : Colors.white
             ),
             onPressed: controller.toggleLoop,
           ),
         ),
      ],
    );
  }
}
