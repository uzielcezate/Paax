import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../widgets/marquee_text.dart';

import '../widgets/overflow_menu.dart';
import '../widgets/app_image.dart';
import '../widgets/smooth_audio_progress_bar.dart';
import '../widgets/queue_bottom_sheet.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/synced_lyrics_view.dart';
import '../../domain/services/lyrics_service.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';
import '../screens/main_wrapper.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/track.dart';

import '../../core/utils/responsive.dart';
import '../../core/utils/string_utils.dart';
import '../../core/image/lh3_url_builder.dart';

const kPlayerHorizontalPadding = 24.0;

/// Full Player modes
enum PlayerMode { song, lyrics }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double _dragOffset = 0;
  final MarqueeController _marqueeSync = MarqueeController();
  PlayerMode _mode = PlayerMode.song;
  bool _lyricsExpanded = false;

  // ── Lyrics state ──
  final LyricsService _lyricsService = LyricsService();
  List<LyricLine> _currentLyrics = [];
  bool _lyricsLoading = false;
  bool _lyricsAvailable = true;
  bool _lyricsAreSynced = false;
  String? _loadedLyricsForTrackId;

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // Only allow dismiss drag in Song mode
    if (_mode != PlayerMode.song) return;
    if (details.delta.dy > 0 || _dragOffset > 0) {
      setState(() => _dragOffset = (_dragOffset + details.delta.dy).clamp(0, double.infinity));
    }
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_mode != PlayerMode.song) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_dragOffset > 100 || velocity > 700) {
      MainWrapper.shellKey.currentState?.closePlayer();
    } else {
      setState(() => _dragOffset = 0);
    }
  }

  /// Fetch lyrics for the given track if not already loaded.
  void _fetchLyricsIfNeeded(Track track) {
    if (_loadedLyricsForTrackId == track.id) return; // Already loaded/loading
    _loadedLyricsForTrackId = track.id;

    // Clear previous lyrics immediately
    setState(() {
      _currentLyrics = [];
      _lyricsLoading = true;
      _lyricsAvailable = true;
      _lyricsAreSynced = false;
    });

    _lyricsService.getLyrics(
      track.id,
      title: track.title,
      artist: track.artistName,
      album: track.albumTitle,
      trackDurationMs: track.duration * 1000,
    ).then((result) {
      if (!mounted) return;
      if (_loadedLyricsForTrackId != track.id) return; // Track changed during fetch
      setState(() {
        _currentLyrics = result.lines;
        _lyricsAvailable = result.isAvailable;
        _lyricsAreSynced = result.isSynced;
        _lyricsLoading = false;
      });
    });
  }

  @override
  void dispose() {
    _marqueeSync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Selector<PlaybackController, Track?>(
      selector: (_, c) => c.currentTrack,
      builder: (context, track, _) {
          if (track == null) return const Scaffold(body: Center(child: Text("No track playing")));

          final screenHeight = MediaQuery.of(context).size.height;
          final screenWidth = MediaQuery.of(context).size.width;
          // Use viewPadding — more reliable across OEM Android skins
          final viewPad = MediaQuery.of(context).viewPadding;
          final topInset = viewPad.top > 0 ? viewPad.top : MediaQuery.of(context).padding.top;
          final bottomInset = [viewPad.bottom, MediaQuery.of(context).padding.bottom, 8.0]
              .reduce((a, b) => a > b ? a : b);

          // ── Artwork sizing ──
          // Controls area height: header(52) + info(60) + progress(40) + controls(60) + lower(50) + spacing(~80)
          const controlsReserved = 340.0;
          final contentWidth = screenWidth - 2 * kPlayerHorizontalPadding;
          const maxArtworkWidth = 440.0;
          final availableHeight = screenHeight - topInset - bottomInset - controlsReserved;
          final maxByHeight = availableHeight * 0.85;
          double artworkSize = contentWidth.clamp(240.0, maxArtworkWidth);
          if (maxByHeight > 200) {
            artworkSize = artworkSize.clamp(240.0, maxByHeight);
          }

          final playback = context.read<PlaybackController>();

          // Dismiss progress: 0.0 (idle) → 1.0 (fully dragged)
          final dismissProgress = (_dragOffset / (screenHeight * 0.35)).clamp(0.0, 1.0);

          return GestureDetector(
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: AnimatedContainer(
              duration: _dragOffset == 0
                  ? const Duration(milliseconds: 150)
                  : Duration.zero,
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(0, _dragOffset, 0),
              child: Opacity(
                opacity: (1.0 - dismissProgress * 0.3).clamp(0.6, 1.0),
                child: Scaffold(
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
                          filter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
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
                        // ── Header with mode switcher ──
                        SizedBox(
                          height: 52,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Pill — perfectly centered via Stack
                              _buildModeSwitcher(),
                              // Left: close button
                              Align(
                                alignment: Alignment.centerLeft,
                                child: IconButton(
                                    onPressed: () => MainWrapper.shellKey.currentState?.closePlayer(),
                                    icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white, size: 32)
                                ),
                              ),
                              // Right: overflow menu
                              Align(
                                alignment: Alignment.centerRight,
                                child: OverflowMenu(
                                  type: MenuType.track, 
                                  track: track,
                                  onNavigation: () => MainWrapper.shellKey.currentState?.closePlayer(), 
                                  isNowPlaying: true,
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 8),

                        // ── Content area: Song mode or Lyrics mode ──
                        Expanded(
                          child: _mode == PlayerMode.song
                            ? _buildSongContent(context, track, playback, artworkSize)
                            : _buildLyricsContent(context, track, playback),
                        ),
                        
                        // ── Track Info ──
                        _buildTrackInfo(track),
                        
                        SizedBox(height: _lyricsExpanded ? 12 : 20),
                        
                        // ── Progress Bar ──
                        const SmoothAudioProgressBar(), 
                        
                        // ── Controls + Lower — hidden when lyrics expanded ──
                        if (!_lyricsExpanded) ...[
                          const SizedBox(height: 16),
                          const _PlayerControls(),
                          const SizedBox(height: 8),
                          const _LowerActions(),
                          const SizedBox(height: 8),
                        ] else
                          const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
              ),
            ),
          );
      }
    );
  }

  // ── Mode Switcher Pill ──
  Widget _buildModeSwitcher() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildModePill(
            icon: Icons.music_note_rounded,
            mode: PlayerMode.song,
          ),
          _buildModePill(
            label: 'Aa',
            mode: PlayerMode.lyrics,
          ),
        ],
      ),
    );
  }

  Widget _buildModePill({IconData? icon, String? label, required PlayerMode mode}) {
    final isActive = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() {
        _mode = mode;
        // Collapse expanded lyrics when switching to song mode
        if (mode == PlayerMode.song) _lyricsExpanded = false;
      }),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: icon != null
            ? Icon(icon, size: 18, color: isActive ? Colors.white : Colors.white54)
            : Text(
                label!,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isActive ? Colors.white : Colors.white54,
                ),
              ),
      ),
    );
  }

  // ── Song Mode Content (artwork + spacers) ──
  Widget _buildSongContent(BuildContext context, Track track, PlaybackController playback, double artworkSize) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -300) {
          playback.playNext();
        } else if (velocity > 300) {
          playback.playPrevious();
        }
      },
      child: Column(
        children: [
          const Spacer(flex: 1),
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
        ],
      ),
    );
  }

  // ── Lyrics Mode Content ──
  Widget _buildLyricsContent(BuildContext context, Track track, PlaybackController playback) {
    // Trigger lyrics fetch for this track
    _fetchLyricsIfNeeded(track);

    final lyricsBody = GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -300) {
          playback.playNext();
        } else if (velocity > 300) {
          playback.playPrevious();
        }
      },
      child: _lyricsLoading
          ? const Center(
              child: CircularProgressIndicator(
                color: Colors.white24,
                strokeWidth: 2,
              ),
            )
          : !_lyricsAvailable
              ? const Center(
                  child: Text(
                    'Lyrics not available',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              : SyncedLyricsView(
                  lyrics: _currentLyrics,
                  positionNotifier: playback.positionNotifier,
                  isSynced: _lyricsAreSynced,
                  onSeekToLine: _lyricsAreSynced
                      ? (time) { playback.seek(time); }
                      : null,
                ),
    );

    return Column(
      children: [
        Expanded(child: lyricsBody),
        // ── Expand/collapse handle ──
        GestureDetector(
          onTap: () => setState(() => _lyricsExpanded = !_lyricsExpanded),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 4),
                Icon(
                  _lyricsExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Track Info ──
  Widget _buildTrackInfo(Track track) {
    return Row(
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
                      MainWrapper.shellKey.currentState?.closePlayer();
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
                child: MarqueeText(
                  text: track.title, 
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 24, min: 20, max: 28), 
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                  controller: _marqueeSync,
                  prefix: track.isExplicit
                      ? const ExplicitBadge(foregroundColor: Colors.white, scale: 1.1)
                      : null,
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
                    MainWrapper.shellKey.currentState?.closePlayer();
                    MainWrapper.shellKey.currentState?.navigateTo(
                      MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                        artistId: artistId,
                        artistName: artistName,
                      )),
                    );
                 },
                 child: MarqueeText(
                   text: track.displayArtist,
                   style: TextStyle(
                     fontSize: Responsive.fontSize(context, 16, min: 14, max: 18),
                     color: AppColors.textSecondary,
                   ),
                   controller: _marqueeSync,
                 ),
              ),
            ],
          ),
        ),
        // Hide action buttons when lyrics are expanded
        if (!_lyricsExpanded) ...[
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
                        color: isLiked ? Colors.white : Colors.white.withValues(alpha: 0.7),
                        size: 26,
                    )
                );
            }
          ),
        ],
      ],
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
