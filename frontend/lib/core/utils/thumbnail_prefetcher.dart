// DEPRECATED: ThumbnailPrefetcher disabled per image loading v2 spec.
// Off-screen prefetching violates the "never preload off-screen images" rule
// and causes 429 rate limiting issues.
// 
// Images now load via AppImage widget with visibility-based loading only.
// This file is kept for reference but should not be used.

import 'package:flutter/widgets.dart';
import 'dart:async';

/// @deprecated Use AppImage widget with visibility-based loading instead.
/// Prefetching off-screen images causes 429 rate limiting issues.
class ThumbnailPrefetcher {
  final BuildContext context;
  Timer? _debounceTimer;
  
  ThumbnailPrefetcher(this.context);

  /// @deprecated Does nothing - prefetching disabled
  void onScroll({
    required ScrollController controller,
    required List<String> imageUrls,
    required double itemExtent,
    int buffer = 5,
  }) {
    // DISABLED: Prefetching causes 429 rate-limit issues
    // AppImage handles loading when items become visible
  }
    
  void dispose() {
    _debounceTimer?.cancel();
  }
}
