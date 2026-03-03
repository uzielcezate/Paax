/// Image size configuration for context-aware loading.
/// Sizes optimized for performance while maintaining visual quality.
enum ImageContext {
  /// Lists, grids, small thumbnails (128-160px)
  list,
  /// Mini player at bottom (256px)
  miniPlayer,
  /// Full-screen player (512px)
  fullPlayer,
  /// Artist/album header images (720px)
  header,
}

/// Returns the optimal pixel size for a given image context.
int getImageSize(ImageContext context) {
  switch (context) {
    case ImageContext.list:
      return 160;
    case ImageContext.miniPlayer:
      return 256;
    case ImageContext.fullPlayer:
      return 512;
    case ImageContext.header:
      return 720;
  }
}

/// Returns the memory cache size (2x display for retina).
int getMemCacheSize(ImageContext context) {
  return getImageSize(context) * 2;
}
