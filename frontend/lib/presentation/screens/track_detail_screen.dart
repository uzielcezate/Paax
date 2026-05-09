import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../widgets/thumbnail.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/entities/track.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../widgets/glass_surface.dart';
import '../widgets/music_card.dart';
import '../widgets/add_to_playlist_sheet.dart';

class TrackDetailScreen extends StatefulWidget {
  final Track track;
  const TrackDetailScreen({super.key, required this.track});

  @override
  State<TrackDetailScreen> createState() => _TrackDetailScreenState();
}

class _TrackDetailScreenState extends State<TrackDetailScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  final ScrollController _scrollController = ScrollController();
  
  Future<List<Track>>? _artistTracksFuture;
  bool _showTitle = false;

  @override
  void initState() {
    super.initState();
    _loadRecommendations();
    
    _scrollController.addListener(() {
      final show = _scrollController.offset > 240; 
      if (show != _showTitle) {
        setState(() {
          _showTitle = show;
        });
      }
    });
  }
  
  void _loadRecommendations() {
      if (widget.track.artistId != null && widget.track.artistId!.isNotEmpty && widget.track.artistId != '0') {
           _artistTracksFuture = _repository.getArtistTopTracks(widget.track.artistId!);
      } else {
           _artistTracksFuture = _repository.searchTracks('artist:"${widget.track.artistName}"');
      }
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          CustomScrollView(
            controller: _scrollController,
        slivers: [
           SliverAppBar(
             expandedHeight: 320,
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
                    Hero(
                      tag: "track_${widget.track.id}",
                      child: Thumbnail.hero(url: widget.track.artworkUrl, borderRadius: 0),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, AppColors.background.withOpacity(0.1), AppColors.background],
                          stops: const [0.0, 0.7, 1.0]
                        ),
                      ),
                    ),
                 ],
               ),
             ),
           ),
           
           SliverToBoxAdapter(
             child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Text(widget.track.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                    Text(widget.track.displayArtist, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppColors.textSecondary)),
                    const SizedBox(height: 32),
            
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildActionButton(
                  icon: Icons.play_arrow_rounded,
                  label: "Play",
                  onTap: () {
                     context.read<PlaybackController>().playTrack(widget.track);
                  }, 
                  primary: true,
                ),
                const SizedBox(width: 16),
                Consumer<LibraryController>(
                  builder: (context, lib, _) {
                    final isLiked = lib.isLiked(widget.track);
                    return _buildActionButton(
                      icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                      label: isLiked ? "Liked" : "Like",
                      onTap: () => lib.toggleLike(widget.track),
                      color: isLiked ? AppColors.primaryEnd : Colors.white,
                    );
                  }
                ),
                const SizedBox(width: 16),
                _buildActionButton(
                  icon: Icons.playlist_add_rounded, 
                  label: "Add to",
                  onTap: () {
                     showModalBottomSheet(
                        context: context,
                        useRootNavigator: true,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => AddToPlaylistSheet(tracks: [widget.track]),
                     );
                  }
                ),
              ],
            ),
            
            const SizedBox(height: 40),

            // Recommended Section (Horizontal Rail)
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Recommended for you", style: Theme.of(context).textTheme.titleLarge),
            ),
            const SizedBox(height: 16),
            
            FutureBuilder<List<Track>>(
              future: _artistTracksFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: Colors.white));
                if (snapshot.hasError) return const Text("Could not load recommendations", style: TextStyle(color: Colors.white54));
                
                // Filter out current track
                final tracks = snapshot.data!.where((t) => t.id != widget.track.id).toList();
                
                if (tracks.isEmpty) return const Text("No recommendations available", style: TextStyle(color: Colors.white54));

                return SizedBox(
                  height: 200,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    primary: false,
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final t = tracks[index];
                      return MusicCard(
                        title: t.title, 
                        subtitle: t.displayArtist, 
                        imageUrl: t.artworkUrl, 
                        onTap: () {
                           // Navigate to new track detail
                           Navigator.push(context, MaterialPageRoute(builder: (_) => TrackDetailScreen(track: t)));
                        }
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    ),
  ],
      ),


            // Top fade gradient
            const DynamicEdgeFade.black(),

            // Floating controls
            FloatingTopControls(
              showScrolledPill: _showTitle,
              topPadding: MediaQuery.of(context).padding.top,
              defaultControls: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GlassCircleButton(
                    icon: Icons.arrow_back_ios_new,
                    iconSize: 18,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              scrolledPill: ScrolledTopPill(
                title: widget.track.title,
                onBack: () => Navigator.pop(context),
              ),
            ),
        ],
      )
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
                width: 60, height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: primary ? Colors.white : Colors.white.withOpacity(0.12),
                  border: primary ? null : Border.all(color: Colors.white.withOpacity(0.15), width: 0.5),
                ),
                child: Icon(icon, color: primary ? Colors.black : color, size: 26),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
      ],
    );
  }
}

