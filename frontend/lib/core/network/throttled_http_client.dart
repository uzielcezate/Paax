import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:math';

class ThrottledHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final int maxConcurrency;
  final int maxRetries;

  ThrottledHttpClient({this.maxConcurrency = 6, this.maxRetries = 3});

  // Active request counter
  int _activeRequests = 0;
  final List<Completer<void>> _queue = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    // Wait for slot
    await _waitForSlot();

    try {
      _activeRequests++;
      return await _sendWithRetry(request);
    } finally {
      _activeRequests--;
      _processQueue();
    }
  }

  Future<void> _waitForSlot() {
    if (_activeRequests < maxConcurrency) {
      return Future.value();
    }
    final completer = Completer<void>();
    _queue.add(completer);
    return completer.future;
  }

  void _processQueue() {
    if (_queue.isNotEmpty && _activeRequests < maxConcurrency) {
      _queue.removeAt(0).complete();
    }
  }

  Future<http.StreamedResponse> _sendWithRetry(http.BaseRequest request, [int attempt = 0]) async {
    try {
      final response = await _inner.send(request);
      
      if (response.statusCode == 429) {
         if (attempt < maxRetries) {
             // Add Jitter: +/- 20% random variation
            final baseDelay = 500 * pow(2, attempt).toInt();
            final jitter = Random().nextInt((baseDelay * 0.4).toInt()) - (baseDelay * 0.2).toInt();
            final delay = Duration(milliseconds: baseDelay + jitter);
            
            // Drain stream to avoid leaks before retry? 
            // StreamedResponse must be listened to or it leaks? 
            // Actually BaseClient.send returns a StreamedResponse. 
            // If we want to retry, we must discard this response stream.
            await response.stream.drain(); 

            await Future.delayed(delay);
            
            // We need to clone the request because it might have been finalized (used)
            // But standard http.Request can't be easily cloned if it's a stream. 
            // Luckily cached_network_image usually sends simple GET requests.
            final newRequest = _copyRequest(request);
            return _sendWithRetry(newRequest, attempt + 1);
         }
      }
      
      return response;
    } catch (e) {
       // Network error?
       if (attempt < maxRetries) {
          await Future.delayed(const Duration(seconds: 1));
           final newRequest = _copyRequest(request);
          return _sendWithRetry(newRequest, attempt + 1);
       }
       rethrow;
    }
  }

  http.BaseRequest _copyRequest(http.BaseRequest request) {
    http.BaseRequest requestCopy;

    if (request is http.Request) {
      requestCopy = http.Request(request.method, request.url)
        ..encoding = request.encoding
        ..bodyBytes = request.bodyBytes;
    } else if (request is http.MultipartRequest) {
      requestCopy = http.MultipartRequest(request.method, request.url)
        ..fields.addAll(request.fields)
        ..files.addAll(request.files);
    } else if (request is http.StreamedRequest) {
       throw Exception("StreamedRequest cannot be retried in ThrottledHttpClient");
    } else {
      requestCopy = http.Request(request.method, request.url);
    }

    requestCopy
      ..headers.addAll(request.headers)
      ..followRedirects = request.followRedirects
      ..maxRedirects = request.maxRedirects
      ..persistentConnection = request.persistentConnection;

    return requestCopy;
  }
}
