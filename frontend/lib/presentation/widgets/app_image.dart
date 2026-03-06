import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/image/lh3_url_builder.dart';
import '../../core/image/image_request_queue.dart';
import '../../core/image/image_pipeline.dart';

/// Unified image widget for the entire app.
/// 
/// Features:
/// - Visibility-based loading (never loads off-screen)
/// - Automatic URL normalization for lh3 thumbnails
/// - Queue integration with priority and cancellation
/// - Platform-aware rendering (Web: Image.network, Mobile: CachedNetworkImage)
/// - Never calls setState during build
/// - Graceful placeholders (never shows error UI)
/// 
/// Standard sizes:
/// - [Lh3UrlBuilder.listSize] (160px) - for lists/grids
/// - [Lh3UrlBuilder.miniPlayerSize] (256px) - for mini player
/// - [Lh3UrlBuilder.fullPlayerSize] (512px) - for full player
/// - [Lh3UrlBuilder.headerSize] (720px) - for artist/album headers
class AppImage extends StatefulWidget {
  /// Original image URL (will be normalized).
  final String url;
  
  /// Target size in pixels. Use constants from [Lh3UrlBuilder].
  final int sizePx;
  
  /// Display width.
  final double? width;
  
  /// Display height.
  final double? height;
  
  /// Border radius.
  final double borderRadius;
  
  /// Box fit.
  final BoxFit fit;
  
  /// Whether to use circular clip.
  final bool isCircular;
  
  /// Placeholder background color.
  final Color? placeholderColor;

  /// When true, bypass the VisibilityDetector queue and load immediately.
  /// Use this for artwork that is always visible on first paint (player screens).
  final bool forceLoad;

  const AppImage({
    super.key,
    required this.url,
    required this.sizePx,
    this.width,
    this.height,
    this.borderRadius = 0,
    this.fit = BoxFit.cover,
    this.isCircular = false,
    this.placeholderColor,
    this.forceLoad = false,
  });

  @override
  State<AppImage> createState() => _AppImageState();
}

class _AppImageState extends State<AppImage> {
  bool _canLoad = false;
  bool _hasError = false;
  bool _disposed = false;
  String? _requestId;
  
  late String _visibilityKey;
  late String _sizedUrl;

  @override
  void initState() {
    super.initState();
    _visibilityKey = 'app_img_${widget.url.hashCode}_${DateTime.now().microsecondsSinceEpoch}';
    _sizedUrl = Lh3UrlBuilder.build(widget.url, widget.sizePx);
    // For always-visible widgets (e.g. player artwork) skip the queue entirely.
    if (widget.forceLoad && widget.url.isNotEmpty) {
      _canLoad = true;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // Cancel pending request
    if (_requestId != null) {
      ImageRequestQueue.instance.cancel(_requestId!);
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(AppImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.sizePx != widget.sizePx) {
      // URL changed - reset state and recalculate
      _hasError = false;
      _sizedUrl = Lh3UrlBuilder.build(widget.url, widget.sizePx);
      if (widget.forceLoad && widget.url.isNotEmpty) {
        // Stay loaded for force-load images; just update the URL.
        _canLoad = true;
      } else {
        _canLoad = false;
      }
      if (_requestId != null) {
        ImageRequestQueue.instance.cancel(_requestId!);
        _requestId = null;
      }
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (_disposed) return;
    
    final isVisible = info.visibleFraction > 0;
    
    if (isVisible && !_canLoad) {
      // Retry if we had an error and cooldown has expired
      if (_hasError && !ImageRequestQueue.instance.isInCooldown(_sizedUrl)) {
        _hasError = false; // Reset error to retry
      }
      
      if (!_hasError) {
        // Schedule load permission request after frame
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!_disposed && mounted) {
            _requestLoadPermission();
          }
        });
      }
    }
  }

  Future<void> _requestLoadPermission() async {
    if (_canLoad || _disposed) return;
    
    // Check web memory cache first
    if (kIsWeb) {
      if (ImagePipeline.instance.webCache.isLoaded(widget.url, widget.sizePx)) {
        _safeSetState(() => _canLoad = true);
        return;
      }
    }
    
    // Check if host is throttled
    if (ImageRequestQueue.instance.isInCooldown(_sizedUrl)) {
      // Will retry when visible again
      return;
    }
    
    // Enqueue request
    final (future, requestId) = ImageRequestQueue.instance.enqueue(
      _sizedUrl,
      priority: ImagePriority.onScreen,
    );
    _requestId = requestId;
    
    await future;
    
    if (!_disposed && mounted) {
      _safeSetState(() => _canLoad = true);
      
      // Mark as loaded in web cache
      if (kIsWeb) {
        ImagePipeline.instance.webCache.markLoaded(widget.url, widget.sizePx);
      }
    }
  }

  void _safeSetState(VoidCallback fn) {
    if (_disposed || !mounted) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed && mounted) {
        setState(fn);
      }
    });
  }

  void _onImageError(Object error) {
    if (_disposed) return;
    
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('429') || errorStr.contains('too many')) {
      ImageRequestQueue.instance.report429(_sizedUrl);
    }
    
    if (kDebugMode) {
      print('[AppImage] Error loading $_sizedUrl: $error');
    }
    
    _safeSetState(() => _hasError = true);
  }

  void _onImageLoaded() {
    if (_disposed) return;
    ImageRequestQueue.instance.reportSuccess(_sizedUrl);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) {
      return _buildPlaceholder();
    }

    return VisibilityDetector(
      key: Key(_visibilityKey),
      onVisibilityChanged: _onVisibilityChanged,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (!_canLoad || _hasError) {
      return _buildPlaceholder();
    }

    // Use higher filter quality for larger images
    final filterQuality = widget.sizePx >= Lh3UrlBuilder.fullPlayerSize
        ? FilterQuality.high
        : FilterQuality.medium;

    Widget image;
    
    if (kIsWeb) {
      // WEB: Use Image.network - NO path_provider, NO disk cache
      // Browser handles caching via HTTP headers
      image = Image.network(
        _sizedUrl,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        filterQuality: filterQuality,
        cacheWidth: widget.sizePx,
        cacheHeight: widget.sizePx,
        gaplessPlayback: true, // Prevents flicker on rebuild
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) {
            _onImageLoaded();
            return child;
          }
          return _buildPlaceholder();
        },
        errorBuilder: (context, error, stackTrace) {
          _onImageError(error);
          return _buildPlaceholder();
        },
      );
    } else {
      // MOBILE: Use CachedNetworkImage with disk cache
      image = CachedNetworkImage(
        imageUrl: _sizedUrl,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        filterQuality: filterQuality,
        fadeInDuration: const Duration(milliseconds: 200),
        fadeOutDuration: const Duration(milliseconds: 100),
        cacheManager: ImagePipeline.instance.cacheManager,
        memCacheWidth: widget.sizePx,
        memCacheHeight: widget.sizePx,
        maxWidthDiskCache: widget.sizePx,
        maxHeightDiskCache: widget.sizePx,
        useOldImageOnUrlChange: true,
        placeholder: (_, __) => _buildPlaceholder(),
        errorWidget: (_, __, error) {
          _onImageError(error);
          return _buildPlaceholder();
        },
        imageBuilder: (context, imageProvider) {
          _onImageLoaded();
          return Image(
            image: imageProvider,
            width: widget.width,
            height: widget.height,
            fit: widget.fit,
            filterQuality: filterQuality,
          );
        },
      );
    }

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
    final iconSize = _getPlaceholderIconSize();

    Widget placeholder = Container(
      width: widget.width,
      height: widget.height,
      color: color,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: Colors.white.withOpacity(0.1),
          size: iconSize,
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
