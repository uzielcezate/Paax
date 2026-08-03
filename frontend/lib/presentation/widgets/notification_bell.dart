// lib/presentation/widgets/notification_bell.dart
//
// Phase 3.4.1.1 — the Home header bell that sits immediately left of the profile
// button. Same circular Paax chrome as the profile avatar (equal touch target),
// with a live red unread badge that hides at zero and caps at "99+". The badge
// is a non-interactive overlay so it never blocks the tap. Tapping opens the
// Notifications screen.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../screens/notifications_screen.dart';
import '../state/notification_controller.dart';

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final count = context.select<NotificationController, int>((c) => c.unreadCount);
    final badge = count > 99 ? '99+' : '$count';

    return Semantics(
      button: true,
      label: count > 0 ? 'Notifications, $count unread' : 'Notifications',
      child: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NotificationsScreen()),
        ),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              const CircleAvatar(
                backgroundColor: AppColors.surfaceLight,
                child: Icon(Icons.notifications_none_rounded, color: Colors.white),
              ),
              if (count > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: IgnorePointer(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: badge.length > 1 ? 5 : 0),
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      decoration: BoxDecoration(
                        color: AppColors.primaryEnd,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: AppColors.background, width: 2),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        badge,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
