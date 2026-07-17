import '../widgets/thumbnail.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_colors.dart';
import '../../core/auth/demographics.dart';
import '../../data/local/hive_storage.dart';
import '../../domain/entities/profile.dart';
import '../state/auth_controller.dart';
import '../state/library_controller.dart';
import '../state/playback_controller.dart';
import '../state/profile_controller.dart';
import '../../domain/entities/track.dart';
import '../widgets/bottom_content_padding.dart';
import '../widgets/section_header.dart';
import 'profile/edit_profile_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Provide a ProfileController inline so main.dart needs no wiring — this
    // scopes the avatar-change workflow to the Profile subtree.
    return ChangeNotifierProvider<ProfileController>(
      create: (_) => ProfileController(),
      child: const _ProfileView(),
    );
  }
}

class _ProfileView extends StatelessWidget {
  const _ProfileView();

  @override
  Widget build(BuildContext context) {
    final profile = context.watch<AuthController>().profile;
    final library = context.watch<LibraryController>();
    final history = HiveStorage.getRecentlyPlayed();
    final email = Supabase.instance.client.auth.currentUser?.email;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: profile == null
                ? _ProfileSkeleton(
                    onRetry: () => context.read<AuthController>().bootstrap(),
                  )
                : SingleChildScrollView(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        _buildHeader(context, profile, email),
                        const SizedBox(height: 20),
                        _buildPlanSection(profile),
                        const SizedBox(height: 16),
                        _buildStatsRow(context, library),
                        const SizedBox(height: 24),
                        _buildDetails(context, profile),
                        const SizedBox(height: 24),
                        if (history.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 20),
                            child: SectionHeader(title: "Recently Played"),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 155,
                            child: ListView.builder(
                              padding: const EdgeInsets.only(left: 20),
                              scrollDirection: Axis.horizontal,
                              physics: const ClampingScrollPhysics(),
                              primary: false,
                              itemCount: history.length,
                              itemBuilder: (context, index) =>
                                  _buildRecentCard(context, history[index]),
                            ),
                          ),
                          const SizedBox(height: 32),
                        ],
                        _buildMenu(context),
                        const BottomContentPadding(),
                      ],
                    ),
                  ),
          ),
          _buildTopFade(),
          _buildBottomFade(context),
        ],
      ),
    );
  }

  // ── Header + avatar ────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, Profile profile, String? email) {
    final controller = context.watch<ProfileController>();
    final displayName = (profile.displayName?.trim().isNotEmpty ?? false)
        ? profile.displayName!.trim()
        : profile.greetingName;

    return Column(
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            _Avatar(
              url: profile.avatarUrl,
              initials: _initials(profile),
              uploading: controller.isSubmitting,
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: _ChangePhotoButton(
                onTap: controller.isSubmitting
                    ? null
                    : () => _onChangeAvatar(context),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          displayName,
          style: const TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(height: 2),
        Text(
          '@${profile.username}',
          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
        if (email != null && email.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            email,
            style: const TextStyle(fontSize: 13, color: AppColors.mutedText),
          ),
        ],
      ],
    );
  }

  Future<void> _onChangeAvatar(BuildContext context) async {
    final controller = context.read<ProfileController>();
    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await controller.changeAvatar();
    if (ok) {
      await auth.bootstrap(); // re-fetch so the new avatar shows
    } else if (controller.error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(controller.error!),
          backgroundColor: AppColors.surface,
        ),
      );
    }
  }

  String _initials(Profile p) {
    final first = (p.firstName ?? '').trim();
    final last = (p.lastName ?? '').trim();
    if (first.isNotEmpty || last.isNotEmpty) {
      final a = first.isNotEmpty ? first[0] : '';
      final b = last.isNotEmpty ? last[0] : '';
      final combined = '$a$b';
      if (combined.isNotEmpty) return combined.toUpperCase();
    }
    final dn = (p.displayName ?? '').trim();
    if (dn.isNotEmpty) {
      final parts = dn.split(RegExp(r'\s+'));
      final a = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0][0] : '';
      final b = parts.length > 1 && parts[1].isNotEmpty ? parts[1][0] : '';
      final combined = '$a$b';
      if (combined.isNotEmpty) return combined.toUpperCase();
    }
    final u = p.username.trim();
    return u.isNotEmpty ? u[0].toUpperCase() : '?';
  }

  // ── Plan / subscription (real) ─────────────────────────────────────────────

  Widget _buildPlanSection(Profile profile) {
    final tier = profile.subscriptionTier;
    final label = tier.isEmpty
        ? 'Free'
        : '${tier[0].toUpperCase()}${tier.substring(1)}';
    final premium = profile.isPremium;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Plan: ", style: TextStyle(color: AppColors.textSecondary)),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
            if (premium) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryEnd,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text("PRO",
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Stats (real, from LibraryController) ───────────────────────────────────

  Widget _buildStatsRow(BuildContext context, LibraryController library) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildStatItem("Liked", library.likedTracks.length.toString()),
          _buildStatItem("Playlists", library.playlists.length.toString()),
          _buildStatItem("Artists", library.followedArtists.length.toString()),
          _buildStatItem("Albums", library.savedAlbums.length.toString()),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 4),
        Text(label.toUpperCase(),
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary, letterSpacing: 1)),
      ],
    );
  }

  // ── Details (location, joined date, onboarding) ────────────────────────────

  Widget _buildDetails(BuildContext context, Profile profile) {
    final location = _location(profile);
    final joined = _joinedDate();

    final rows = <Widget>[
      if (location != null) _detailRow(Icons.place_outlined, location),
      if (joined != null) _detailRow(Icons.calendar_today_outlined, 'Joined $joined'),
      if (!profile.onboardingCompleted)
        _detailRow(Icons.info_outline, 'Onboarding not finished'),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              rows[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _detailRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.mutedText),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
        ),
      ],
    );
  }

  String? _location(Profile p) {
    final parts = <String>[
      if ((p.city ?? '').trim().isNotEmpty) p.city!.trim(),
      if ((p.stateRegion ?? '').trim().isNotEmpty) p.stateRegion!.trim(),
      if (Countries.nameFor(p.countryCode) != null) Countries.nameFor(p.countryCode)!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  String? _joinedDate() {
    final createdAt = Supabase.instance.client.auth.currentUser?.createdAt;
    if (createdAt == null || createdAt.isEmpty) return null;
    final dt = DateTime.tryParse(createdAt);
    if (dt == null) return null;
    return DateFormat('MMM y').format(dt.toLocal());
  }

  // ── Menu (edit + preserved log out / clear data) ───────────────────────────

  Widget _buildMenu(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          _buildMenuItem("Edit profile", Icons.edit_outlined, () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const EditProfileScreen()),
            );
          }),
          const SizedBox(height: 8),
          _buildMenuItem("Settings", Icons.settings_outlined, () {}),
          const SizedBox(height: 8),
          _buildMenuItem("Clear Data", Icons.delete_outline,
              () => _confirmClearData(context),
              isDestructive: true),
          const SizedBox(height: 8),
          _buildMenuItem("Log out", Icons.logout, () {
            // Signs out; AuthGate reacts to the state change and routes back
            // to Welcome. Local library is preserved.
            context.read<AuthController>().logout();
          }),
        ],
      ),
    );
  }

  Widget _buildMenuItem(String title, IconData icon, VoidCallback onTap,
      {bool isDestructive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.03),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
        ),
        child: Row(
          children: [
            Icon(icon, color: isDestructive ? Colors.redAccent : Colors.white, size: 22),
            const SizedBox(width: 16),
            Expanded(
                child: Text(title,
                    style: TextStyle(
                        color: isDestructive ? Colors.redAccent : Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500))),
            if (!isDestructive)
              const Icon(Icons.arrow_forward_ios,
                  color: AppColors.textSecondary, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentCard(BuildContext context, Track track) {
    return GestureDetector(
      onTap: () => context.read<PlaybackController>().playTrack(track),
      child: Container(
        width: 100,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Thumbnail.list(url: track.artworkUrl, size: 100, borderRadius: 8),
            const SizedBox(height: 8),
            Text(track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(height: 2),
            Text(track.displayArtist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  void _confirmClearData(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text("Clear Data?", style: TextStyle(color: Colors.white)),
        content: const Text(
            "This will delete all your liked songs, playlists, and history.",
            style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
              onPressed: () async {
                // Wipe the on-device library, then sign out. AuthGate routes back
                // to Welcome once signed out (whole shell is rebuilt, so no stale
                // in-memory state remains).
                final auth = context.read<AuthController>();
                Navigator.pop(context);
                await HiveStorage.clearAll();
                await auth.logout();
              },
              child: const Text("Clear", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  // ── Edge fades (unchanged) ─────────────────────────────────────────────────

  Widget _buildTopFade() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Container(
          height: 120,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFF121212),
                const Color(0xFF121212).withValues(alpha: 0.65),
                const Color(0xFF121212).withValues(alpha: 0.25),
                const Color(0xFF121212).withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.35, 0.65, 1.0],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomFade(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          height: context.read<PlaybackController>().currentTrack != null ? 240 : 160,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                const Color(0xFF121212).withValues(alpha: 0.96),
                const Color(0xFF121212).withValues(alpha: 0.65),
                const Color(0xFF121212).withValues(alpha: 0.25),
                const Color(0xFF121212).withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.35, 0.65, 1.0],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Avatar widget with network image + initials fallback ──────────────────────

class _Avatar extends StatelessWidget {
  final String? url;
  final String initials;
  final bool uploading;

  const _Avatar({required this.url, required this.initials, required this.uploading});

  @override
  Widget build(BuildContext context) {
    final hasUrl = (url ?? '').trim().isNotEmpty;
    return Container(
      width: 90,
      height: 90,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceLight,
        border: Border.all(color: Colors.white24, width: 2),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (hasUrl)
              Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _initialsFallback(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : _initialsFallback(),
              )
            else
              _initialsFallback(),
            if (uploading)
              Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _initialsFallback() {
    return Container(
      color: AppColors.surfaceLight,
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(
            color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _ChangePhotoButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _ChangePhotoButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Change photo',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryEnd,
            border: Border.all(color: AppColors.background, width: 2),
          ),
          child: const Icon(Icons.camera_alt, size: 15, color: Colors.white),
        ),
      ),
    );
  }
}

// ── Loading skeleton (shown while the real profile loads) ─────────────────────

class _ProfileSkeleton extends StatelessWidget {
  final VoidCallback onRetry;
  const _ProfileSkeleton({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(8),
          ),
        );

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.06),
            ),
          ),
          const SizedBox(height: 16),
          bar(140, 18),
          const SizedBox(height: 10),
          bar(90, 14),
          const SizedBox(height: 24),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mutedText),
          ),
          const SizedBox(height: 20),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry',
                style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
