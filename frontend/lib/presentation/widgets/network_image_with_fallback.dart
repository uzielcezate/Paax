import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_colors.dart';
import '../../core/network/throttled_cache_manager.dart';
import '../../core/network/image_load_queue.dart';

/// Network image widget with automatic fallback and rate limiting on web.
class NetworkImageWithFallback extends StatefulWidget {
  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final Widget? placeholderOverride;
  final int? memCacheWidth;
  final int? memCacheHeight;

  const NetworkImageWithFallback({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.placeholderOverride,
    this.memCacheWidth,
    this.memCacheHeight,
  });

  @override
  State<NetworkImageWithFallback> createState() => _NetworkImageWithFallbackState();
}

class _NetworkImageWithFallbackState extends State<NetworkImageWithFallback> {
  bool _canLoad = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _requestLoadPermission();
  }

  void _requestLoadPermission() async {
    // On mobile, load immediately. On web, use queue to stagger.
    if (!kIsWeb) {
      if (mounted) setState(() => _canLoad = true);
      return;
    }

    // Request permission from the global queue
    await ImageLoadQueue.instance.enqueue(() async {
      // Small artificial delay to spread requests
      await Future.delayed(const Duration(milliseconds: 75));
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

    // Show placeholder until queue permits loading
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
    return widget.placeholderOverride ?? Container(
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

