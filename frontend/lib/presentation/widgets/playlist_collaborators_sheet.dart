// lib/presentation/widgets/playlist_collaborators_sheet.dart
//
// Phase 3.4.1 — owner-only collaboration management (spec §12/§13) in the current
// Paax bottom-sheet style. Decoupled from the controller (pure data + callbacks)
// so it is widget-testable. `showManageCollaboratorsSheet` /
// `showTransferOwnershipSheet` bind a PlaylistDetailController.

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../state/playlist_detail_controller.dart';

Future<void> showManageCollaboratorsSheet(
    BuildContext context, PlaylistDetailController c) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => ListenableBuilder(
      listenable: c,
      builder: (context, _) => ManageCollaboratorsSheet(
        ownerName: c.ownerUsername ?? 'Owner',
        collaborators: c.allCollaborators,
        onInvite: c.inviteByUsername,
        onRemove: c.removeCollaborator,
        onTransfer: c.allCollaborators.any((m) => m.isAccepted)
            ? () {
                Navigator.pop(context);
                showTransferOwnershipSheet(context, c);
              }
            : null,
      ),
    ),
  );
}

Future<void> showTransferOwnershipSheet(
    BuildContext context, PlaylistDetailController c) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => TransferOwnershipSheet(
      accepted: c.allCollaborators.where((m) => m.isAccepted).toList(),
      onTransfer: c.transferOwnershipTo,
    ),
  );
}

class ManageCollaboratorsSheet extends StatefulWidget {
  final String ownerName;
  final List<ManagedCollaborator> collaborators;
  final Future<String?> Function(String username) onInvite;
  final Future<void> Function(String userId) onRemove;
  final VoidCallback? onTransfer;

  const ManageCollaboratorsSheet({
    super.key,
    required this.ownerName,
    required this.collaborators,
    required this.onInvite,
    required this.onRemove,
    this.onTransfer,
  });

  @override
  State<ManageCollaboratorsSheet> createState() => _ManageCollaboratorsSheetState();
}

class _ManageCollaboratorsSheetState extends State<ManageCollaboratorsSheet> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onInvite(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) _controller.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const Text('Collaborators',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          // Owner
          _row(icon: Icons.star_rounded, name: widget.ownerName, trailingLabel: 'Owner'),
          // Collaborators (accepted + pending)
          ...widget.collaborators.map((m) => _row(
                icon: m.isPending ? Icons.hourglass_empty_rounded : Icons.person_rounded,
                name: m.username.isEmpty ? 'user' : m.username,
                trailingLabel: m.isPending ? 'Pending' : null,
                onRemove: () => widget.onRemove(m.userId),
              )),
          const SizedBox(height: 12),
          // Invite row
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Invite by username',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _invite(),
                ),
              ),
              const SizedBox(width: 10),
              _busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(onPressed: _invite, child: const Text('Invite')),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ),
          if (widget.onTransfer != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: widget.onTransfer,
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Transfer ownership'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required String name,
    String? trailingLabel,
    VoidCallback? onRemove,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
          if (trailingLabel != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(trailingLabel, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              behavior: HitTestBehavior.opaque,
              child: const Icon(Icons.close_rounded, color: Colors.white38, size: 20),
            ),
        ],
      ),
    );
  }
}

class TransferOwnershipSheet extends StatelessWidget {
  final List<ManagedCollaborator> accepted;
  final Future<String?> Function(String userId) onTransfer;

  const TransferOwnershipSheet({super.key, required this.accepted, required this.onTransfer});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const Text('Transfer ownership',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text('Choose an accepted collaborator. You will become an editor.',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 12),
          ...accepted.map((m) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_rounded, color: Colors.white54),
                title: Text(m.username.isEmpty ? 'user' : m.username,
                    style: const TextStyle(color: Colors.white)),
                onTap: () => _confirm(context, m),
              )),
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext context, ManagedCollaborator m) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Transfer ownership?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Make ${m.username.isEmpty ? 'this user' : m.username} the owner? This cannot be undone by you afterward.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dctx, true), child: const Text('Transfer')),
        ],
      ),
    );
    if (ok != true) return;
    final err = await onTransfer(m.userId);
    if (context.mounted) {
      Navigator.pop(context);
      if (err != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err), behavior: SnackBarBehavior.floating));
      }
    }
  }
}
