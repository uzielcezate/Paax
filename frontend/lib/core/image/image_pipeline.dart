import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Platform-separated image caching pipelines.
/// - Web: Memory-only (NO path_provider, NO disk cache)
/// - Mobile: Disk cache via flutter_cache_manager
class ImagePipeline {
  static final ImagePipeline _instance = ImagePipeline._();
  static ImagePipeline get instance => _instance;

  ImagePipeline._();

  CacheManager? _cacheManager;

  /// Get the cache manager.
  /// Web returns a memory-only config (no disk access).
  /// Mobile returns persistent disk cache.
  CacheManager get cacheManager {
    if (_cacheManager != null) return _cacheManager!;
    
    if (kIsWeb) {
      // Web: Memory-only cache - NO path_provider, NO disk
      // The browser handles caching via HTTP cache headers
      _cacheManager = CacheManager(
        Config(
          'beaty_web_memory',
          stalePeriod: const Duration(hours: 1), // Short for memory
          maxNrOfCacheObjects: 200, // Small for memory
          // Web uses in-memory FileService by default in flutter_cache_manager
        ),
      );
    } else {
      // Mobile: Persistent disk cache
      _cacheManager = CacheManager(
        Config(
          'beaty_images_v2',
          stalePeriod: const Duration(days: 30),
          maxNrOfCacheObjects: 2000,
        ),
      );
    }
    
    return _cacheManager!;
  }

  /// Web-specific in-memory cache for loaded URLs.
  final WebMemoryCache _webCache = WebMemoryCache._();
  WebMemoryCache get webCache => _webCache;

  /// Clear all caches.
  Future<void> clearCache() async {
    if (!kIsWeb) {
      await _cacheManager?.emptyCache();
    }
    _webCache.clear();
  }
}

/// In-memory LRU cache for web platform.
/// Tracks loaded URLs to avoid duplicate requests.
class WebMemoryCache {
  WebMemoryCache._();

  static const int _maxEntries = 500;
  
  // LRU cache using LinkedHashMap with access order
  final LinkedHashMap<String, bool> _cache = LinkedHashMap<String, bool>();
  
  // Inflight requests for deduplication
  final Map<String, Completer<void>> _inflight = {};

  /// Check if URL+size is already cached.
  bool isLoaded(String url, int sizePx) {
    final key = _makeKey(url, sizePx);
    if (_cache.containsKey(key)) {
      // Move to end (most recently used) by removing and re-adding
      _cache.remove(key);
      _cache[key] = true;
      return true;
    }
    return false;
  }

  /// Mark URL+size as loaded.
  void markLoaded(String url, int sizePx) {
    final key = _makeKey(url, sizePx);
    _cache[key] = true;
    
    // Evict oldest entries if over limit
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// Get or create an inflight future for deduplication.
  (Future<void>, bool) getOrCreateInflight(String url, int sizePx) {
    final key = _makeKey(url, sizePx);
    
    if (_inflight.containsKey(key)) {
      return (_inflight[key]!.future, true); // Already inflight
    }
    
    final completer = Completer<void>();
    _inflight[key] = completer;
    return (completer.future, false); // New request
  }

  /// Complete an inflight request.
  void completeInflight(String url, int sizePx) {
    final key = _makeKey(url, sizePx);
    final completer = _inflight.remove(key);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Clear cache.
  void clear() {
    _cache.clear();
    _inflight.clear();
  }

  String _makeKey(String url, int sizePx) => '${url}_$sizePx';
}
