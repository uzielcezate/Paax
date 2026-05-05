import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/app_colors.dart';
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

  // Resolved from the API — takes priority over widget.album fields
  // to fix the context inheritance bug where track.artistName overwrites album artist.
  String? _resolvedArtistName;
  String? _resolvedArtistId;
  List<Map<String, String>>? _resolvedArtists;

  bool get _isSingleMode => widget.singleDetail != null;

  String get _title => _isSingleMode ? widget.singleDetail!.title : widget.album!.title;
  // Prefer building display name from the resolved artists list (e.g. "Anuel AA, Ozuna"),
  // then fall back to the resolved single string, then the widget's initial data.
  String get _artistName {
    if (_resolvedArtists != null && _resolvedArtists!.isNotEmpty) {
      return _resolvedArtists!.map((a) => a['name']).join(', ');
    }
    return _resolvedArtistName
        ?? (_isSingleMode ? widget.singleDetail!.artistName : widget.album!.artistName);
  }
  String get _artworkUrl => _isSingleMode ? widget.singleDetail!.artworkUrl : widget.album!.artworkUrl;

  @override
  void initState() {
    super.initState();
    if (!_isSingleMode) {
      _detailsFuture = _repository.getAlbum(widget.album!.albumId).then((album) {
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

  /// Cross-reference album tracks with the playback queue to get richer artist
  /// metadata. The YouTube Music album API often returns only the primary artist,
  /// while the search/play queue contains all collaborators.
  SavedAlbum _enrichFromPlayback(SavedAlbum album) {
    final controller = context.read<PlaybackController>();
    final currentTrack = controller.currentTrack;
    final queue = controller.queue;

    if (album.tracks == null || album.tracks!.isEmpty) return album;

    // Build lookup map: videoId → richest Track from playback queue
    final Map<String, Track> richMap = {};
    for (final t in queue) {
      final existing = richMap[t.id];
      if (existing == null || (t.artists?.length ?? 0) > (existing.artists?.length ?? 0)) {
        richMap[t.id] = t;
      }
    }
    if (currentTrack != null) {
      final existing = richMap[currentTrack.id];
      if (existing == null || (currentTrack.artists?.length ?? 0) > (existing.artists?.length ?? 0)) {
        richMap[currentTrack.id] = currentTrack;
      }
    }

    // Enrich each album track with richer artist data from the queue
    final enrichedTracks = album.tracks!.map((t) {
      final rich = richMap[t.id];
      if (rich != null && (rich.artists?.length ?? 0) > (t.artists?.length ?? 0)) {
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
      if (q.id == track.id && (q.artists?.length ?? 0) > (track.artists?.length ?? 0)) {
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
      final enrichedTrack = _enrichTrackFromPlayback(widget.singleDetail!.track);

      // Update resolved artists if the enriched track has more
      if (_resolvedArtists == null && enrichedTrack.artists != null &&
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
                  ),
                ),
                
                if (isLoading)
                   SliverList(
                     delegate: SliverChildBuilderDelegate(
                       (context, index) => _buildSkeletonRow(),
                       childCount: 8, // Show 8 placeholder rows
                     ),
                   )
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

            // Top fade gradient
            const TopFadeGradient(height: 110),

            // Floating controls
            FloatingTopControls(
              showScrolledPill: _showTitle,
              topPadding: MediaQuery.of(context).padding.top,
              defaultControls: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GlassCircleButton(
                    icon: Icons.arrow_back_ios_new,
                    iconSize: 18,
                    onPressed: () => Navigator.pop(context),
                  ),
                  GlassMenuButton(
                    child: _isSingleMode
                        ? OverflowMenu(type: MenuType.track, track: widget.singleDetail!.track)
                        : OverflowMenu(type: MenuType.album, album: widget.album!),
                  ),
                ],
              ),
              scrolledPill: ScrolledTopPill(
                title: _title,
                onBack: () => Navigator.pop(context),
                trailing: _isSingleMode
                    ? OverflowMenu(type: MenuType.track, track: widget.singleDetail!.track)
                    : OverflowMenu(type: MenuType.album, album: widget.album!),
              ),
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
                  Container(height: 14, width: double.infinity, color: Colors.white),
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
        .where((a) => (a['id'] ?? '').isNotEmpty && (a['name'] ?? '').isNotEmpty)
        .toList();

    if (validArtists.isEmpty) {
      // Fallback: try single artist ID
      final fallbackId = _resolvedArtistId
          ?? widget.album?.artistId
          ?? widget.singleDetail?.track.artistId
          ?? '';

      if (fallbackId.isNotEmpty) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
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
          Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
            artistId: results.first.id,
            artistName: results.first.name,
            pictureUrl: results.first.picture,
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
      return;
    }

    // Single artist → route directly
    if (validArtists.length == 1) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
        artistId: validArtists.first['id']!,
        artistName: validArtists.first['name']!,
      )));
      return;
    }

    // Multiple artists → show selection BottomSheet
    _showAlbumArtistPicker(validArtists);
  }

  /// Multi-artist selection BottomSheet for album headers.
  void _showAlbumArtistPicker(List<Map<String, String>> artists) {
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A).withOpacity(0.9),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05), width: 1)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    child: Text(
                      "Choose Artist",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Divider(color: Colors.white.withOpacity(0.1)),
                  ...artists.map((a) => ListTile(
                    leading: const Icon(Icons.person_outline, color: Colors.white70),
                    title: Text(
                      a['name'] ?? '',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    onTap: () {
                      Navigator.pop(sheetCtx);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ArtistDetailScreen(
                        artistId: a['id']!,
                        artistName: a['name']!,
                      )));
                    },
                  )),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
