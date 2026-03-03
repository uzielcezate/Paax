import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
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

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _selectedIndex = 0;



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text("Your Library",
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),

            // Chip tabs
            LibraryChipTabs(
              selectedIndex: _selectedIndex,
              onTabSelected: (index) => setState(() => _selectedIndex = index),
              tabs: const ["Liked", "Playlists", "Albums", "Artists"],
            ),

            // Body
            Expanded(
              child: IndexedStack(
                index: _selectedIndex,
                children: const [
                  _LikedSongsTab(),
                  _PlaylistsTab(),
                  _SavedAlbumsTab(),
                  _FollowedArtistsTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// LIKED SONGS TAB
// -----------------------------------------------------------------------------
class _LikedSongsTab extends StatefulWidget {
  const _LikedSongsTab();

  @override
  State<_LikedSongsTab> createState() => _LikedSongsTabState();
}

class _LikedSongsTabState extends State<_LikedSongsTab> with AutomaticKeepAliveClientMixin {
  String _searchQuery = "";
  // Sort options: 0=Recents, 1=Title, 2=Artist, 3=Album
  int _sortOption = 0; 

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tracks = context.watch<LibraryController>().likedTracks;

    // Filter & Sort
    var displayedTracks = tracks.where((t) {
      if (_searchQuery.isEmpty) return true;
      return t.title.toLowerCase().contains(_searchQuery.toLowerCase()) || 
             t.artistName.toLowerCase().contains(_searchQuery.toLowerCase());
    }).toList();

    // Sorting logic
    if (_sortOption == 1) { // Title
      displayedTracks.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sortOption == 2) { // Artist
      displayedTracks.sort((a, b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
    } else if (_sortOption == 3) { // Album
      displayedTracks.sort((a, b) => (a.albumTitle ?? "").toLowerCase().compareTo((b.albumTitle ?? "").toLowerCase()));
    } 

    return Column(
      children: [
        SearchSortHeader(
          currentSort: _getSortLabel(_sortOption),
          onSearchChanged: (val) => setState(() => _searchQuery = val),
          onSortPressed: _showSortMenu,
        ),
        
        Expanded(
          child: displayedTracks.isEmpty
            ? (tracks.isEmpty
                ? const Center(child: Text("No liked songs yet.", style: TextStyle(color: AppColors.textSecondary)))
                : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
            : ListView.builder(
                key: const PageStorageKey("LikedSongsList"),
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: BottomContentPadding.bottomHeight(context),
                ),
                itemCount: displayedTracks.length,
                itemBuilder: (context, index) {
                  final track = displayedTracks[index];
                  return TrackListTile(
                    track: track, 
                    index: index,
                    showArtwork: true,
                    onTap: () => context.read<PlaybackController>().playQueue(displayedTracks, index: index),
                    onCoverTap: () => _navigateToDetail(context, track),
                  );
                },
              ),
        ),
      ],
    );
  }

  String _getSortLabel(int option) {
    switch (option) {
      case 1: return "Title";
      case 2: return "Artist";
      case 3: return "Album";
      default: return "Recents";
    }
  }

  void _showSortMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      isScrollControlled: true,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (context) => SortBottomSheet(
        options: const ["Recently Added", "Title", "Artist", "Album"],
        selectedIndex: _sortOption,
        onSelected: (index) {
          setState(() => _sortOption = index);
          Navigator.pop(context);
        },
      ),
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
  const _PlaylistsTab();

  @override
  State<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends State<_PlaylistsTab> with AutomaticKeepAliveClientMixin {
  String _searchQuery = "";
  int _sortOption = 0; // 0=Recents, 1=Name

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final playlists = context.watch<LibraryController>().playlists;

    var displayed = playlists.where((p) => p.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    if (_sortOption == 1) {
      displayed.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return Column(
      children: [
        SearchSortHeader(
          currentSort: _sortOption == 1 ? "Name" : "Recents",
          onSearchChanged: (val) => setState(() => _searchQuery = val),
          onSortPressed: () {
             showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              useRootNavigator: true,
              isScrollControlled: true,
              barrierColor: Colors.black.withOpacity(0.55),
              builder: (context) => SortBottomSheet(
                options: const ["Recently Added", "Name"],
                selectedIndex: _sortOption,
                onSelected: (index) {
                  setState(() => _sortOption = index);
                  Navigator.pop(context);
                },
              ),
            );
          },
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: InkWell(
            onTap: () => _showCreatePlaylistDialog(context),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [AppColors.primaryStart, AppColors.primaryEnd]),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(color: AppColors.primaryStart.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4))
                ]
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.add_rounded, color: Colors.white, size: 28),
                  SizedBox(width: 8),
                  Text("Create Playlist", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                ],
              ),
            ),
          ),
        ),

        Expanded(
          child: displayed.isEmpty
            ? (playlists.isEmpty && _searchQuery.isEmpty
                ? const Center(child: Text("Create your first playlist.", style: TextStyle(color: AppColors.textSecondary)))
                : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
            : ListView.builder(
                key: const PageStorageKey("PlaylistsList"),
                padding: EdgeInsets.only(
                  bottom: BottomContentPadding.bottomHeight(context),
                ),
                itemCount: displayed.length,
                itemBuilder: (context, index) {
                  final pl = displayed[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: SizedBox(
                      width: 56, 
                      height: 56,
                      child: PlaylistCover(playlist: pl, size: 56),
                    ),
                    title: Text(pl.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: Text("${pl.tracks.length} tracks", style: const TextStyle(color: AppColors.textSecondary)),
                    trailing: OverflowMenu(type: MenuType.playlist, playlist: pl),
                    onTap: () {
                       Navigator.push(context, MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: pl)));
                    },
                  );
                },
              ),
        ),
      ],
    );
  }

  void _showCreatePlaylistDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      useRootNavigator: true, 
      barrierColor: Colors.black.withOpacity(0.55),
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
                hintText: "Playlist Name",
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.primaryStart)),
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: ()=>Navigator.pop(dialogContext), child: const Text("Cancel", style: TextStyle(color: Colors.white70))),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    context.read<LibraryController>().createPlaylist(controller.text);
                    Navigator.pop(dialogContext);
                  }
                }, 
                child: const Text("Create", style: TextStyle(color: AppColors.primaryStart))
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// SAVED ALBUMS TAB
// -----------------------------------------------------------------------------
class _SavedAlbumsTab extends StatefulWidget {
  const _SavedAlbumsTab();

  @override
  State<_SavedAlbumsTab> createState() => _SavedAlbumsTabState();
}

class _SavedAlbumsTabState extends State<_SavedAlbumsTab> with AutomaticKeepAliveClientMixin {
  String _searchQuery = "";
  int _sortOption = 0; // 0=Recents, 1=Title, 2=Artist

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final albums = context.watch<LibraryController>().savedAlbums;
    
    var displayed = albums.where((a) => 
      a.title.toLowerCase().contains(_searchQuery.toLowerCase()) || 
      a.artistName.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();

    if (_sortOption == 1) {
      displayed.sort((a,b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    } else if (_sortOption == 2) {
      displayed.sort((a,b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
    }

    return Column(
      children: [
        SearchSortHeader(
          currentSort: _getSortLabel(_sortOption),
          onSearchChanged: (val) => setState(() => _searchQuery = val),
          onSortPressed: () {
              showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              useRootNavigator: true,
              isScrollControlled: true,
              barrierColor: Colors.black.withOpacity(0.55),
              builder: (context) => SortBottomSheet(
                options: const ["Recently Added", "Title", "Artist"],
                selectedIndex: _sortOption,
                onSelected: (index) {
                  setState(() => _sortOption = index);
                  Navigator.pop(context);
                },
              ),
            );
          },
        ),

        Expanded(
          child: displayed.isEmpty
            ? (albums.isEmpty
                 ? const Center(child: Text("No saved albums.", style: TextStyle(color: AppColors.textSecondary)))
                 : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
            : GridView.builder(
                key: const PageStorageKey("AlbumsGrid"),
                padding: EdgeInsets.fromLTRB(
                  16, 16, 16, BottomContentPadding.bottomHeight(context),
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
                        Text(album.title, maxLines: 1, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        Text(album.artistName, maxLines: 1, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  );
                },
              ),
        ),
      ],
    );
  }

  String _getSortLabel(int option) {
    if (option == 1) return "Title";
    if (option == 2) return "Artist";
    return "Recents";
  }
}

// -----------------------------------------------------------------------------
// FOLLOWED ARTISTS TAB
// -----------------------------------------------------------------------------
class _FollowedArtistsTab extends StatefulWidget {
  const _FollowedArtistsTab();

  @override
  State<_FollowedArtistsTab> createState() => _FollowedArtistsTabState();
}

class _FollowedArtistsTabState extends State<_FollowedArtistsTab> with AutomaticKeepAliveClientMixin {
  String _searchQuery = "";
  int _sortOption = 0; // 0=Recents, 1=Name

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final artists = context.watch<LibraryController>().followedArtists;
    
    var displayed = artists.where((a) => a.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    
    if (_sortOption == 1) {
      displayed.sort((a,b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return Column(
      children: [
        SearchSortHeader(
          currentSort: _sortOption == 1 ? "Name" : "Recents",
          onSearchChanged: (val) => setState(() => _searchQuery = val),
          onSortPressed: () {
             showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              useRootNavigator: true,
              isScrollControlled: true,
              barrierColor: Colors.black.withOpacity(0.55),
              builder: (context) => SortBottomSheet(
                options: const ["Recently Followed", "Name"],
                selectedIndex: _sortOption,
                onSelected: (index) {
                  setState(() => _sortOption = index);
                  Navigator.pop(context);
                },
              ),
            );
          },
        ),
        
        Expanded(
          child: displayed.isEmpty
           ? (artists.isEmpty
              ? const Center(child: Text("No followed artists.", style: TextStyle(color: AppColors.textSecondary)))
              : const Center(child: Text("No results found", style: TextStyle(color: Colors.grey))))
           : GridView.builder(
              key: const PageStorageKey("ArtistsGrid"),
              padding: EdgeInsets.fromLTRB(
                 16, 16, 16, BottomContentPadding.bottomHeight(context),
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
            ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------------
// SORT BOTTOM SHEET
// -----------------------------------------------------------------------------

