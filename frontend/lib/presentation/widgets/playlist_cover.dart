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

    // 2+ Tracks -> 2x2 Collage
    List<String> collageUrls = [];
    if (uniqueUrls.length >= 4) {
      collageUrls = uniqueUrls.take(4).toList();
    } else {
      collageUrls.addAll(uniqueUrls);
      while (collageUrls.length < 4) {
        collageUrls.add(uniqueUrls.last);
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _mosaicItem(collageUrls[0]), 
                  _mosaicItem(collageUrls[1]),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  _mosaicItem(collageUrls[2]), 
                  _mosaicItem(collageUrls[3]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Color(playlist.coverColor ?? 0xFF37474F),
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Icon(Icons.music_note, color: Colors.white24, size: size * 0.5),
    );
  }

  Widget _buildSingleImage(String url) {
    return AppImage(
      url: url,
      sizePx: Lh3UrlBuilder.listSize,
      width: size,
      height: size,
      borderRadius: borderRadius,
      fit: BoxFit.cover,
    );
  }

  Widget _mosaicItem(String url) {
    final itemSize = size / 2;
    return Expanded(
      child: AppImage(
        url: url,
        sizePx: Lh3UrlBuilder.listSize,
        width: itemSize,
        height: itemSize,
        fit: BoxFit.cover,
      ),
    );
  }
}
