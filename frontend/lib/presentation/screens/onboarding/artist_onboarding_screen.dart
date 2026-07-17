// lib/presentation/screens/onboarding/artist_onboarding_screen.dart
//
// Phase 3.2 — real artist onboarding. The user picks >= 5 artists they love so
// Paax can tune their experience. Selections come from a batched "popular" grid
// or a debounced normalized search, are deduped by Supabase UUID, and survive
// switching between search and popular. Completion calls an atomic RPC (via the
// OnboardingController) and then re-resolves AuthController so the AuthGate
// advances to Home — this screen performs no navigation itself.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/onboarding_artist.dart';
import '../../state/auth_controller.dart';
import '../../state/onboarding_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class ArtistOnboardingScreen extends StatefulWidget {
  const ArtistOnboardingScreen({super.key});

  @override
  State<ArtistOnboardingScreen> createState() => _ArtistOnboardingScreenState();
}

class _ArtistOnboardingScreenState extends State<ArtistOnboardingScreen> {
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final auth = context.read<AuthController>();
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Log out?',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text(
          'You need to pick a few artists to finish setting up your account. '
          'Log out instead?',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Log out',
                style: TextStyle(color: AppColors.primaryEnd)),
          ),
        ],
      ),
    );
    if (leave == true) {
      await auth.logout();
    }
  }

  Future<void> _onContinue() async {
    final controller = context.read<OnboardingController>();
    final ok = await controller.complete();
    if (!ok || !mounted) return;
    // Re-resolve auth: onboarding_completed is now true → AuthGate routes to
    // Home. This screen intentionally performs no Navigator work of its own.
    await context.read<AuthController>().bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<OnboardingController>();

    return PopScope(
      // Block Android back so onboarding can't be bypassed into Home. Offer a
      // logout instead of silently trapping the user.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmLogout();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          automaticallyImplyLeading: false,
          title: const Text(
            'Choose artists you love',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          actions: [
            TextButton(
              onPressed: _confirmLogout,
              child: const Text('Log out',
                  style: TextStyle(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              _Header(count: controller.selectedCount),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: _SearchField(
                  controller: _searchCtrl,
                  onChanged: controller.search,
                  onClear: () {
                    _searchCtrl.clear();
                    controller.search('');
                  },
                ),
              ),
              Expanded(child: _Body(controller: controller)),
              _ContinueBar(
                controller: controller,
                onContinue: _onContinue,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Header (subtitle + live counter) ───────────────────────────────────────────

class _Header extends StatelessWidget {
  final int count;
  const _Header({required this.count});

  @override
  Widget build(BuildContext context) {
    final enough = count >= OnboardingController.minSelection;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pick a few artists you love so Paax can tune your experience.',
            style: TextStyle(
                color: AppColors.textSecondary, fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                enough ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 16,
                color: enough ? Colors.greenAccent : AppColors.mutedText,
              ),
              const SizedBox(width: 6),
              Text(
                '$count of ${OnboardingController.minSelection} selected'
                '${enough ? '' : ' (min ${OnboardingController.minSelection})'}',
                style: TextStyle(
                  color: enough ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Search field ───────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: const TextStyle(color: AppColors.textPrimary),
      cursorColor: AppColors.textPrimary,
      decoration: InputDecoration(
        hintText: 'Search artists',
        hintStyle: const TextStyle(color: AppColors.mutedText),
        prefixIcon: const Icon(Icons.search, color: AppColors.mutedText),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, __) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  icon: const Icon(Icons.close, color: AppColors.mutedText),
                  onPressed: onClear,
                  tooltip: 'Clear search',
                ),
        ),
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}

// ── Body (loading / error / empty / grid) ──────────────────────────────────────

class _Body extends StatelessWidget {
  final OnboardingController controller;
  const _Body({required this.controller});

  @override
  Widget build(BuildContext context) {
    final searchMode = controller.isSearchMode;

    // Search mode.
    if (searchMode) {
      if (controller.isSearching) {
        return const _CenteredSpinner();
      }
      if (controller.searchError != null) {
        return _ErrorState(
          message: controller.searchError!,
          onRetry: () => controller.search(controller.query),
        );
      }
      if (controller.searchResults.isEmpty) {
        return const _MessageState(
          icon: Icons.search_off,
          title: 'No artists found',
          subtitle: 'Try a different name.',
        );
      }
      return _ArtistGrid(controller: controller, artists: controller.searchResults);
    }

    // Popular mode.
    if (controller.isLoadingPopular && controller.popular.isEmpty) {
      return const _CenteredSpinner();
    }
    if (controller.error != null && controller.popular.isEmpty) {
      return _ErrorState(
        message: controller.error!,
        onRetry: controller.loadPopular,
      );
    }
    if (controller.popular.isEmpty) {
      return _MessageState(
        icon: Icons.person_search,
        title: 'No artists to show',
        subtitle: 'Search for artists you love above.',
      );
    }
    return _ArtistGrid(controller: controller, artists: controller.popular);
  }
}

// ── Artist grid ────────────────────────────────────────────────────────────────

class _ArtistGrid extends StatelessWidget {
  final OnboardingController controller;
  final List<OnboardingArtist> artists;
  const _ArtistGrid({required this.controller, required this.artists});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
      ),
      itemCount: artists.length,
      itemBuilder: (context, index) {
        final artist = artists[index];
        return _ArtistCard(
          artist: artist,
          selected: controller.isSelected(artist),
          resolving: controller.isResolving(artist),
          onTap: () async {
            final err = await controller.toggle(artist);
            if (err != null && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(err),
                  backgroundColor: AppColors.surface,
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          },
        );
      },
    );
  }
}

class _ArtistCard extends StatelessWidget {
  final OnboardingArtist artist;
  final bool selected;
  final bool resolving;
  final Future<void> Function() onTap;

  const _ArtistCard({
    required this.artist,
    required this.selected,
    required this.resolving,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '${artist.name}${selected ? ', selected' : ''}',
      child: InkWell(
        onTap: resolving ? null : () => onTap(),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Avatar(artist: artist, selected: selected, resolving: resolving),
              const SizedBox(height: 6),
              Text(
                artist.name,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular artist avatar with a selection ring + check overlay and a safe
/// fallback to initials when the image is null or fails to load.
class _Avatar extends StatelessWidget {
  final OnboardingArtist artist;
  final bool selected;
  final bool resolving;
  const _Avatar({
    required this.artist,
    required this.selected,
    required this.resolving,
  });

  @override
  Widget build(BuildContext context) {
    const double size = 84;
    final url = artist.imageUrl;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surface,
              border: Border.all(
                color: selected ? AppColors.primaryEnd : Colors.white12,
                width: selected ? 3 : 1,
              ),
            ),
            child: ClipOval(
              child: (url == null || url.isEmpty)
                  ? _initials()
                  : Image.network(
                      url,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      loadingBuilder: (context, child, progress) =>
                          progress == null ? child : _placeholder(),
                      errorBuilder: (context, error, stack) => _initials(),
                    ),
            ),
          ),
          if (resolving)
            Positioned.fill(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black54,
                ),
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                ),
              ),
            )
          else if (selected)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppColors.primaryEnd,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.background, width: 2),
                ),
                child: const Icon(Icons.check, size: 16, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  Widget _placeholder() => Container(
        color: AppColors.surface,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
        ),
      );

  Widget _initials() {
    final name = artist.name.trim();
    final letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return Container(
      color: AppColors.surface,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 30,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ── Continue bar ───────────────────────────────────────────────────────────────

class _ContinueBar extends StatelessWidget {
  final OnboardingController controller;
  final Future<void> Function() onContinue;
  const _ContinueBar({required this.controller, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final canComplete = controller.canComplete;
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        12,
        20,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: const BoxDecoration(
        color: AppColors.background,
        border: Border(top: BorderSide(color: Colors.white10, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AuthInlineError(controller.submitError),
          PaaxPrimaryButton(
            label: canComplete
                ? 'Continue'
                : 'Select ${controller.remaining} more',
            loading: controller.isSubmitting,
            onPressed:
                canComplete && !controller.isSubmitting ? () => onContinue() : null,
          ),
        ],
      ),
    );
  }
}

// ── Shared small states ────────────────────────────────────────────────────────

class _CenteredSpinner extends StatelessWidget {
  const _CenteredSpinner();
  @override
  Widget build(BuildContext context) => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ),
      );
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _MessageState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.mutedText, size: 48),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off, color: AppColors.mutedText, size: 48),
            const SizedBox(height: 14),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.textSecondary, fontSize: 14, height: 1.4)),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
