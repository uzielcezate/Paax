import 'dart:ui';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../state/auth_controller.dart';
import '../../core/utils/playlist_meta.dart';
import '../../core/utils/library_layout.dart';
import 'track_detail_screen.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import '../../domain/entities/single_track_album_detail.dart';
import '../../domain/entities/saved_album.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/bottom_content_padding.dart';
import 'playlist_detail_screen.dart';
import '../widgets/library_headers.dart';
import '../widgets/playlist_cover.dart';
import '../../core/image/lh3_url_builder.dart';
import '../widgets/app_image.dart';
import '../widgets/sort_bottom_sheet.dart';
import '../widgets/glass_surface.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _selectedIndex = 0;
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0.0);

  // Phase 3.3.6: the floating header's MEASURED height (title + chips + search,
  // incl. safe area). Content tabs pad their lists by this exact value instead
  // of the old hardcoded `padding.top + 230`, which over-reserved ~80px and left
  // a large blank gap before the first result. Shared across every tab — one
  // source of truth, not a per-tab magic number.
  final GlobalKey _headerKey = GlobalKey();
  final ValueNotifier<double> _headerHeight = ValueNotifier<double>(0.0);

  void _measureHeader() {
    final h = _headerKey.currentContext?.size?.height;
    if (h != null && (h - _headerHeight.value).abs() > 0.5) {
      _headerHeight.value = h;
      // Rebuild so the tabs (which read headerHeight.value in build) re-pad to
      // the measured height — otherwise at large text scale / after rotation the
      // first item can underlap the header until an unrelated rebuild.
      if (mounted) setState(() {});
    }
  }

  // Per-tab search/sort state (lifted from tabs)
  final List<String> _searchQueries = ["", "", "", ""];
  final List<int> _sortOptions = [0, 0, 0, 0];

  // Sort options per tab
  static const List<List<String>> _sortLabelsPerTab = [
    ["Recently Added", "Title", "Artist", "Album"],
    ["Recently Added", "Name"],
    ["Recently Added", "Title", "Artist"],
    ["Recently Followed", "Name"],
  ];

  String _currentSortLabel() {
    final opt = _sortOptions[_selectedIndex];
    final labels = _sortLabelsPerTab[_selectedIndex];
    if (opt >= 0 && opt < labels.length) return labels[opt];
    return labels[0];
  }

  @override
  void dispose() {
    _scrollOffset.dispose();
    _headerHeight.dispose();
    super.dispose();
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withOpacity(0.55),
      barrierDismissible: true,
      builder: (dialogContext) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text("New Playlist", style: TextStyle(color: Colors.white)),
            content: TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Playlist name",
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white)),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel", style: TextStyle(color: Colors.white70))),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    context.read<LibraryController>().createPlaylist(controller.text);
                    Navigator.pop(dialogContext);
                  }
                },
                child: const Text("Create", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSortMenu() {
    final tabIndex = _selectedIndex;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => SortBottomSheet(
        options: _sortLabelsPerTab[tabIndex],
        selectedIndex: _sortOptions[tabIndex],
        onSelected: (index) {
          setState(() => _sortOptions[tabIndex] = index);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Measure the floating header after layout so tabs pad to its real height.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureHeader());

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Content fills entire screen ──
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification) {
                  _scrollOffset.value = notification.metrics.pixels;
                }
                return false;
              },
              child: IndexedStack(
                index: _selectedIndex,
                children: [
                  _LikedSongsTab(searchQuery: _searchQueries[0], sortOption: _sortOptions[0], headerHeight: _headerHeight),
                  _PlaylistsTab(searchQuery: _searchQueries[1], sortOption: _sortOptions[1], headerHeight: _headerHeight),
                  _SavedAlbumsTab(searchQuery: _searchQueries[2], sortOption: _sortOptions[2], headerHeight: _headerHeight),
                  _FollowedArtistsTab(searchQuery: _searchQueries[3], sortOption: _sortOptions[3], headerHeight: _headerHeight),
                ],
              ),
            ),
          ),

          // ── Bottom fade gradient (below header/controls) ──
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Container(
                height: context.read<PlaybackController>().currentTrack != null ? 240 : 160,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      AppColors.background.withValues(alpha: 0.96),
                      AppColors.background.withValues(alpha: 0.65),
                      AppColors.background.withValues(alpha: 0.25),
                      AppColors.background.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 0.35, 0.65, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ── Floating header: title + chips + sort/search + fade tail ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  key: _headerKey,
                  color: AppColors.background,
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Title
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text("Your Library",
                            style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                          ),
                        ),
                        // Chip tabs
                        LibraryChipTabs(
                          selectedIndex: _selectedIndex,
                          onTabSelected: (index) => setState(() => _selectedIndex = index),
                          tabs: const ["Liked", "Playlists", "Albums", "Artists"],
                        ),
                        // Sort/Search row — integrated into top bar
                        SearchSortHeader(
                          currentSort: _currentSortLabel(),
                          onSearchChanged: (val) => setState(() => _searchQueries[_selectedIndex] = val),
                          onSortPressed: _showSortMenu,
                        ),
                      ],
                    ),
                  ),
                ),
                // Scroll-triggered fade tail below controls
                ValueListenableBuilder<double>(
                  valueListenable: _scrollOffset,
                  builder: (_, offset, __) {
                    final fadeOpacity = (offset / 8.0).clamp(0.0, 1.0);
                    return IgnorePointer(
                      child: Opacity(
                        opacity: fadeOpacity,
                        child: Container(
                          height: 45,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                AppColors.background,
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          // ── Floating create playlist FAB — only on Playlists tab ──
          if (_selectedIndex == 1)
            Builder(
              builder: (context) {
                final hasMiniPlayer = context.watch<PlaybackController>().currentTrack != null;
                final safePadding = MediaQuery.of(context).padding.bottom;
                final fabBottom = safePadding + 63 + 8 + (hasMiniPlayer ? 71 : 0);
                return Positioned(
                  right: 16,
                  bottom: fabBottom.toDouble(),
                  child: GestureDetector(
                    onTap: () => _showCreatePlaylistDialog(context),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black38,
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(Icons.add_rounded, color: Color(0xFF121212), size: 24),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}


/// Shared top inset for every Library content list (one source of truth — not a
/// per-tab magic number). Delegates to [LibraryLayout.listTopInset].
double _libraryListTop(BuildContext ctx, double measured) {
  return LibraryLayout.listTopInset(
    safeTop: MediaQuery.of(ctx).padding.top,
    measuredHeader: measured,
  );
}

// -----------------------------------------------------------------------------
// LIKED SONGS TAB
// -----------------------------------------------------------------------------
class _LikedSongsTab extends StatefulWidget {
  final String searchQuery;
  final int sortOption;
  final ValueListenable<double> headerHeight;
  const _LikedSongsTab({required this.searchQuery, required this.sortOption, required this.headerHeight});

  @override
  State<_LikedSongsTab> createState() => _LikedSongsTabState();
}

class _LikedSongsTabState extends State<_LikedSongsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tracks = context.watch<LibraryController>().likedTracks;

    var displayedTracks = tracks.where((t) {
      if (widget.searchQuery.isEmpty) return true;
      return t.title.toLowerCase().contains(widget.searchQuery.toLowerCase()) || 
             t.artistName.toLowerCase().contains(widget.searchQuery.toLowerCase());
    }).toList();

    if (widget.sortOption == 1) {
      displayedTracks.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (widget.sortOption == 2) {
      displayedTracks.sort((a, b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
    } else if (widget.sortOption == 3) {
      displayedTracks.sort((a, b) => (a.albumTitle ?? "").toLowerCase().compareTo((b.albumTitle ?? "").toLowerCase()));
    } 

    return displayedTracks.isEmpty
      ? (tracks.isEmpty
          ? const Center(child: Text("No liked songs yet.", style: TextStyle(color: AppColors.textSecondary)))
          : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
      : ListView.builder(
          key: const PageStorageKey("LikedSongsList"),
          padding: EdgeInsets.only(
            top: _libraryListTop(context, widget.headerHeight.value),
            bottom: BottomContentPadding.bottomHeight(context),
          ),
          itemCount: displayedTracks.length,
          itemBuilder: (context, index) {
            final track = displayedTracks[index];
            return TrackListTile(
              track: track, 
              index: index,
              showArtwork: true,
              allowSwipeActions: true,
              onTap: () => context.read<PlaybackController>().playQueue(displayedTracks, index: index),
              onCoverTap: () => _navigateToDetail(context, track),
            );
          },
        );
  }

  void _navigateToDetail(BuildContext context, dynamic track) {
     if (track.albumId != 0) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(
          album: SavedAlbum(
             albumId: track.albumId, 
             title: track.albumTitle, 
             artistName: track.artistName, 
             artworkUrl: track.artworkUrl
          )
        )));
     } else {
        Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(
          singleDetail: SingleTrackAlbumDetail.fromTrack(track)
        )));
     }
  }
}

// -----------------------------------------------------------------------------
// PLAYLISTS TAB
// -----------------------------------------------------------------------------
class _PlaylistsTab extends StatefulWidget {
  final String searchQuery;
  final int sortOption;
  final ValueListenable<double> headerHeight;
  const _PlaylistsTab({required this.searchQuery, required this.sortOption, required this.headerHeight});

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> with AutomaticKeepAliveClientMixin {

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final library = context.watch<LibraryController>();
    final playlists = library.playlists;

    var filtered = playlists.where((p) => p.name.toLowerCase().contains(widget.searchQuery.toLowerCase())).toList();

    // Separate pinned and unpinned
    final pinned = filtered.where((p) => library.isPlaylistPinned(p.id)).toList();
    final unpinned = filtered.where((p) => !library.isPlaylistPinned(p.id)).toList();

    // Sort pinned by pinnedAt ascending (first pinned = first in list)
    pinned.sort((a, b) => library.pinnedAt(a.id).compareTo(library.pinnedAt(b.id)));

    // Sort unpinned by active sort option
    if (widget.sortOption == 1) {
      unpinned.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    final displayed = [...pinned, ...unpinned];

    return displayed.isEmpty
      ? (playlists.isEmpty && widget.searchQuery.isEmpty
          ? const Center(child: Text("Create your first playlist.", style: TextStyle(color: AppColors.textSecondary)))
          : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
      : ListView.builder(
          key: const PageStorageKey("PlaylistsList"),
          padding: EdgeInsets.only(
            top: _libraryListTop(context, widget.headerHeight.value),
            bottom: BottomContentPadding.bottomHeight(context),
          ),
          itemCount: displayed.length,
          itemBuilder: (context, index) {
            final pl = displayed[index];
            final isPinned = library.isPlaylistPinned(pl.id);
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: SizedBox(
                width: 56, 
                height: 56,
                child: PlaylistCover(playlist: pl, size: 56),
              ),
              title: Row(
                children: [
                  if (isPinned)
                    const Padding(
                      padding: EdgeInsets.only(right: 5),
                      child: Icon(Icons.push_pin_rounded, size: 14, color: Colors.white70),
                    ),
                  Expanded(
                    child: Text(pl.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              subtitle: Builder(builder: (context) {
                final fallback = context.watch<AuthController>().profile?.username ??
                    context.read<AuthController>().profile?.displayName;
                final owner = PlaylistMeta.contributorLine(pl, fallbackUsername: fallback);
                final count = PlaylistMeta.songCount(pl.tracks.length);
                final text = owner.isEmpty ? count : "$owner${PlaylistMeta.separator}$count";
                return Text(text, style: const TextStyle(color: AppColors.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis);
              }),
              trailing: OverflowMenu(
                type: MenuType.playlist,
                playlist: pl,
                iconColor: Colors.white,
                onEdit: () => _showRenamePlaylistDialog(context, pl),
                onDelete: () => _confirmDeletePlaylist(context, pl.id, pl.name),
              ),
              onTap: () {
                 Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: pl)));
              },
            );
          },
        );
  }

  void _showRenamePlaylistDialog(BuildContext context, dynamic playlist) {
    final controller = TextEditingController(text: playlist.name);
    showDialog(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) => Center(
        child: Material(
          type: MaterialType.transparency,
          child: AlertDialog(
            backgroundColor: AppColors.surface,
            title: const Text("Rename Playlist", style: TextStyle(color: Colors.white)),
            content: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Playlist Name",
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text("Cancel", style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    context.read<LibraryController>().renamePlaylist(playlist, controller.text);
                    Navigator.pop(dialogContext);
                  }
                },
                child: const Text("Rename", style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeletePlaylist(BuildContext context, String playlistId, String playlistName) {
    final library = context.read<LibraryController>();
    final playlist = library.playlists.firstWhere((p) => p.id == playlistId);

    showDialog(
      context: context,
      useRootNavigator: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Delete Playlist?", style: TextStyle(color: Colors.white)),
        content: Text(
          "Are you sure you want to delete '$playlistName'?",
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("Cancel", style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop(); // close dialog first
              await library.deletePlaylist(playlist);
            },
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SAVED ALBUMS TAB
// -----------------------------------------------------------------------------
class _SavedAlbumsTab extends StatefulWidget {
  final String searchQuery;
  final int sortOption;
  final ValueListenable<double> headerHeight;
  const _SavedAlbumsTab({required this.searchQuery, required this.sortOption, required this.headerHeight});

  @override
  State<_SavedAlbumsTab> createState() => _SavedAlbumsTabState();
}

class _SavedAlbumsTabState extends State<_SavedAlbumsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final albums = context.watch<LibraryController>().savedAlbums;
    
    var displayed = albums.where((a) => 
      a.title.toLowerCase().contains(widget.searchQuery.toLowerCase()) || 
      a.artistName.toLowerCase().contains(widget.searchQuery.toLowerCase())
    ).toList();

    if (widget.sortOption == 1) {
      displayed.sort((a,b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (widget.sortOption == 2) {
      displayed.sort((a,b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
    }

    return displayed.isEmpty
      ? (albums.isEmpty
           ? const Center(child: Text("No saved albums.", style: TextStyle(color: AppColors.textSecondary)))
           : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
      : GridView.builder(
          key: const PageStorageKey("AlbumsGrid"),
          padding: EdgeInsets.fromLTRB(
            16, _libraryListTop(context, widget.headerHeight.value), 16, BottomContentPadding.bottomHeight(context),
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
             crossAxisCount: 2,
             childAspectRatio: 0.75,
             crossAxisSpacing: 16,
             mainAxisSpacing: 16
          ),
          itemCount: displayed.length,
          itemBuilder: (context, index) {
            final album = displayed[index];
            return GestureDetector(
              onTap: () {
                 Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)));
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppImage(
                      url: album.artworkUrl,
                      sizePx: Lh3UrlBuilder.listSize,
                      borderRadius: 16,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(album.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ],
              ),
            );
          },
        );
  }
}

// -----------------------------------------------------------------------------
// FOLLOWED ARTISTS TAB
// -----------------------------------------------------------------------------
class _FollowedArtistsTab extends StatefulWidget {
  final String searchQuery;
  final int sortOption;
  final ValueListenable<double> headerHeight;
  const _FollowedArtistsTab({required this.searchQuery, required this.sortOption, required this.headerHeight});

  @override
  State<_FollowedArtistsTab> createState() => _FollowedArtistsTabState();
}

class _FollowedArtistsTabState extends State<_FollowedArtistsTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final artists = context.watch<LibraryController>().followedArtists;
    
    var displayed = artists.where((a) => a.name.toLowerCase().contains(widget.searchQuery.toLowerCase())).toList();
    
    if (widget.sortOption == 1) {
      displayed.sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return displayed.isEmpty
     ? (artists.isEmpty
        ? const Center(child: Text("No followed artists.", style: TextStyle(color: AppColors.textSecondary)))
        : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
     : GridView.builder(
        key: const PageStorageKey("ArtistsGrid"),
        padding: EdgeInsets.fromLTRB(
           16, _libraryListTop(context, widget.headerHeight.value), 16, BottomContentPadding.bottomHeight(context),
        ),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
           crossAxisCount: 3,
           childAspectRatio: 0.7,
           crossAxisSpacing: 16,
           mainAxisSpacing: 16
        ),
        itemCount: displayed.length,
        itemBuilder: (context, index) {
          final artist = displayed[index];
          return GestureDetector(
            onTap: () {
               Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                 artistId: artist.id,
                 artistName: artist.name,
                 pictureUrl: artist.picture
               )));
            },
            child: Column(
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: AppImage(
                    url: artist.picture,
                    sizePx: Lh3UrlBuilder.listSize,
                    isCircular: true,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 8),
                Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              ],
            ),
          );
        },
      );
  }
}
