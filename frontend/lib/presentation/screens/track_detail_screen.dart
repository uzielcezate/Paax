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

        // ─────────────────────────────────────────────────────────────────
        // DEBUG-ONLY OVERLAY — TEMPORARY, remove before production.
        // Positioned at top of screen, overlaying all scrollable content.
        // Always visible in debug mode regardless of scroll position or state.
        // ─────────────────────────────────────────────────────────────────
        if (kDebugMode)
          Positioned(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 4,
            left: 12,
            right: 12,
            child: ValueListenableBuilder<PlaybackDiagnostics?>(
              valueListenable: PlaybackDiagnosticsNotifier,
              builder: (context, diag, _) => _DebugDiagnosticsPanel(diag: diag),
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
// Positioned overlay at top of screen; always rendered in debug mode.
// =============================================================================
class _DebugDiagnosticsPanel extends StatelessWidget {
  // Nullable: shows placeholder when no diagnostics have been published yet.
  final PlaybackDiagnostics? diag;
  const _DebugDiagnosticsPanel({required this.diag});

  @override
  Widget build(BuildContext context) {
    // ── Null state: no track has been played yet ──────────────────────────
    if (diag == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A00).withOpacity(0.97),
          border: Border.all(color: Colors.yellowAccent, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          children: [
            Icon(Icons.bug_report, color: Colors.yellowAccent, size: 14),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'DEBUG PLAYBACK INFO — no diagnostics yet. Tap Play to begin.',
                style: TextStyle(
                  color: Colors.yellowAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final d = diag!;
    final isResolving = d.failedAt == null && !d.succeeded && d.urlHost == '…';
    final statusColor = d.succeeded
        ? Colors.greenAccent
        : isResolving
            ? Colors.amber
            : Colors.redAccent;
    final statusLabel = d.succeeded
        ? '✓ PLAYING'
        : isResolving
            ? '⧗ Resolving…'
            : '✗ FAILED at ${d.failedAt ?? 'resolve'}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xEE0A0A1A),
        border: Border.all(color: statusColor, width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.bug_report, color: statusColor, size: 14),
              const SizedBox(width: 6),
              Text(
                'DEBUG PLAYBACK INFO',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _row('status', statusLabel, statusColor),
          _row('videoId', d.videoId),
          _row('host', d.urlHost),
          _row('scheme', d.urlScheme),
          _row('mime', d.mimeType),
          _row('container', d.container),
          _row('bitrate', d.bitrateKbps > 0 ? '${d.bitrateKbps} kbps' : '?'),
          _row('size', d.sizeKnown
              ? '${(d.totalBytes / 1024 / 1024).toStringAsFixed(2)} MB'
              : '✗ unknown'),
          _row('headers', d.headersAttached ? '✓ attached' : '✗ MISSING'),
          _row('direct', d.directStream ? '✓ byte-pipe' : '✗ URL redirect'),
          _row('manifest', d.isManifest ? '⚠ YES — bad!' : 'no'),
          if (!d.succeeded && d.shortReason != null) ...[
            const Divider(color: Colors.white24, height: 12),
            _row('failed at', d.failedAt ?? 'resolve', Colors.redAccent),
            _row('reason', d.shortReason!, Colors.orangeAccent),
            if (d.exceptionMessage != null)
              _row('exception', d.exceptionMessage!, Colors.white54),
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
            width: 72,
            child: Text(label,
                style: const TextStyle(color: Colors.white38, fontSize: 10.5)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: valueColor,
                    fontSize: 10.5,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

