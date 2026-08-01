import 'package:flutter/material.dart';
import '../../domain/entities/playlist.dart';
import '../../core/image/lh3_url_builder.dart';
import 'app_image.dart';

/// Generated playlist cover collage.
///
/// Phase 3.3.6 fix: the collage now FILLS its parent square via
/// `AspectRatio(1)` + `Expanded` quadrants instead of a rigid `SizedBox(size)`
/// with fixed-size tiles. The old fixed grid was clipped whenever the parent box
/// was smaller than [size] (the Playlist Detail header sized its box to
/// `screenWidth * 0.54` but passed `size: 240`), which cropped the right column
/// and bottom row and made the quadrants look uneven. Filling the parent makes
/// each quadrant exactly half the ACTUAL rendered box — a true, even 2x2 grid at
/// any width. One outer border radius is applied once; quadrants are never
/// rounded individually. [size] is now only a resolution/icon hint.
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
    // uniqueArtworkUrls already dedupes and drops empty/invalid URLs, preserving
    // playlist order (so we take the first eligible covers).
    final urls = playlist.uniqueArtworkUrls;

    if (urls.isEmpty) return _buildPlaceholder();
    if (urls.length == 1) return _clip(_fill(_tile(urls.first)));

    final imgSize =
        size > 100 ? Lh3UrlBuilder.headerSize : Lh3UrlBuilder.miniPlayerSize;

    Widget grid;
    if (urls.length == 2) {
      // Balanced 50/50 — two vertical halves.
      grid = Row(children: [
        Expanded(child: _fill(_tile(urls[0], imgSize))),
        Expanded(child: _fill(_tile(urls[1], imgSize))),
      ]);
    } else if (urls.length == 3) {
      // Deterministic balanced layout: left half full-height, right half split.
      grid = Row(children: [
        Expanded(child: _fill(_tile(urls[0], imgSize))),
        Expanded(
          child: Column(children: [
            Expanded(child: _fill(_tile(urls[1], imgSize))),
            Expanded(child: _fill(_tile(urls[2], imgSize))),
          ]),
        ),
      ]);
    } else {
      // 4+ → true 2x2 of the first four eligible covers.
      grid = Column(children: [
        Expanded(
          child: Row(children: [
            Expanded(child: _fill(_tile(urls[0], imgSize))),
            Expanded(child: _fill(_tile(urls[1], imgSize))),
          ]),
        ),
        Expanded(
          child: Row(children: [
            Expanded(child: _fill(_tile(urls[2], imgSize))),
            Expanded(child: _fill(_tile(urls[3], imgSize))),
          ]),
        ),
      ]);
    }

    return _clip(grid);
  }

  /// One outer clip + square aspect, applied once to the whole collage.
  Widget _clip(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: AspectRatio(aspectRatio: 1, child: child),
    );
  }

  /// Force a child to fill its (tight) cell so BoxFit.cover center-crops evenly.
  Widget _fill(Widget child) => SizedBox.expand(child: child);

  Widget _tile(String url, [int? sizePx]) {
    return AppImage(
      url: url,
      sizePx: sizePx ?? (size > 100 ? Lh3UrlBuilder.headerSize : Lh3UrlBuilder.listSize),
      fit: BoxFit.cover, // center-crop by default; never stretches
    );
  }

  Widget _buildPlaceholder() {
    final baseColor = Color(playlist.coverColor ?? 0xFF2A2A2E);
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                baseColor,
                Color.lerp(baseColor, Colors.black, 0.4)!,
              ],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.06),
              width: 1,
            ),
          ),
          child: Icon(Icons.music_note_rounded,
              color: Colors.white24, size: size * 0.4),
        ),
      ),
    );
  }
}
