// lib/presentation/widgets/playlist_collaborators_sheet.dart
//
// Phase 3.4.1 (owner-only collaboration management) + Phase 3.4.1.2C (People
// Picker). The sheet is organised into Owner / Collaborators / Pending / Search
// people sections. Inviting no longer requires typing an exact username from
// memory: a debounced, privacy-safe search surfaces real profiles and tapping a
// result invites by profile UUID through the existing secure RPC. Typing an
// exact username and pressing enter still works (exact server-side resolution).
//
// Decoupled from the controller (pure data + callbacks) so it stays
// widget-testable. `showManageCollaboratorsSheet` binds a PlaylistDetailController.

import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../state/playlist_detail_controller.dart';
import 'actor_avatar.dart';

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
        ownerAvatarUrl: c.ownerAvatarUrl,
        collaborators: c.allCollaborators,
        onInvite: c.inviteByUsername,
        onInviteUser: c.inviteByUserId,
        onSearch: c.searchPeople,
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
  final String? ownerAvatarUrl;
  final List<ManagedCollaborator> collaborators;
  final Future<String?> Function(String username) onInvite;
  final Future<String?> Function(String userId) onInviteUser;
  final Future<List<PeoplePickerResult>> Function(String query) onSearch;
  final Future<void> Function(String userId) onRemove;
  final VoidCallback? onTransfer;

  const ManageCollaboratorsSheet({
    super.key,
    required this.ownerName,
    this.ownerAvatarUrl,
    required this.collaborators,
    required this.onInvite,
    required this.onInviteUser,
    required this.onSearch,
    required this.onRemove,
    this.onTransfer,
  });

  @override
  State<ManageCollaboratorsSheet> createState() => _ManageCollaboratorsSheetState();
}

class _ManageCollaboratorsSheetState extends State<ManageCollaboratorsSheet> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  int _reqId = 0; // guards against stale search responses replacing newer ones

  String _query = '';
  List<PeoplePickerResult> _results = const [];
  bool _searching = false;
  bool _searchError = false;

  String? _error; // invite error (kept until the next attempt)
  bool _inviting = false; // guards against duplicate taps while an RPC is in flight
  final Set<String> _invitedIds = {}; // optimistic exclusion after a sent invite

  static const int _minChars = 2;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _queryReady => _query.trim().replaceFirst(RegExp(r'^\s*@?\s*'), '').trim().length >= _minChars;

  Set<String> get _managedIds => widget.collaborators.map((m) => m.userId).toSet();

  List<PeoplePickerResult> get _visibleResults => _results
      .where((r) => !_invitedIds.contains(r.userId) && !_managedIds.contains(r.userId))
      .toList();

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _query = value;
      _error = null;
      if (!_queryReady) {
        _results = const [];
        _searching = false;
        _searchError = false;
      }
    });
    if (!_queryReady) return;
    _debounce = Timer(const Duration(milliseconds: 300), _runSearch);
  }

  Future<void> _runSearch() async {
    final reqId = ++_reqId;
    setState(() {
      _searching = true;
      _searchError = false;
    });
    try {
      final results = await widget.onSearch(_query);
      if (!mounted || reqId != _reqId) return; // a newer query superseded this one
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (_) {
      if (!mounted || reqId != _reqId) return;
      setState(() {
        _searchError = true;
        _searching = false;
      });
    }
  }

  Future<void> _inviteExact() async {
    if (_inviting || _searchCtrl.text.trim().isEmpty) return;
    setState(() {
      _inviting = true;
      _error = null;
    });
    final err = await widget.onInvite(_searchCtrl.text);
    if (!mounted) return;
    setState(() {
      _inviting = false;
      _error = err;
      if (err == null) _clearSearch();
    });
    if (err == null) _sent();
  }

  Future<void> _inviteUser(PeoplePickerResult r) async {
    if (_inviting) return; // one invitation at a time; blocks rapid double taps
    setState(() {
      _inviting = true;
      _error = null;
    });
    // The profile UUID is the authoritative identity (never the visible handle).
    final err = await widget.onInviteUser(r.userId);
    if (!mounted) return;
    setState(() {
      _inviting = false;
      if (err == null) {
        _invitedIds.add(r.userId); // remove from results; refresh moves to Pending
        _clearSearch();
      } else {
        _error = err; // keep the results so the owner can retry
      }
    });
    if (err == null) _sent();
  }

  void _clearSearch() {
    _searchCtrl.clear();
    _query = '';
    _results = const [];
    _searching = false;
    _searchError = false;
    FocusScope.of(context).unfocus();
  }

  void _sent() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Invitation sent'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom +
        MediaQuery.of(context).padding.bottom;
    final accepted = widget.collaborators.where((m) => m.isAccepted).toList();
    final pending = widget.collaborators.where((m) => m.isPending).toList();

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
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
          const SizedBox(height: 8),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('Owner'),
                  _personRow(
                    displayName: widget.ownerName,
                    username: widget.ownerName,
                    avatarUrl: widget.ownerAvatarUrl,
                    trailingLabel: 'Owner',
                  ),
                  if (accepted.isNotEmpty) ...[
                    _sectionLabel('Collaborators'),
                    ...accepted.map((m) => _personRow(
                          displayName: _displayOf(m),
                          username: m.username,
                          avatarUrl: m.avatarUrl,
                          onRemove: () => widget.onRemove(m.userId),
                        )),
                  ],
                  if (pending.isNotEmpty) ...[
                    _sectionLabel('Pending'),
                    ...pending.map((m) => _personRow(
                          displayName: _displayOf(m),
                          username: m.username,
                          avatarUrl: m.avatarUrl,
                          trailingLabel: 'Pending',
                          onRemove: () => widget.onRemove(m.userId),
                        )),
                  ],
                  _sectionLabel('Search people'),
                  _searchField(),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                    ),
                  _searchBody(),
                ],
              ),
            ),
          ),
          if (widget.onTransfer != null) ...[
            const Divider(color: Colors.white12, height: 20),
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

  String _displayOf(ManagedCollaborator m) {
    final d = (m.displayName ?? '').trim();
    if (d.isNotEmpty) return d;
    return m.username.isEmpty ? 'user' : m.username;
  }

  Widget _searchField() {
    return Semantics(
      label: 'Search people',
      textField: true,
      child: TextField(
      controller: _searchCtrl,
      style: const TextStyle(color: Colors.white),
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: (_) => _inviteExact(),
      decoration: InputDecoration(
        hintText: 'Search by name or username',
        hintStyle: const TextStyle(color: Colors.white38),
        prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 20),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      ),
      ),
    );
  }

  Widget _searchBody() {
    if (!_queryReady) {
      return _hint('Search by name or username.');
    }
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_searchError) {
      return _hint("Couldn't search people. Try again.");
    }
    final results = _visibleResults;
    if (results.isEmpty) {
      return _hint('No users found.');
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: results.map(_resultRow).toList(),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 13)),
      );

  Widget _resultRow(PeoplePickerResult r) {
    final display = (r.displayName ?? '').trim().isNotEmpty
        ? r.displayName!.trim()
        : r.username;
    return Semantics(
      button: true,
      label: 'Invite $display, @${r.username}',
      child: InkWell(
        onTap: _inviting ? null : () => _inviteUser(r),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              ActorAvatar(imageUrl: r.avatarUrl, displayName: display, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(display,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    Text('@${r.username}',
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.person_add_alt_1_rounded, color: Colors.white54, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
      );

  Widget _personRow({
    required String displayName,
    required String username,
    String? avatarUrl,
    String? trailingLabel,
    VoidCallback? onRemove,
  }) {
    final showHandle = username.isNotEmpty && username != displayName;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          ActorAvatar(imageUrl: avatarUrl, displayName: displayName, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(displayName,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 14)),
                if (showHandle)
                  Text('@$username',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
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
