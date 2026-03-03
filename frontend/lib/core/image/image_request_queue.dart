import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'host_throttle_state.dart';

/// Request priority levels for the image queue.
enum ImagePriority {
  /// Currently visible on screen - highest priority
  onScreen,
  /// Near the viewport - medium priority  
  nearScreen,
  /// Off screen - lowest priority (deferred)
  offScreen,
}

/// Production-grade image request queue with:
/// - Priority-based ordering
/// - STRICT serial processing (one at a time on web)
/// - Concurrency limits (1 web, 4 mobile)
/// - Spacing between requests (500ms web, 150ms mobile)
/// - Request cancellation
/// - Inflight deduplication
/// - Host throttle integration
class ImageRequestQueue {
  static final ImageRequestQueue _instance = ImageRequestQueue._();
  static ImageRequestQueue get instance => _instance;

  ImageRequestQueue._();

  // Platform-specific configuration - STRICT for web
  int get _maxConcurrent => kIsWeb ? 1 : 4;  // Serial on web!
  Duration get _delayBetweenRequests => kIsWeb 
      ? const Duration(milliseconds: 500)  // Longer delay on web
      : const Duration(milliseconds: 150);

  // State
  final Map<ImagePriority, Queue<_ImageRequest>> _queues = {
    ImagePriority.onScreen: Queue(),
    ImagePriority.nearScreen: Queue(),
    ImagePriority.offScreen: Queue(),
  };
  
  int _activeRequests = 0;
  bool _isProcessing = false;
  
  // Global pause on any 429 - prevents parallel requests from all hitting 429
  bool _globalPause = false;
  
  // Inflight deduplication: same URL returns same Future
  final Map<String, Completer<void>> _inflight = {};
  
  // Cancelled request IDs
  final Set<String> _cancelled = {};

  /// Enqueue an image load request with priority.
  /// Returns a Future that completes when the request can proceed.
  /// Returns the request ID for cancellation.
  (Future<void>, String) enqueue(
    String url, {
    ImagePriority priority = ImagePriority.onScreen,
  }) {
    final requestId = '${url.hashCode}_${DateTime.now().microsecondsSinceEpoch}';
    
    // Check for inflight request with same URL
    if (_inflight.containsKey(url)) {
      return (_inflight[url]!.future, requestId);
    }
    
    final completer = Completer<void>();
    _inflight[url] = completer;
    
    _queues[priority]!.add(_ImageRequest(
      id: requestId,
      url: url,
      completer: completer,
      priority: priority,
      timestamp: DateTime.now(),
    ));

    _processQueue();
    
    return (completer.future, requestId);
  }

  /// Cancel a pending request by ID.
  void cancel(String requestId) {
    _cancelled.add(requestId);
  }

  /// Check if currently in cooldown for any reason.
  bool isInCooldown([String? url]) {
    if (_globalPause) return true;
    if (url != null) {
      final host = HostThrottleState.extractHost(url);
      return HostThrottleState.instance.isThrottled(host);
    }
    return false;
  }

  /// Report a 429 error - triggers GLOBAL pause.
  void report429(String url) {
    final host = HostThrottleState.extractHost(url);
    HostThrottleState.instance.report429(host);
    
    // Global pause to stop other requests
    _globalPause = true;
    
    final remaining = HostThrottleState.instance.getRemainingCooldown(host);
    
    if (kDebugMode) {
      print('[ImageQueue] 429 for $host, cooldown ${remaining.inSeconds}s');
    }
    
    // Resume after cooldown
    Future.delayed(remaining, () {
      _globalPause = false;
      _processQueue();
    });
  }

  /// Report successful load.
  void reportSuccess(String url) {
    final host = HostThrottleState.extractHost(url);
    HostThrottleState.instance.reportSuccess(host);
    _inflight.remove(url);
  }

  void _processQueue() {
    if (_isProcessing || _globalPause) return;
    _isProcessing = true;
    _processNext();
  }

  void _processNext() async {
    // Check global pause
    if (_globalPause) {
      _isProcessing = false;
      return;
    }
    
    while (_activeRequests < _maxConcurrent && !_globalPause) {
      final request = _getNextRequest();
      if (request == null) break;
      
      // Skip cancelled requests
      if (_cancelled.contains(request.id)) {
        _cancelled.remove(request.id);
        _inflight.remove(request.url);
        continue;
      }
      
      // Check host throttle
      final host = HostThrottleState.extractHost(request.url);
      if (HostThrottleState.instance.isThrottled(host)) {
        final remaining = HostThrottleState.instance.getRemainingCooldown(host);
        // Re-queue with delay
        Future.delayed(remaining, () {
          if (!_cancelled.contains(request.id)) {
            _queues[request.priority]!.addFirst(request);
            _processQueue();
          }
        });
        continue;
      }
      
      _activeRequests++;
      
      // Delay BEFORE granting permission (not just between requests)
      await Future.delayed(_delayBetweenRequests);
      
      // Check global pause again after delay
      if (_globalPause) {
        _activeRequests--;
        // Re-queue this request
        _queues[request.priority]!.addFirst(request);
        break;
      }
      
      // Grant permission
      if (!request.completer.isCompleted) {
        request.completer.complete();
      }
      
      // Wait a bit before allowing next concurrent request
      // This ensures we get 429 feedback before starting next
      if (kIsWeb) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      // Decrement after short delay
      Future.delayed(const Duration(milliseconds: 50), () {
        _activeRequests--;
        if (_hasQueuedRequests() && !_globalPause) {
          Future.microtask(_processNext);
        }
      });
    }
    
    _isProcessing = _hasQueuedRequests() && !_globalPause;
  }

  _ImageRequest? _getNextRequest() {
    // Priority order: onScreen > nearScreen > offScreen
    for (final priority in ImagePriority.values) {
      if (_queues[priority]!.isNotEmpty) {
        return _queues[priority]!.removeFirst();
      }
    }
    return null;
  }

  bool _hasQueuedRequests() {
    return _queues.values.any((q) => q.isNotEmpty);
  }

  // Debug info
  int get pendingCount => _queues.values.fold(0, (sum, q) => sum + q.length);
  int get activeCount => _activeRequests;
  int get inflightCount => _inflight.length;
}

class _ImageRequest {
  final String id;
  final String url;
  final Completer<void> completer;
  final ImagePriority priority;
  final DateTime timestamp;

  _ImageRequest({
    required this.id,
    required this.url,
    required this.completer,
    required this.priority,
    required this.timestamp,
  });
}
