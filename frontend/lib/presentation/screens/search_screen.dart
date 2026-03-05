// Replace the old SearchScreen implementation with the new UI
import 'package:flutter/material.dart';
import 'main_wrapper.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/artist.dart';
import '../state/search_controller.dart' as app_search;
import '../state/playback_controller.dart';
import 'artist_detail_screen.dart';
import 'album_detail_screen.dart';
import 'track_detail_screen.dart';
import '../widgets/track_list_tile.dart';
import '../widgets/music_card.dart';
import '../widgets/thumbnail.dart';

import '../widgets/bottom_content_padding.dart';
import '../widgets/black_glass_blur_surface.dart';
import '../widgets/genre_card.dart';
import 'genre_results_screen.dart';

import '../../core/utils/responsive.dart';

 class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  // ... (State variables same)
  final TextEditingController _textController = TextEditingController();
  String _selectedFilter = 'All';

  @override
  Widget build(BuildContext context) {
    final search = context.watch<app_search.SearchController>(); 
    final double topPadding = MediaQuery.of(context).padding.top;
    
    // Header Calculations
    final double contentHeight = 120.0; 
    final double headerHeight = topPadding + contentHeight;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomScrollView(
              slivers: [
                 SliverToBoxAdapter(child: SizedBox(height: headerHeight)),
                 ..._buildBodySlivers(search),
              ],
            ),
          ),
          
          Positioned(
            top: 0, 
            left: 0, 
            right: 0,
            height: headerHeight,
            child: BlackGlassBlurSurface(
              blurSigma: 20.0,
              height: headerHeight,
              bottomBorder: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: topPadding),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        children: [
                           IconButton(
                             icon: const Icon(Icons.arrow_back, color: Colors.white),
                             onPressed: () {
                               final mainWrapper = MainWrapper.shellKey.currentState;
                               if (mainWrapper != null) {
                                 mainWrapper.onBackPressed();
                               } else {
                                 Navigator.maybePop(context);
                               }
                             },
                             padding: EdgeInsets.zero,
                             constraints: const BoxConstraints(),
                           ),
                           const SizedBox(width: 16),
                           Expanded(
                             child: TextField(
                                controller: _textController,
                                style: const TextStyle(color: Colors.white, fontSize: 16),
                                decoration: InputDecoration(
                                  hintText: "What do you want to listen to?",
                                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 15),
                                  prefixIcon: const Icon(Icons.search, color: Colors.white70, size: 22),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.08),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(30),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                                  isDense: true,
                                  suffixIcon: _textController.text.isNotEmpty 
                                      ? IconButton(
                                          icon: const Icon(Icons.clear, color: Colors.grey, size: 20),
                                          onPressed: () {
                                            _textController.clear();
                                            search.onQueryChanged("");
                                          },
                                        ) 
                                      : null,
                                ),
                                onChanged: (val) {
                                   search.onQueryChanged(val);
                                   setState(() {}); 
                                },
                              ),
                           ),
                        ],
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 12),
                  
                  SizedBox(
                    height: 48, 
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
                      physics: const BouncingScrollPhysics(),
                      children: ["All", "Tracks", "Albums", "Artists"].map((filter) {
                        final isSelected = _selectedFilter == filter;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: FilterChip(
                            label: Text(filter),
                            selected: isSelected,
                            onSelected: (_) => setState(() => _selectedFilter = filter),
                            backgroundColor: Colors.white.withOpacity(0.05),
                            selectedColor: AppColors.primaryStart.withOpacity(0.8),
                            checkmarkColor: Colors.white,
                            labelStyle: TextStyle(
                              color: isSelected ? Colors.white : Colors.grey[400],
                              fontSize: 13,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: isSelected ? Colors.transparent : Colors.white.withOpacity(0.1), 
                                width: 1
                              )
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 4), 
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ... (Genre Data skipped)
  final List<Map<String, dynamic>> _genres = [
    {"name": "Pop", "colors": [const Color(0xFF8A2387), const Color(0xFFE94057), const Color(0xFFF27121)]},
    {"name": "Rock", "colors": [const Color(0xFF232526), const Color(0xFF414345)]},
    {"name": "Latin", "colors": [const Color(0xFFDA22FF), const Color(0xFF9733EE)]},
    {"name": "Hip Hop", "colors": [const Color(0xFF11998e), const Color(0xFF38ef7d)]},
    {"name": "Electro", "colors": [const Color(0xFF12c2e9), const Color(0xFFc471ed), const Color(0xFFf64f59)]},
    {"name": "Indie", "colors": [const Color(0xFF00b09b), const Color(0xFF96c93d)]},
    {"name": "R&B", "colors": [const Color(0xFF8E2DE2), const Color(0xFF4A00E0)]},
    {"name": "Reggaeton", "colors": [const Color(0xFFFF512F), const Color(0xFFDD2476)]},
    {"name": "K-pop", "colors": [const Color(0xFFf953c6), const Color(0xFFb91d73)]},
    {"name": "Jazz", "colors": [const Color(0xFFFDC830), const Color(0xFFF37335)]},
    {"name": "Classical", "colors": [const Color(0xFF4CA1AF), const Color(0xFFC4E0E5)]},
    {"name": "Country", "colors": [const Color(0xFFe65c00), const Color(0xFFF9D423)]},
    {"name": "Metal", "colors": [const Color(0xFF000000), const Color(0xFF434343)]},
    {"name": "Funk", "colors": [const Color(0xFFCC95C0), const Color(0xFFDBD4B4), const Color(0xFF7AA1D2)]},
    {"name": "House", "colors": [const Color(0xFF4568DC), const Color(0xFFB06AB3)]},
    {"name": "Techno", "colors": [const Color(0xFF200122), const Color(0xFF6f0000)]},
    {"name": "Lo-fi", "colors": [const Color(0xFF5f2c82), const Color(0xFF49a09d)]},
    {"name": "Afro", "colors": [const Color(0xFFD38312), const Color(0xFFA83279)]},
    {"name": "Regional", "colors": [const Color(0xFF00416A), const Color(0xFFE4E5E6)]},
  ];

  List<Widget> _buildBodySlivers(app_search.SearchController search) {
    if (search.isLoading) {
      return [const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: AppColors.primaryStart)))];
    }
    
    // Add top padding to content so it doesn't touch the divider immediately
    const topContentPadding = SliverToBoxAdapter(child: SizedBox(height: 12));

    if (_textController.text.isEmpty) {
      return [
         topContentPadding,
         SliverPadding(
           padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
           sliver: SliverToBoxAdapter(
             child: Padding(
               padding: const EdgeInsets.only(bottom: 16),
               child: const Text("Browse All", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
             ),
           ),
         ),
         SliverPadding(
           padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
           sliver: SliverGrid(
             gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
               maxCrossAxisExtent: 200, // Responsive tiles
               childAspectRatio: 1.6,
               crossAxisSpacing: 12,
               mainAxisSpacing: 12,
             ),
             delegate: SliverChildBuilderDelegate(
               (context, index) {
                 final genre = _genres[index];
                   return GenreCard(
                     label: genre['name'],
                     colors: genre['colors'],
                     onTap: () {
                        Navigator.push(context, MaterialPageRoute(builder: (_) => GenreResultsScreen(
                          genreSlug: genre['name'],
                          gradientColors: genre['colors'],
                        )));
                     },
                   );
               },
               childCount: _genres.length,
             ),
           ),
         ),
         const SliverToBoxAdapter(child: BottomContentPadding()),
      ];
    }
    
    if (search.error != null) {
      return [SliverFillRemaining(child: Center(child: Text("Error: ${search.error}", style: const TextStyle(color: Colors.red))))];
    }
    
    final bool hasResults = search.trackResults.isNotEmpty || search.albumResults.isNotEmpty || search.artistResults.isNotEmpty;

    if (!hasResults) {
      return [const SliverFillRemaining(child: Center(child: Text("No results found.", style: TextStyle(color: Colors.grey))))];
    }

    if (_selectedFilter == "All") {
      return [topContentPadding, ..._buildAllResultsSlivers(search)];
    } else if (_selectedFilter == "Tracks") {
      return [topContentPadding, ..._buildTracksListSlivers(search.trackResults)];
    } else if (_selectedFilter == "Albums") {
      return [topContentPadding, ..._buildAlbumsGridSlivers(search.albumResults)];
    } else {
      return [topContentPadding, ..._buildArtistsGridSlivers(search.artistResults)];
    }
  }

  // ... (Rest of build methods _buildAllResultsSlivers, etc. remain unchanged)

  List<Widget> _buildAllResultsSlivers(app_search.SearchController search) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildListDelegate([
            // Best Match (Artist)
            if (search.artistResults.isNotEmpty) ...[
              const Text("Top Result", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildArtistTile(search.artistResults.first, large: true),
              const SizedBox(height: 24),
            ],

            // Tracks
            if (search.trackResults.isNotEmpty) ...[
              const Text("Songs", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ...search.trackResults.take(4).map((t) => _buildTrackTile(t)).toList(),
              if (search.trackResults.length > 4)
                 Align(
                   alignment: Alignment.centerLeft,
                   child: TextButton(
                     child: const Text("See all songs", style: TextStyle(color: AppColors.primaryStart)), 
                     onPressed: () => setState(() => _selectedFilter = "Tracks")
                   )
                 ),
              const SizedBox(height: 24),
            ],

            // Albums
            if (search.albumResults.isNotEmpty) ...[
              const Text("Albums", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _buildAlbumsRail(search.albumResults),
              const SizedBox(height: 24),
            ],
            
            // Artists 
            if (search.artistResults.length > 1) ...[ 
               const Text("Artists", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
               const SizedBox(height: 12),
               _buildArtistsRail(search.artistResults.skip(1).toList()),
            ],
            
            const BottomContentPadding(),
          ]),
        ),
      ),
    ];
  }

  // --- Components ---

  Widget _buildTrackTile(Track track) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: TrackListTile(
         track: track,
         index: 0, 
         showArtwork: true,
         onTap: () {
            context.read<PlaybackController>().playTrack(track);
         },
      ),
    );
  }
  
  List<Widget> _buildTracksListSlivers(List<Track> tracks) {
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (_, i) {
               if (i == tracks.length) return const BottomContentPadding();
               return Padding(
                 padding: const EdgeInsets.only(bottom: 8.0),
                 child: TrackListTile(
                  track: tracks[i], 
                  index: i,
                  showArtwork: true,
                  onTap: () {
                     context.read<PlaybackController>().playQueue(tracks, index: i);
                  }
                 ),
               );
            },
            childCount: tracks.length + 1,
          ),
        ),
      )
    ];
  }

  Widget _buildArtistTile(Artist artist, {bool large = false}) {
    return GestureDetector(
      onTap: () {
         Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
            artistId: artist.id, artistName: artist.name, pictureUrl: artist.picture
         )));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Hero(
              tag: 'artist_${artist.id}',
              child: CircleAvatar(
                radius: large ? 40 : 24,
                backgroundImage: CachedNetworkImageProvider(artist.picture),
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(artist.name, style: TextStyle(
                  color: Colors.white, 
                  fontWeight: FontWeight.bold,
                  fontSize: large ? 20 : 16
                )),
                const Text("Artist", style: TextStyle(color: Colors.grey)),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildArtistsRail(List<Artist> artists) {
    // Responsive avatar size
    final avatarRadius = Responsive.value(context, mobile: 50.0, tablet: 60.0, desktop: 70.0);
    // Height: Diameter + Spacing + Text
    final railHeight = (avatarRadius * 2) + 8 + 40;

    return SizedBox(
      height: railHeight,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: artists.length,
        itemBuilder: (_, i) => Padding(
          padding: EdgeInsets.only(right: Responsive.spacing(context)),
          child: Column(
            children: [
              GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                   artistId: artists[i].id, artistName: artists[i].name, pictureUrl: artists[i].picture
                ))),
                child: CircleAvatar(
                  radius: avatarRadius,
                  backgroundImage: CachedNetworkImageProvider(artists[i].picture),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: avatarRadius * 2,
                child: Text(
                  artists[i].name, 
                  maxLines: 1, 
                  overflow: TextOverflow.ellipsis, 
                  textAlign: TextAlign.center, 
                  style: const TextStyle(color: Colors.white)
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  List<Widget> _buildArtistsGridSlivers(List<Artist> artists) {
    return [
       SliverPadding(
         padding: const EdgeInsets.symmetric(horizontal: 16),
         sliver: SliverGrid(
           gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
             maxCrossAxisExtent: 200, 
             childAspectRatio: 0.8,
             crossAxisSpacing: 16, 
             mainAxisSpacing: 16
           ),
           delegate: SliverChildBuilderDelegate(
             (context, index) {
               final artist = artists[index];
               return GestureDetector(
                 onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                      artistId: artist.id,
                      artistName: artist.name,
                      pictureUrl: artist.picture
                    )));
                 },
                 child: Column(
                   children: [
                     Expanded(
                       child: Container(
                         decoration: BoxDecoration(
                           shape: BoxShape.circle,
                           image: DecorationImage(
                             image: CachedNetworkImageProvider(artist.picture),
                             fit: BoxFit.cover,
                           ),
                         ),
                       ),
                     ),
                     const SizedBox(height: 12),
                     Text(
                       artist.name, 
                       maxLines: 1, 
                       overflow: TextOverflow.ellipsis, 
                       textAlign: TextAlign.center, 
                       style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
                     ),
                   ],
                 ),
               );
             },
             childCount: artists.length,
           ),
         ),
       ),
       const SliverToBoxAdapter(child: BottomContentPadding()),
    ];
  }
  
  Widget _buildAlbumsRail(List<SavedAlbum> albums) {
    final cardWidth = Responsive.value(context, mobile: 140.0, tablet: 160.0, desktop: 200.0);
    final cardHeight = cardWidth + 56; 

    return SizedBox(
      height: cardHeight,
      child: ListView.builder(
        padding: const EdgeInsets.only(left: 0), 
        scrollDirection: Axis.horizontal,
        itemCount: albums.length,
        itemBuilder: (_, i) => Padding(
          padding: EdgeInsets.only(right: Responsive.spacing(context)),
          child: MusicCard(
            width: cardWidth,
            title: albums[i].title,
            subtitle: albums[i].artistName,
            imageUrl: albums[i].artworkUrl,
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: albums[i]))),
          ),
        ),
      ),
    );
  }
  
  List<Widget> _buildAlbumsGridSlivers(List<SavedAlbum> albums) {
    return [
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: Responsive.spacing(context)),
        sliver: SliverGrid(
           gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
               maxCrossAxisExtent: 200, 
               childAspectRatio: 0.75, 
               crossAxisSpacing: 16, 
               mainAxisSpacing: 16
           ),
           delegate: SliverChildBuilderDelegate(
             (context, index) {
               final album = albums[index];
               return GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: album))),
                  child: Column(
                       crossAxisAlignment: CrossAxisAlignment.start,
                       children: [
                         Expanded(child: Thumbnail(
                           url: album.artworkUrl,
                           sizePx: 200,
                           borderRadius: 12,
                           fit: BoxFit.cover,
                         )),
                         const SizedBox(height: 8),
                         Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                         Text(album.artistName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                       ],
                  ),
               );
             },
             childCount: albums.length
           ),
        ),
      ),
      const SliverToBoxAdapter(child: BottomContentPadding()),
    ];
  }
}
