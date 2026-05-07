
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
import '../widgets/glass_surface.dart';
import '../widgets/bottom_content_padding.dart';
import 'package:share_plus/share_plus.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/library_headers.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/sort_bottom_sheet.dart';
import '../widgets/dynamic_background.dart';
import '../../core/utils/dominant_color_service.dart';

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

  /// Edit Order mode — shows drag handles and remove icons.
  bool _isEditMode = false;

  // Dynamic background state
  Color _dominantColor = DominantColorService.fallback;
  Color _foregroundColor = Colors.white;

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
    // In edit mode, always show the raw track order (no sort/filter)
    if (_isEditMode) return List.from(tracks);

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

  void _enterEditMode() {
    setState(() => _isEditMode = true);
  }

  void _exitEditMode() {
    setState(() => _isEditMode = false);
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
      body: Stack(
        children: [
          // Dynamic ambient background from playlist first track artwork
          DynamicBackground(
            imageUrl: tracks.isNotEmpty ? tracks.first.artworkUrl : null,
            onColorExtracted: (color) {
              if (!mounted) return;
              setState(() {
                _dominantColor = color;
                _foregroundColor = DominantColorService.foregroundOn(color);
              });
            },
          ),

          CustomScrollView(
            controller: _scrollController,
            slivers: [
              SliverAppBar(
                expandedHeight: 320,
                pinned: true,
                backgroundColor: Colors.transparent,
                forceMaterialTransparency: true,
                elevation: 0,
                automaticallyImplyLeading: false,
                leadingWidth: 0,
                leading: const SizedBox.shrink(),
                titleSpacing: 0,
                title: null,
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.pin,
                  background: ClipRect(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
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
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                _dominantColor.withOpacity(0.1),
                                _dominantColor.withOpacity(0.7),
                                _dominantColor,
                              ],
                              stops: const [0.0, 0.5, 0.85, 1.0]
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
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
                     style: TextStyle(
                       fontSize: 28, 
                       fontWeight: FontWeight.w800, 
                       height: 1.2,
                       color: _foregroundColor
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
                         style: TextStyle(color: _foregroundColor.withOpacity(0.5), fontSize: 13, fontWeight: FontWeight.w500),
                       ),
                     ],
                   ),
                   const SizedBox(height: 24),
                   
                   // ACTIONS ROW — hidden in edit mode
                   if (!_isEditMode)
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
                   if (!_isEditMode) const SizedBox(height: 16),
                ],
              ),
            ),
          ),
          
          // Search & Sort Controls — hidden in edit mode
          if (tracks.isNotEmpty && !_isEditMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: SearchSortHeader(
                  currentSort: _currentSort,
                  foregroundColor: _foregroundColor,
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
          else if (_isEditMode)
            // ── Edit Mode: ReorderableListView with drag handles + remove icons ──
            SliverToBoxAdapter(
              child: ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                onReorder: (oldIndex, newIndex) {
                  library.reorderPlaylistTrack(currentPlaylist!, oldIndex, newIndex);
                },
                itemCount: displayTracks.length,
                proxyDecorator: (child, index, animation) {
                  return Material(
                    color: Colors.transparent,
                    elevation: 4,
                    shadowColor: Colors.black54,
                    child: child,
                  );
                },
                itemBuilder: (context, index) {
                  final track = displayTracks[index];
                  return Container(
                    key: ValueKey('edit_${track.id}_$index'),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      children: [
                        // Remove button
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline_rounded,
                            color: Colors.redAccent, size: 22),
                          onPressed: () {
                            library.removeFromPlaylist(currentPlaylist!, track);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Removed "${track.title}" from playlist'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          },
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                        ),
                        // Track info
                        Expanded(
                          child: TrackListTile(
                            track: track,
                            index: index + 1,
                            showArtwork: true,
                            hideActions: true,
                            foregroundColor: _foregroundColor,
                            onTap: () {},
                          ),
                        ),
                        // Drag handle
                        ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Icon(Icons.drag_handle_rounded,
                              color: Colors.white38, size: 24),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            // ── Normal Mode: clean list, no drag handles ──
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final track = displayTracks[index];
                  return Dismissible(
                    key: ValueKey('dismiss_${track.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    onDismissed: (_) {
                       library.removeFromPlaylist(currentPlaylist!, track);
                       ScaffoldMessenger.of(context).showSnackBar(
                         SnackBar(
                           content: Text('Removed "${track.title}" from playlist'),
                           duration: const Duration(seconds: 2),
                         ),
                       );
                    },
                    child: TrackListTile(
                      track: track,
                      index: index + 1,
                      showArtwork: true,
                      foregroundColor: _foregroundColor,
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

      // Top fade gradient — matches dominant background color
      TopFadeGradient(color: _dominantColor),

      // Floating controls
      FloatingTopControls(
        showScrolledPill: _showTitle,
        topPadding: MediaQuery.of(context).padding.top,
        defaultControls: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!_isEditMode)
              GlassCircleButton(
                icon: Icons.arrow_back_ios_new,
                iconSize: 18,
                iconColor: _foregroundColor,
                onPressed: () => Navigator.pop(context),
              )
            else
              const SizedBox(width: 38),
            if (_isEditMode)
              GestureDetector(
                onTap: _exitEditMode,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.07),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.14), width: 0.5),
                  ),
                  child: Text('Done', style: TextStyle(color: _foregroundColor, fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              )
            else
              GlassMenuButton(
                child: OverflowMenu(
                  type: MenuType.playlist,
                  playlist: currentPlaylist,
                  iconColor: _foregroundColor,
                  onEdit: () => _showRenameDialog(context, library, currentPlaylist!),
                  onDelete: () => _confirmDelete(context, library, currentPlaylist!),
                  onEditOrder: tracks.isNotEmpty ? _enterEditMode : null,
                ),
              ),
          ],
        ),
        scrolledPill: ScrolledTopPill(
          title: _isEditMode ? 'Edit Order' : currentPlaylist.name,
          foregroundColor: _foregroundColor,
          onBack: () {
            if (_isEditMode) {
              _exitEditMode();
            } else {
              Navigator.pop(context);
            }
          },
          trailing: _isEditMode
              ? GestureDetector(
                  onTap: _exitEditMode,
                  child: Text('Done', style: TextStyle(color: _foregroundColor, fontWeight: FontWeight.bold, fontSize: 14)),
                )
              : OverflowMenu(
                  type: MenuType.playlist,
                  playlist: currentPlaylist,
                  iconColor: _foregroundColor,
                  onEdit: () => _showRenameDialog(context, library, currentPlaylist!),
                  onDelete: () => _confirmDelete(context, library, currentPlaylist!),
                  onEditOrder: tracks.isNotEmpty ? _enterEditMode : null,
                ),
        ),
      ),
        ],
      ),
    );
  }

  Widget _buildActionButton({required IconData icon, required String label, required VoidCallback onTap, bool primary = false, Color color = Colors.white}) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipOval(
            child: BackdropFilter(
              filter: primary ? ImageFilter.blur() : ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary ? _foregroundColor : _foregroundColor.withOpacity(0.12),
                  border: primary ? null : Border.all(color: _foregroundColor.withOpacity(0.15), width: 0.5),
                ),
                child: Icon(icon, color: primary ? _dominantColor : _foregroundColor, size: 26),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: _foregroundColor.withOpacity(0.7), fontSize: 12)),
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
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
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
            child: const Text("Rename", style: TextStyle(color: Colors.white)),
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
