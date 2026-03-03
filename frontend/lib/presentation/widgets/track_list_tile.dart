import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import '../widgets/app_image.dart';
import '../widgets/overflow_menu.dart'; 
import '../../core/utils/responsive.dart';

class TrackListTile extends StatelessWidget {
  final Track track;
  final int index;
  final VoidCallback onTap;
  final VoidCallback? onCoverTap; 
  final bool showArtwork;

  const TrackListTile({
    super.key,
    required this.track,
    required this.index,
    required this.onTap,
    this.onCoverTap,
    this.showArtwork = false,
  });

  @override
  Widget build(BuildContext context) {
    // Watch playback state for current track
    final playback = context.watch<PlaybackController>();
    final isCurrentTrack = playback.currentTrack?.id == track.id;
    final isPlaying = isCurrentTrack && playback.isPlaying;
    
    // Scale sizes
    final fontSizeTitle = Responsive.fontSize(context, 16, min: 14, max: 18);
    final fontSizeSubtitle = Responsive.fontSize(context, 12, min: 11, max: 14);
    final iconSize = Responsive.iconSize(context, base: 20, min: 18, max: 24);

    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: Responsive.horizontalPadding(context), vertical: 4),
      leading: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: _buildLeading(context, isCurrentTrack, isPlaying),
        ),
      ),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isCurrentTrack ? AppColors.primaryStart : Colors.white,
          fontWeight: isCurrentTrack ? FontWeight.bold : FontWeight.normal,
          fontSize: fontSizeTitle,
        ),
      ),
      subtitle: Text(
        track.artistName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey, fontSize: fontSizeSubtitle),
      ),
      trailing: SizedBox(
        width: 100, // Fixed width for actions is okay, but could be responsive if needed
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Consumer<LibraryController>(
              builder: (context, lib, _) => IconButton(
                icon: Icon(
                  lib.isLiked(track) ? Icons.favorite : Icons.favorite_border,
                  size: iconSize,
                  color: lib.isLiked(track) ? AppColors.primaryEnd : Colors.white60,
                ),
                onPressed: () => lib.toggleLike(track),
              ),
            ),
             OverflowMenu(type: MenuType.track, track: track),
          ],
        ),
      ),
      onTap: onTap,
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
                    color: AppColors.primaryStart,
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
          color: AppColors.primaryStart,
          size: 20,
        );
      } else {
        return Text(
          "${index + 1}",
          style: TextStyle(
              color: AppColors.textSecondary, 
              fontSize: Responsive.fontSize(context, 14, min: 12, max: 16)
          ),
        );
      }
    }
  }
}
