
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';

class BottomContentPadding extends StatelessWidget {
  final bool isSliver;

  const BottomContentPadding({super.key, this.isSliver = false});

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackController, bool>((c) => c.currentTrack != null);
    final bottomSafe = MediaQuery.of(context).padding.bottom;

    // Heights
    final double navHeight = 80;
    final double miniPlayerHeight = hasTrack ? 80 : 0;
    final double spacing = 24;

    final double totalHeight = navHeight + miniPlayerHeight + bottomSafe + spacing;

    if (isSliver) {
      return SliverToBoxAdapter(child: SizedBox(height: totalHeight));
    } else {
      return SizedBox(height: totalHeight);
    }
  }

  static double bottomHeight(BuildContext context) {
    // Determine if mini-player is visible
    // We can try to access the provider, or just default to a safe value that includes potential mini-player.
    // To be 100% safe and avoid hiding content, we'll assume the max height (with mini-player).
    // Or we can try to read the provider if possible.
    // User requested simpler helper. Let's return a safe max value.
    final safe = MediaQuery.of(context).padding.bottom;
    // 80 (nav) + 80 (miniplayer) + 24 (spacing)
    return 184 + safe; 
  }
}
