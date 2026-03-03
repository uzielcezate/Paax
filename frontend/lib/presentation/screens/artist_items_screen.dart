import 'package:flutter/material.dart';
import '../../domain/entities/saved_album.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/repositories/music_repository.dart';
import '../../core/theme/app_colors.dart';
import '../widgets/music_card.dart';
import 'album_detail_screen.dart'; // To navigate to album details
import 'package:shimmer/shimmer.dart';

class ArtistItemsScreen extends StatefulWidget {
  final String artistId;
  final String title;
  final String? initialParams;

  const ArtistItemsScreen({
    super.key,
    required this.artistId,
    required this.title,
    this.initialParams,
  });

  @override
  State<ArtistItemsScreen> createState() => _ArtistItemsScreenState();
}

class _ArtistItemsScreenState extends State<ArtistItemsScreen> {
  final MusicRepository _repository = MusicRepositoryImpl();
  final ScrollController _scrollController = ScrollController();
  final List<SavedAlbum> _items = [];
  
  String? _nextPageToken;
  bool _isLoading = false;
  bool _hasError = false;
  bool _isFirstLoad = true;

  @override
  void initState() {
    super.initState();
    _fetchPage(isFirst: true);
    _scrollController.addListener(_onScroll);
  }
  
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isFirstLoad) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _nextPageToken != null) {
      _fetchPage();
    }
  }

  Future<void> _fetchPage({bool isFirst = false}) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final (newItems, token) = await _repository.getArtistAlbumsPage(
        widget.artistId,
        widget.initialParams, // Always pass initial params if needed for context
        isFirst ? null : _nextPageToken,
      );

      if (mounted) {
        setState(() {
          // Deduplicate if needed?
          // Usually YouTube paging is clean, but safe to check IDs?
          // For now, append.
          _items.addAll(newItems);
          _nextPageToken = token;
          _isLoading = false;
          _isFirstLoad = false;
        });
      }
    } catch (e) {
      print("Error fetching artist items page: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError && _items.isEmpty) {
        return Scaffold(
            appBar: AppBar(title: Text(widget.title), backgroundColor: Colors.transparent, elevation: 0),
            backgroundColor: AppColors.background,
            body: Center(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                        const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                        const SizedBox(height: 16),
                        const Text("Failed to load items", style: TextStyle(color: Colors.white70)),
                        const SizedBox(height: 16),
                        TextButton(
                            onPressed: () => _fetchPage(isFirst: true), 
                            child: const Text("Retry", style: TextStyle(color: AppColors.primaryStart))
                        )
                    ]
                )
            )
        );
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _isFirstLoad && _isLoading 
          ? _buildShimmerGrid() 
          : _items.isEmpty && !_isLoading
              ? const Center(child: Text("No items found", style: TextStyle(color: Colors.white54)))
              : _buildGrid(),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75, // Adjust card aspect ratio
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _items.length + (_isLoading ? 2 : 0), // Show loading placeholders
      itemBuilder: (context, index) {
        if (index >= _items.length) {
             return _buildShimmerCard();
        }
        final item = _items[index];
        return MusicCard(
          title: item.title,
          subtitle: item.releaseDate ?? item.artistName,
          imageUrl: item.artworkUrl,
          onTap: () {
             Navigator.push(context, MaterialPageRoute(builder: (_) => AlbumDetailScreen(album: item)));
          },
        );
      },
    );
  }
  
  Widget _buildShimmerGrid() {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
           crossAxisCount: 2,
           childAspectRatio: 0.75,
           crossAxisSpacing: 16,
           mainAxisSpacing: 16,
        ),
        itemCount: 6,
        itemBuilder: (_, __) => _buildShimmerCard(),
      );
  }

  Widget _buildShimmerCard() {
    return Shimmer.fromColors(
      baseColor: Colors.grey[900]!,
      highlightColor: Colors.grey[800]!,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Container(width: 100, height: 12, color: Colors.white),
          const SizedBox(height: 4),
          Container(width: 60, height: 10, color: Colors.white),
        ],
      ),
    );
  }
}
