// lib/presentation/screens/notifications_screen.dart
//
// Phase 3.4.1.1 — the notification inbox. Top-bar style with an iOS back
// chevron (matches the rest of Paax), newest-first, grouped Today / Earlier.
// Unread rows are subtly distinct; each carries a relative timestamp. Live
// collaboration invites show Accept/Decline; resolved/revoked ones show a quiet
// status line instead. Pull-to-refresh + realtime keep it current. Loading,
// empty, and error/offline states are all handled. Opening a row marks it read.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/app_notification.dart';
import '../../domain/entities/playlist_activity.dart' show ActivitySummary;
import '../state/notification_controller.dart';

class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(),
            Expanded(child: _Body()),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final hasUnread =
        context.select<NotificationController, bool>((c) => c.unreadCount > 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Back',
          ),
          const Expanded(
            child: Text('Notifications',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
          ),
          if (hasUnread)
            TextButton(
              onPressed: () =>
                  context.read<NotificationController>().markAllRead(),
              child: const Text('Mark all as read',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.watch<NotificationController>();

    if (c.isLoading && c.items.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primaryEnd));
    }
    if (c.hasError && c.items.isEmpty) {
      return _ErrorState(onRetry: () => c.load());
    }
    if (c.items.isEmpty) {
      return RefreshIndicator(
        color: AppColors.primaryEnd,
        backgroundColor: AppColors.surface,
        onRefresh: c.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [SizedBox(height: 120), _EmptyState()],
        ),
      );
    }

    final now = DateTime.now();
    final today = <AppNotification>[];
    final earlier = <AppNotification>[];
    for (final n in c.items) {
      final d = n.createdAt;
      if (d.year == now.year && d.month == now.month && d.day == now.day) {
        today.add(n);
      } else {
        earlier.add(n);
      }
    }

    final rows = <Widget>[];
    if (today.isNotEmpty) {
      rows.add(const _SectionLabel('Today'));
      rows.addAll(today.map((n) => _NotificationTile(n)));
    }
    if (earlier.isNotEmpty) {
      rows.add(const _SectionLabel('Earlier'));
      rows.addAll(earlier.map((n) => _NotificationTile(n)));
    }

    return RefreshIndicator(
      color: AppColors.primaryEnd,
      backgroundColor: AppColors.surface,
      onRefresh: c.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 24),
        children: rows,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: AppColors.mutedText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
      );
}

class _NotificationTile extends StatelessWidget {
  final AppNotification n;
  const _NotificationTile(this.n);

  @override
  Widget build(BuildContext context) {
    final c = context.read<NotificationController>();
    final when = ActivitySummary.relativeTime(n.createdAt, DateTime.now());
    final acting = context.select<NotificationController, bool>(
        (x) => x.isActing(n.id));

    return InkWell(
      onTap: () => c.markRead(n.id),
      child: Container(
        color: n.isRead ? Colors.transparent : Colors.white.withValues(alpha: 0.05),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Avatar(cover: n.playlistCover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.body.isNotEmpty ? n.body : n.title,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.3,
                        fontWeight:
                            n.isRead ? FontWeight.w400 : FontWeight.w600),
                  ),
                  if ((n.playlistTitle ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('“${n.playlistTitle}”',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12)),
                  ],
                  const SizedBox(height: 6),
                  Text(when,
                      style: const TextStyle(
                          color: AppColors.mutedText, fontSize: 11)),
                  if (n.type == NotificationType.invited) ...[
                    const SizedBox(height: 10),
                    if (n.isActionable)
                      _InviteActions(notification: n, busy: acting)
                    else
                      const _ResolvedInvite(),
                  ],
                ],
              ),
            ),
            if (!n.isRead)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 4),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: AppColors.primaryEnd, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? cover;
  const _Avatar({this.cover});
  @override
  Widget build(BuildContext context) {
    final hasCover = (cover ?? '').isNotEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 44,
        height: 44,
        color: AppColors.surfaceLight,
        child: hasCover
            ? Image.network(cover!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                    Icons.queue_music_rounded,
                    color: Colors.white38))
            : const Icon(Icons.queue_music_rounded, color: Colors.white38),
      ),
    );
  }
}

class _InviteActions extends StatelessWidget {
  final AppNotification notification;
  final bool busy;
  const _InviteActions({required this.notification, required this.busy});

  Future<void> _respond(BuildContext context, bool accept) async {
    final c = context.read<NotificationController>();
    final err = await c.respondToInvite(notification, accept);
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primaryEnd)),
      );
    }
    return Row(
      children: [
        ElevatedButton(
          onPressed: () => _respond(context, true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primaryEnd,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            minimumSize: const Size(0, 36),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18)),
          ),
          child: const Text('Accept',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: () => _respond(context, false),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            minimumSize: const Size(0, 36),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18)),
          ),
          child: const Text('Decline',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ],
    );
  }
}

class _ResolvedInvite extends StatelessWidget {
  const _ResolvedInvite();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(top: 2),
        child: Text('This invitation is no longer available',
            style: TextStyle(
                color: AppColors.mutedText,
                fontSize: 12,
                fontStyle: FontStyle.italic)),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) => Column(
        children: const [
          Icon(Icons.notifications_none_rounded,
              color: Colors.white24, size: 56),
          SizedBox(height: 16),
          Text('You’re all caught up',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          SizedBox(height: 6),
          Text('Invitations and playlist updates will show up here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.mutedText, fontSize: 13)),
        ],
      );
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white24, size: 48),
            const SizedBox(height: 14),
            const Text("Couldn't load notifications",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              child: const Text('Try Again'),
            ),
          ],
        ),
      );
}
