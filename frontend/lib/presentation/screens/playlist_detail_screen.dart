
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track.dart';
import '../../core/theme/app_colors.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/black_glass_blur_surface.dart';
import '../widgets/bottom_content_padding.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/library_headers.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/sort_bottom_sheet.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late ScrollController _scrollController;
  bool _showTitle = false;
  
  // Search & Sort State
  String _searchQuery = "";
  String _currentSort = "Recently added";
  final List<String> _sortOptions = ["Recently added", "Title", "Artist", "Album"];

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }
  
  void _onScroll() {
    if (_scrollController.hasClients && _scrollController.offset > 240) {
      if (!_showTitle) setState(() => _showTitle = true);
    } else {
      if (_showTitle) setState(() => _showTitle = false);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  // Filter & Sort Logic
  List<Track> _getFilteredTracks(List<Track> tracks) {
    List<Track> filtered = List.from(tracks);
    
    // 1. Filter
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      filtered = filtered.where((t) => 
        t.title.toLowerCase().contains(q) ||
        t.artistName.toLowerCase().contains(q) ||
        t.albumTitle.toLowerCase().contains(q)
      ).toList();
    }
    
    // 2. Sort
    switch (_currentSort) {
      case "Title":
        filtered.sort((a, b) => a.title.compareTo(b.title));
        break;
      case "Artist":
        filtered.sort((a, b) => a.artistName.compareTo(b.artistName));
        break;
      case "Album":
        filtered.sort((a, b) => a.albumTitle.compareTo(b.albumTitle));
        break;
      case "Recently added":
      default:
        // Default is newest first (reverse of original list usually)
        // Assuming 'tracks' is ordered by added date (oldest first or as provided)
        filtered = filtered.reversed.toList(); 
        break;
    }
    
    return filtered;
  }
  
  void _showSortMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (context) => SortBottomSheet(
        options: _sortOptions,
        selectedIndex: _sortOptions.indexOf(_currentSort),
        onSelected: (index) {
          setState(() => _currentSort = _sortOptions[index]);
          Navigator.pop(context);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch library to get updates (e.g. track removed)
    final library = context.watch<LibraryController>();
    // Re-fetch playlist from library to ensure we have latest state
    // If deleted, pop.
    Playlist? currentPlaylist;
    try {
      currentPlaylist = library.playlists.firstWhere((p) => p.id == widget.playlist.id);
    } catch (_) {
      // Playlist was deleted — navigate back on the next frame instead of
      // rendering a blank SizedBox that leaves a dead route on the stack.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
      // Return a neutral scaffold while the pop is pending (never actually shown)
      return const Scaffold(backgroundColor: Colors.transparent);
    }

    final tracks = currentPlaylist.tracks;
    
    // Calculate duration
    int totalDuration = 0;
    for(var t in tracks) {
      totalDuration += t.duration;
    }
    
    // Processed Tracks
    final displayTracks = _getFilteredTracks(tracks);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: Colors.transparent, // Transparent for glass effect
            forceMaterialTransparency: true,
            elevation: 0,
            // Fade-in title on scroll
            title: AnimatedOpacity(
               duration: const Duration(milliseconds: 200),
               opacity: _showTitle ? 1.0 : 0.0,
               child: Text(currentPlaylist.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            leading: IconButton(
               icon: const Icon(Icons.arrow_back, color: Colors.white),
               onPressed: () => Navigator.pop(context),
            ),
            actions: [
               OverflowMenu(
                 type: MenuType.playlist, 
                 playlist: currentPlaylist,
                 onEdit: () => _showRenameDialog(context, library, currentPlaylist!),
                 onDelete: () => _confirmDelete(context, library, currentPlaylist!),
               ),
            ],
            flexibleSpace: Stack(
              fit: StackFit.expand,
              children: [
                FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Full width cover
                        FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: MediaQuery.of(context).size.width,
                            height: MediaQuery.of(context).size.width,
                            child: Hero(
                              tag: "playlist_${currentPlaylist.id}",
                              child: PlaylistCover(
                                playlist: currentPlaylist, 
                                size: MediaQuery.of(context).size.width,
                                borderRadius: 0, 
                              ),
                            ),
                          ),
                        ),
                        
                        // Gradient Overlay
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, AppColors.background.withOpacity(0.1), AppColors.background],
                              stops: const [0.0, 0.7, 1.0]
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  centerTitle: true,
                ),
                
                // Glass Blur Layer (Controlled by Scroll)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: MediaQuery.of(context).padding.top + kToolbarHeight,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _showTitle ? 1.0 : 0.0,
                    child: BlackGlassBlurSurface(
                       height: MediaQuery.of(context).padding.top + kToolbarHeight,
                       width: MediaQuery.of(context).size.width,
                       bottomBorder: true,
                       child: Container(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Header Info & Actions
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
              child: Column(
                children: [
                   Text(
                     currentPlaylist.name,
                     textAlign: TextAlign.center,
                     style: const TextStyle(
                       fontSize: 28, 
                       fontWeight: FontWeight.w800, 
                       height: 1.2,
                       color: Colors.white
                     ),
                     maxLines: 2,
                     overflow: TextOverflow.ellipsis,
                   ),
                   const SizedBox(height: 12),
                   Row(
                     mainAxisAlignment: MainAxisAlignment.center,
                     children: [
                       Text(
                         "${tracks.length} tracks • ${_formatTotalDuration(totalDuration)}",
                         style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
                       ),
                     ],
                   ),
                   const SizedBox(height: 24),
                   
                   // ACTIONS ROW
                   Row(
                     mainAxisAlignment: MainAxisAlignment.center,
                     children: [
                       // Play Button
                       Consumer<PlaybackController>(
                          builder: (context, playback, _) {
                            final isPlaying = playback.isPlaying;
                            final currentId = playback.currentTrack?.id;
                            final isContext = currentId != null && tracks.any((t) => t.id == currentId);
                            
                            return _buildActionButton(
                              icon: (isPlaying && isContext) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              label: (isPlaying && isContext) ? "Pause" : "Play",
                              onTap: () {
                                 if (tracks.isEmpty) return;
                                 if (isContext) {
                                    playback.togglePlayPause();
                                 } else {
                                    // Play sorted list or original?
                                    // Usually play what you see.
                                    playback.playQueue(displayTracks);
                                 }
                              }, 
                              primary: true,
                            );
                          }
                       ),
                       const SizedBox(width: 24),
                       
                       // Add To Button
                       _buildActionButton(
                         icon: Icons.playlist_add_rounded, 
                         label: "Add to",
                         onTap: () {
                            showModalBottomSheet(
                               context: context,
                               useRootNavigator: true,
                               isScrollControlled: true,
                               backgroundColor: Colors.transparent,
                               builder: (context) => AddToPlaylistSheet(tracks: tracks), 
                            );
                         }
                       ),
                     ],
                   ),
                   const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          
          // Search & Sort Controls (Scrollable)
          if (tracks.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: SearchSortHeader(
                  currentSort: _currentSort,
                  onSearchChanged: (val) {
                    setState(() => _searchQuery = val);
                  },
                  onSortPressed: _showSortMenu,
                ),
              ),
            ),

          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Center(child: Text("This playlist is empty. Add some songs!", style: TextStyle(color: Colors.grey))),
              ),
            )
          else if (displayTracks.isEmpty)
             const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32.0),
                child: Center(child: Text("No tracks found.", style: TextStyle(color: Colors.grey))),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final track = displayTracks[index];
                  // Need to know original index? 
                  // TrackListTile just uses 'index' for display.
                  
                  return Dismissible(
                    key: ValueKey(track.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    onDismissed: (_) {
                       library.removeFromPlaylist(currentPlaylist!, track);
                    },
                    child: TrackListTile(
                      track: track,
                      index: index + 1,
                      showArtwork: true,
                      onTap: () {
                         context.read<PlaybackController>().playQueue(displayTracks, index: index);
                      },
                    ),
                  );
                },
                childCount: displayTracks.length,
              ),
            ),
            
          const SliverToBoxAdapter(child: BottomContentPadding()),
        ],
      ),
    );
  }

  Widget _buildActionButton({required IconData icon, required String label, required VoidCallback onTap, bool primary = false, Color color = Colors.white}) {
    return Column(
      children: [
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary ? AppColors.primaryStart : AppColors.surfaceLight,
            gradient: primary ? AppColors.primaryGradient : null,
          ),
          child: IconButton(
            icon: Icon(icon, color: primary ? Colors.white : color),
            onPressed: onTap,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
      ],
    );
  }

  String _formatTotalDuration(int totalSeconds) {
    if (totalSeconds < 3600) return "${totalSeconds ~/ 60} min";
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    return "$hours hr $mins min";
  }

  void _showRenameDialog(BuildContext context, LibraryController library, Playlist playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Rename Playlist", style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryStart)),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                 library.renamePlaylist(playlist, controller.text);
                 Navigator.pop(context);
              }
            },
            child: const Text("Rename", style: TextStyle(color: AppColors.primaryStart)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context, LibraryController library, Playlist playlist) {
    // Capture the detail screen's Navigator BEFORE opening the dialog.
    // The dialog gets its own BuildContext; using that context for Navigator
    // after the dialog is disposed causes errors or pops the wrong route.
    final screenNavigator = Navigator.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Delete Playlist?", style: TextStyle(color: Colors.white)),
        content: Text("Are you sure you want to delete '${playlist.name}'?", style: const TextStyle(color: Colors.grey)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () async {
              // Close dialog first so it's off the stack before we do async work.
              Navigator.of(dialogContext).pop();

              // Await so state is correct before navigation.
              await library.deletePlaylist(playlist);

              // Pop the detail screen.  popUntil is safe even if the screen
              // was already popped by the build() fallback above.
              if (screenNavigator.canPop()) {
                screenNavigator.pop();
              }
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}




