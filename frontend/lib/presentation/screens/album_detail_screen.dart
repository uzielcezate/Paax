import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_colors.dart';
import '../widgets/error_state_widget.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/single_track_album_detail.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../widgets/mini_player.dart';
import '../widgets/glass_surface.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/app_image.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../core/utils/string_utils.dart';
import 'artist_detail_screen.dart';
import '../../core/utils/dominant_color_service.dart';

class AlbumDetailScreen extends StatefulWidget {
  final SavedAlbum? album;
  final SingleTrackAlbumDetail? singleDetail;

  const AlbumDetailScreen({super.key, this.album, this.singleDetail})
      : assert(album != null || singleDetail != null,
            'Either album or singleDetail must be provided');

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  final ScrollController _scrollController = ScrollController();

  Future<SavedAlbum>? _detailsFuture; // Now returns updated SavedAlbum
  bool _showTitle = false;
  bool _isNavigatingToArtist = false;

  // Accent color from artwork (used for action buttons)
  Color _dominantColor = DominantColorService.fallback;

  // Resolved from the API â€” takes priority over widget.album fields
  // to fix the context inheritance bug where track.artistName overwrites album artist.
  String? _resolvedArtistName;
  String? _resolvedArtistId;
  List<Map<String, String>>? _resolvedArtists;

  bool get _isSingleMode => widget.singleDetail != null;

  String get _title =>
      _isSingleMode ? widget.singleDetail!.title : widget.album!.title;
  // Prefer building display name from the resolved artists list (e.g. "Anuel AA, Ozuna"),
  // then fall back to the resolved single string, then the widget's initial data.
  String get _artistName {
    if (_resolvedArtists != null && _resolvedArtists!.isNotEmpty) {
      return _resolvedArtists!.map((a) => a['name']).join(', ');
    }
    return _resolvedArtistName ??
        (_isSingleMode
            ? widget.singleDetail!.artistName
            : widget.album!.artistName);
  }

  String get _artworkUrl => _isSingleMode
      ? widget.singleDetail!.artworkUrl
      : widget.album!.artworkUrl;

  /// Build an album with resolved artist data for menus.
  SavedAlbum get _resolvedAlbum => SavedAlbum(
        albumId: widget.album!.albumId,
        title: widget.album!.title,
        artistName: _artistName,
        artworkUrl: widget.album!.artworkUrl,
        artistId: _resolvedArtistId ?? widget.album!.artistId,
        artists: _resolvedArtists ?? widget.album!.artists,
      );

  @override
  void initState() {
    super.initState();
    if (!_isSingleMode) {
      _detailsFuture =
          _repository.getAlbum(widget.album!.albumId).then((album) {
        // Enrich album data with richer metadata from the playback queue.
        // The YouTube Music album API often returns only the primary artist,
        // while the search/play API returns all collaborators.
        final enriched = _enrichFromPlayback(album);

        // Update resolved artist data from the enriched result
        if (mounted) {
          setState(() {
            _resolvedArtistName = enriched.artistName;
            _resolvedArtistId = enriched.artistId;
            _resolvedArtists = enriched.artists;
          });
        }
        // Phase 3.3.4: load authoritative per-track credits from the normalized
        // catalog PROGRESSIVELY (off the album-open path) and update the track
        // subtitles when they arrive — so every album (not just played ones)
        // shows real collaborators, reliably, without slowing the album open.
        _enrichCreditsFromCatalog(enriched);
        return enriched;
      });
    }

    _scrollController.addListener(() {
      final show = _scrollController.offset > 240;
      if (show != _showTitle) {
        setState(() {
          _showTitle = show;
        });
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Background progressive credit enrichment (Phase 3.3.4). Fetches the
  /// authoritative per-track credits from the normalized catalog (one batched
  /// request; keeps each track's playback videoId) and updates the visible
  /// subtitles when they arrive. The repository owns the coverage-aware retry
  /// (it retries only a partially-ingested album, never a not-in-catalog one),
  /// so the screen just awaits one result and applies it once.
  Future<void> _enrichCreditsFromCatalog(SavedAlbum album) async {
    SavedAlbum next;
    try {
      next = await _repository.enrichAlbumCredits(album);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (identical(next, album)) return; // no credits to apply
    setState(() {
      _detailsFuture = Future.value(next);
      _resolvedArtists = next.artists;
    });
  }

  /// Cross-reference album tracks with the playback queue to get richer artist
  /// metadata. The YouTube Music album API often returns only the primary artist,
  /// while the search/play queue contains all collaborators.
  SavedAlbum _enrichFromPlayback(SavedAlbum album) {
    final controller = context.read<PlaybackController>();
    final currentTrack = controller.currentTrack;
    final queue = controller.queue;

    if (album.tracks == null || album.tracks!.isEmpty) return album;

    // Build lookup map: videoId â†’ richest Track from playback queue
    final Map<String, Track> richMap = {};
    for (final t in queue) {
      final existing = richMap[t.id];
      if (existing == null ||
          (t.artists?.length ?? 0) > (existing.artists?.length ?? 0)) {
        richMap[t.id] = t;
      }
    }
    if (currentTrack != null) {
      final existing = richMap[currentTrack.id];
      if (existing == null ||
          (currentTrack.artists?.length ?? 0) >
              (existing.artists?.length ?? 0)) {
        richMap[currentTrack.id] = currentTrack;
      }
    }

    // Enrich each album track with richer artist data from the queue
    final enrichedTracks = album.tracks!.map((t) {
      final rich = richMap[t.id];
      if (rich != null &&
          (rich.artists?.length ?? 0) > (t.artists?.length ?? 0)) {
        // Keep album-level fields (albumId, albumTitle, artwork), but adopt richer artists
        return t.copyWith(
          artistName: rich.displayArtist,
          artistId: rich.artistId,
          artists: rich.artists,
        );
      }
      return t;
    }).toList();

    return SavedAlbum(
      albumId: album.albumId,
      title: album.title,
      artistName: album.artistName,
      artistId: album.artistId ?? '',
      artworkUrl: album.artworkUrl,
      tracks: enrichedTracks,
      duration: album.duration,
      trackCount: album.trackCount,
      releaseDate: album.releaseDate,
      label: album.label,
      artists: album.artists,
    );
  }

  /// Enrich a single track with richer artist data from the playback queue.
  Track _enrichTrackFromPlayback(Track track) {
    final controller = context.read<PlaybackController>();
    final currentTrack = controller.currentTrack;

    // Check if current playing track IS this track (same videoId)
    if (currentTrack != null && currentTrack.id == track.id) {
      if ((currentTrack.artists?.length ?? 0) > (track.artists?.length ?? 0)) {
        return track.copyWith(
          artistName: currentTrack.displayArtist,
          artistId: currentTrack.artistId,
          artists: currentTrack.artists,
        );
      }
    }

    // Also check the queue
    for (final q in controller.queue) {
      if (q.id == track.id &&
          (q.artists?.length ?? 0) > (track.artists?.length ?? 0)) {
        return track.copyWith(
          artistName: q.displayArtist,
          artistId: q.artistId,
          artists: q.artists,
        );
      }
    }

    return track;
  }

  @override
  Widget build(BuildContext context) {
    if (_isSingleMode) {
      // Enrich the single's track from playback for richer artist data
      final enrichedTrack =
          _enrichTrackFromPlayback(widget.singleDetail!.track);

      // Update resolved artists if the enriched track has more
      if (_resolvedArtists == null &&
          enrichedTrack.artists != null &&
          enrichedTrack.artists!.length > 1) {
        // Schedule update after build
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _resolvedArtists = enrichedTrack.artists;
              _resolvedArtistName = enrichedTrack.displayArtist;
              _resolvedArtistId = enrichedTrack.artistId;
            });
          }
        });
      }

      return _buildContent(
          releaseDate: "${widget.singleDetail!.releaseYear}",
          label: "",
          nbTracks: 1,
          duration: widget.singleDetail!.duration,
          tracks: [enrichedTrack],
          hasData: true,
          isLoading: false);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: FutureBuilder<SavedAlbum>(
          future: _detailsFuture,
          builder: (context, snapshot) {
            // Handle errors before checking data
            if (snapshot.hasError) {
              return Stack(
                children: [
                  _buildContent(
                    releaseDate: '', label: '', nbTracks: 0, duration: 0,
                    tracks: [], hasData: false, isLoading: false,
                    artworkUrl: widget.album?.artworkUrl ?? widget.singleDetail?.artworkUrl,
                  ),
                  Positioned.fill(
                    child: Container(
                      color: AppColors.background.withOpacity(0.85),
                      child: ErrorStateWidget(
                        rawError: snapshot.error.toString(),
                        foregroundColor: Colors.white,
                        onRetry: () {
                          setState(() {
                            _detailsFuture = _isSingleMode
                                ? Future.value(SavedAlbum(
                                    albumId: '', title: widget.singleDetail!.title,
                                    artistName: widget.singleDetail!.artistName,
                                    artworkUrl: widget.singleDetail!.artworkUrl,
                                    tracks: [widget.singleDetail!.track], trackCount: 1,
                                  ))
                                : _repository.getAlbum(widget.album!.albumId);
                          });
                        },
                      ),
                    ),
                  ),
                ],
              );
            }

            final hasData = snapshot.hasData;
            final albumData = snapshot.data;

            final releaseDate = albumData?.releaseDate ?? '';
            final label = albumData?.label ?? '';
            final nbTracks = albumData?.trackCount ?? 0;
            final duration = albumData?.duration ?? 0;

            // Use fetched artwork if available, otherwise fallback to widget
            final artworkUrl =
                hasData ? albumData?.artworkUrl : (widget.album?.artworkUrl);

            final List<Track> tracks = albumData?.tracks ?? [];

            return _buildContent(
              releaseDate: releaseDate,
              label: label,
              nbTracks: nbTracks,
              duration: duration,
              tracks: tracks,
              hasData: hasData,
              isLoading: !hasData &&
                  snapshot.connectionState == ConnectionState.waiting,
              artworkUrl: artworkUrl,
            );
          }),
    );
  }

  Widget _buildContent({
    required String releaseDate,
    required String label,
    required int nbTracks,
    required int duration,
    required List<Track> tracks,
    required bool hasData,
    required bool isLoading,
    String? artworkUrl,
  }) {
    // Fallback to widget data if null passed
    final effectiveArtworkUrl = artworkUrl ?? _artworkUrl;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Scrollable Content ──
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 1. Scrollable Header (Blur Background + Cover + Metadata + Buttons)
              SliverToBoxAdapter(
                child: Stack(
                  children: [
                    // Solid black base for the entire header to prevent any transparency
                    Positioned.fill(
                      child: Container(color: AppColors.background),
                    ),
                    // 1:1 Atmospheric Clipped Blurred Background
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: MediaQuery.of(context).size.width,
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ImageFiltered(
                              imageFilter: ImageFilter.blur(sigmaX: 45, sigmaY: 45, tileMode: TileMode.decal),
                              child: Transform.scale(
                                scale: 1.2,
                                child: AppImage(
                                  url: effectiveArtworkUrl,
                                  fit: BoxFit.cover,
                                  sizePx: Lh3UrlBuilder.headerSize,
                                ),
                              ),
                            ),
                            // Fade directly to black at the bottom of the 1:1 area
                            Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0x99121212),
                                    AppColors.background,
                                  ],
                                  stops: [0.0, 0.6, 1.0],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Foreground Rigid Layout
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Builder(
                        builder: (context) {
                          final double screenWidth = MediaQuery.of(context).size.width;
                          final double topSafeArea = MediaQuery.of(context).padding.top;
                          final double coverSize = screenWidth * 0.54;
                          const double textBlockHeight = 84; 
                          final double targetButtonY = screenWidth + 16;
                          final double currentY = topSafeArea + 16 + coverSize + textBlockHeight + 16; // 16 is bottom gap
                          final double gap = targetButtonY - currentY;
                          final double dynamicGap = gap > 0 ? gap : 0;
                          final bool isLongTitle = _title.length > 25;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Top slot: Cover aligns visually between top icons
                              SizedBox(height: topSafeArea + 16),

                              // Square Foreground Cover Art (Smaller 54% Width)
                              Center(
                                child: Hero(
                                  tag: _isSingleMode
                                      ? "track_${widget.singleDetail!.track.id}"
                                      : "album_${widget.album!.albumId}",
                                  child: Container(
                                    width: coverSize,
                                    height: coverSize,
                                    constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.5),
                                          blurRadius: 20,
                                          offset: const Offset(0, 10),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: AppImage(
                                        url: effectiveArtworkUrl,
                                        sizePx: Lh3UrlBuilder.headerSize,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                              ),

                              // Dynamic spacer to enforce exact Y alignment for the buttons
                              SizedBox(height: dynamicGap),

                              // Fixed Text Block (Title, Artist, Metadata)
                              SizedBox(
                                height: textBlockHeight,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    // Album Title
                                    Text(
                                      _title,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: isLongTitle ? 16 : 20,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                        letterSpacing: -0.5,
                                        height: 1.2,
                                      ),
                                    ),
                                    const SizedBox(height: 6),

                                    // Artist Name
                                    GestureDetector(
                                      onTap: _isNavigatingToArtist ? null : _onArtistTap,
                                      child: _isNavigatingToArtist
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: Colors.white,
                                              ),
                                            )
                                          : Text(
                                              _artistName,
                                              textAlign: TextAlign.center,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 15,
                                                color: Colors.white,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                    ),
                                    const SizedBox(height: 4),

                                    // Metadata: year • songs • duration
                                    Text(
                                      "${releaseDate.split('-').first} • $nbTracks ${_isSingleMode ? 'song' : 'songs'} • ${_formatTotalDuration(duration)}",
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),

                          // Action Buttons Row
                          if (hasData)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                // Shuffle
                                _buildActionButton(
                                  icon: Icons.shuffle_rounded,
                                  onTap: () {
                                    if (tracks.isNotEmpty) {
                                      final shuffled = List<Track>.from(tracks)..shuffle();
                                      context.read<PlaybackController>().playQueue(shuffled);
                                    }
                                  },
                                ),
                                // Save / Like
                                Consumer<LibraryController>(
                                  builder: (context, lib, _) {
                                    if (_isSingleMode) {
                                      final isLiked = lib.isLiked(widget.singleDetail!.track);
                                      return _buildActionButton(
                                        icon: isLiked
                                            ? Icons.favorite_rounded
                                            : Icons.favorite_border_rounded,
                                        onTap: () => lib.toggleLike(widget.singleDetail!.track),
                                      );
                                    } else {
                                      final isSaved = lib.isAlbumSaved(widget.album!.albumId);
                                      return _buildActionButton(
                                        icon: isSaved
                                            ? Icons.bookmark_rounded
                                            : Icons.bookmark_border_rounded,
                                        onTap: () => lib.toggleSaveAlbum(widget.album!),
                                      );
                                    }
                                  },
                                ),
                                // Play / Pause (Large Center Button)
                                Consumer<PlaybackController>(
                                  builder: (context, playback, _) {
                                    final isPlaying = playback.isPlaying;
                                    final currentTrack = playback.currentTrack;
                                    final albumId = widget.album?.albumId ??
                                        (widget.singleDetail?.track.albumId ?? 0);
                                    final isContext = currentTrack?.albumId == albumId;

                                    return _buildActionButton(
                                      icon: (isPlaying && isContext)
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                      size: 58,
                                      iconSize: 28,
                                      primary: true,
                                      onTap: () {
                                        if (isContext) {
                                          playback.togglePlayPause();
                                        } else {
                                          if (tracks.isNotEmpty) {
                                            playback.playQueue(tracks);
                                          }
                                        }
                                      },
                                    );
                                  },
                                ),
                                // Add to Playlist
                                _buildActionButton(
                                  icon: Icons.playlist_add_rounded,
                                  onTap: () {
                                    if (tracks.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text("No tracks to add")),
                                      );
                                      return;
                                    }
                                    showModalBottomSheet(
                                      context: context,
                                      useRootNavigator: true,
                                      isScrollControlled: true,
                                      backgroundColor: Colors.transparent,
                                      builder: (context) => AddToPlaylistSheet(tracks: tracks),
                                    );
                                  },
                                ),
                                // Download
                                _buildActionButton(
                                  icon: Icons.download_rounded,
                                  onTap: () {
                                    // TODO: Implement download functionality
                                  },
                                ),
                              ],
                            ),
                          const SizedBox(height: 16),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),

              // Song List
              if (isLoading)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => _buildSkeletonRow(),
                    childCount: 8,
                  ),
                )
              else if (hasData) ...[
                if (tracks.isNotEmpty)
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final track = tracks[index];
                        return TrackListTile(
                          track: track,
                          index: index,
                          foregroundColor: Colors.white,
                          allowSwipeActions: true,
                          onTap: () {
                            context.read<PlaybackController>().playQueue(tracks, index: index);
                          },
                        );
                      },
                      childCount: tracks.length,
                    ),
                  )
                else
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(
                        child: Text(
                          "No tracks available for this album.",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  ),

                if (label.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 24, bottom: 40),
                      child: Center(
                        child: Text(
                          "© $label",
                          style: const TextStyle(color: Colors.white24, fontSize: 11),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                const BottomContentPadding(isSliver: true),
              ],
            ],
          ),

          // ── 3. Edge Fades for Cinematic Transitions ──
          DynamicEdgeFade.dynamicBottom(
            key: ValueKey('fade_bot_album_${widget.album?.albumId ?? widget.singleDetail?.track.id}'),
            color: AppColors.background,
            height: 120,
          ),

          // ── 4. Clean local top navigation bar ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  color: _showTitle ? AppColors.background : Colors.transparent,
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top,
                  ),
                  child: SizedBox(
                    height: 58,
                    child: Stack(
                      children: [
                        // Left: back button — fixed position
                        Positioned(
                          left: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 24),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                        // Center: title — absolute center, independent of icons
                        Positioned.fill(
                          child: Center(
                            child: AnimatedOpacity(
                              opacity: _showTitle ? 1.0 : 0.0,
                              duration: const Duration(milliseconds: 150),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 56),
                                child: Text(
                                  _title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Right: overflow menu — fixed position
                        Positioned(
                          right: 4,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: SizedBox(
                              width: 48,
                              height: 48,
                              child: Center(
                                child: _isSingleMode
                                    ? OverflowMenu(
                                        type: MenuType.track,
                                        track: widget.singleDetail!.track,
                                        iconColor: Colors.white,
                                      )
                                    : OverflowMenu(
                                        type: MenuType.album,
                                        album: _resolvedAlbum,
                                        iconColor: Colors.white,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Soft bottom fade overlay
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 45,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _showTitle ? AppColors.background : Colors.transparent,
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// High-contrast solid circular action button.
  Widget _buildActionButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 46,
    double iconSize = 22,
    bool primary = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary ? Colors.white : Colors.white.withValues(alpha: 0.08),
          border: primary ? null : Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1),
        ),
        child: Center(
          child: Icon(
            icon,
            color: primary ? const Color(0xFF121212) : Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  String _formatTotalDuration(int totalSeconds) {
    if (totalSeconds < 3600) return "${totalSeconds ~/ 60} min";
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    return "$hours hr $mins min";
  }

  /// Shimmer placeholder row shown while tracks are loading.
  Widget _buildSkeletonRow() {
    return Shimmer.fromColors(
      baseColor: AppColors.surfaceLight,
      highlightColor: const Color(0xFF3A3A4A),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Index number placeholder
            Container(width: 20, height: 14, color: Colors.white),
            const SizedBox(width: 16),
            // Title + artist stack
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                      height: 14, width: double.infinity, color: Colors.white),
                  const SizedBox(height: 6),
                  Container(height: 11, width: 120, color: Colors.white),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Trailing icon placeholder
            Container(width: 24, height: 24, color: Colors.white),
          ],
        ),
      ),
    );
  }

  Future<void> _onArtistTap() async {
    // Guard against placeholder artist
    if (isPlaceholderArtist(_artistName)) return;

    // Build the valid artists list from API-resolved data
    final validArtists = (_resolvedArtists ?? [])
        .where(
            (a) => (a['id'] ?? '').isNotEmpty && (a['name'] ?? '').isNotEmpty)
        .toList();

    if (validArtists.isEmpty) {
      // Fallback: try single artist ID
      final fallbackId = _resolvedArtistId ??
          widget.album?.artistId ??
          widget.singleDetail?.track.artistId ??
          '';

      if (fallbackId.isNotEmpty) {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => ArtistDetailScreen(
                      artistId: fallbackId,
                      artistName: _artistName,
                    )));
        return;
      }

      // Last resort: search by name
      setState(() => _isNavigatingToArtist = true);
      try {
        final results = await _repository.searchArtists(_artistName);
        if (!mounted) return;
        setState(() => _isNavigatingToArtist = false);
        if (results.isNotEmpty) {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => ArtistDetailScreen(
                        artistId: results.first.id,
                        artistName: results.first.name,
                        pictureUrl: results.first.picture,
                      )));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Artist info unavailable")));
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isNavigatingToArtist = false);
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Artist info unavailable")));
        }
      }
      return;
    }

    // Single artist â†’ route directly
    if (validArtists.length == 1) {
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ArtistDetailScreen(
                    artistId: validArtists.first['id']!,
                    artistName: validArtists.first['name']!,
                  )));
      return;
    }

    // Multiple artists â†’ show selection BottomSheet
    _showAlbumArtistPicker(validArtists);
  }

  /// Multi-artist selection BottomSheet for album headers.
  void _showAlbumArtistPicker(List<Map<String, String>> artists) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        final sheetBg = DominantColorService.adaptiveSheetColor(_dominantColor);
        final sheetFg = DominantColorService.foregroundOn(sheetBg);
        return Container(
          decoration: BoxDecoration(
            color: sheetBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
                top: BorderSide(color: sheetFg.withOpacity(0.05), width: 1)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(
                    "Choose Artist",
                    style: TextStyle(
                      color: sheetFg,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Divider(color: sheetFg.withOpacity(0.1)),
                ...artists.map((a) => ListTile(
                      leading: Icon(Icons.person_outline,
                          color: sheetFg.withOpacity(0.7)),
                      title: Text(
                        a['name'] ?? '',
                        style: TextStyle(color: sheetFg, fontSize: 16),
                      ),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ArtistDetailScreen(
                                      artistId: a['id']!,
                                      artistName: a['name']!,
                                    )));
                      },
                    )),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }
}
