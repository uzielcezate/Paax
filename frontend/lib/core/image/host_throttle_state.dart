import 'dart:math';

/// Per-host throttle state with exponential backoff and jitter.
/// Prevents 429 errors by rate-limiting requests to throttled hosts.
class HostThrottleState {
  static final HostThrottleState _instance = HostThrottleState._();
  static HostThrottleState get instance => _instance;

  HostThrottleState._();

  final Map<String, _ThrottleInfo> _hostStates = {};
  final Random _random = Random();

  // Backoff configuration
  static const Duration _initialBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(seconds: 60);
  static const int _maxJitterMs = 500;

  /// Check if a host is currently throttled.
  bool isThrottled(String host) {
    final info = _hostStates[host];
    if (info == null) return false;
    
    if (DateTime.now().isAfter(info.cooldownUntil)) {
      // Cooldown expired - clear state
      _hostStates.remove(host);
      return false;
    }
    return true;
  }

  /// Get remaining cooldown time for a host.
  Duration getRemainingCooldown(String host) {
    final info = _hostStates[host];
    if (info == null) return Duration.zero;
    
    final remaining = info.cooldownUntil.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Report a 429 error for a host. Applies exponential backoff.
  void report429(String host) {
    final existing = _hostStates[host];
    final attempt = (existing?.attempt ?? 0) + 1;
    
    // Calculate backoff: 2^attempt seconds, capped at max
    final baseBackoffMs = _initialBackoff.inMilliseconds * pow(2, attempt - 1);
    final clampedBackoffMs = min(baseBackoffMs.toInt(), _maxBackoff.inMilliseconds);
    
    // Add jitter (0 to 500ms)
    final jitterMs = _random.nextInt(_maxJitterMs);
    final totalBackoffMs = clampedBackoffMs + jitterMs;
    
    final cooldownUntil = DateTime.now().add(Duration(milliseconds: totalBackoffMs));
    
    _hostStates[host] = _ThrottleInfo(
      attempt: attempt,
      cooldownUntil: cooldownUntil,
    );
  }

  /// Report a successful request - reset backoff for host.
  void reportSuccess(String host) {
    _hostStates.remove(host);
  }

  /// Report a permanent failure (404, 410) - mark as unavailable.
  void reportPermanentFailure(String host, String url) {
    // Could track permanently failed URLs here if needed
  }

  /// Extract host from URL.
  static String extractHost(String url) {
    return Uri.tryParse(url)?.host ?? 'unknown';
  }
}

class _ThrottleInfo {
  final int attempt;
  final DateTime cooldownUntil;

  _ThrottleInfo({required this.attempt, required this.cooldownUntil});
}
