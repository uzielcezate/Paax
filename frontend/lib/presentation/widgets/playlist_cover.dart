import 'package:flutter/material.dart';
import '../../domain/entities/playlist.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';

class PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final double size;
  final double borderRadius;

  const PlaylistCover({
    super.key,
    required this.playlist,
    this.size = 56,
    this.borderRadius = 8,
  });

  @override
  Widget build(BuildContext context) {
    if (playlist.tracks.isEmpty) {
      return _buildPlaceholder();
    }

    final uniqueUrls = playlist.uniqueArtworkUrls;
    
    // 1 Track or Single Valid Cover -> Full Image
    if (uniqueUrls.length == 1) {
      return _buildSingleImage(uniqueUrls.first);
    }
    
    // Empty URLs (tracks exist but no artwork)
    if (uniqueUrls.isEmpty) {
      return _buildPlaceholder();
    }

    // 2+ Tracks -> tight 2x2 Collage (no gaps)
    List<String> collageUrls = [];
    if (uniqueUrls.length >= 4) {
      collageUrls = uniqueUrls.take(4).toList();
    } else {
      collageUrls.addAll(uniqueUrls);
      while (collageUrls.length < 4) {
        collageUrls.add(uniqueUrls.last);
      }
    }

    final half = size / 2;
    final imgSize = size > 100 ? Lh3UrlBuilder.headerSize : Lh3UrlBuilder.miniPlayerSize;

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 0,
          children: [
            SizedBox(
              height: half,
              child: Row(
                spacing: 0,
                children: [
                  _tile(collageUrls[0], half, imgSize),
                  _tile(collageUrls[1], half, imgSize),
                ],
              ),
            ),
            SizedBox(
              height: half,
              child: Row(
                spacing: 0,
                children: [
                  _tile(collageUrls[2], half, imgSize),
                  _tile(collageUrls[3], half, imgSize),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(String url, double tileSize, int sizePx) {
    return SizedBox(
      width: tileSize,
      height: tileSize,
      child: AppImage(
        url: url,
        sizePx: sizePx,
        width: tileSize,
        height: tileSize,
        fit: BoxFit.cover,
      ),
    );
  }

  Widget _buildPlaceholder() {
    final baseColor = Color(playlist.coverColor ?? 0xFF2A2A2E);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            baseColor,
            Color.lerp(baseColor, Colors.black, 0.4)!,
          ],
        ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: Colors.white.withOpacity(0.06),
          width: 1,
        ),
      ),
      child: Icon(Icons.music_note_rounded, color: Colors.white24, size: size * 0.4),
    );
  }

  Widget _buildSingleImage(String url) {
    return AppImage(
      url: url,
      sizePx: size > 100 ? Lh3UrlBuilder.headerSize : Lh3UrlBuilder.listSize,
      width: size,
      height: size,
      borderRadius: borderRadius,
      fit: BoxFit.cover,
    );
  }
}
