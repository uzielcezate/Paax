
import '../../domain/entities/playlist_mutation_result.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:provider/provider.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track.dart';
import '../../core/theme/app_colors.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../state/auth_controller.dart';
import '../state/playlist_detail_controller.dart';
import '../../core/utils/playlist_meta.dart';
import '../../data/repositories/playlist_repository.dart';
import '../../data/remote/playlist_realtime_service.dart';
import '../widgets/playlist_activity_timeline_sheet.dart';
import '../widgets/playlist_collaborators_sheet.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/glass_surface.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/playlist_cover.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/library_headers.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/sort_bottom_sheet.dart';
import '../../core/utils/dominant_color_service.dart';
import '../widgets/app_image.dart';
import '../../core/image/lh3_url_builder.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

/// Height of the fixed Playlist Detail / Edit Order top bar (below the safe
/// area). Single source of truth shared by the bar and the edit-list top inset.
const double kEditOrderBarHeight = 58;

/// Gap between the bottom of the fixed Edit Order bar and the first reorderable
/// row, so the first row never renders under the bar.
const double kEditOrderListGap = 12;

/// Top inset for the reorderable list in Edit Order mode: safe area + the fixed
/// bar height + a gap. Kept as a pure function so the layout invariant (first
/// row below the bar) is unit-testable without mounting the whole screen.
EdgeInsets editOrderListPadding(double safeAreaTop) =>
    EdgeInsets.only(top: safeAreaTop + kEditOrderBarHeight + kEditOrderListGap);

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late ScrollController _scrollController;
  bool _showTitle = false;
  
  // Search & Sort State
  String _searchQuery = "";
  String _currentSort = "Custom";
  final List<String> _sortOptions = ["Custom", "Recently added", "Title", "Artist", "Album", "Oldest added"];

  /// Edit Order mode â€” shows drag handles and remove icons.
  bool _isEditMode = false;

  /// Phase 3.3.6: staged track order while in Edit Order mode. Reordering and
  /// removals mutate ONLY this buffer; nothing is persisted until the user
  /// presses Save (check). Cancelling / back discards it, retaining the last
  /// committed order. Null when not editing.
  List<Track>? _editOrder;

  // Accent color from artwork
  Color _dominantColor = DominantColorService.fallback;

  /// Phase 3.4.1: cloud state (owner/collaborators/followers/last-modified/role)
  /// for this playlist. Created once in didChangeDependencies; no-ops gracefully
  /// for a local (non-cloud) playlist.
  PlaylistDetailController? _cloud;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cloud == null) {
      final auth = context.read<AuthController>();
      _cloud = PlaylistDetailController(
        repository: context.read<PlaylistRepository>(),
        realtime: context.read<PlaylistRealtimeService>(),
        currentUserId: auth.profile?.id,
        playlistId: widget.playlist.id,
        initialOwnerId: widget.playlist.ownerId,
        initialOwnerUsername: widget.playlist.ownerUsername,
        initialVisibility: widget.playlist.visibilityOrDefault,
      );
      // ignore: discarded_futures
      _cloud!.load();
    }
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
    _cloud?.dispose();
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
        filtered.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case "Artist":
        filtered.sort((a, b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
        break;
      case "Album":
        filtered.sort((a, b) => a.albumTitle.toLowerCase().compareTo(b.albumTitle.toLowerCase()));
        break;
      case "Recently added":
        filtered = filtered.reversed.toList();
        break;
      case "Oldest added":
        break;
      case "Custom":
      default:
        break;
    }
    
    return filtered;
  }
  
  /// Open the "Last modified…" activity timeline (Phase 3.4.1.2A): a paginated,
  /// realtime, newest-first history — not just the latest event. Cloud-only.
  Future<void> _openActivitySheet(PlaylistDetailController c) async {
    if (!c.isCloud) return;
    await showPlaylistActivityTimeline(context, c.playlistId);
  }

  /// Non-member "Add to playlist" (spec §9): reuse the current Paax bottom sheet
  /// to create a new playlist from these tracks or add them to an existing one.
  void _openAddToPlaylistSheet(List<Track> tracks) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (context) => AddToPlaylistSheet(tracks: tracks),
    );
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

  /// Membership + order captured when Edit Order OPENED. Diffed against the
  /// staged list on Save so Activity records what actually changed. Nothing is
  /// emitted before Save, and Cancel discards this with the staged copy.
  List<Track>? _editOrderSnapshot;

  void _enterEditMode(List<Track> current) {
    setState(() {
      _isEditMode = true;
      _editOrder = List<Track>.from(current); // staged copy
      _editOrderSnapshot = List<Track>.from(current); // immutable baseline
    });
  }

  /// Cancel / back — discard the staged order AND the snapshot, keeping the
  /// committed order. Emits no activity: nothing was ever committed.
  void _exitEditMode() {
    setState(() {
      _isEditMode = false;
      _editOrder = null;
      _editOrderSnapshot = null;
    });
  }

  /// Save — commit the staged order (normalizes explicit positions + persists).
  Future<void> _saveOrder(LibraryController library, Playlist playlist) async {
    final staged = _editOrder;
    final snapshot = _editOrderSnapshot;
    PlaylistMutationResult? result;
    if (staged != null) {
      // Pass the open-time snapshot so removals/additions are committed through
      // their own RPCs and recorded as tracks_removed / tracks_added, with
      // tracks_reordered only when relative order actually changed.
      result = await library.commitPlaylistOrder(
        playlist,
        staged,
        expectedVersion: (_cloud?.isCloud == true) ? _cloud?.version : null,
        originalOrder: snapshot,
      );
    }
    if (!mounted) return;
    setState(() {
      _isEditMode = false;
      _editOrder = null;
      _editOrderSnapshot = null;
    });
    if (result != null && result != PlaylistMutationResult.applied) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (result) {
          PlaylistMutationResult.queuedOffline =>
            'Saved — will sync when you\'re back online',
          PlaylistMutationResult.conflict =>
            'This playlist changed on another device. Reopen it to see the latest.',
          PlaylistMutationResult.forbidden =>
            'You no longer have permission to edit this playlist',
          _ => 'Couldn\'t save the new order',
        }),
        duration: const Duration(seconds: 3),
      ));
      // ignore: discarded_futures
      if (result == PlaylistMutationResult.conflict) _cloud?.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch library to get updates (e.g. track removed)
    final library = context.watch<LibraryController>();
    // Phase 3.4.1.1 (B): the playlist was deleted (soft) or access was lost —
    // resolve to unavailable and leave (realtime 'deleted' / null authoritative
    // read), never show stale cached content.
    if (_cloud?.isDeleted == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.canPop(context)) Navigator.pop(context);
      });
      return const Scaffold(backgroundColor: Colors.transparent);
    }
    // Prefer the live library copy (reflects local edits); fall back to the
    // entity we were opened with when it is not in the library — e.g. deep-nav
    // from a notification to a pending-invite playlist the user hasn't added
    // yet. Genuine unavailability (soft-delete / lost access) is already handled
    // by the `_cloud.isDeleted` guard above, so a miss here is safe to render.
    Playlist currentPlaylist = widget.playlist;
    for (final p in library.playlists) {
      if (p.id == widget.playlist.id) {
        currentPlaylist = p;
        break;
      }
    }

    final tracks = currentPlaylist.tracks;

    // Processed Tracks
    final displayTracks = _getFilteredTracks(tracks);

    return PopScope(
      // In Edit Order mode, a hardware/gesture back cancels editing (discarding
      // the staged order — committed order retained) instead of leaving the
      // screen, matching the on-screen back button.
      canPop: !_isEditMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isEditMode) _exitEditMode();
      },
      child: Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Scrollable Content ──
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 1. Scrollable Header (Blur Background + Cover + Metadata + Buttons)
              if (!_isEditMode)
                SliverToBoxAdapter(
                  child: Stack(
                    children: [
                      // Solid black base for the entire header to prevent any transparency
                      Positioned.fill(
                        child: Container(color: AppColors.background),
                      ),
                      // 1:1 Atmospheric Clipped Blurred Background
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: MediaQuery.of(context).size.width,
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ImageFiltered(
                                imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45, tileMode: TileMode.decal),
                                child: Transform.scale(
                                  scale: 1.2,
                                  child: AppImage(
                                    url: currentPlaylist.uniqueArtworkUrls.isNotEmpty ? currentPlaylist.uniqueArtworkUrls.first : '',
                                    fit: BoxFit.cover,
                                    sizePx: Lh3UrlBuilder.headerSize,
                                  ),
                                ),
                              ),
                              // Fade directly to black at the bottom of the 1:1 area
                              Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Color(0x99121212),
                                      AppColors.background,
                                    ],
                                    stops: [0.0, 0.6, 1.0],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Foreground Rigid Layout
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Builder(
                          builder: (context) {
                            final double screenWidth = MediaQuery.of(context).size.width;
                            final double topSafeArea = MediaQuery.of(context).padding.top;
                            final double coverSize = screenWidth * 0.54;
                            // Phase 3.3.6: 3-line metadata (title / contributors /
                            // visibility·songs·duration) needs a bit more height.
                            const double textBlockHeight = 100;
                            // Owner fallback: legacy playlists have no stored
                            // owner username → use the current profile.
                            final String? fallbackUsername =
                                context.watch<AuthController>().profile?.username ??
                                    context.read<AuthController>().profile?.displayName;
                            final double targetButtonY = screenWidth + 16;
                            final double currentY = topSafeArea + 16 + coverSize + textBlockHeight + 16; // 16 is bottom gap
                            final double gap = targetButtonY - currentY;
                            final double dynamicGap = gap > 0 ? gap : 0;
                            final bool isLongTitle = currentPlaylist!.name.length > 25;

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Top slot: Cover aligns visually between top icons
                                SizedBox(height: topSafeArea + 16),

                                // Square Foreground Cover Art (Smaller 54% Width)
                                Center(
                                  child: Hero(
                                    tag: "playlist_${currentPlaylist!.id}",
                                    child: Container(
                                      width: coverSize,
                                      height: coverSize,
                                      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withValues(alpha: 0.5),
                                            blurRadius: 20,
                                            offset: const Offset(0, 10),
                                          ),
                                        ],
                                      ),
                                      // PlaylistCover fills this box and applies
                                      // its own single clip (Phase 3.3.6) — no
                                      // redundant outer ClipRRect, no size/parent
                                      // mismatch that used to crop the collage.
                                      child: PlaylistCover(
                                        playlist: currentPlaylist!,
                                        size: coverSize,
                                        borderRadius: 12,
                                      ),
                                    ),
                                  ),
                                ),

                                // Dynamic spacer to enforce exact Y alignment for the buttons
                                SizedBox(height: dynamicGap),

                                // Text Block (Title, Contributors, Metadata).
                                // minHeight (not fixed height) so the 3 lines can
                                // GROW at large system text scale instead of
                                // overflowing the box (accessibility, ui.md).
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                      minHeight: textBlockHeight),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      // Playlist Title
                                      Text(
                                        currentPlaylist!.name,
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: isLongTitle ? 16 : 20,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white,
                                          letterSpacing: -0.5,
                                          height: 1.2,
                                        ),
                                      ),
                                      const SizedBox(height: 4),

                                      // Phase 3.4.1 header (spec §6):
                                      //  Line 1: contributors · Last modified …  (tappable)
                                      //  Line 2: visibility · songs · duration · followers
                                      // Falls back to the local contributor/detail
                                      // line for a not-yet-cloud playlist.
                                      ListenableBuilder(
                                        listenable: _cloud!,
                                        builder: (context, _) {
                                          final c = _cloud!;
                                          final cloud = c.isCloud && c.loaded;
                                          final names = cloud
                                              ? c.contributorNames(fallback: fallbackUsername)
                                              : PlaylistMeta.contributorNames(currentPlaylist!,
                                                  fallbackUsername: fallbackUsername);
                                          final contributors = names.join(', ');
                                          final modified = PlaylistMeta.lastModifiedText(
                                              cloud ? c.lastModifiedAt : null, DateTime.now());
                                          final line1 = [
                                            if (contributors.isNotEmpty) contributors,
                                            if (modified != null) modified,
                                          ].join(PlaylistMeta.separator);
                                          final line2 = PlaylistMeta.statsLine(
                                            visibility: cloud ? c.visibility : currentPlaylist!.visibility,
                                            trackCount: currentPlaylist!.trackCount,
                                            totalDurationSeconds: currentPlaylist.totalDurationSeconds,
                                            followerCount: cloud ? c.followerCount : null,
                                          );
                                          return Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.center,
                                            children: [
                                              if (line1.isNotEmpty) ...[
                                                GestureDetector(
                                                  behavior: HitTestBehavior.opaque,
                                                  // Phase 3.4.1.1 (C): tappable for
                                                  // EVERY cloud playlist (fetches +
                                                  // creation fallback), not just when
                                                  // activity is already loaded.
                                                  onTap: cloud ? () => _openActivitySheet(c) : null,
                                                  child: Text(
                                                    line1,
                                                    textAlign: TextAlign.center,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(height: 2),
                                              ],
                                              Text(
                                                line2,
                                                textAlign: TextAlign.center,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),

                                // Action Buttons Row — role-dependent (Phase 3.4.1
                                // §9). Owner/accepted-collaborator (or a local
                                // playlist) keep the edit row (Shuffle · Pin · Play
                                // · Reorder · Download). A non-member sees
                                // Shuffle · Add-to-playlist · Play · Follow · Download;
                                // Pin moves to the overflow menu.
                                ListenableBuilder(
                                  listenable: _cloud!,
                                  builder: (context, _) {
                                    final c = _cloud!;
                                    // Review M7: deny-by-default from the initial
                                    // owner id (available immediately) — do NOT
                                    // wait for `loaded`, else a non-member/follower
                                    // transiently sees the owner/editor row.
                                    final nonMember = c.isCloud && !c.permissions.isEditorMember;

                                    final shuffle = _buildActionButton(
                                      icon: Icons.shuffle_rounded,
                                      onTap: () {
                                        if (tracks.isNotEmpty) {
                                          final shuffled = List<Track>.from(tracks)..shuffle();
                                          context.read<PlaybackController>().playQueue(shuffled);
                                        }
                                      },
                                    );
                                    final play = Consumer<PlaybackController>(
                                      builder: (context, playback, _) {
                                        final isPlaying = playback.isPlaying;
                                        final currentId = playback.currentTrack?.id;
                                        final isContext = currentId != null && tracks.any((t) => t.id == currentId);
                                        return _buildActionButton(
                                          icon: (isPlaying && isContext)
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          size: 58, iconSize: 28, primary: true,
                                          onTap: () {
                                            if (tracks.isEmpty) return;
                                            if (isContext) {
                                              playback.togglePlayPause();
                                            } else {
                                              playback.playQueue(displayTracks);
                                            }
                                          },
                                        );
                                      },
                                    );
                                    final download = _buildActionButton(
                                      icon: Icons.download_rounded,
                                      onTap: () {},
                                    );

                                    final List<Widget> children;
                                    if (nonMember) {
                                      children = [
                                        shuffle,
                                        // Add to playlist (clone / add-to-existing)
                                        _buildActionButton(
                                          icon: Icons.playlist_add_rounded,
                                          onTap: () => _openAddToPlaylistSheet(tracks),
                                        ),
                                        play,
                                        // Follow / Following
                                        _buildActionButton(
                                          icon: c.isFollowing
                                              ? Icons.bookmark_added_rounded
                                              : Icons.bookmark_add_outlined,
                                          primary: c.isFollowing,
                                          onTap: () => c.toggleFollow(),
                                        ),
                                        download,
                                      ];
                                    } else {
                                      children = [
                                        shuffle,
                                        // Pin (device-local)
                                        Consumer<LibraryController>(
                                          builder: (context, lib, _) {
                                            final isPinned = lib.isPlaylistPinned(currentPlaylist!.id);
                                            return _buildActionButton(
                                              icon: isPinned
                                                  ? Icons.push_pin_rounded
                                                  : Icons.push_pin_outlined,
                                              onTap: () async {
                                                final result = await lib.togglePinPlaylist(currentPlaylist!.id);
                                                if (result == null && mounted) {
                                                  ScaffoldMessenger.of(context).clearSnackBars();
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    const SnackBar(
                                                      content: Text('You can pin up to 5 playlists'),
                                                      duration: Duration(seconds: 2),
                                                      behavior: SnackBarBehavior.floating,
                                                    ),
                                                  );
                                                }
                                              },
                                            );
                                          },
                                        ),
                                        play,
                                        // Reorder (Edit Order)
                                        _buildActionButton(
                                          icon: Icons.swap_vert_rounded,
                                          onTap: tracks.isNotEmpty ? () => _enterEditMode(tracks) : () {},
                                        ),
                                        download,
                                      ];
                                    }
                                    return Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: children,
                                    );
                                  },
                                ),
                                const SizedBox(height: 16),
                                // Pending-invitation prompt (spec §12) — shown to
                                // an invited user viewing the playlist.
                                ListenableBuilder(
                                  listenable: _cloud!,
                                  builder: (context, _) {
                                    if (!_cloud!.myPendingInvite) return const SizedBox.shrink();
                                    return Container(
                                      margin: const EdgeInsets.only(bottom: 12),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.08),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        children: [
                                          const Expanded(
                                            child: Text("You're invited to collaborate",
                                                style: TextStyle(color: Colors.white, fontSize: 13)),
                                          ),
                                          TextButton(
                                            onPressed: () => _cloud!.respondToInvitation(false),
                                            child: const Text('Decline'),
                                          ),
                                          TextButton(
                                            onPressed: () => _cloud!.respondToInvitation(true),
                                            child: const Text('Accept'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

              // Search & Sort Controls (hidden in edit mode)
              if (tracks.isNotEmpty && !_isEditMode)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: SearchSortHeader(
                      currentSort: _currentSort,
                      foregroundColor: Colors.white,
                      onSearchChanged: (val) {
                        setState(() => _searchQuery = val);
                      },
                      onSortPressed: _showSortMenu,
                    ),
                  ),
                ),

              // Track List or Empty States
              if (tracks.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Center(
                      child: Text(
                        "This playlist is empty. Add some songs!",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                )
              else if (displayTracks.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Center(
                      child: Text(
                        "No tracks found.",
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                )
              else if (_isEditMode)
                // ── Edit Mode: ReorderableListView with drag handles + remove icons ──
                SliverToBoxAdapter(
                  child: Padding(
                    // Phase 3.4.1.1 (A): clear the fixed Edit Order top bar
                    // (safe-area + the bar's own height + a normal gap) so the
                    // first reorderable row is fully visible below it. No
                    // device-specific number — composed from the real bar height.
                    padding: editOrderListPadding(MediaQuery.of(context).padding.top),
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      buildDefaultDragHandles: false,
                      onReorder: (oldIndex, newIndex) {
                        // Staged only — nothing persists until Save.
                        setState(() {
                          if (newIndex > oldIndex) newIndex--;
                          final t = _editOrder!.removeAt(oldIndex);
                          _editOrder!.insert(newIndex, t);
                        });
                      },
                      itemCount: (_editOrder ?? const <Track>[]).length,
                      proxyDecorator: (child, index, animation) {
                        return Material(
                          color: Colors.transparent,
                          elevation: 4,
                          shadowColor: Colors.black54,
                          child: child,
                        );
                      },
                      itemBuilder: (context, index) {
                        final track = _editOrder![index];
                        return Container(
                          key: ValueKey('edit_${track.id}_$index'),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Row(
                            children: [
                              // Remove button (staged — commits on Save)
                              IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline_rounded,
                                  color: Colors.redAccent,
                                  size: 22,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _editOrder!.removeWhere((t) => t.id == track.id);
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Removed "${track.title}" — Save to confirm'),
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
                                  foregroundColor: Colors.white,
                                  onTap: () {},
                                ),
                              ),
                              // Drag handle
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: Icon(
                                    Icons.drag_handle_rounded,
                                    color: Colors.white38,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                )
              else
                // ── Normal Mode: Clean list ──
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final track = displayTracks[index];
                      return TrackListTile(
                        track: track,
                        index: index + 1,
                        showArtwork: true,
                        foregroundColor: Colors.white,
                        allowSwipeActions: true,
                        isPlaylistContext: true,
                        // Phase 3.4.4 — enables "Remove from this playlist" in the
                        // SHARED track overflow menu, gated on edit permission so
                        // a follower/read-only viewer never sees it.
                        playlistContext: currentPlaylist,
                        canEditPlaylistContext:
                            _cloud == null || _cloud!.isCloud != true
                                ? true
                                : _cloud!.permissions.isEditorMember,
                        onRemoveFromPlaylist: () {
                          // Same canonical mutation path as the menu action, so
                          // swipe and menu can never diverge.
                          // ignore: discarded_futures
                          library
                              .removeFromPlaylist(currentPlaylist!, track)
                              .then((result) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(switch (result) {
                                PlaylistMutationResult.applied =>
                                  'Removed "${track.title}" from playlist',
                                PlaylistMutationResult.queuedOffline =>
                                  'Removed — will sync when you\'re back online',
                                PlaylistMutationResult.conflict =>
                                  'This playlist changed on another device. Reopen it to see the latest.',
                                PlaylistMutationResult.forbidden =>
                                  'You no longer have permission to edit this playlist',
                                PlaylistMutationResult.failed =>
                                  'Couldn\'t remove that song',
                              }),
                              duration: const Duration(seconds: 3),
                            ));
                          });
                        },
                        onTap: () {
                          context.read<PlaybackController>().playQueue(displayTracks, index: index);
                        },
                      );
                    },
                    childCount: displayTracks.length,
                  ),
                ),

              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
          ),

          // ── 3. Edge Fades for Cinematic Transitions ──
          DynamicEdgeFade.dynamicBottom(
            key: ValueKey('fade_bot_playlist_${widget.playlist.id}'),
            color: AppColors.background,
            height: 120,
          ),

          // ── 4. Clean local top navigation bar ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  color: (_showTitle || _isEditMode) ? AppColors.background : Colors.transparent,
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top,
                  ),
                  child: SizedBox(
                    height: kEditOrderBarHeight,
                    child: Stack(
                      children: [
                        // Left: back button — fixed position
                        Positioned(
                          left: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 24),
                              onPressed: () {
                                if (_isEditMode) {
                                  _exitEditMode();
                                } else {
                                  Navigator.pop(context);
                                }
                              },
                            ),
                          ),
                        ),
                        // Center: title — absolute center, independent of icons
                        Positioned.fill(
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: (_showTitle || _isEditMode) ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 150),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 56),
                                child: Text(
                                  _isEditMode ? 'Edit Order' : currentPlaylist.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Right: menu or check button — fixed position
                        Positioned(
                          right: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _isEditMode
                                ? IconButton(
                                    icon: const Icon(Icons.check_rounded, color: Colors.white, size: 26),
                                    onPressed: () => _saveOrder(library, currentPlaylist!),
                                  )
                                : SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: ListenableBuilder(
                                        listenable: _cloud!,
                                        builder: (context, _) {
                                          final c = _cloud!;
                                          // Role signals (Phase 3.4.1.1 B). A local
                                          // playlist is treated as owner-editable.
                                          final isOwner = !c.isCloud || c.permissions.isOwner;
                                          final canEdit = !c.isCloud || c.permissions.isEditorMember;
                                          final isCollaborator = c.isCloud && canEdit && !isOwner;
                                          return OverflowMenu(
                                            type: MenuType.playlist,
                                            playlist: currentPlaylist,
                                            iconColor: Colors.white,
                                            canManage: canEdit,
                                            isOwner: isOwner,
                                            isFollowing: c.isFollowing,
                                            isPendingInvite: c.myPendingInvite,
                                            onUnfollow: () => c.toggleFollow(),
                                            onAddToPlaylist: () => _openAddToPlaylistSheet(tracks),
                                            onDecline: c.myPendingInvite
                                                ? () => c.respondToInvitation(false)
                                                : null,
                                            onLeave: isCollaborator
                                                ? () => _confirmLeave(context, library, c, currentPlaylist!)
                                                : null,
                                            onManageCollaborators: (c.isCloud && c.permissions.canManageCollaborators)
                                                ? () => showManageCollaboratorsSheet(context, c)
                                                : null,
                                            onEditPrivacy: (c.isCloud && c.permissions.canChangeVisibility)
                                                ? () => _showEditPrivacySheet(context, c)
                                                : null,
                                            onEdit: isOwner
                                                ? () => _showRenameDialog(context, library, currentPlaylist!)
                                                : null,
                                            onDelete: isOwner
                                                ? () => _confirmDelete(context, library, currentPlaylist!)
                                                : null,
                                            onEditOrder: canEdit && tracks.isNotEmpty
                                                ? () => _enterEditMode(tracks)
                                                : null,
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Soft bottom fade overlay
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 45,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        (_showTitle || _isEditMode) ? AppColors.background : Colors.transparent,
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      ), // Scaffold
    ); // PopScope
  }

  /// High-contrast solid circular action button.
  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 46,
    double iconSize = 22,
    bool primary = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary ? Colors.white : Colors.white.withValues(alpha: 0.08),
          border: primary ? null : Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1),
        ),
        child: Center(
          child: Icon(
            icon,
            color: primary ? const Color(0xFF121212) : Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
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
              Navigator.of(dialogContext).pop();
              try {
                // RPC-first: throws on failure WITHOUT removing local state, so a
                // failed delete never diverges local vs cloud (Phase 3.4.1.1 B).
                await library.deletePlaylist(playlist);
                if (screenNavigator.canPop()) screenNavigator.pop();
              } catch (_) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text("Couldn't delete the playlist. Please try again."),
                    behavior: SnackBarBehavior.floating,
                  ));
                }
              }
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// Accepted collaborator leaves the playlist (Phase 3.4.1.1 B).
  void _confirmLeave(BuildContext context, LibraryController library,
      PlaylistDetailController c, Playlist playlist) {
    final screenNavigator = Navigator.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Leave playlist?", style: TextStyle(color: Colors.white)),
        content: Text("You'll lose access to '${playlist.name}'. The playlist itself is not deleted.",
            style: const TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text("Cancel")),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await library.leavePlaylist(playlist.id);
              if (screenNavigator.canPop()) screenNavigator.pop();
            },
            child: const Text("Leave", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  /// Owner-only privacy editor (Phase 3.4.1.1 D): Private / Public, version-
  /// checked cloud RPC with optimistic update + rollback on conflict.
  void _showEditPrivacySheet(BuildContext context, PlaylistDetailController c) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (sheetCtx) {
        Widget option(String value, String label, IconData icon) {
          final selected = c.visibility == value;
          return ListTile(
            leading: Icon(icon, color: Colors.white70),
            title: Text(label, style: const TextStyle(color: Colors.white)),
            trailing: selected ? const Icon(Icons.check_rounded, color: Colors.white) : null,
            onTap: () async {
              Navigator.pop(sheetCtx);
              if (selected) return;
              final err = await c.changeVisibility(value);
              if (err != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
              }
            },
          );
        }
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).padding.bottom + 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Align(alignment: Alignment.centerLeft,
                    child: Text("Playlist privacy", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700))),
              ),
              option('private', 'Private', Icons.lock_outline_rounded),
              option('public', 'Public', Icons.public_rounded),
            ],
          ),
        );
      },
    );
  }
}
