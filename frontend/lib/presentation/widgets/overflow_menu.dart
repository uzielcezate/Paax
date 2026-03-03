
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
  final bool isNowPlaying; // Flag to enable dynamic current track resolution
  final VoidCallback? onNavigation;

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
    this.onNavigation,
    this.isNowPlaying = false, // Default false
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
        parentContext: context,
        onNavigation: onNavigation, 
        isNowPlaying: isNowPlaying,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
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
  final VoidCallback? onNavigation;
  final bool isNowPlaying;
  final BuildContext parentContext;

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
    this.onNavigation,
    this.isNowPlaying = false,
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
    
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A).withOpacity(0.85), 
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
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Added to queue")));
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
               artistName: effectiveTrack.artistName, 
               artworkUrl: effectiveTrack.artworkUrl,
               artistId: effectiveTrack.artistId
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
         Navigator.pop(context); // Close sheet
         if (onNavigation != null) onNavigation!();

         final route = MaterialPageRoute(builder: (_) => ArtistDetailScreen(
            artistId: effectiveTrack.artistId ?? '',
            artistName: effectiveTrack.artistName, 
            sourceTrack: effectiveTrack, 
         ));
         
         if (MainWrapper.shellKey.currentState != null) {
            MainWrapper.shellKey.currentState!.navigateTo(route);
         } else {
            Navigator.push(parentContext, route);
         }
      }),
      _actionItem(context, icon: Icons.share, label: "Share", onTap: () {
         Navigator.pop(context);
         Share.share('Check out "${effectiveTrack.title}" by ${effectiveTrack.artistName} on Beaty! https://music.youtube.com/watch?v=${effectiveTrack.id}');
      }),
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
           color: isSaved ? AppColors.primaryEnd : Colors.white,
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
        color: isFollowed ? AppColors.primaryEnd : Colors.white,
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
}
