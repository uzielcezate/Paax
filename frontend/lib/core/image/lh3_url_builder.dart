import 'dart:math';

/// Strict URL sizing for googleusercontent.com thumbnails.
/// Enforces consistent sizes and implements DOMAIN SHARDING to prevent 429 errors.
class Lh3UrlBuilder {
  /// Standard sizes (DO NOT EXCEED):
  /// - List/Grid: 160px
  /// - Mini Player: 256px
  /// - Full Player: 512px
  /// - Header: 720px
  static const int listSize = 160;
  static const int miniPlayerSize = 256;
  static const int fullPlayerSize = 512;
  static const int headerSize = 720;

  static final RegExp _sizePattern = RegExp(r'=w\d+-h\d+|=s\d+');
  static final RegExp _domainPattern = RegExp(r'lh3\.googleusercontent\.com');

  /// Available domains for sharding
  static final List<String> _shards = [
    'lh3.googleusercontent.com',
    'lh4.googleusercontent.com',
    'lh5.googleusercontent.com',
    'lh6.googleusercontent.com',
  ];

  /// Builds a sized URL with domain sharding.
  /// Rotates the domain based on hash code to distribute load.
  static String build(String url, int targetPx) {
    if (url.isEmpty) return url;
    
    // Check if it's a google user content URL
    if (!url.contains('.googleusercontent.com')) {
      return url;
    }

    String processedUrl = url;

    // 1. Shard the domain if it is 'lh3'
    if (url.contains('lh3.googleusercontent.com')) {
      // Use hash of the URL path to consistently pick a shard
      // This ensures the same image always uses the same shard (better for caching)
      // BUT helps distribute different images across shards
      final hash = url.hashCode;
      final shardIndex = hash.abs() % _shards.length;
      final targetShard = _shards[shardIndex];
      
      processedUrl = url.replaceFirst('lh3.googleusercontent.com', targetShard);
    }

    // 2. Enforce size
    if (_sizePattern.hasMatch(processedUrl)) {
      return processedUrl.replaceAllMapped(
        _sizePattern,
        (_) => '=w$targetPx-h$targetPx',
      );
    }

    // No size param found - append one
    if (processedUrl.contains('=')) {
      return '$processedUrl-w$targetPx-h$targetPx';
    } else {
      return '$processedUrl=w$targetPx-h$targetPx-l90-rj';
    }
  }

  /// Convenience methods for common contexts
  static String forList(String url) => build(url, listSize);
  static String forMiniPlayer(String url) => build(url, miniPlayerSize);
  static String forFullPlayer(String url) => build(url, fullPlayerSize);
  static String forHeader(String url) => build(url, headerSize);
}
