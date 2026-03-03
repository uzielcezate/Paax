import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/image_request_queue.dart';
import '../../core/image/image_size_config.dart';
import '../../core/image/platform_cache_manager.dart';

/// Production-grade network image widget with:
/// - Visibility-based loading (never loads off-screen images)
/// - Queue-based rate limiting (prevents 429s)
/// - Context-aware sizing
/// - Graceful placeholders (never shows error UI)
/// - No flicker with gaplessPlayback
class SmartNetworkImage extends StatefulWidget {
  final String imageUrl;
  final ImageContext context;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double borderRadius;
  final Color? placeholderColor;
  final bool isCircular;

  const SmartNetworkImage({
    super.key,
    required this.imageUrl,
    this.context = ImageContext.list,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.placeholderColor,
    this.isCircular = false,
  });

  @override
  State<SmartNetworkImage> createState() => _SmartNetworkImageState();
}

class _SmartNetworkImageState extends State<SmartNetworkImage> {
  bool _isVisible = false;
  bool _hasRequestedLoad = false;
  bool _canLoad = false;
  bool _hasError = false;
  bool _disposed = false;
  
  // Unique key for visibility detector
  late final String _visibilityKey;
  
  @override
  void initState() {
    super.initState();
    _visibilityKey = 'smart_img_${widget.imageUrl.hashCode}_${DateTime.now().microsecondsSinceEpoch}';
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (_disposed) return;
    
    final wasVisible = _isVisible;
    _isVisible = info.visibleFraction > 0;
    
    // Only request load when becoming visible for the first time
    if (_isVisible && !wasVisible && !_hasRequestedLoad) {
      // Defer to avoid calling setState during build
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && mounted) {
          _requestLoadPermission();
        }
      });
    }
  }

  void _requestLoadPermission() async {
    if (_hasRequestedLoad || _disposed) return;
    _hasRequestedLoad = true;
    
    // Check if already in memory cache (skip queue)
    if (kIsWeb) {
      final size = getImageSize(widget.context);
      if (WebMemoryCache.instance.isLoaded(widget.imageUrl, size)) {
        _safeSetState(() => _canLoad = true);
        return;
      }
    }
    
    // On mobile, load immediately if not rate-limited
    // On web, always use queue
    if (!kIsWeb && !ImageRequestQueue.instance.isInCooldown()) {
      _safeSetState(() => _canLoad = true);
      return;
    }
    
    // Request permission from queue
    final (future, _) = ImageRequestQueue.instance.enqueue(widget.imageUrl);
    await future;
    
    _safeSetState(() => _canLoad = true);
    
    // Mark as loaded in web memory cache
    if (kIsWeb) {
      final size = getImageSize(widget.context);
      WebMemoryCache.instance.markLoaded(widget.imageUrl, size);
    }
  }
  
  /// Safe setState that defers if called during build
  void _safeSetState(VoidCallback fn) {
    if (_disposed || !mounted) return;
    
    // Use addPostFrameCallback to avoid setState during build
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && mounted) {
        setState(fn);
      }
    });
  }

  void _onImageError(Object error) {
    if (_disposed) return;
    
    // Check for 429 and report to queue
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('429') || errorStr.contains('too many')) {
      ImageRequestQueue.instance.report429(widget.imageUrl);
    }
    
    // Use _safeSetState to defer setState until after build phase
    _safeSetState(() => _hasError = true);
    
    // Silent logging in debug only
    if (kDebugMode) {
      print('[SmartNetworkImage] Error loading ${widget.imageUrl}: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.imageUrl.isEmpty) {
      return _buildPlaceholder();
    }

    return VisibilityDetector(
      key: Key(_visibilityKey),
      onVisibilityChanged: _onVisibilityChanged,
      child: _buildImageContent(),
    );
  }

  Widget _buildImageContent() {
    // Show placeholder until:
    // 1. Image becomes visible AND
    // 2. Queue grants permission to load
    if (!_canLoad) {
      return _buildPlaceholder();
    }

    // If error occurred, show placeholder (never error UI)
    if (_hasError) {
      return _buildPlaceholder();
    }

    final size = getImageSize(widget.context);
    final memCacheSize = getMemCacheSize(widget.context);

    Widget image = CachedNetworkImage(
      imageUrl: widget.imageUrl,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      fadeInDuration: const Duration(milliseconds: 200),
      fadeOutDuration: const Duration(milliseconds: 100),
      cacheManager: PlatformCacheManager.instance.cacheManager,
      memCacheWidth: memCacheSize,
      memCacheHeight: memCacheSize,
      maxWidthDiskCache: size,
      maxHeightDiskCache: size,
      // Prevent flicker on rebuild
      useOldImageOnUrlChange: true,
      placeholder: (ctx, url) => _buildPlaceholder(),
      errorWidget: (ctx, url, error) {
        // Report error but show placeholder, never error UI
        _onImageError(error);
        return _buildPlaceholder();
      },
    );

    // Apply shape
    if (widget.isCircular) {
      image = ClipOval(child: image);
    } else if (widget.borderRadius > 0) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: image,
      );
    }

    return image;
  }

  Widget _buildPlaceholder() {
    final color = widget.placeholderColor ?? AppColors.surfaceLight;
    
    Widget placeholder = Container(
      width: widget.width,
      height: widget.height,
      color: color,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white.withOpacity(0.1),
          size: _getPlaceholderIconSize(),
        ),
      ),
    );

    if (widget.isCircular) {
      placeholder = ClipOval(child: placeholder);
    } else if (widget.borderRadius > 0) {
      placeholder = ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: placeholder,
      );
    }

    return placeholder;
  }

  double _getPlaceholderIconSize() {
    final size = widget.width ?? widget.height ?? 48;
    if (size < 50) return 16;
    if (size < 100) return 24;
    return 32;
  }
}
