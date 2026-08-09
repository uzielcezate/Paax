// lib/presentation/widgets/offline_notice.dart
//
// Phase 3.4.3 — the canonical offline empty-state.
//
// A KNOWN offline failure is not an error, and must never render as
// "Something went wrong". That copy tells the user something is broken and
// gives them nothing to do; "you're offline" tells them what happened and
// implies the fix. One widget so the wording can never drift between screens.
//
// This is for surfaces whose content is genuinely UNAVAILABLE offline
// (recommendations, uncached artists/albums, search). Anything already cached
// must keep rendering — see `OfflineBanner` for the ambient indicator that
// accompanies cached content.

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

class OfflineNotice extends StatelessWidget {
  /// Optional retry. When null, only the message is shown — a section that
  /// cannot be retried independently should not pretend otherwise.
  final Future<void> Function()? onRetry;

  /// Compact form for inline sections inside an otherwise-populated screen.
  final bool compact;

  const OfflineNotice({super.key, this.onRetry, this.compact = false});

  /// Exact product copy — do not reword per-screen.
  static const String title = "Oops, you're offline";
  static const String body = 'Connect to the internet to enjoy more music.';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 32,
        vertical: compact ? 20 : 44,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded,
              size: compact ? 30 : 48, color: Colors.white38),
          SizedBox(height: compact ? 10 : 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: compact ? 15 : 19,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white60,
              fontSize: compact ? 12.5 : 14,
              height: 1.4,
            ),
          ),
          if (onRetry != null) ...[
            SizedBox(height: compact ? 12 : 20),
            TextButton(
              // ignore: discarded_futures
              onPressed: () => onRetry!(),
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}
