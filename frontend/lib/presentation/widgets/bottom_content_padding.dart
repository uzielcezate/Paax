
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';
import '../../core/utils/safe_insets.dart';

class BottomContentPadding extends StatelessWidget {
  final bool isSliver;

  const BottomContentPadding({super.key, this.isSliver = false});

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<PlaybackController, bool>((c) => c.currentTrack != null);
    final bottomSafe = SafeInsets.bottomInset(context);

    // Heights
    final double navHeight = 90;
    final double miniPlayerHeight = hasTrack ? 90 : 0;
    final double spacing = 24;

    final double totalHeight = navHeight + miniPlayerHeight + bottomSafe + spacing;

    if (isSliver) {
      return SliverToBoxAdapter(child: SizedBox(height: totalHeight));
    } else {
      return SizedBox(height: totalHeight);
    }
  }

  static double bottomHeight(BuildContext context) {
    final safe = SafeInsets.bottomInset(context);
    // 90 (nav) + 90 (miniplayer) + 24 (spacing)
    return 204 + safe; 
  }
}
