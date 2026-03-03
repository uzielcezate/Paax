import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../state/auth_controller.dart'; 
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../../data/local/hive_storage.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart'; 
import '../../domain/entities/artist.dart';
import '../../domain/entities/single_track_album_detail.dart';
import '../widgets/section_header.dart';
import '../widgets/music_card.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'profile_screen.dart';
import '../widgets/bottom_content_padding.dart';
import '../../core/utils/thumbnail_prefetcher.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  
  // Structured Sections data
  // Using Records: ({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _globalCharts;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _usCharts;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _mxCharts;
  
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _popContent;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _rockContent;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _latinContent;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _hipHopContent;
  late Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> _indieContent;

  // Personalization
  List<Track> _forYouTracks = [];
  String _forYouTitle = "For You";
  bool _personalizationLoaded = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _prefetcher = ThumbnailPrefetcher(context);
    // Prefetching logic logic for Home is implied by lazy loading, 
    // but we can add explicit prefetch on scroll if we map the sections.
    // For now, lazy loading + throttled cache is the biggest win.
    
    _initFutures();
    _loadPersonalizedSection();
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    _prefetcher?.dispose();
    super.dispose();
  }
  
  void _initFutures() {
    // Charts
    _globalCharts = _repository.getCharts('ZZ');
    _usCharts = _repository.getCharts('US');
    _mxCharts = _repository.getCharts('MX');
    
    // Genres
    _popContent = _repository.getGenreContent('Pop', 'US');
    _rockContent = _repository.getGenreContent('Rock', 'US');
    _latinContent = _repository.getGenreContent('Latin', 'US');
    _hipHopContent = _repository.getGenreContent('Hip-Hop', 'US');
    _indieContent = _repository.getGenreContent('Indie', 'US');
  }

  Future<void> _loadPersonalizedSection() async {
     try {
       final recentSearches = HiveStorage.getRecentSearches();
       if (recentSearches.isNotEmpty) {
          final lastQuery = recentSearches.first;
          final results = await _repository.searchTracks(lastQuery);
          if (results.isNotEmpty) {
             if (mounted) {
               setState(() {
                 _forYouTracks = results;
                 _forYouTitle = "Based on \"$lastQuery\"";
                 _personalizationLoaded = true;
               });
             }
             return;
          }
       }
       
       // Fallback to search if no personal history
       final trending = await _repository.searchTracks('Top Hits');
       if (mounted) {
         setState(() {
           _forYouTracks = trending.take(10).toList();
           _forYouTitle = "Trending Now";
           _personalizationLoaded = true;
         });
       }
     } catch (e) {
       print("Personalization error: $e");
       if (mounted) setState(() => _personalizationLoaded = true);
     }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthController>().currentUser;
    final userName = user?.name.split(' ').first ?? 'Guest';
    
    final hour = DateTime.now().hour;
    String greeting = "Good morning";
    if (hour >= 12) greeting = "Good afternoon";
    if (hour >= 18) greeting = "Good evening";
    
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          controller: _scrollController,
          slivers: [
             SliverToBoxAdapter(child: _buildHeader(context, greeting, userName)),
             
             if (_personalizationLoaded && _forYouTracks.isNotEmpty)
                SliverToBoxAdapter(child: _buildTrackRow(context, _forYouTitle, _forYouTracks)),
             
             // Lazy build the rest of the sections
             SliverList(
               delegate: SliverChildBuilderDelegate(
                 (context, index) {
                    switch (index) {
                      case 0: return _buildCategorySection("Global Top Charts", _globalCharts);
                      case 1: return _buildCategorySection("US Top Charts", _usCharts);
                      case 2: return _buildCategorySection("Mexico Top Charts", _mxCharts);
                      case 3: return _buildCategorySection("Pop Essentials", _popContent);
                      case 4: return _buildCategorySection("Rock Classics & New", _rockContent);
                      case 5: return _buildCategorySection("Latin & Reggaeton", _latinContent);
                      case 6: return _buildCategorySection("Hip-Hop & Rap", _hipHopContent);
                      case 7: return _buildCategorySection("Indie & Alternative", _indieContent);
                      case 8: return const BottomContentPadding();
                      default: return null;
                    }
                 },
                 childCount: 9,
               ),
             ),
          ],
        ),
      ),
    );
  }
  
  late ScrollController _scrollController;
  ThumbnailPrefetcher? _prefetcher;

  Widget _buildHeader(BuildContext context, String greeting, String userName) {
      return Padding(
         padding: const EdgeInsets.all(20.0),
         child:Row(
           mainAxisAlignment: MainAxisAlignment.spaceBetween,
           children: [
             Column(
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 Text(
                   "$greeting,",
                   style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                     color: AppColors.textSecondary,
                     fontWeight: FontWeight.w400,
                     fontSize: 20
                   ),
                 ),
                 Text(
                   userName,
                   style: Theme.of(context).textTheme.displaySmall?.copyWith(
                     color: AppColors.textPrimary,
                     fontWeight: FontWeight.bold,
                     fontSize: 28
                   ),
                 ),
               ],
             ),
             GestureDetector(
               onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
               },
               child: CircleAvatar(
                  backgroundColor: AppColors.surfaceLight,
                  child: const Icon(Icons.person, color: Colors.white),
               ),
             )
           ],
         ),
       );
  }

  Widget _buildCategorySection(String title, Future<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})> future) {
      return FutureBuilder<({List<Track> tracks, List<SavedAlbum> albums, List<Artist> artists})>(
        future: future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          
          final data = snapshot.data!;
          // If all empty, show nothing
          if (data.tracks.isEmpty && data.albums.isEmpty && data.artists.isEmpty) return const SizedBox.shrink();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
               // We can layout them as separate rows
               if (data.tracks.isNotEmpty) _buildTrackRow(context, "$title - Top Songs", data.tracks),
               if (data.albums.isNotEmpty) _buildAlbumRow(context, "$title - Top Albums", data.albums),
               if (data.artists.isNotEmpty) _buildArtistRow(context, "$title - Top Artists", data.artists),
               const SizedBox(height: 20), // Spacing between categories
            ],
          );
        },
      );
  }

  Widget _buildTrackRow(BuildContext context, String title, List<Track> tracks) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    
    // Calculate responsive dimensions
    final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
    // Height = AspectRatio(1) + Title + Subtitle + Spacing + buffer
    final cardHeight = cardWidth + 64; 

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return MusicCard(
                width: cardWidth,
                title: track.title,
                subtitle: track.artistName,
                imageUrl: track.artworkUrl,
                onTap: () {
                   // Play single track or album context
                   if (track.albumId.isNotEmpty && track.albumId != '0') {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(
                        album: SavedAlbum(
                           albumId: track.albumId, 
                           title: track.albumTitle, 
                           artistName: track.artistName, 
                           artworkUrl: track.artworkUrl
                        )
                      )));
                   } else {
                      Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(
                        singleDetail: SingleTrackAlbumDetail.fromTrack(track)
                      )));
                   }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumRow(BuildContext context, String title, List<SavedAlbum> albums) {
    if (albums.isEmpty) return const SizedBox.shrink();
    
    // Calculate responsive dimensions
    final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
    final cardHeight = cardWidth + 64; 

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            itemCount: albums.length,
            itemBuilder: (context, index) {
              final album = albums[index];
              return MusicCard(
                width: cardWidth,
                title: album.title,
                subtitle: album.artistName,
                imageUrl: album.artworkUrl,
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album)));
                },
              );
            },
          ),
        ),
      ],
    );
  }
  
  Widget _buildArtistRow(BuildContext context, String title, List<Artist> artists) {
    if (artists.isEmpty) return const SizedBox.shrink();

    // Calculate responsive dimensions
    final cardWidth = Responsive.value(context, mobile: 100.0, tablet: 120.0, desktop: 140.0);
    // Circle needs slightly less height for text
    final cardHeight = cardWidth + 50; 

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        SizedBox(
          height: cardHeight,
          child: ListView.builder(
            padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
            scrollDirection: Axis.horizontal,
            itemCount: artists.length,
            itemBuilder: (context, index) {
              final artist = artists[index];
              return MusicCard(
                width: cardWidth,
                title: artist.name,
                subtitle: "Artist",
                imageUrl: artist.picture,
                isCircle: true,
                onTap: () {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                    artistId: artist.id,
                    artistName: artist.name,
                    pictureUrl: artist.picture,
                  )));
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
