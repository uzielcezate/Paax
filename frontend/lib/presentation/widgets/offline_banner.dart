// lib/presentation/widgets/offline_banner.dart
//
// Subtle offline/sync indicator (Phase 3.4.2).
//
// Deliberately NOT a blocking overlay, modal, or full-screen error. Requirement:
// "Add a subtle offline/sync-status indicator, not a blocking full-screen
// error." The app remains fully interactive against cached data; this strip only
// explains why remote-only actions may be unavailable, and it disappears on its
// own once connectivity returns and the background sync reconciles.

import '../../core/network/offline_status.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/auth_controller.dart';

/// A slim, non-interactive status strip. Renders nothing when online.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    // Offline if EITHER signal says so: the startup/profile state machine
    // (Phase 3.4.2) or the request-outcome-derived status (Phase 3.4.5). Both
    // are watched as plain booleans, so an online↔offline flip is the only
    // thing that rebuilds this strip.
    final authOffline = context.select<AuthController, bool>((c) => c.isOffline);
    final networkOffline =
        context.select<OfflineStatus, bool>((s) => s.isOffline);
    final offline = authOffline || networkOffline;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: !offline
          ? const SizedBox.shrink(key: ValueKey('online'))
          : Container(
              key: const ValueKey('offline'),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
              color: Colors.white.withValues(alpha: 0.06),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_off_rounded, size: 13, color: Colors.white54),
                  SizedBox(width: 7),
                  Text(
                    'Offline — showing your saved music',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
    );
  }
}
