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
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0.0);

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
    _scrollController.addListener(() {
      _scrollOffset.value = _scrollController.offset;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  int _compareByYearDesc(SavedAlbum a, SavedAlbum b) =>
      // Date-aware newest-first (exact date > year > title). The old
      // int.tryParse on ISO dates collapsed every dated release to 0 (§5).
      compareReleaseDesc(a.releaseDate, a.title, b.releaseDate, b.title);

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
    // Header: status bar + 6 + title row (40) + 10 + chips (34) + 12
    final fixedHeaderHeight = topPadding + 6 + 40 + 10 + 34 + 12;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Scrollable content ──────────────────────────────────
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // Spacer for fixed header
              SliverToBoxAdapter(child: SizedBox(height: fixedHeaderHeight)),
              // Content
              SliverToBoxAdapter(child: _buildContent()),
              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
          ),

          // Bottom fade — dissolves content behind mini player / nav
          DynamicEdgeFade.dynamicBottom(
            key: ValueKey('fade_bot_discography_${widget.artistName}'),
            color: AppColors.background,
          ),

          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title bar
                Container(
                  color: AppColors.background,
                  padding: EdgeInsets.only(top: topPadding),
                  child: SizedBox(
                    height: 58,
                    child: Stack(
                      children: [
                        Positioned(
                          left: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              icon: Icon(Icons.arrow_back_ios_new_rounded, color: widget.foregroundColor, size: 24),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 56),
                              child: Text(
                                'Discography',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: widget.foregroundColor,
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Filter chips row
                Container(
                  color: AppColors.background,
                  padding: const EdgeInsets.only(left: 16, bottom: 12),
                  child: Builder(builder: (context) {
                    final isLightBg = DominantColorService.isLight(widget.dominantColor);
                    final chipSelectedColor = isLightBg ? Colors.black : Colors.white;
                    final chipSelectedTextColor = isLightBg ? Colors.white : Colors.black;
                    return SizedBox(
                      height: 34,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        children: List.generate(_filterLabels.length, (i) {
                          final selected = _selectedFilter == i;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedFilter = i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: selected ? chipSelectedColor : AppColors.surface,
                                  borderRadius: BorderRadius.circular(17),
                                ),
                                child: Text(
                                  _filterLabels[i],
                                  style: TextStyle(
                                    color: selected ? chipSelectedTextColor : widget.foregroundColor.withOpacity(0.8),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    );
                  }),
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
