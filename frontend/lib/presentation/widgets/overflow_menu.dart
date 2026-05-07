
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/track.dart';
import 'add_to_playlist_sheet.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/single_track_album_detail.dart';
import '../../core/utils/string_utils.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../screens/artist_detail_screen.dart';
import '../screens/album_detail_screen.dart';
import '../screens/home_screen.dart'; // Import MainWrapper if needed, but it's a circular dep maybe.
import '../screens/main_wrapper.dart'; // To access MainWrapper.shellKey
import 'package:share_plus/share_plus.dart';

// import 'package:share_plus/share_plus.dart'; 
// If share_plus is not available, I will use a placeholder print or snackbar.

enum MenuType { track, album, artist, playlist }

class OverflowMenu extends StatelessWidget {
  final MenuType type;
  final Track? track;
  final SavedAlbum? album;
  final Artist? artist;
  final Playlist? playlist;
  final SingleTrackAlbumDetail? singleDetail;
  final VoidCallback? onDelete; // For playlists
  final VoidCallback? onEdit;   // For playlists
  final VoidCallback? onEditOrder; // For playlist reorder mode
  final bool isNowPlaying; // Flag to enable dynamic current track resolution
  final VoidCallback? onNavigation;
  final Playlist? playlistContext; // When non-null, adds 'Remove from Playlist'
  final Color? iconColor;

  const OverflowMenu({
    super.key,
    required this.type,
    this.track,
    this.album,
    this.artist,
    this.playlist,
    this.singleDetail,
    this.onDelete,
    this.onEdit,
    this.onEditOrder,
    this.onNavigation,
    this.isNowPlaying = false, // Default false
    this.playlistContext,
    this.iconColor,
  });

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true, 
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _MenuContent(
        type: type,
        track: track,
        album: album,
        artist: artist,
        playlist: playlist,
        onDelete: onDelete,
        onEdit: onEdit,
        onEditOrder: onEditOrder,
        parentContext: context,
        onNavigation: onNavigation, 
        isNowPlaying: isNowPlaying,
        playlistContext: playlistContext,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.more_vert_rounded, color: iconColor ?? Colors.white),
      onPressed: () => _showMenu(context),
    );
  }
}

class _MenuContent extends StatelessWidget {
  final MenuType type;
  final Track? track;
  final SavedAlbum? album;
  final Artist? artist;
  final Playlist? playlist;
  final SingleTrackAlbumDetail? singleDetail;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onEditOrder;
  final VoidCallback? onNavigation;
  final bool isNowPlaying;
  final BuildContext parentContext;
  final Playlist? playlistContext;

  const _MenuContent({
    required this.type,
    required this.parentContext,
    this.track,
    this.album,
    this.artist,
    this.playlist,
    this.singleDetail,
    this.onDelete,
    this.onEdit,
    this.onEditOrder,
    this.onNavigation,
    this.isNowPlaying = false,
    this.playlistContext,
  });

  @override
  Widget build(BuildContext context) {
    // Resolve track dynamically if isNowPlaying is true
    Track? effectiveTrack = track;
    if (isNowPlaying) { // Only dynamic if explicitly requested (e.g. from Player)
       final playback = context.watch<PlaybackController>(); // Watch for updates
       if (playback.currentTrack != null) {
          effectiveTrack = playback.currentTrack; 
       }
    }
    // ... rest of build logic using effectiveTrack instead of track
    
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface, 
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05), width: 1)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, effectiveTrack),
            Divider(color: Colors.white.withOpacity(0.1), height: 32),
            ..._buildActions(context, effectiveTrack),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, Track? effectiveTrack) {
    String title = "";
    String subtitle = "";
    String? imageUrl;

    if (type == MenuType.track && effectiveTrack != null) {
      title = effectiveTrack.title;
      subtitle = effectiveTrack.artistName;
      imageUrl = effectiveTrack.artworkUrl;
    // ... rest matches original, just use effectiveTrack instead of track
    } else if (type == MenuType.album) {
      // Handle unified single mode as album
      if (singleDetail != null) {
         title = singleDetail!.title;
         subtitle = singleDetail!.artistName;
         imageUrl = singleDetail!.artworkUrl;
      } else if (album != null) {
         title = album!.title;
         subtitle = album!.artistName;
         imageUrl = album!.artworkUrl;
      }
    } else if (type == MenuType.artist && artist != null) {
      title = artist!.name;
      subtitle = "Artist";
      imageUrl = artist!.picture;
    } else if (type == MenuType.playlist && playlist != null) {
      title = playlist!.name;
      subtitle = "Playlist • ${playlist!.trackIds.length} tracks";
    }

    return ListTile(
      leading: imageUrl != null 
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(imageUrl, width: 48, height: 48, fit: BoxFit.cover,
                errorBuilder: (_,__,___) => Container(color: Colors.grey, width: 48, height: 48, child: const Icon(Icons.music_note)),
              ),
            )
          : Container(
              width: 48, height: 48, 
              decoration: BoxDecoration(color: AppColors.surfaceLight, borderRadius: BorderRadius.circular(4)),
              child: const Icon(Icons.music_note, color: Colors.white54),
            ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  List<Widget> _buildActions(BuildContext context, Track? effectiveTrack) {
    switch (type) {
      case MenuType.track: return _buildTrackActions(context, effectiveTrack);
      case MenuType.album: return _buildAlbumActions(context);
      case MenuType.artist: return _buildArtistActions(context);
      case MenuType.playlist: return _buildPlaylistActions(context);
    }
  }

  List<Widget> _buildTrackActions(BuildContext context, Track? effectiveTrack) {
    if (effectiveTrack == null) return [];
    final lib = context.read<LibraryController>();
    final isLiked = lib.isLiked(effectiveTrack); // Use updated API

    return [
      _actionItem(context, 
        icon: isLiked ? Icons.favorite : Icons.favorite_border,
        label: isLiked ? "Unlike" : "Like",
        color: isLiked ? AppColors.primaryEnd : Colors.white,
        onTap: () {
          lib.toggleLike(effectiveTrack);
          Navigator.pop(context); 
        }
      ),
      _actionItem(context, icon: Icons.playlist_add, label: "Add to Playlist", onTap: () {
        Navigator.pop(context); // Close overflow menu
        showModalBottomSheet(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (context) => AddToPlaylistSheet(tracks: [effectiveTrack]),
        );
      }),
      _actionItem(context, icon: Icons.queue_music, label: "Add to Queue", onTap: () {
        final playback = context.read<PlaybackController>();
        if (playback.currentTrack == null) {
           playback.playTrack(effectiveTrack);
        } else {
           playback.addToQueue(effectiveTrack);
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Added to queue"), duration: Duration(seconds: 2)));
        }
        Navigator.pop(context);
      }),
      _actionItem(context, icon: Icons.album, label: "Go to Album", onTap: () {
        Navigator.pop(context); 
        
        if (effectiveTrack.albumId.isEmpty || effectiveTrack.albumId == '0') {
            if (onNavigation != null) onNavigation!(); 
            ScaffoldMessenger.of(parentContext).showSnackBar(const SnackBar(content: Text("This track does not have a valid album.")));
            return;
        }

        if (onNavigation != null) onNavigation!(); 

        final route = MaterialPageRoute(builder: (_) => AlbumDetailScreen(
             album: SavedAlbum(
               albumId: effectiveTrack.albumId,
               title: effectiveTrack.albumTitle,
               // Don't pass track.artistName here — it's the track's artists
               // (e.g. "DUKI, Judeline"), not the album's artist.
               // The AlbumDetailScreen will resolve the true album artist from the API.
               artistName: '',
               artworkUrl: effectiveTrack.artworkUrl,
               artistId: '',
             )
        ));
        
        if (MainWrapper.shellKey.currentState != null) {
           MainWrapper.shellKey.currentState!.navigateTo(route);
        } else {
           Navigator.push(parentContext, route);
        }
      }),

      if (!isPlaceholderArtist(effectiveTrack.artistName))
      _actionItem(context, icon: Icons.person, label: "Go to Artist", onTap: () {
         // Build valid artist list from track metadata
         final validArtists = (effectiveTrack.artists ?? [])
             .where((a) => (a['id'] ?? '').isNotEmpty && (a['name'] ?? '').isNotEmpty)
             .toList();

         // Fallback: use track-level artistId/artistName if artists list is empty
         if (validArtists.isEmpty) {
           final fallbackId = effectiveTrack.artistId ?? '';
           if (fallbackId.isEmpty) {
             Navigator.pop(context);
             ScaffoldMessenger.of(parentContext).showSnackBar(
               const SnackBar(content: Text("Artist info unavailable")),
             );
             return;
           }
           Navigator.pop(context);
           if (onNavigation != null) onNavigation!();
           _navigateToArtist(fallbackId, effectiveTrack.artistName, effectiveTrack);
           return;
         }

         Navigator.pop(context); // Close overflow sheet
         if (onNavigation != null) onNavigation!();

         if (validArtists.length == 1) {
           // Single artist — route directly
           _navigateToArtist(
             validArtists.first['id']!,
             validArtists.first['name']!,
             effectiveTrack,
           );
         } else {
           // Multiple artists — show selection BottomSheet
           _showArtistPicker(parentContext, validArtists, effectiveTrack);
         }
      }),
      _actionItem(context, icon: Icons.share, label: "Share", onTap: () {
         Navigator.pop(context);
         Share.share('Check out "${effectiveTrack.title}" by ${effectiveTrack.artistName} on Beaty! https://music.youtube.com/watch?v=${effectiveTrack.id}');
      }),
      // Remove from Playlist (only shown when inside a playlist)
      if (playlistContext != null)
        _actionItem(context, icon: Icons.playlist_remove, label: "Remove from Playlist",
          color: Colors.redAccent,
          onTap: () {
            final lib = context.read<LibraryController>();
            lib.removeFromPlaylist(playlistContext!, effectiveTrack);
            Navigator.pop(context);
            ScaffoldMessenger.of(parentContext).showSnackBar(
              const SnackBar(
                content: Text('Removed from playlist'),
                duration: Duration(seconds: 2),
              ),
            );
          },
        ),
    ];
  }

  List<Widget> _buildAlbumActions(BuildContext context) {
    final effectiveAlbumId = album?.albumId ?? singleDetail?.track.albumId ?? '';
    if ((effectiveAlbumId.isEmpty || effectiveAlbumId == '0') && singleDetail == null) return [];
    
    final lib = context.read<LibraryController>();
    final isSaved = lib.isAlbumSaved(effectiveAlbumId);
    
    // For Single Detail treated as Album
    final isSingle = singleDetail != null;
    
    final artistId = album?.artistId ?? singleDetail?.track.artistId;
    final artistName = album?.artistName ?? singleDetail?.track.artistName ?? 'Unknown';

    return [
      if (!isSingle) ...[
         _actionItem(context, icon: Icons.play_arrow, label: "Play Album", onTap: () {
            Navigator.pop(context); 
            if (album != null) {
               final route = MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album!));
               if (MainWrapper.shellKey.currentState != null) {
                  MainWrapper.shellKey.currentState!.navigateTo(route);
               } else {
                  Navigator.push(parentContext, route);
               }
            }
         }),
         _actionItem(context, 
           icon: isSaved ? Icons.bookmark : Icons.bookmark_border,
           label: isSaved ? "Remove from Library" : "Save to Library",
           color: isSaved ? Colors.white : Colors.white,
           onTap: () {
             if (album != null) lib.toggleSaveAlbum(album!);
             Navigator.pop(context);
           }
         ),
      ],
      if (artistId != null && artistId.isNotEmpty && artistId != '0' && !isPlaceholderArtist(artistName))
      _actionItem(context, icon: Icons.person, label: "Go to Artist", onTap: () {
        Navigator.pop(context);
        if (onNavigation != null) onNavigation!();

         final route = MaterialPageRoute(builder: (_) => ArtistDetailScreen(
            artistId: artistId!,
            artistName: artistName,
         ));
         
         if (MainWrapper.shellKey.currentState != null) {
            MainWrapper.shellKey.currentState!.navigateTo(route);
         } else {
            Navigator.push(parentContext, route);
         }
      }),
      _actionItem(context, icon: Icons.share, label: "Share", onTap: () {
        Navigator.pop(context);
        if (effectiveAlbumId.isNotEmpty && effectiveAlbumId != '0') {
            Share.share('Check out "${album?.title ?? singleDetail?.title}" by $artistName on Beaty! https://music.youtube.com/browse/$effectiveAlbumId');
        } else {
             Share.share('Check out "${singleDetail?.title}" by $artistName on Beaty!');
        }
      }),
    ];
  }

  List<Widget> _buildArtistActions(BuildContext context) {
    if (artist == null) return [];
    final lib = context.read<LibraryController>();
    final isFollowed = lib.isArtistFollowed(artist!.id);

    return [
      _actionItem(context, 
        icon: isFollowed ? Icons.check : Icons.person_add_alt,
        label: isFollowed ? "Unfollow" : "Follow",
        color: isFollowed ? Colors.white : Colors.white,
        onTap: () {
           lib.toggleFollowArtist(artist!);
           Navigator.pop(context);
        }
      ),
      _actionItem(context, icon: Icons.share, label: "Share", onTap: () {
         Navigator.pop(context);
         Share.share('Check out ${artist!.name} on Beaty! https://deezer.com/artist/${artist!.id}');
      }),
    ];
  }

  List<Widget> _buildPlaylistActions(BuildContext context) {
    if (playlist == null) return [];
    return [
      _actionItem(context, icon: Icons.play_arrow, label: "Play Playlist", onTap: () {
         Navigator.pop(context);
         // Play playlist logic
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Play playlist not implemented")));
      }),
      if (onEditOrder != null)
        _actionItem(context, icon: Icons.reorder_rounded, label: "Edit Order", onTap: () {
           Navigator.pop(context);
           onEditOrder!();
        }),
      _actionItem(context, icon: Icons.edit, label: "Edit Playlist", onTap: () {
         Navigator.pop(context);
         if (onEdit != null) onEdit!();
      }),
      _actionItem(context, icon: Icons.delete_outline, label: "Delete Playlist", color: Colors.redAccent, onTap: () {
         Navigator.pop(context);
         if (onDelete != null) onDelete!();
      }),
      _actionItem(context, icon: Icons.share, label: "Share", onTap: () {
         Navigator.pop(context);
          Share.share('Check out my playlist "${playlist!.name}" on Beaty!');
      }),
    ];
  }

  Widget _actionItem(BuildContext context, {required IconData icon, required String label, required VoidCallback onTap, Color color = Colors.white}) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color, fontSize: 16)),
      onTap: onTap,
    );
  }

  /// Navigate to an artist profile via the shell navigator (keeps bottom nav)
  /// or falls back to a direct push.
  void _navigateToArtist(String artistId, String artistName, Track? sourceTrack) {
    final route = MaterialPageRoute(
      builder: (_) => ArtistDetailScreen(
        artistId: artistId,
        artistName: artistName,
        sourceTrack: sourceTrack,
      ),
    );
    if (MainWrapper.shellKey.currentState != null) {
      MainWrapper.shellKey.currentState!.navigateTo(route);
    } else {
      Navigator.push(parentContext, route);
    }
  }

  /// Shows a multi-artist selection BottomSheet (Spotify-style).
  void _showArtistPicker(
    BuildContext ctx,
    List<Map<String, String>> artists,
    Track? sourceTrack,
  ) {
    showModalBottomSheet(
      context: ctx,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05), width: 1)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(
                  "Choose Artist",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Divider(color: Colors.white.withOpacity(0.1)),
              ...artists.map((a) => ListTile(
                leading: const Icon(Icons.person_outline, color: Colors.white70),
                title: Text(
                  a['name'] ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx); // Close picker
                  _navigateToArtist(a['id']!, a['name']!, sourceTrack);
                },
              )),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
