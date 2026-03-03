import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/repositories/music_repository.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../widgets/music_card.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/network_image_with_fallback.dart';
import '../../core/utils/string_utils.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import '../widgets/black_glass_blur_surface.dart';
import '../../core/utils/responsive.dart';
import '../../core/utils/thumbnail_prefetcher.dart';

class GenreResultsScreen extends StatefulWidget {
  final String genreSlug;
  final List<Color> gradientColors;

  const GenreResultsScreen({
    super.key,
    required this.genreSlug,
    required this.gradientColors,
  });

  @override
  State<GenreResultsScreen> createState() => _GenreResultsScreenState();
}

class _GenreResultsScreenState extends State<GenreResultsScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  
  List<Track> _tracks = [];
  List<SavedAlbum> _albums = [];
  List<Artist> _artists = [];
  
  bool _isLoading = true;
  String? _error;
  bool _songsExpanded = false; // Track if "See all" is pressed
  late ScrollController _scrollController;
  bool _showTitle = false;
  ThumbnailPrefetcher? _prefetcher;

  @override
  void initState() {
    super.initState();
    _prefetcher = ThumbnailPrefetcher(context);
    _scrollController = ScrollController();
    _scrollController.addListener(() {
      // Threshold: when collapsed enough that title should show
      // Using 200 as a safe bet for "near top"
      final showTitle = _scrollController.hasClients && _scrollController.offset > 200;
      if (showTitle != _showTitle) {
        setState(() => _showTitle = showTitle);
      }
      
      // Prefetching
      if (!_isLoading && _tracks.isNotEmpty) {
         final urls = [
           ..._tracks.map((t) => t.artworkUrl),
           ..._albums.map((a) => a.artworkUrl),
           ..._artists.map((a) => a.picture),
         ].where((u) => u.isNotEmpty).toList();
         
         _prefetcher?.onScroll(
           controller: _scrollController,
           imageUrls: urls,
           itemExtent: 80, // Avg item height
           buffer: 10,
         );
      }
    });
    _fetchGenreContent();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _prefetcher?.dispose();
    super.dispose();
  }

  Future<void> _fetchGenreContent() async {
    try {
      setState(() { _isLoading = true; _error = null; });
      
      // Use search-based approach to get songs, albums, artists for this genre
      // This avoids playlist endpoints completely
      final results = await Future.wait([
        _repository.searchTracks('${widget.genreSlug} top songs'),
        _repository.searchAlbums('${widget.genreSlug} top albums'),
        _repository.searchArtists('${widget.genreSlug} music'),  // Broader search for more results
      ]);

      setState(() {
        // Take up to 50 tracks, 10 albums, 10 artists
        _tracks = (results[0] as List<Track>).take(50).toList();
        _albums = (results[1] as List<SavedAlbum>)
            .where((a) => !isPlaceholderArtist(a.artistName))
            .take(10)
            .toList();
        _artists = (results[2] as List<Artist>)
            .where((a) => !isPlaceholderArtist(a.name))
            .take(10)
            .toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          _buildSliverAppBar(),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: AppColors.primaryStart)),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(child: Text("Error: $_error", style: const TextStyle(color: Colors.white))),
            )
          else ...[
            // === SPACE ===
            const SliverToBoxAdapter(child: SizedBox(height: 20)),

            // === TOP SONGS HEADER ===
            if (_tracks.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Top Songs", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                      TextButton.icon(
                        onPressed: _showAddToPlaylistSheet,
                        icon: const Icon(Icons.playlist_add, color: AppColors.primaryStart, size: 20),
                        label: const Text("Add all", style: TextStyle(color: AppColors.primaryStart, fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),

             // === TOP SONGS LIST (Lazy) ===
             if (_tracks.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final track = _tracks[index];
                      // If collapsed, only show first 5
                      if (!_songsExpanded && index >= 5) return null;
                      
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4.0, left: 16, right: 16),
                        child: TrackListTile(
                          track: track,
                          index: index + 1,
                          showArtwork: true,
                          onTap: () => context.read<PlaybackController>().playQueue(_tracks, index: index),
                        ),
                      );
                    },
                    childCount: _songsExpanded ? _tracks.length : 5.clamp(0, _tracks.length),
                  ),
                ),
            
            // === EXPAND BUTTON ===
            if (_tracks.length > 5)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Center(
                    child: TextButton(
                      onPressed: () => setState(() => _songsExpanded = !_songsExpanded),
                      child: Text(
                        _songsExpanded ? "Show less" : "See all ${_tracks.length} songs",
                        style: const TextStyle(
                          color: AppColors.primaryEnd, // Magenta
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

             const SliverToBoxAdapter(child: SizedBox(height: 24)),

             // === TOP ALBUMS ===
             if (_albums.isNotEmpty)
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       _buildSectionHeader("Top Albums"),
                       _buildAlbumsCarousel(),
                       const SizedBox(height: 24),
                    ],
                  ),
                ),

             // === TOP ARTISTS ===
             if (_artists.isNotEmpty)
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       _buildSectionHeader("Top Artists"),
                       _buildArtistsCarousel(),
                       const SizedBox(height: 24),
                    ],
                  ),
                ),
                
             const SliverToBoxAdapter(child: BottomContentPadding()),
          ],
        ],
      ),
    );
  }

  Widget _buildSliverAppBar() {
    final expandedHeight = Responsive.value(context, mobile: 320.0, tablet: 380.0, desktop: 420.0); // Slightly taller to match Artist
    final threshold = expandedHeight - kToolbarHeight - 50; // Trigger earlier

    return SliverAppBar(
      pinned: true,
      expandedHeight: expandedHeight,
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
      title: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: _showTitle ? 1.0 : 0.0,
        child: Text(
          widget.genreSlug,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      flexibleSpace: Stack(
        fit: StackFit.expand,
        children: [
          FlexibleSpaceBar(
            collapseMode: CollapseMode.pin,
            background: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: widget.gradientColors.length > 1
                      ? widget.gradientColors
                      : [widget.gradientColors.first, Colors.black],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                   // Gradient Scrim (Darkens bottom for text legibility)
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.1),
                          Colors.black.withOpacity(0.4),
                          Colors.black.withOpacity(0.8),
                          AppColors.background,
                        ],
                        stops: const [0.0, 0.5, 0.85, 1.0],
                      ),
                    ),
                  ),
                  
                  // Genre Title Positioned at Bottom-Left (Like Artist Detail)
                  Positioned(
                    bottom: 24,
                    left: Responsive.spacing(context),
                    right: Responsive.spacing(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.music_note_rounded, size: 80, color: Colors.white.withOpacity(0.9)),
                        const SizedBox(height: 8),
                        Text(
                          widget.genreSlug,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Roboto',
                            fontSize: Responsive.fontSize(context, 48, min: 36, max: 64),
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            height: 1.1,
                            shadows: [Shadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))]
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Sticky Glass Header
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
                 child: const SizedBox(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
    );
  }

  // === TOP SONGS SECTION (5 + expandable to 50) ===
  Widget _buildSongsSection() {
    final displayTracks = _songsExpanded ? _tracks : _tracks.take(5).toList();
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with "Add all to playlist" button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Top Songs", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              TextButton.icon(
                onPressed: _showAddToPlaylistSheet,
                icon: const Icon(Icons.playlist_add, color: AppColors.primaryStart, size: 20),
                label: const Text("Add all", style: TextStyle(color: AppColors.primaryStart, fontSize: 14)),
              ),
            ],
          ),
        ),
        
        // Track list
        ...displayTracks.asMap().entries.map((entry) {
          final index = entry.key;
          final track = entry.value;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4.0, left: 16, right: 16),
            child: TrackListTile(
              track: track,
              index: index + 1,
              showArtwork: true,
              onTap: () => context.read<PlaybackController>().playQueue(_tracks, index: _tracks.indexOf(track)),
            ),
          );
        }),
        
        // See all / Collapse button
        if (_tracks.length > 5)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Center(
              child: TextButton(
                onPressed: () => setState(() => _songsExpanded = !_songsExpanded),
                child: Text(
                  _songsExpanded ? "Show less" : "See all ${_tracks.length} songs",
                  style: const TextStyle(
                    color: AppColors.primaryEnd, // Magenta
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showAddToPlaylistSheet() {
    final songsToAdd = _songsExpanded ? _tracks : _tracks.take(5).toList();
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AddToPlaylistSheet(tracks: songsToAdd),
    );
  }

  // === TOP ALBUMS CAROUSEL (10 items) ===
  Widget _buildAlbumsCarousel() {
    return SizedBox(
      height: 200,
      child: ListView.builder(
        padding: const EdgeInsets.only(left: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _albums.length,
        itemBuilder: (context, index) {
          final album = _albums[index];
          return MusicCard(
            title: album.title,
            subtitle: album.artistName,
            imageUrl: album.artworkUrl,
            onTap: () {
              Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)));
            },
          );
        },
      ),
    );
  }

  // === TOP ARTISTS CAROUSEL (10 items) ===
  Widget _buildArtistsCarousel() {
    return SizedBox(
      height: 160,
      child: ListView.builder(
        padding: const EdgeInsets.only(left: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _artists.length,
        itemBuilder: (context, index) {
          final artist = _artists[index];
          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: GestureDetector(
              onTap: () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                  artistId: artist.id,
                  artistName: artist.name,
                  pictureUrl: artist.picture,
                )));
              },
              child: Column(
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.surfaceLight,
                    ),
                    child: ClipOval(
                      child: NetworkImageWithFallback(
                        imageUrl: artist.picture,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 100,
                    child: Text(
                      artist.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 13),
                    ),
                  )
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
