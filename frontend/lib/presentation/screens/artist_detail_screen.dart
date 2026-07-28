import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_colors.dart';
import '../widgets/error_state_widget.dart';
import '../../domain/entities/artist.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../widgets/music_card.dart';
import 'album_detail_screen.dart';
import '../widgets/glass_surface.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/network_image_with_fallback.dart';
import '../widgets/bottom_content_padding.dart';
import '../../core/utils/thumbnail_prefetcher.dart';
import '../widgets/app_image.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../core/image/image_pipeline.dart';
import 'artist_discography_screen.dart';
import '../../core/utils/dominant_color_service.dart';

import '../../core/utils/responsive.dart';
import '../../core/utils/string_utils.dart';

 class ArtistDetailScreen extends StatefulWidget {
  // ... (unchanged)
  final String artistId;
  final String artistName;
  final String? pictureUrl;
  final Track? sourceTrack; 

  const ArtistDetailScreen({
    super.key, 
    required this.artistId, 
    required this.artistName,
    this.pictureUrl,
    this.sourceTrack,
  });

  @override
  State<ArtistDetailScreen> createState() => _ArtistDetailScreenState();
}

class _ArtistDetailScreenState extends State<ArtistDetailScreen> {
  // ... (unchanged state)
  final MusicRepository _repository = MusicRepositoryImpl();
  final ScrollController _scrollController = ScrollController();
  
  late Future<Artist> _artistInfoFuture;
  // ... (other futures)
  
  bool _showTitle = false;
  bool _isLoading = true;
  bool _hasError = false;
  bool _isEnriching = false;
  String _resolvedArtistId = '';

  // Phase 3.3 §6: Paax follower count reconciliation. The API count is server
  // truth at fetch time (already reflects the user's persisted follow state);
  // the displayed count is that baseline plus the net follow/unfollow toggles
  // the user makes on THIS screen. This is independent of library-load timing,
  // so it never double-counts on a cold/cross-device open.
  int? _followBaselineCount;
  int _sessionFollowDelta = 0;
  
  ThumbnailPrefetcher? _prefetcher;
  Artist? _cachedArtist;
  // Stash raw songs for background enrichment
  final List<dynamic> _rawSongs = [];

  // Accent color from artwork
  Color _dominantColor = DominantColorService.fallback;
  String? _resolvedPictureUrl;

  @override
  void initState() {
    super.initState();
    _resolvedArtistId = widget.artistId;
    _resolvedPictureUrl = widget.pictureUrl;
    _loadData();
    
    _prefetcher = ThumbnailPrefetcher(context);

    _scrollController.addListener(() {
      final show = _scrollController.offset > 200; 
      if (show != _showTitle) {
        setState(() {
          _showTitle = show;
        });
      }
      
      // ... (prefetch logic unchanged)
      if (_cachedArtist != null) {
         final urls = [
            ...(_cachedArtist!.topTracks as List).cast<Track>().map((t) => t.artworkUrl),
            ...(_cachedArtist!.albums as List).cast<SavedAlbum>().map((a) => a.artworkUrl),
            ...(_cachedArtist!.singles as List).cast<SavedAlbum>().map((s) => s.artworkUrl),
            ...(_cachedArtist!.relatedArtists as List).cast<Artist>().map((r) => r.picture),
         ].where((u) => u.isNotEmpty).toList().cast<String>();
         
         _prefetcher?.onScroll(
           controller: _scrollController, 
           imageUrls: urls, 
           itemExtent: 80, 
           buffer: 6,
         );
      }
    });
  }

  // ... (_loadData, dispose unchanged)
  Future<void> _loadData() async {
    final loadStopwatch = Stopwatch()..start();
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      if ((_resolvedArtistId.isEmpty || _resolvedArtistId == '0') && widget.sourceTrack != null) {
         final fullTrack = await _repository.getTrack(widget.sourceTrack!.id);
         if (fullTrack.artistId != null && fullTrack.artistId!.isNotEmpty) {
             _resolvedArtistId = fullTrack.artistId!;
         }
      }

      if (_resolvedArtistId.isEmpty || _resolvedArtistId == '0') {
        throw Exception("Could not resolve artist ID");
      }

      // Phase 1: Load basic artist data (no enrichment) â€” renders immediately
      _artistInfoFuture = _repository.getArtistBasic(_resolvedArtistId);
      final artist = await _artistInfoFuture; 
      _cachedArtist = artist;

      debugPrint('[Perf] ArtistDetailScreen first render in ${loadStopwatch.elapsedMilliseconds}ms');

      if (mounted) {
        // Update the picture URL from API data so DynamicBackground can re-extract
        if (artist.picture.isNotEmpty && artist.picture != _resolvedPictureUrl) {
          _resolvedPictureUrl = artist.picture;
        }
        // Capture the follower baseline (server truth) and reset the per-screen
        // toggle delta for this load.
        if (artist.platformFollowers != null) {
          _followBaselineCount = artist.platformFollowers;
          _sessionFollowDelta = 0;
        }
        setState(() {
          _isLoading = false;
        });
      }

      // Precache key images in background
      _precacheImages(artist);

      // Phase 2 (Phase 3.3.1 §2): load top tracks + related artists as a
      // background section so the core page is never blocked by the eager
      // legacy top-track YouTube matching (which could take tens of seconds).
      _loadExtras(artist);
    } catch (e) {
      debugPrint('[Perf] ArtistDetailScreen FAILED in ${loadStopwatch.elapsedMilliseconds}ms: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  /// Background section load — top tracks + related artists (Phase 3.3.1 §2).
  /// The core profile already rendered; these populate the "Popular" and
  /// "Fans Also Like" sections when ready. On failure the sections stay hidden
  /// (existing empty behavior) and the page remains visible — never a global
  /// spinner.
  Future<void> _loadExtras(Artist coreArtist) async {
    // The legacy fallback path already includes top tracks + related.
    if (coreArtist.topTracks.isNotEmpty || coreArtist.relatedArtists.isNotEmpty) {
      return;
    }
    if (!mounted) return;
    setState(() => _isEnriching = true);

    final enrichStopwatch = Stopwatch()..start();
    try {
      final extras = await _repository.getArtistExtras(_resolvedArtistId);

      if (mounted) {
        final base = _cachedArtist ?? coreArtist;
        final updated = base.copyWith(
          topTracks: extras.topTracks,
          relatedArtists: extras.relatedArtists,
        );
        _cachedArtist = updated;
        // Update the future so FutureBuilders rebuild
        _artistInfoFuture = Future.value(updated);
        debugPrint('[Perf] ArtistDetailScreen extras loaded in ${enrichStopwatch.elapsedMilliseconds}ms');
        setState(() => _isEnriching = false);
      }
    } catch (err) {
      debugPrint('[Repo] Background extras load failed: $err');
      if (mounted) setState(() => _isEnriching = false);
    }
  }

  /// Precache key images so back-navigation feels instant.
  void _precacheImages(Artist artist) {
    if (kIsWeb) return;
    try {
      final mgr = ImagePipeline.instance.cacheManager;
      final urls = <String>[
        if (artist.picture.isNotEmpty) Lh3UrlBuilder.build(artist.picture, Lh3UrlBuilder.headerSize),
        ...(artist.albums as List).cast<SavedAlbum>().take(5).map((a) => Lh3UrlBuilder.forList(a.artworkUrl)),
        ...(artist.singles as List).cast<SavedAlbum>().take(5).map((s) => Lh3UrlBuilder.forList(s.artworkUrl)),
      ].where((u) => u.isNotEmpty).toList();
      for (final url in urls) {
        mgr.downloadFile(url).catchError((_) => null as dynamic);
      }
    } catch (_) {}
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    _prefetcher?.dispose();
    super.dispose();
  }
  Widget _buildSkeleton(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Center(
            child: ErrorStateWidget(
              rawError: "An error occurred while loading this artist profile.",
              foregroundColor: Colors.white,
              onRetry: _loadData,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _buildSkeleton(context);
    if (_hasError) return _buildError(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // ── Scrollable Content ──
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              // 1. Scrollable Hero Header (Image + Title/Fans)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: MediaQuery.of(context).size.width,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Artist Image
                      if (_resolvedPictureUrl != null && _resolvedPictureUrl!.isNotEmpty)
                        NetworkImageWithFallback(
                          imageUrl: _resolvedPictureUrl!.replaceAll(RegExp(r'w\d+-h\d+.*'), 'w1080-h1080'),
                          fit: BoxFit.cover,
                          memCacheWidth: 1080,
                        )
                      else
                        FutureBuilder<Artist>(
                          future: _artistInfoFuture,
                          builder: (context, snapshot) {
                            if (snapshot.hasData && snapshot.data!.picture.isNotEmpty) {
                              final hdUrl = snapshot.data!.picture.replaceAll(RegExp(r'w\d+-h\d+.*'), 'w1080-h1080');
                              return NetworkImageWithFallback(
                                imageUrl: hdUrl, 
                                fit: BoxFit.cover,
                                memCacheWidth: 1080,
                              );
                            }
                            return Container(color: Colors.black);
                          }
                        ),
                      
                      // Bottom fade into AppColors.background (#121212)
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
                            stops: [0.0, 0.5, 1.0],
                          ),
                        ),
                      ),

                      // Artist Title and Fans (Aligned to Bottom)
                      Positioned(
                        bottom: 24,
                        left: 20,
                        right: 20,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              widget.artistName,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 36,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: -1.0,
                                height: 1.1,
                              ),
                            ),
                            const SizedBox(height: 8),
                            FutureBuilder<Artist>(
                              future: _artistInfoFuture,
                              builder: (context, snapshot) {
                                if (!snapshot.hasData) return const SizedBox.shrink();
                                final artist = snapshot.data!;
                                // Phase 3.3.1 §3/§6: ALWAYS show the Paax platform
                                // follower count (never the external Deezer fan
                                // count) with correct singular/plural, plus the
                                // in-session follow/unfollow delta — so following
                                // an artist opened from Related Artists moves the
                                // count 0→1 even when the normalized profile isn't
                                // available and platformFollowers is unknown.
                                Widget pill(String label) => Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 1),
                                  ),
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                );
                                // Baseline = server-truth platform count when
                                // known, else 0 (the delta still reflects the
                                // user's own follow). Never the Deezer fan count.
                                final base = _followBaselineCount ??
                                    artist.platformFollowers ??
                                    0;
                                final count =
                                    (base + _sessionFollowDelta).clamp(0, 1 << 31);
                                return pill(formatFollowers(count));
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Action Buttons Row (Below Image)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      const SizedBox(height: 16),
                      FutureBuilder<Artist>(
                        future: _artistInfoFuture,
                        builder: (context, snapshot) {
                          final artistObj = snapshot.data;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Shuffle
                              _buildActionButton(
                                icon: Icons.shuffle_rounded,
                                onTap: () async {
                                  try {
                                    final artist = await _artistInfoFuture;
                                    if (artist.topTracks.isNotEmpty && mounted) {
                                      final tracks = (artist.topTracks as List).cast<Track>();
                                      final shuffled = List<Track>.from(tracks)..shuffle();
                                      context.read<PlaybackController>().playQueue(shuffled);
                                    }
                                  } catch (_) {}
                                },
                              ),
                              const SizedBox(width: 14),
                              // Play (Large Center Button)
                              Consumer<PlaybackController>(
                                builder: (_, playback, __) {
                                  final isPlaying = playback.isPlaying && playback.currentTrack?.artistId == _resolvedArtistId;
                                  return _buildActionButton(
                                    icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    size: 58,
                                    iconSize: 28,
                                    primary: true,
                                    onTap: () async {
                                      try {
                                        final artist = await _artistInfoFuture;
                                        if (artist.topTracks.isNotEmpty && mounted) {
                                          if (playback.currentTrack?.artistId == _resolvedArtistId) {
                                            playback.togglePlayPause();
                                          } else {
                                            final tracks = (artist.topTracks as List).cast<Track>();
                                            playback.playQueue(tracks);
                                          }
                                        }
                                      } catch (_) {}
                                    },
                                  );
                                },
                              ),
                              const SizedBox(width: 14),
                              // Follow
                              Consumer<LibraryController>(
                                builder: (context, lib, _) {
                                  final isFollowed = lib.isArtistFollowed(_resolvedArtistId);
                                  return _buildActionButton(
                                    icon: isFollowed ? Icons.check_rounded : Icons.person_add_rounded,
                                    onTap: () {
                                      if (artistObj != null) {
                                        // Track the count change for this screen
                                        // session so the follower pill reflects it
                                        // without depending on library-load timing.
                                        final willFollow = !lib.isArtistFollowed(_resolvedArtistId);
                                        setState(() =>
                                            _sessionFollowDelta += willFollow ? 1 : -1);
                                        lib.toggleFollowArtist(artistObj);
                                      }
                                    },
                                  );
                                },
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),

              _buildTopTracksSection(context),
              _buildLatestReleaseSection(context),
              _buildDiscographyAlbumsSection(context),
              _buildDiscographySinglesSection(context),
              _buildDiscographyButton(context),
              _buildRelatedArtistsSection(context),
              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
          ),

          // ── 3. Edge Fades ──
          DynamicEdgeFade.dynamicBottom(
            key: ValueKey('fade_bot_artist_${widget.artistId}'),
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
                                  widget.artistName,
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
                                child: OverflowMenu(
                                  type: MenuType.artist,
                                  artist: Artist(
                                    id: _resolvedArtistId,
                                    name: widget.artistName,
                                    picture: widget.pictureUrl ?? '',
                                  ),
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

  Widget _buildTopTracksSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.topTracks.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final tracks = (snapshot.data!.topTracks as List).cast<Track>();
        
        // Take top 5
        final displayTracks = tracks.take(5).toList();

        return SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index == 0) return Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 8), child: Text("Popular", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)));
              final track = displayTracks[index - 1];
              return TrackListTile(
                 track: track, 
                 index: index - 1,
                 showArtwork: true,
                 foregroundColor: Colors.white,
                 allowSwipeActions: true,
                 onTap: () => context.read<PlaybackController>().playQueue(tracks, index: index - 1)
              );
            },
            childCount: displayTracks.length + 1,
          ),
        );
      },
    );
  }

  // â”€â”€ Latest Release â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildLatestReleaseSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());

        final albums = (snapshot.data!.albums as List).cast<SavedAlbum>();
        final singles = (snapshot.data!.singles as List).cast<SavedAlbum>();
        final allReleases = [...albums, ...singles];
        if (allReleases.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

        // Newest first — date-aware (exact date > year > title); the old
        // int.tryParse on ISO dates collapsed everything to year 0 (§5).
        allReleases.sort((a, b) => compareReleaseDesc(
            a.releaseDate, a.title, b.releaseDate, b.title,
            idA: a.albumId, idB: b.albumId));
        final latest = allReleases.first;
        final yearStr = latest.releaseDate ?? '';

        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(top: 24, bottom: 12),
                  child: Text('Latest Release',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                ),
                GestureDetector(
                  onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: latest))),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withOpacity(0.12), width: 0.5),
                    ),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(12),
                            bottomLeft: Radius.circular(12),
                          ),
                          child: AppImage(
                            url: latest.artworkUrl,
                            sizePx: Lh3UrlBuilder.listSize,
                            width: 110,
                            height: 110,
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
                                Text(latest.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
                                const SizedBox(height: 6),
                                Text(() {
                                  final type = displayReleaseType(latest.releaseType);
                                  final year = extractYear(yearStr);
                                  if (year != null) return '$type \u00B7 $year';
                                  return type;
                                }(),
                                  style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.7))),
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
          ),
        );
      },
    );
  }

  // â”€â”€ Ãlbumes (latest 5) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildDiscographyAlbumsSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final albums = (snapshot.data!.albums as List).cast<SavedAlbum>();
        if (albums.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

        final display = albums.take(5).toList();
        final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
        final cardHeight = cardWidth + 56;

        return SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Text('Albums',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
              SizedBox(
                height: cardHeight,
                child: ListView.builder(
                  padding: EdgeInsets.only(left: Responsive.spacing(context)),
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  primary: false,
                  itemCount: display.length,
                  itemBuilder: (context, index) {
                    return _buildReleaseCard(context, display[index], cardWidth, showType: false);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // â”€â”€ Singles & EPs (latest 5) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildDiscographySinglesSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final singles = (snapshot.data!.singles as List).cast<SavedAlbum>();
        if (singles.isEmpty && !_isEnriching) return const SliverToBoxAdapter(child: SizedBox.shrink());

        final display = singles.take(5).toList();
        final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
        final cardHeight = cardWidth + 56;

        return SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                child: Row(
                  children: [
                    Text('Singles & EPs',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                    if (_isEnriching) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white24,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (display.isNotEmpty)
                SizedBox(
                  height: cardHeight,
                  child: ListView.builder(
                    padding: EdgeInsets.only(left: Responsive.spacing(context)),
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    primary: false,
                    itemCount: display.length,
                    itemBuilder: (context, index) {
                      return _buildReleaseCard(context, display[index], cardWidth, showType: false);
                    },
                  ),
                )
              else if (_isEnriching)
                Shimmer.fromColors(
                  baseColor: Colors.grey[900]!,
                  highlightColor: Colors.grey[800]!,
                  child: SizedBox(
                    height: cardHeight,
                    child: ListView.builder(
                      padding: EdgeInsets.only(left: Responsive.spacing(context)),
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: 3,
                      itemBuilder: (_, __) => Container(
                        width: cardWidth,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // â”€â”€ See full discography button â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget _buildDiscographyButton(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final albums = (snapshot.data!.albums as List).cast<SavedAlbum>();
        final singles = (snapshot.data!.singles as List).cast<SavedAlbum>();
        if (albums.isEmpty && singles.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: Responsive.spacing(context),
              vertical: 20,
            ),
            child: OutlinedButton(
              onPressed: () {
                Navigator.push(context, MaterialPageRoute(
                  builder: (_) => ArtistDiscographyScreen(
                    artistName: widget.artistName,
                    albums: albums,
                    singles: singles,
                    dominantColor: _dominantColor,
                    foregroundColor: Colors.white,
                  ),
                ));
              },
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.white,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                foregroundColor: Colors.black,
              ),
              child: Text('See full discography',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
            ),
          ),
        );
      },
    );
  }

  Widget _buildReleaseCard(BuildContext context, SavedAlbum album, double width, {bool showType = true}) {
      final year = extractYear(album.releaseDate);
      String subtitle;
      if (showType) {
        final typeLabel = displayReleaseType(album.releaseType);
        subtitle = year != null ? '$typeLabel \u00B7 $year' : typeLabel;
      } else {
        subtitle = year ?? '';
      }
      return MusicCard(
        width: width,
        title: album.title,
        subtitle: subtitle, 
        imageUrl: album.artworkUrl,
        foregroundColor: Colors.white,
        onTap: () {
           Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)));
        },
      );
  }

  Widget _buildRelatedArtistsSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.relatedArtists.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
        final artists = (snapshot.data!.relatedArtists as List).cast<Artist>();
        
        final width = Responsive.value(context, mobile: 100.0, tablet: 120.0, desktop: 140.0);
        final height = width + 60;

        return SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               Padding(padding: EdgeInsets.all(Responsive.spacing(context)), child: Text("Fans Also Like", style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white))),
               SizedBox(
                 height: height,
                 child: ListView.builder(
                   padding: EdgeInsets.only(left: Responsive.spacing(context)),
                   scrollDirection: Axis.horizontal,
                   physics: const ClampingScrollPhysics(),
                   primary: false,
                   itemCount: artists.length,
                   itemBuilder: (context, index) {
                     final artist = artists[index];
                     return GestureDetector(
                       onTap: () {
                          Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                            artistId: artist.id, 
                            artistName: artist.name,
                            pictureUrl: artist.picture,
                          )));
                       },
                       child: Container(
                         width: width,
                         margin: EdgeInsets.only(right: Responsive.spacing(context)),
                         child: Column(
                           children: [
                             ClipOval(
                               child: NetworkImageWithFallback(
                                 imageUrl: artist.picture,
                                 width: width,
                                 height: width,
                                 fit: BoxFit.cover,
                               ),
                             ),
                             const SizedBox(height: 8),
                             Text(
                               artist.name,
                               maxLines: 1,
                               overflow: TextOverflow.ellipsis,
                               textAlign: TextAlign.center,
                               style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13, color: Colors.white),
                             )
                           ],
                         ),
                       ),
                     );
                   },
                 ),
               )
            ],
          ),
        );
      },
    );
  }
}
