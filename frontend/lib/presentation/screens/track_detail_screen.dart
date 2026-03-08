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
import '../widgets/black_glass_blur_surface.dart';
import '../widgets/music_card.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../../core/playback/playback_diagnostics.dart';

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
             title: AnimatedOpacity(
               duration: const Duration(milliseconds: 200),
               opacity: _showTitle ? 1.0 : 0.0,
               child: Text(widget.track.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
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

            // ── DEBUG-ONLY DIAGNOSTICS PANEL ─────────────────────────────
            // TEMPORARY — remove before production release.
            // Visible only in debug builds; zero cost in release.
            if (kDebugMode)
              ValueListenableBuilder<PlaybackDiagnostics?>(
                valueListenable: PlaybackDiagnosticsNotifier,
                builder: (context, diag, _) {
                  if (diag == null) return const SizedBox.shrink();
                  return _DebugDiagnosticsPanel(diag: diag);
                },
              ),

            // Recommended Section (Horizontal Rail)
            Align(
              alignment: Alignment.centerLeft,
              child: Text("Recommended for you", style: Theme.of(context).textTheme.titleLarge),
            ),
            const SizedBox(height: 16),
            
            FutureBuilder<List<Track>>(
              future: _artistTracksFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: AppColors.primaryStart));
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
        
        ],
      )
    );
  }
  
  Widget _buildActionButton({required IconData icon, required String label, required VoidCallback onTap, bool primary = false, Color color = Colors.white}) {
    return Column(
      children: [
        Container(
          width: 60, height: 60,
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
}

// =============================================================================
// TEMPORARY DEBUG-ONLY WIDGET — remove before shipping to production.
// =============================================================================
class _DebugDiagnosticsPanel extends StatelessWidget {
  final PlaybackDiagnostics diag;
  const _DebugDiagnosticsPanel({required this.diag});

  @override
  Widget build(BuildContext context) {
    final isResolving = diag.failedAt == null && !diag.succeeded
        && diag.urlHost == '…';
    final statusColor = diag.succeeded
        ? Colors.greenAccent
        : isResolving
            ? Colors.amber
            : Colors.redAccent;
    final statusLabel = diag.succeeded
        ? '✓ PLAYING'
        : isResolving
            ? '⧗ Resolving…'
            : '✗ FAILED at ${diag.failedAt ?? 'resolve'}'
            '${diag.shortReason != null ? '' : ''}';

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E).withOpacity(0.95),
        border: Border.all(color: statusColor.withOpacity(0.6), width: 1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bug_report, color: statusColor, size: 14),
              const SizedBox(width: 6),
              Text(
                'DEBUG — Playback Diagnostics',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _row('Status', statusLabel, statusColor),
          _row('videoId', diag.videoId),
          _row('host', diag.urlHost),
          _row('scheme', diag.urlScheme),
          _row('mime', diag.mimeType),
          _row('container', diag.container),
          _row('bitrate', diag.bitrateKbps > 0 ? '${diag.bitrateKbps} kbps' : '?'),
          _row('size known', diag.sizeKnown
              ? '${(diag.totalBytes / 1024 / 1024).toStringAsFixed(2)} MB'
              : '✗ unknown (duration inferred)'),
          _row('headers', diag.headersAttached ? '✓ attached' : '✗ missing!'),
          _row('direct stream', diag.directStream ? '✓ byte-pipe' : '✗ redirected URL'),
          _row('is manifest', diag.isManifest ? '⚠ YES — not a direct stream!' : 'no'),
          if (!diag.succeeded && diag.shortReason != null) ...[
            const Divider(color: Colors.white24, height: 16),
            _row('failed at', diag.failedAt ?? 'resolve', Colors.redAccent),
            _row('reason', diag.shortReason!, Colors.orangeAccent),
            if (diag.exceptionMessage != null)
              _row('exception', diag.exceptionMessage!, Colors.white54),
          ],
        ],
      ),
    );
  }

  Widget _row(String label, String value, [Color valueColor = Colors.white70]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10.5),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor, fontSize: 10.5, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
