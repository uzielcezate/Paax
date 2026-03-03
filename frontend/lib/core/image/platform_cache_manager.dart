import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

/// Platform-aware cache manager.
/// - Web: Memory-only caching (no path_provider)
/// - Mobile: Persistent disk cache with path_provider
class PlatformCacheManager {
  static final PlatformCacheManager _instance = PlatformCacheManager._();
  static PlatformCacheManager get instance => _instance;
  
  PlatformCacheManager._();
  
  CacheManager? _cacheManager;
  
  /// Get the platform-appropriate cache manager.
  CacheManager get cacheManager {
    if (_cacheManager != null) return _cacheManager!;
    
    if (kIsWeb) {
      // Web: Use default cache manager with memory-only focus
      _cacheManager = CacheManager(
        Config(
          'beaty_image_cache_web',
          stalePeriod: const Duration(days: 1), // Shorter for web (session-like)
          maxNrOfCacheObjects: 500, // Lower for web memory
        ),
      );
    } else {
      // Mobile: Persistent disk cache
      _cacheManager = CacheManager(
        Config(
          'beaty_image_cache',
          stalePeriod: const Duration(days: 30), // Long TTL for mobile
          maxNrOfCacheObjects: 2000,
        ),
      );
    }
    
    return _cacheManager!;
  }
  
  /// Generate a cache key from URL and size.
  String getCacheKey(String url, int size) {
    return '${url}_$size';
  }
  
  /// Clear cache (for debugging/settings).
  Future<void> clearCache() async {
    await _cacheManager?.emptyCache();
  }
}

/// Simple in-memory cache for web to track already-loaded URLs.
class WebMemoryCache {
  static final WebMemoryCache _instance = WebMemoryCache._();
  static WebMemoryCache get instance => _instance;
  
  WebMemoryCache._();
  
  final Set<String> _loadedUrls = {};
  
  /// Check if URL+size combo is already cached.
  bool isLoaded(String url, int size) {
    return _loadedUrls.contains('${url}_$size');
  }
  
  /// Mark URL+size as loaded.
  void markLoaded(String url, int size) {
    _loadedUrls.add('${url}_$size');
    
    // Limit memory usage
    if (_loadedUrls.length > 1000) {
      // Remove oldest entries (FIFO approximation)
      final toRemove = _loadedUrls.take(200).toList();
      _loadedUrls.removeAll(toRemove);
    }
  }
  
  /// Check if we have this URL in memory.
  bool contains(String key) => _loadedUrls.contains(key);
}
