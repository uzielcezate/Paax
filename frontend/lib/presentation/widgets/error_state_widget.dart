import 'package:flutter/material.dart';

/// Friendly error state widget for when the server is down or internet is off.
/// 
/// Detects the type of error from the raw error string and shows an
/// appropriate icon, title, and subtitle. Includes a retry button.
class ErrorStateWidget extends StatelessWidget {
  /// Raw error string (from catch block). Used to detect error type.
  final String? rawError;
  /// Callback when user taps "Try Again".
  final VoidCallback? onRetry;
  /// Foreground color for text and icon (defaults to white).
  final Color foregroundColor;

  const ErrorStateWidget({
    super.key,
    this.rawError,
    this.onRetry,
    this.foregroundColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final errorType = _classifyError(rawError ?? '');
    
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              errorType.icon,
              size: 56,
              color: foregroundColor.withOpacity(0.35),
            ),
            const SizedBox(height: 20),
            Text(
              errorType.title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foregroundColor.withOpacity(0.85),
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              errorType.subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: foregroundColor.withOpacity(0.5),
                fontSize: 14,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: onRetry,
                icon: Icon(Icons.refresh_rounded, color: foregroundColor.withOpacity(0.7), size: 18),
                label: Text(
                  "Try Again",
                  style: TextStyle(
                    color: foregroundColor.withOpacity(0.7),
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                style: TextButton.styleFrom(
                  backgroundColor: foregroundColor.withOpacity(0.08),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                    side: BorderSide(color: foregroundColor.withOpacity(0.12)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static _ErrorType _classifyError(String raw) {
    final lower = raw.toLowerCase();
    
    // ── 1. Server / API errors (check FIRST — these are often wrapped in
    //       "Network Error: Exception: API Error 404: ..." so the network
    //       keyword would match too early if checked first) ──
    
    // 404 / Not found / Application not found
    if (lower.contains('404') ||
        lower.contains('not found') ||
        lower.contains('application not found')) {
      return _ErrorType(
        icon: Icons.cloud_off_rounded,
        title: "Service unavailable",
        subtitle: "Could not reach the music service.\nPlease try again later.",
      );
    }
    
    // Server errors (5xx)
    if (lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503') ||
        lower.contains('504') ||
        lower.contains('internal server error') ||
        lower.contains('server error') ||
        lower.contains('bad gateway') ||
        lower.contains('service unavailable')) {
      return _ErrorType(
        icon: Icons.cloud_off_rounded,
        title: "Server unavailable",
        subtitle: "The music service is temporarily down.\nPlease try again later.",
      );
    }
    
    // API errors (generic — any status code mention)
    if (lower.contains('api error')) {
      return _ErrorType(
        icon: Icons.cloud_off_rounded,
        title: "Service error",
        subtitle: "Something went wrong with the music service.\nPlease try again later.",
      );
    }
    
    // ── 2. Network / connectivity issues (pure network — no server response) ──
    if (lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('no internet') ||
        lower.contains('failed host lookup') ||
        lower.contains('network is unreachable') ||
        lower.contains('connection timed out') ||
        lower.contains('handshake') ||
        lower.contains('errno')) {
      return _ErrorType(
        icon: Icons.wifi_off_rounded,
        title: "No connection",
        subtitle: "Check your internet connection\nand try again.",
      );
    }
    
    // Timeout
    if (lower.contains('timeout') || lower.contains('timed out')) {
      return _ErrorType(
        icon: Icons.timer_off_rounded,
        title: "Request timed out",
        subtitle: "The server took too long to respond.\nPlease try again.",
      );
    }
    
    // Generic fallback
    return _ErrorType(
      icon: Icons.error_outline_rounded,
      title: "Something went wrong",
      subtitle: "An unexpected error occurred.\nPlease try again.",
    );
  }
}

class _ErrorType {
  final IconData icon;
  final String title;
  final String subtitle;
  
  const _ErrorType({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
}
