import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart'; // For kDebugMode
import '../../core/theme/app_colors.dart';
import '../../domain/entities/saved_album.dart';
import '../../domain/entities/track.dart';
import '../../domain/entities/single_track_album_detail.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../state/playback_controller.dart';
import '../state/library_controller.dart';
import '../widgets/mini_player.dart';
import '../widgets/black_glass_blur_surface.dart';
import '../widgets/track_list_tile.dart'; 
import '../widgets/overflow_menu.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/app_image.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../core/utils/string_utils.dart';
import 'artist_detail_screen.dart';

class AlbumDetailScreen extends StatefulWidget {
  final SavedAlbum? album;
  final SingleTrackAlbumDetail? singleDetail;
  
  const AlbumDetailScreen({
    super.key, 
    this.album, 
    this.singleDetail
  }) : assert(album != null || singleDetail != null, 'Either album or singleDetail must be provided');

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  final ScrollController _scrollController = ScrollController();
  
  Future<SavedAlbum>? _detailsFuture; // Now returns updated SavedAlbum
  bool _showTitle = false;
  bool _isNavigatingToArtist = false;

  bool get _isSingleMode => widget.singleDetail != null;

  String get _title => _isSingleMode ? widget.singleDetail!.title : widget.album!.title;
  String get _artistName => _isSingleMode ? widget.singleDetail!.artistName : widget.album!.artistName;
  String get _artworkUrl => _isSingleMode ? widget.singleDetail!.artworkUrl : widget.album!.artworkUrl;

  @override
  void initState() {
    super.initState();
    if (!_isSingleMode) {
      _detailsFuture = _repository.getAlbum(widget.album!.albumId);
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

  @override
  Widget build(BuildContext context) {
    if (_isSingleMode) {
      return _buildContent(
        releaseDate: "${widget.singleDetail!.releaseYear}",
        label: "",
        nbTracks: 1,
        duration: widget.singleDetail!.duration,
        tracks: [widget.singleDetail!.track],
        hasData: true,
        isLoading: false
      );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: FutureBuilder<SavedAlbum>(
        future: _detailsFuture,
        builder: (context, snapshot) {
           final hasData = snapshot.hasData;
           final albumData = snapshot.data;
           
           final releaseDate = albumData?.releaseDate ?? '';
           final label = albumData?.label ?? '';
           final nbTracks = albumData?.trackCount ?? 0;
           final duration = albumData?.duration ?? 0; 
           
           // Use fetched artwork if available, otherwise fallback to widget
           final artworkUrl = hasData ? albumData?.artworkUrl : (widget.album?.artworkUrl);

           final List<Track> tracks = albumData?.tracks ?? [];

           return _buildContent(
             releaseDate: releaseDate,
             label: label,
             nbTracks: nbTracks,
             duration: duration,
             tracks: tracks,
             hasData: hasData,
             isLoading: !hasData && snapshot.connectionState == ConnectionState.waiting,
             artworkUrl: artworkUrl,
           );
        }
      ),
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
            CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 320,
                  backgroundColor: Colors.transparent,
                  forceMaterialTransparency: true,
                  elevation: 0,
                  title: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _showTitle ? 1.0 : 0.0,
                    child: Text(_title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  ),
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
                            Hero(
                              tag: _isSingleMode ? "track_${widget.singleDetail!.track.id}" : "album_${widget.album!.albumId}",
                              child: AppImage(
                                url: effectiveArtworkUrl,
                                sizePx: Lh3UrlBuilder.headerSize,
                                fit: BoxFit.cover,
                              ),
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
                        // title: Text(_title), // Removed to avoid text-over-image issues
                        centerTitle: true,
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
                  actions: [
                     if (_isSingleMode) 
                        OverflowMenu(type: MenuType.track, track: widget.singleDetail!.track)
                     else
                        OverflowMenu(type: MenuType.album, album: widget.album!),
                     const SizedBox(width: 8),
                  ],
                ),
                
                if (isLoading)
                   const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: AppColors.primaryStart)))
                else if (hasData) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                      child: Column(
                        children: [
                           Text(
                             _title,
                             textAlign: TextAlign.center,
                             style: const TextStyle(
                               fontSize: 28, 
                               fontWeight: FontWeight.w800, 
                               height: 1.2,
                               color: Colors.white
                             ),
                             maxLines: 2,
                             overflow: TextOverflow.ellipsis,
                           ),
                           const SizedBox(height: 8),
                       GestureDetector(
                         onTap: _isNavigatingToArtist ? null : _onArtistTap,
                         child: _isNavigatingToArtist 
                           ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primaryStart))
                           : Text(
                               _artistName,
                               textAlign: TextAlign.center,
                               style: const TextStyle(fontSize: 18, color: AppColors.primaryStart, fontWeight: FontWeight.w500),
                             ),
                       ),
                           const SizedBox(height: 12),
                           Row(
                             mainAxisAlignment: MainAxisAlignment.center,
                             children: [
                               Text(
                                 "${releaseDate.split('-').first} • $nbTracks ${_isSingleMode ? 'song' : 'songs'} • ${_formatTotalDuration(duration)}",
                                 style: const TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.w500),
                               ),
                             ],
                           ),
                           const SizedBox(height: 24),
                           
                           // NEW 3-BUTTON ROW
                           Row(
                             mainAxisAlignment: MainAxisAlignment.center,
                             children: [
                               Consumer<PlaybackController>(
                                  builder: (context, playback, _) {
                                    final isPlaying = playback.isPlaying;
                                    final currentTrack = playback.currentTrack;
                                    // Use albumId from widget.album if available, or try to get from singleDetail
                                    final albumId = widget.album?.albumId ?? (widget.singleDetail?.track.albumId ?? 0);
                                    final isContext = currentTrack?.albumId == albumId;
                                    
                                    return _buildActionButton(
                                      icon: (isPlaying && isContext) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                      label: (isPlaying && isContext) ? "Pause" : "Play",
                                      onTap: () {
                                         if (isContext) {
                                            playback.togglePlayPause();
                                         } else {
                                            if (tracks.isNotEmpty) playback.playQueue(tracks);
                                         }
                                      }, 
                                      primary: true,
                                    );
                                  }
                               ),
                               const SizedBox(width: 24),
                               
                               Consumer<LibraryController>(
                                 builder: (context, lib, _) {
                                   if (_isSingleMode) {
                                      final isLiked = lib.isLiked(widget.singleDetail!.track);
                                      return _buildActionButton(
                                        icon: isLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                        label: isLiked ? "Liked" : "Like",
                                        onTap: () => lib.toggleLike(widget.singleDetail!.track),
                                        color: isLiked ? AppColors.primaryEnd : Colors.white,
                                      );
                                   } else {
                                      final isSaved = lib.isAlbumSaved(widget.album!.albumId);
                                      return _buildActionButton(
                                        icon: isSaved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                                        label: isSaved ? "Saved" : "Save",
                                        onTap: () => lib.toggleSaveAlbum(widget.album!),
                                        color: isSaved ? AppColors.primaryEnd : Colors.white,
                                      );
                                   }
                                 }
                               ),
                               const SizedBox(width: 24),
                               
                               _buildActionButton(
                                 icon: Icons.playlist_add_rounded, 
                                 label: "Add to",
                                 onTap: () {
                                    if (tracks.isEmpty) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No tracks to add")));
                                      return;
                                    }
                                    showModalBottomSheet(
                                       context: context,
                                       useRootNavigator: true,
                                       isScrollControlled: true,
                                       backgroundColor: Colors.transparent,
                                       builder: (context) => AddToPlaylistSheet(tracks: tracks), // Adds all tracks
                                    );
                                 }
                               ),
                             ],
                           ),
                        ],
                      ),
                    ),
                  ),
    
                  if (tracks.isNotEmpty)
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final track = tracks[index];
                        return TrackListTile(
                          track: track,
                          index: index,
                          onTap: () {
                             context.read<PlaybackController>().playQueue(tracks, index: index);
                          },
                        );
                      },
                      childCount: tracks.length,
                    ),
                  )
                  else 
                    const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(32), child: Center(child: Text("No tracks available for this album.", style: TextStyle(color: Colors.grey))))),
                  
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
                ]
              ],
            ),
        ],
      )
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

  String _formatTotalDuration(int totalSeconds) {
    if (totalSeconds < 3600) return "${totalSeconds ~/ 60} min";
    final hours = totalSeconds ~/ 3600;
    final mins = (totalSeconds % 3600) ~/ 60;
    return "$hours hr $mins min";
  }

  Future<void> _onArtistTap() async {
    // Guard against placeholder artist
    if (isPlaceholderArtist(_artistName)) return;

    final explicitId = widget.album?.artistId ?? widget.singleDetail?.track.artistId;
    
    // 1. If we have ID, go direct
    if (explicitId != null && explicitId.isNotEmpty) {
       Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
         artistId: explicitId!, 
         artistName: _artistName
       )));
       return;
    }

    // 2. Fetch via search
    setState(() => _isNavigatingToArtist = true);
    
    try {
      final results = await _repository.searchArtists(_artistName);
      if (!mounted) return;
      
      setState(() => _isNavigatingToArtist = false);
      
      if (results.isNotEmpty) {
        // Assume best match is first
        final artist = results.first;
        Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
           artistId: artist.id,
           artistName: artist.name,
           pictureUrl: artist.picture,
        )));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Artist info unavailable")));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isNavigatingToArtist = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Artist info unavailable")));
      }
    }
  }
}
