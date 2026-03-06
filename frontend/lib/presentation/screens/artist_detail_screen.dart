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
import '../widgets/section_header.dart';
import 'album_detail_screen.dart';
import '../widgets/black_glass_blur_surface.dart';
import '../widgets/mini_player.dart'; 
import '../widgets/track_list_tile.dart';
import '../widgets/overflow_menu.dart';
import '../widgets/network_image_with_fallback.dart';
import '../widgets/bottom_content_padding.dart';
import '../../core/utils/thumbnail_prefetcher.dart';
import 'artist_items_screen.dart';

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
  String _resolvedArtistId = '';
  
  ThumbnailPrefetcher? _prefetcher;
  Artist? _cachedArtist;

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

      _artistInfoFuture = _repository.getArtist(_resolvedArtistId);
      
      final artist = await _artistInfoFuture; 
      _cachedArtist = artist;

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
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
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              _buildSliverAppBar(context),
              SliverToBoxAdapter(child: _buildActionButtons(context)),
              SliverToBoxAdapter(child: const SizedBox(height: 20)),
              
              _buildTopTracksSection(context),
              _buildAlbumsSection(context),
              _buildRelatedArtistsSection(context),
              const SliverToBoxAdapter(child: BottomContentPadding()),
            ],
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
               child: Text("Retry", style: TextStyle(color: AppColors.primaryStart)),
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
      title: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _showTitle ? 1.0 : 0.0,
        child: Text(widget.artistName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      actions: [
        OverflowMenu(
          type: MenuType.artist,
          artist: Artist(
            id: _resolvedArtistId,
            name: widget.artistName,
            picture: widget.pictureUrl ?? '',
          ),
        ),
        const SizedBox(width: 8),
      ],
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          FlexibleSpaceBar(
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
                         Colors.black.withOpacity(0.2),
                         Colors.black.withOpacity(0.8),
                         AppColors.background,
                       ],
                       stops: const [0.4, 0.6, 0.9, 1.0],
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
                           color: Colors.white,
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
                                   color: Colors.black.withOpacity(0.6),
                                   borderRadius: BorderRadius.circular(20),
                                   border: Border.all(color: Colors.amber.withOpacity(0.6), width: 1),
                                   boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4)]
                                 ),
                                 child: Row(
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     const Icon(Icons.people_alt_rounded, color: Colors.amber, size: 14),
                                     const SizedBox(width: 6),
                                     Text(
                                       fanStr, 
                                       style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)
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
                                            color: isFollowed ? AppColors.primaryStart : Colors.white.withOpacity(0.2),
                                            border: Border.all(color: Colors.white.withOpacity(0.3), width: 1)
                                         ),
                                         child: Icon(
                                           isFollowed ? Icons.check : Icons.person_add_rounded,
                                           color: Colors.white, 
                                           size: 20
                                         ),
                                      ),
                                    );
                                 },
                               ),
                             ],
                           );
                         },
                       ),
                     ],
                   ),
                 ),
              ],
            ),
          ),
          
          // Glass Blur Layer (Controlled by Scroll)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.of(context).padding.top + kToolbarHeight,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: _showTitle ? 1.0 : 0.0,
              child: BlackGlassBlurSurface(
                 height: MediaQuery.of(context).padding.top + kToolbarHeight,
                 width: MediaQuery.of(context).size.width,
                 bottomBorder: true,
                 child: Container(),
              ),
            ),
          ),
        ],
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
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary ? AppColors.primaryStart : AppColors.surfaceLight,
            gradient: primary ? AppColors.primaryGradient : null,
          ),
          child: IconButton(
            icon: Icon(icon, color: primary ? Colors.white : color),
            onPressed: onTap,
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
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
              if (index == 0) return const Padding(padding: EdgeInsets.fromLTRB(20, 24, 20, 12), child: Text("Popular", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)));
              final track = displayTracks[index - 1];
              return TrackListTile(
                 track: track, 
                 index: index - 1,
                 showArtwork: true, // Show artwork
                 onTap: () => context.read<PlaybackController>().playQueue(tracks, index: index - 1)
              );
            },
            childCount: displayTracks.length + 1,
          ),
        );
      },
    );
  }

  Widget _buildAlbumsSection(BuildContext context) {
    return FutureBuilder<Artist>(
      future: _artistInfoFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SliverToBoxAdapter(child: SizedBox.shrink());
        
        final artist = snapshot.data!;
        final albums = (artist.albums as List).cast<SavedAlbum>();
        final singles = (artist.singles as List).cast<SavedAlbum>();
        
        // Calculate responsive dimensions
        final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
        final cardHeight = cardWidth + 56; 

        return SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               if (albums.isNotEmpty) ...[
                 SectionHeader(
                   title: "Albums",
                   onSeeAll: artist.albumsParams != null 
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistItemsScreen(
                          artistId: _resolvedArtistId, 
                          title: "Albums", 
                          initialParams: artist.albumsParams
                      )))
                      : null,
                 ),
                 SizedBox(
                   height: cardHeight,
                   child: ListView.builder(
                     padding: EdgeInsets.only(left: Responsive.spacing(context)),
                     scrollDirection: Axis.horizontal,
                     physics: const ClampingScrollPhysics(),
                     primary: false,
                     itemCount: albums.length,
                     itemBuilder: (context, index) {
                       return _buildReleaseCard(context, albums[index], "Album", cardWidth);
                     },
                   ),
                 )
               ],
               
               if (singles.isNotEmpty) ...[
                 SectionHeader(
                   title: "Singles & EPs",
                   onSeeAll: artist.singlesParams != null 
                      ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistItemsScreen(
                          artistId: _resolvedArtistId, 
                          title: "Singles & EPs", 
                          initialParams: artist.singlesParams
                      )))
                      : null,
                 ),
                 SizedBox(
                   height: cardHeight,
                   child: ListView.builder(
                     padding: EdgeInsets.only(left: Responsive.spacing(context)),
                     scrollDirection: Axis.horizontal,
                     physics: const ClampingScrollPhysics(),
                     primary: false,
                     itemCount: singles.length,
                     itemBuilder: (context, index) {
                       return _buildReleaseCard(context, singles[index], "Single", cardWidth);
                     },
                   ),
                 )
               ]
            ],
          ),
        );
      },
    );
  }
  
  Widget _buildReleaseCard(BuildContext context, SavedAlbum album, String subtitle, double width) {
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
               Padding(padding: EdgeInsets.all(Responsive.spacing(context)), child: const Text("Fans Also Like", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
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
