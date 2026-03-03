import 'dart:math' as math;

/// Utility for handling YouTube Music thumbnail URLs.
/// Upgrades lh3.googleusercontent.com URLs to higher resolutions.
class ThumbnailUtils {
  /// Regex to match lh3 URLs with resolution parameters like =w60-h60 or =s60
  static final RegExp _lh3SizePattern = RegExp(r'=(?:w\d+-h\d+|s\d+)(?:-[a-zA-Z0-9]+)*(?:$|\?)');
  
  /// Upgrades a thumbnail URL to the specified width.
  /// Works for lh3.googleusercontent.com URLs used by YouTube Music.
  /// 
  /// Example transformations:
  /// - `...=w60-h60-l90-rj` → `...=w800-h800-l90-rj`
  /// - `...=s60-rj` → `...=s800-rj`
  static String upgradeResolution(String url, {int targetWidth = 800}) {
    if (url.isEmpty) return url;
    
    // Only process lh3.googleusercontent.com URLs
    if (!url.contains('lh3.googleusercontent.com')) {
      return url;
    }
    
    // Replace width/height parameters
    if (url.contains('=w') || url.contains('=s')) {
      // Pattern: =wXXX-hXXX or =sXXX followed by optional flags
      final replaced = url.replaceAllMapped(
        RegExp(r'=w\d+-h\d+'),
        (match) => '=w$targetWidth-h$targetWidth',
      ).replaceAllMapped(
        RegExp(r'=s\d+'),
        (match) => '=s$targetWidth',
      );
      return replaced;
    }
    
    // If no size parameter, try appending one
    if (url.contains('=')) {
      // Has other params, append size
      return '$url-w$targetWidth-h$targetWidth';
    } else {
      // No params at all
      return '$url=w$targetWidth-h$targetWidth-l90-rj';
    }
  }
  
  /// Gets the best URL for a given context.
  /// For Full Player, uses high resolution (800px).
  /// For lists/cards, uses standard resolution (226px).
  static String forFullPlayer(String url) => upgradeResolution(url, targetWidth: 800);
  static String forHeader(String url) => upgradeResolution(url, targetWidth: 544);
  static String forCard(String url) => upgradeResolution(url, targetWidth: 226);
  static String forList(String url) => upgradeResolution(url, targetWidth: 120);
}
