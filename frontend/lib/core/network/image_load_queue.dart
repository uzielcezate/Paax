import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

/// Global rate limiter for image loading.
/// This is especially important on Flutter Web where the browser handles HTTP requests
/// and our custom ThrottledHttpClient doesn't apply.
class ImageLoadQueue {
  static final ImageLoadQueue _instance = ImageLoadQueue._();
  static ImageLoadQueue get instance => _instance;

  ImageLoadQueue._();

  final Queue<_QueuedRequest> _queue = Queue();
  int _activeRequests = 0;
  
  // Configuration
  final int maxConcurrent = kIsWeb ? 3 : 6; // Lower on web
  final Duration delayBetweenRequests = const Duration(milliseconds: 100); // Spread out requests
  
  bool _isProcessing = false;

  /// Wraps an async operation (like precacheImage) with rate limiting.
  /// Returns a Future that completes when the operation is done.
  Future<T> enqueue<T>(Future<T> Function() operation, {String? debugLabel}) async {
    final completer = Completer<T>();
    
    _queue.add(_QueuedRequest(
      operation: () async {
        try {
          final result = await operation();
          completer.complete(result);
        } catch (e) {
          completer.completeError(e);
        }
      },
      debugLabel: debugLabel,
    ));

    _processQueue();
    
    return completer.future;
  }

  void _processQueue() {
    if (_isProcessing) return;
    _isProcessing = true;
    
    _processNext();
  }

  void _processNext() async {
    // Process items while we have capacity and items in queue
    while (_queue.isNotEmpty && _activeRequests < maxConcurrent) {
      final request = _queue.removeFirst();
      _activeRequests++;
      
      // Add a small delay between starting requests to spread them out
      if (_activeRequests > 1) {
        await Future.delayed(delayBetweenRequests);
      }
      
      // Fire and forget - don't wait for completion to start next
      request.operation().whenComplete(() {
        _activeRequests--;
        // Schedule next check after this one completes
        if (_queue.isNotEmpty) {
          Future.microtask(() => _processNext());
        }
      });
    }
    
    _isProcessing = _queue.isNotEmpty;
  }

  /// Check if we're at capacity
  bool get isThrottling => _activeRequests >= maxConcurrent;
  
  /// Number of pending requests
  int get pendingCount => _queue.length;
}

class _QueuedRequest {
  final Future<void> Function() operation;
  final String? debugLabel;

  _QueuedRequest({required this.operation, this.debugLabel});
}
