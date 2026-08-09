import '../../domain/entities/playlist.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../../core/image/lh3_url_builder.dart';
import '../widgets/app_image.dart';
import '../widgets/overflow_menu.dart'; 
import '../../core/utils/responsive.dart';
import 'explicit_badge.dart';
import 'add_to_playlist_sheet.dart';

class TrackListTile extends StatelessWidget {
  final Track track;
  final int index;
  final VoidCallback onTap;
  final VoidCallback? onCoverTap; 
  final bool showArtwork;
  /// When true, hides the like button and overflow menu (used in edit mode).
  final bool hideActions;
  /// Foreground color for text/icons — adapts to dynamic backgrounds.
  final Color foregroundColor;

  // ── Swipe configuration ──
  /// Enable swipe-left = Add to Playlist, swipe-right = Add to Queue.
  final bool allowSwipeActions;
  /// When true, swipe-left = Remove from Playlist (red). Overrides add-to-playlist.
  final bool isPlaylistContext;

  /// Phase 3.4.4 — when set, the shared track overflow menu additionally offers
  /// "Remove from this playlist". Threaded through rather than duplicated so
  /// there remains exactly ONE track-action implementation.
  final Playlist? playlistContext;

  /// Whether the current user may edit [playlistContext]. False for followed /
  /// read-only playlists.
  final bool canEditPlaylistContext;
  /// Called when swipe-left remove-from-playlist fires.
  final VoidCallback? onRemoveFromPlaylist;

  /// Phase 3.4.5 — the track is KNOWN but cannot be streamed right now
  /// (offline, and no local/downloaded source). It stays VISIBLE so the user
  /// can still see their library, but is dimmed and non-playable rather than
  /// silently failing on tap. Hiding it would make the library look corrupted;
  /// leaving it enabled would produce a dead tap.
  final bool unavailableOffline;

  const TrackListTile({
    super.key,
    required this.track,
    required this.index,
    required this.onTap,
    this.onCoverTap,
    this.showArtwork = false,
    this.hideActions = false,
    this.foregroundColor = Colors.white,
    this.allowSwipeActions = false,
    this.isPlaylistContext = false,
    this.playlistContext,
    this.canEditPlaylistContext = false,
    this.unavailableOffline = false,
    this.onRemoveFromPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    // Selector: rebuild ONLY when this exact tile's play/current status changes.
    final (isCurrentTrack, isPlaying) =
        context.select<PlaybackController, (bool, bool)>((p) {
      final isCurrent = p.currentTrack?.id == track.id;
      return (isCurrent, isCurrent && p.isPlaying);
    });

    // Hidden state
    final isHidden = context.select<LibraryController, bool>(
      (lib) => lib.isHidden(track.id),
    );

    // Scale sizes — computed once per build (not per frame)
    final fontSizeTitle = Responsive.fontSize(context, 16, min: 14, max: 18);
    final fontSizeSubtitle = Responsive.fontSize(context, 12, min: 11, max: 14);
    final iconSize = Responsive.iconSize(context, base: 20, min: 18, max: 24);

    // Dim for hidden OR unavailable-offline. Both remain VISIBLE — the user's
    // library should never look like it lost content just because the network
    // did. Unavailable-offline is dimmed slightly less than hidden so the two
    // states stay visually distinguishable.
    final tileOpacity = isHidden
        ? 0.38
        : unavailableOffline
            ? 0.45
            : 1.0;

    Widget tile = Opacity(
      opacity: tileOpacity,
      child: Container(
        decoration: BoxDecoration(
          border: isCurrentTrack && !isHidden
              ? Border(
                  top: BorderSide(color: foregroundColor.withValues(alpha: 0.1), width: 0.5),
                  bottom: BorderSide(color: foregroundColor.withValues(alpha: 0.1), width: 0.5),
                )
              : null,
        ),
        child: ListTile(
          contentPadding: EdgeInsets.symmetric(horizontal: Responsive.horizontalPadding(context), vertical: 1),
          leading: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: _buildLeading(context, isCurrentTrack && !isHidden, isPlaying && !isHidden),
            ),
          ),
          title: Row(
            children: [
              if (track.isExplicit)
                ExplicitBadge(foregroundColor: foregroundColor),
              Expanded(
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foregroundColor,
                    fontWeight: isCurrentTrack && !isHidden ? FontWeight.w900 : FontWeight.w800,
                    fontSize: fontSizeTitle,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            track.displayArtist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: foregroundColor.withOpacity(0.6), fontSize: fontSizeSubtitle, fontWeight: FontWeight.w500),
          ),
          trailing: hideActions
              ? null
              : SizedBox(
                  width: 100,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Consumer<LibraryController>(
                        builder: (context, lib, _) => IconButton(
                          icon: Icon(
                            lib.isLiked(track) ? Icons.favorite : Icons.favorite_border,
                            size: iconSize,
                            color: lib.isLiked(track) ? foregroundColor : foregroundColor.withOpacity(0.5),
                          ),
                          onPressed: () => lib.toggleLike(track),
                        ),
                      ),
                       OverflowMenu(
                         type: MenuType.track,
                         track: track,
                         playlistContext: playlistContext,
                         canEditPlaylistContext: canEditPlaylistContext,
                         iconColor: foregroundColor.withOpacity(0.5)),
                    ],
                  ),
                ),
          // A dead tap is worse than a disabled row: an unavailable track
          // cannot start playback, so it is not tappable.
          onTap: (isHidden || unavailableOffline) ? null : onTap,
        ),
      ),
    );

    // Wrap with swipe actions if enabled
    if (allowSwipeActions) {
      tile = _buildSwipeable(context, tile, isHidden);
    }

    return tile;
  }

  Widget _buildSwipeable(BuildContext context, Widget child, bool isHidden) {
    if (isPlaylistContext && onRemoveFromPlaylist != null) {
      // Playlist context: swipe left = remove from playlist
      return Dismissible(
        key: ValueKey('dismiss_${track.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          color: Colors.red,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        onDismissed: (_) => onRemoveFromPlaylist!(),
        child: child,
      );
    }

    // General context: swipe left = Add to Playlist, swipe right = Add to Queue
    return Dismissible(
      key: ValueKey('swipe_${track.id}_$index'),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // Swipe left → Add to Playlist
          if (!context.mounted) return false;
          showModalBottomSheet(
            context: context,
            backgroundColor: Colors.transparent,
            isScrollControlled: true,
            useRootNavigator: true,
            builder: (_) => AddToPlaylistSheet(tracks: [track]),
          );
        } else if (direction == DismissDirection.startToEnd) {
          // Swipe right → Add to Queue
          if (!context.mounted) return false;
          context.read<PlaybackController>().addToQueue(track);
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Added "${track.title}" to queue'),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return false; // Don't remove the item
      },
      background: Container(
        // Swipe right background (queue)
        color: Colors.black,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.queue_music_rounded, color: Colors.white, size: 24),
      ),
      secondaryBackground: Container(
        // Swipe left background (add to playlist)
        color: Colors.black,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.playlist_add_rounded, color: Colors.white, size: 24),
      ),
      child: child,
    );
  }

  Widget _buildLeading(BuildContext context, bool isCurrentTrack, bool isPlaying) {
    if (showArtwork) {
      return GestureDetector(
        onTap: onCoverTap, 
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Stack(
            alignment: Alignment.center,
            children: [
              AppImage(
                url: track.artworkUrl,
                sizePx: Lh3UrlBuilder.listSize,
                width: 48,
                height: 48,
                fit: BoxFit.cover,
              ),
              if (isCurrentTrack)
                Container(
                  color: Colors.black54,
                  child: Icon(
                    isPlaying ? Icons.graphic_eq : Icons.pause, 
                    color: Colors.white,
                    size: 24,
                  ),
                ),
            ],
          ),
        ),
      );
    } else {
      // Numerical Index or Playing Indicator
      if (isCurrentTrack) {
        return Icon(
          isPlaying ? Icons.graphic_eq : Icons.pause, 
          color: foregroundColor,
          size: 20,
        );
      } else {
        return Text(
          "${index + 1}",
          style: TextStyle(
              color: foregroundColor.withOpacity(0.5), 
              fontSize: Responsive.fontSize(context, 14, min: 12, max: 16),
               fontWeight: FontWeight.w600,
          ),
        );
      }
    }
  }
}
