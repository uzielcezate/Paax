import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../domain/entities/saved_album.dart';
import '../widgets/app_image.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/glass_surface.dart';
import '../../core/utils/string_utils.dart';
import 'album_detail_screen.dart';
import '../../core/utils/dominant_color_service.dart';

/// Full artist discography screen with filter chips.
class ArtistDiscographyScreen extends StatefulWidget {
  final String artistName;
  final List<SavedAlbum> albums;
  final List<SavedAlbum> singles;
  final Color dominantColor;
  final Color foregroundColor;

  const ArtistDiscographyScreen({
    super.key,
    required this.artistName,
    required this.albums,
    required this.singles,
    required this.dominantColor,
    required this.foregroundColor,
  });

  @override
  State<ArtistDiscographyScreen> createState() =>
      _ArtistDiscographyScreenState();
}

class _ArtistDiscographyScreenState extends State<ArtistDiscographyScreen> {
  int _selectedFilter = 0; // 0=All, 1=Albums, 2=Singles & EPs

  static const _filterLabels = ['All', 'Albums', 'Singles & EPs'];

  /// All releases merged and sorted newest → oldest.
  late final List<SavedAlbum> _allReleases;

  /// The single latest release across all types.
  SavedAlbum? _latestRelease;

  @override
  void initState() {
    super.initState();
    _allReleases = [...widget.albums, ...widget.singles]
      ..sort(_compareByYearDesc);
    _latestRelease = _allReleases.isNotEmpty ? _allReleases.first : null;
  }

  int _compareByYearDesc(SavedAlbum a, SavedAlbum b) {
    final ya = int.tryParse(a.releaseDate ?? '') ?? 0;
    final yb = int.tryParse(b.releaseDate ?? '') ?? 0;
    return yb.compareTo(ya);
  }

  List<SavedAlbum> get _filteredReleases {
    switch (_selectedFilter) {
      case 1:
        return widget.albums.toList()..sort(_compareByYearDesc);
      case 2:
        return widget.singles.toList()..sort(_compareByYearDesc);
      default:
        return _allReleases;
    }
  }

  String _displayType(String? type) {
    return displayReleaseType(type);
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    // Pill height (46) + spacing (6+12) + chips height (40) + spacing (12)
    final fixedHeaderHeight = topPadding + 6 + 46 + 12 + 40 + 12;

    return Scaffold(
      backgroundColor: widget.dominantColor,
      body: Stack(
        children: [
          // ── Scrollable content ──────────────────────────────────
          CustomScrollView(
            slivers: [
              // Spacer for fixed header
              SliverToBoxAdapter(child: SizedBox(height: fixedHeaderHeight)),
              // Content
              SliverToBoxAdapter(child: _buildContent()),
              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
          ),

          // ── Top fade gradient — dynamic color, 75% intensity ──
          DynamicEdgeFade.dynamic(
            key: ValueKey('fade_discography_${widget.artistName}'),
            color: widget.dominantColor,
          ),

          // ── Pinned floating controls ──────────────────────────
          Positioned(
            top: topPadding + 6,
            left: 12,
            right: 12,
            child: Column(
              children: [
                // Pill
                ScrolledTopPill(
                  title: 'Discography',
                  foregroundColor: widget.foregroundColor,
                  onBack: () => Navigator.pop(context),
                ),
                const SizedBox(height: 12),
                // Glass-style filter chips with real blur
                Builder(builder: (context) {
                  final isLightBg = DominantColorService.isLight(widget.dominantColor);
                  final chipSelectedColor = isLightBg ? Colors.black : Colors.white;
                  final chipSelectedTextColor = isLightBg ? Colors.white : Colors.black;
                  return SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    children: List.generate(_filterLabels.length, (i) {
                      final selected = _selectedFilter == i;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GlassChip(
                          label: _filterLabels[i],
                          selected: selected,
                          selectedColor: chipSelectedColor,
                          textColor: selected ? chipSelectedTextColor : widget.foregroundColor.withOpacity(0.8),
                          onTap: () => setState(() => _selectedFilter = i),
                        ),
                      );
                    }),
                  ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_selectedFilter == 0) {
      return _buildAllContent();
    }

    final releases = _filteredReleases;

    if (releases.isEmpty) {
      return Center(
        child: Text(
          'No releases',
          style: TextStyle(color: widget.foregroundColor.withOpacity(0.7), fontSize: 15),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.spacing(context),
      ),
      itemCount: releases.length,
      itemBuilder: (context, index) {
        final release = releases[index];
        return _buildReleaseListItem(release, showType: false);
      },
    );
  }

  /// Builds the "All" tab with section headers.
  Widget _buildAllContent() {
    return ListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.spacing(context),
      ),
      children: [
        // Latest Release hero
        if (_latestRelease != null)
          _buildLatestReleaseHero(_latestRelease!),

        // Albums section
        if (widget.albums.isNotEmpty) ...[
          _buildSectionHeader('Albums'),
          ...(widget.albums.toList()..sort(_compareByYearDesc))
              .map((r) => _buildReleaseListItem(r, showType: false)),
        ],

        // Singles & EPs section
        if (widget.singles.isNotEmpty) ...[
          _buildSectionHeader('Singles & EPs'),
          ...(widget.singles.toList()..sort(_compareByYearDesc))
              .map((r) => _buildReleaseListItem(r, showType: false)),
        ],
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: widget.foregroundColor,
        ),
      ),
    );
  }

  Widget _buildLatestReleaseHero(SavedAlbum release) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Latest Release',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: widget.foregroundColor,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _openAlbum(release),
            child: Container(
              decoration: BoxDecoration(
                color: widget.foregroundColor.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(12),
                      bottomLeft: Radius.circular(12),
                    ),
                    child: AppImage(
                      url: release.artworkUrl,
                      sizePx: Lh3UrlBuilder.listSize,
                      width: 120,
                      height: 120,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            release.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: widget.foregroundColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(() {
                            final type = _displayType(release.releaseType);
                            final year = extractYear(release.releaseDate);
                            if (year != null) return '$type \u00B7 $year';
                            return type;
                          }(),
                            style: TextStyle(
                              fontSize: 13,
                              color: widget.foregroundColor.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReleaseListItem(SavedAlbum release, {bool showType = true}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openAlbum(release),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AppImage(
                url: release.artworkUrl,
                sizePx: Lh3UrlBuilder.listSize,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: widget.foregroundColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    () {
                      final year = extractYear(release.releaseDate);
                      if (showType) {
                        final type = _displayType(release.releaseType);
                        if (year != null) return '$type \u00B7 $year';
                        return type;
                      }
                      return year ?? '';
                    }(),
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.foregroundColor.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openAlbum(SavedAlbum release) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(album: release),
      ),
    );
  }
}
