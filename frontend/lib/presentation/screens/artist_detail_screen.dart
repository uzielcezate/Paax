import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_colors.dart';
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
import '../widgets/dynamic_background.dart';
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
  
  ThumbnailPrefetcher? _prefetcher;
  Artist? _cachedArtist;
  // Stash raw songs for background enrichment
  final List<dynamic> _rawSongs = [];

  // Dynamic background state
  Color _dominantColor = DominantColorService.fallback;
  Color _foregroundColor = Colors.white;

  @override
  void initState() {
    super.initState();
    _resolvedArtistId = widget.artistId;
    _loadData();
    
    _prefetcher = ThumbnailPrefetcher(context);

    _scrollController.addListener(() {
      final show = _scrollController.offset > 240; 
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

      // Phase 1: Load basic artist data (no enrichment) — renders immediately
      _artistInfoFuture = _repository.getArtistBasic(_resolvedArtistId);
      final artist = await _artistInfoFuture; 
      _cachedArtist = artist;

      debugPrint('[Perf] ArtistDetailScreen first render in ${loadStopwatch.elapsedMilliseconds}ms');

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      // Precache key images in background
      _precacheImages(artist);

      // Phase 2: Enrich releases in background
      _enrichReleases(artist);
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

  /// Background enrichment — updates albums/singles with year and type data.
  Future<void> _enrichReleases(Artist basicArtist) async {
    if (!mounted) return;
    setState(() => _isEnriching = true);

    final enrichStopwatch = Stopwatch()..start();
    try {
      final albums = (basicArtist.albums as List).cast<SavedAlbum>();
      final singles = (basicArtist.singles as List).cast<SavedAlbum>();

      final enriched = await _repository.enrichArtistReleases(
        existingAlbums: albums,
        existingSingles: singles,
        rawSongs: _rawSongs,
      );

      if (mounted) {
        final updated = basicArtist.copyWith(
          albums: enriched.albums,
          singles: enriched.singles,
        );
        _cachedArtist = updated;
        // Update the future so FutureBuilders rebuild
        _artistInfoFuture = Future.value(updated);
        debugPrint('[Perf] ArtistDetailScreen enrichment done in ${enrichStopwatch.elapsedMilliseconds}ms');
        setState(() => _isEnriching = false);
      }
    } catch (err) {
      debugPrint('[Repo] Background enrichment failed: $err');
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _buildSkeleton(context);
    if (_hasError) return _buildError(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Dynamic ambient background from artist image
          DynamicBackground(
            imageUrl: widget.pictureUrl,
            onColorExtracted: (color) {
              if (!mounted) return;
              setState(() {
                _dominantColor = color;
                _foregroundColor = DominantColorService.foregroundOn(color);
              });
            },
          ),

          CustomScrollView(
            controller: _scrollController,
            slivers: [
              _buildSliverAppBar(context),
              SliverToBoxAdapter(child: _buildActionButtons(context)),
              SliverToBoxAdapter(child: const SizedBox(height: 20)),
              
              _buildTopTracksSection(context),
              _buildLatestReleaseSection(context),
              _buildDiscographyAlbumsSection(context),
              _buildDiscographySinglesSection(context),
              _buildDiscographyButton(context),
              _buildRelatedArtistsSection(context),
              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
          ),
          
          // Top fade gradient — matches dominant background color
          TopFadeGradient(color: _dominantColor),
          
          // Floating controls
          FloatingTopControls(
            showScrolledPill: _showTitle,
            topPadding: MediaQuery.of(context).padding.top,
            defaultControls: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GlassCircleButton(
                  icon: Icons.arrow_back_ios_new,
                  iconSize: 18,
                  iconColor: _foregroundColor,
                  onPressed: () => Navigator.pop(context),
                ),
                GlassMenuButton(
                  child: OverflowMenu(
                    type: MenuType.artist,
                    artist: Artist(
                      id: _resolvedArtistId,
                      name: widget.artistName,
                      picture: widget.pictureUrl ?? '',
                    ),
                    iconColor: _foregroundColor,
                  ),
                ),
              ],
            ),
            scrolledPill: ScrolledTopPill(
              title: widget.artistName,
              onBack: () => Navigator.pop(context),
              foregroundColor: _foregroundColor,
              trailing: OverflowMenu(
                type: MenuType.artist,
                artist: Artist(
                  id: _resolvedArtistId,
                  name: widget.artistName,
                  picture: widget.pictureUrl ?? '',
                ),
                iconColor: _foregroundColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ... (_buildError, _buildSkeleton unchanged - skipped for brevity in update, assume they exist)
  Widget _buildError(BuildContext context) {
      // ... (Can keep existing)
      return Scaffold(
       backgroundColor: AppColors.background,
       appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
       body: Center(
         child: Column(
           mainAxisAlignment: MainAxisAlignment.center,
           children: [
             Icon(Icons.error_outline, size: 48, color: Colors.white54),
             SizedBox(height: 16),
             Text("Artist info unavailable", style: TextStyle(color: Colors.white70)),
             SizedBox(height: 16),
             TextButton(
               onPressed: _loadData,
               child: Text("Retry", style: TextStyle(color: _foregroundColor)),
             )
           ],
         ),
       ),
     );
  }

  Widget _buildSkeleton(BuildContext context) {
     return Scaffold(
       backgroundColor: AppColors.background,
       body: Shimmer.fromColors(
         baseColor: Colors.grey[900]!,
         highlightColor: Colors.grey[800]!,
         child: SingleChildScrollView(
           physics: const NeverScrollableScrollPhysics(),
           child: Column(
             children: [
               Container(height: 340, color: Colors.white),
               // ... (simulated skeleton)
             ],
           ),
         ),
       ),
     );
  }

  Widget _buildSliverAppBar(BuildContext context) {
    final expandedHeight = Responsive.value(context, mobile: 340.0, tablet: 400.0, desktop: 450.0);
    
    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      backgroundColor: Colors.transparent,
      forceMaterialTransparency: true,
      elevation: 0,
      automaticallyImplyLeading: false,
      leadingWidth: 0,
      leading: const SizedBox.shrink(),
      titleSpacing: 0,
      title: null,
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.pin,
        background: Stack(
          fit: StackFit.expand,
          children: [
              if (widget.pictureUrl != null && widget.pictureUrl!.isNotEmpty)
                   NetworkImageWithFallback(
                     imageUrl: widget.pictureUrl!.replaceAll(RegExp(r'w\d+-h\d+.*'), 'w1080-h1080'), // Force HD
                     fit: BoxFit.cover,
                     memCacheWidth: 1080, // Ensure high quality memory cache
                   )
                 else
                    FutureBuilder<Artist>(
                      future: _artistInfoFuture,
                      builder: (context, snapshot) {
                        if (snapshot.hasData) {
                          // Force HD URL by removing resizing params or setting large dimensions
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
                    
                 // Gradient Scrim
                 Container(
                   decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          _dominantColor.withOpacity(0.15),
                          _dominantColor.withOpacity(0.7),
                          _dominantColor,
                        ],
                        stops: const [0.3, 0.55, 0.85, 1.0],
                      ),
                   ),
                 ),

                 // Content Positioned at Bottom
                 Positioned(
                   bottom: 24,
                   left: Responsive.spacing(context),
                   right: Responsive.spacing(context),
                   child: Column(
                     crossAxisAlignment: CrossAxisAlignment.start,
                     mainAxisSize: MainAxisSize.min,
                     children: [
                       // Artist Name
                       Text(
                         widget.artistName,
                         maxLines: 2,
                         overflow: TextOverflow.ellipsis,
                         style: TextStyle(
                           fontFamily: 'Roboto', 
                           fontSize: Responsive.fontSize(context, 42, min: 32, max: 56), 
                           fontWeight: FontWeight.w900, 
                           color: _foregroundColor,
                           height: 1.1,
                           shadows: [Shadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 2))]
                         )
                       ),
                       const SizedBox(height: 12),
                       
                       // Fans Badge & Follow Button
                       FutureBuilder<Artist>(
                         future: _artistInfoFuture,
                         builder: (context, snapshot) {
                           if (!snapshot.hasData) return const SizedBox.shrink();
                           final fans = snapshot.data!.nbFans;
                           final fanStr = formatFans(fans);
                           
                           final artistObj = snapshot.data!;

                           return Row(
                             children: [
                               Container(
                                 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                 decoration: BoxDecoration(
                                    color: _foregroundColor.withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: _foregroundColor.withOpacity(0.2), width: 0.5),
                                 ),
                                 child: Row(
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                      Icon(Icons.people_alt_rounded, color: _foregroundColor.withOpacity(0.7), size: 14),
                                     const SizedBox(width: 6),
                                     Text(
                                       fanStr, 
                                        style: TextStyle(color: _foregroundColor, fontWeight: FontWeight.bold, fontSize: 13)
                                     ),
                                   ],
                                 ),
                               ),
                               const SizedBox(width: 16),
                               
                               // Follow Button
                               Consumer<LibraryController>(
                                 builder: (context, lib, _) {
                                    final isFollowed = lib.isArtistFollowed(_resolvedArtistId);
                                    return GestureDetector(
                                      onTap: () => lib.toggleFollowArtist(artistObj),
                                      child: Container(
                                         width: 36, height: 36,
                                         decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                             color: isFollowed ? _foregroundColor.withOpacity(0.3) : _foregroundColor.withOpacity(0.1),
                                             border: Border.all(color: _foregroundColor.withOpacity(0.2), width: 0.5)
                                         ),
                                         child: Icon(
                                           isFollowed ? Icons.check : Icons.person_add_rounded,
                                           color: _foregroundColor, 
                                           size: 20
                                         ),
                                      ),
                                    );
                                 },
                               ),
                             ],
                           );
                         }
                       ),
                     ],
                   ),
                 ),
              ],
            ),
          ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 24,
          runSpacing: 16,
          children: [
             // Play Button
             Consumer<PlaybackController>(
               builder: (_, playback, __) {
                  final isPlaying = playback.isPlaying && playback.currentTrack?.artistId == _resolvedArtistId;
                  return _buildActionButton(
                    icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    label: isPlaying ? "Pause" : "Play",
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
                    }
                  );
               }
             ),
             // Shuffle Button
             _buildActionButton(
               icon: Icons.shuffle_rounded,
               label: "Shuffle",
               onTap: () async {
                  try {
                    final artist = await _artistInfoFuture;
                    if (artist.topTracks.isNotEmpty && mounted) {
                       final tracks = (artist.topTracks as List).cast<Track>();
                       final shuffled = List<Track>.from(tracks)..shuffle();
                       context.read<PlaybackController>().playQueue(shuffled);
                    }
                  } catch (_) {}
               }
             ),
          ],
        ),
      );
  }

  Widget _buildActionButton({required IconData icon, required String label, required VoidCallback onTap, bool primary = false, Color color = Colors.white}) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: ClipOval(
            child: BackdropFilter(
              filter: primary ? ImageFilter.blur() : ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary ? Colors.white : Colors.white.withOpacity(0.12),
                  border: primary ? null : Border.all(color: Colors.white.withOpacity(0.15), width: 0.5),
                ),
                child: Icon(icon, color: primary ? Colors.black : _foregroundColor, size: 26),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: _foregroundColor.withOpacity(0.7), fontSize: 12)),
      ],
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
              if (index == 0) return Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 12), child: Text("Popular", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _foregroundColor)));
              final track = displayTracks[index - 1];
              return TrackListTile(
                 track: track, 
                 index: index - 1,
                 showArtwork: true,
                 foregroundColor: _foregroundColor,
                 onTap: () => context.read<PlaybackController>().playQueue(tracks, index: index - 1)
              );
            },
            childCount: displayTracks.length + 1,
          ),
        );
      },
    );
  }

  // ── Latest Release ──────────────────────────────────────────────────
  Widget _buildLatestReleaseSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());

        final albums = (snapshot.data!.albums as List).cast<SavedAlbum>();
        final singles = (snapshot.data!.singles as List).cast<SavedAlbum>();
        final allReleases = [...albums, ...singles];
        if (allReleases.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

        // Sort newest first by year
        allReleases.sort((a, b) {
          final ya = int.tryParse(a.releaseDate ?? '') ?? 0;
          final yb = int.tryParse(b.releaseDate ?? '') ?? 0;
          return yb.compareTo(ya);
        });
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
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _foregroundColor)),
                ),
                GestureDetector(
                  onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: latest))),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.surfaceLight,
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
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _foregroundColor)),
                                const SizedBox(height: 6),
                                Text(() {
                                  final type = displayReleaseType(latest.releaseType);
                                  final year = extractYear(yearStr);
                                  if (year != null) return '$type \u00B7 $year';
                                  return type;
                                }(),
                                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
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

  // ── Álbumes (latest 5) ─────────────────────────────────────────────────
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
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _foregroundColor)),
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

  // ── Singles & EPs (latest 5) ────────────────────────────────────────
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
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _foregroundColor)),
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

  // ── See full discography button ────────────────────────────────────
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
                    foregroundColor: _foregroundColor,
                  ),
                ));
              },
              style: OutlinedButton.styleFrom(
                backgroundColor: _foregroundColor,
                side: BorderSide.none,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                foregroundColor: _foregroundColor == Colors.white ? Colors.black : Colors.white,
              ),
              child: Text('See full discography',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
               Padding(padding: EdgeInsets.all(Responsive.spacing(context)), child: Text("Fans Also Like", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _foregroundColor))),
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
                               style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
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
