import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_colors.dart';
import '../../core/network/throttled_cache_manager.dart';
import '../../core/network/image_load_queue.dart';

/// A network image widget that uses a global queue to stagger image loading.
/// This prevents overwhelming the server with too many concurrent requests,
/// especially important on Flutter Web where browser handles HTTP directly.
class QueuedNetworkImage extends StatefulWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final int? memCacheWidth;
  final int? memCacheHeight;

  const QueuedNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.memCacheWidth,
    this.memCacheHeight,
  });

  @override
  State<QueuedNetworkImage> createState() => _QueuedNetworkImageState();
}

class _QueuedNetworkImageState extends State<QueuedNetworkImage> {
  bool _canLoad = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _requestLoadPermission();
  }

  void _requestLoadPermission() async {
    // On mobile, load immediately. On web, use queue.
    if (!kIsWeb) {
      if (mounted) setState(() => _canLoad = true);
      return;
    }

    // Request permission from the queue
    await ImageLoadQueue.instance.enqueue(() async {
      // Small delay to stagger requests
      await Future.delayed(const Duration(milliseconds: 50));
    });

    if (!_disposed && mounted) {
      setState(() => _canLoad = true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl.isEmpty) {
      return _buildFallback();
    }

    if (!_canLoad) {
      return _buildPlaceholder();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: CachedNetworkImage(
        imageUrl: widget.imageUrl,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        fadeInDuration: const Duration(milliseconds: 300),
        cacheManager: ThrottledCacheManager(),
        memCacheHeight: widget.memCacheHeight ?? (widget.height != null ? (widget.height! * 2).toInt() : null),
        memCacheWidth: widget.memCacheWidth ?? (widget.width != null ? (widget.width! * 2).toInt() : null),
        maxHeightDiskCache: 1000, 
        maxWidthDiskCache: 1000,
        placeholder: (context, url) => _buildPlaceholder(),
        errorWidget: (context, url, error) => _buildFallback(),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Colors.white10, size: 24),
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(widget.borderRadius),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white24, 
          size: (widget.width != null && widget.width! < 50) ? 20 : 32,
        ),
      ),
    );
  }
}
