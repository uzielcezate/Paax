import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';

/// Renders the engine's platform view (web only — just_audio is headless on mobile).
class HiddenVideoPlayer extends StatelessWidget {
  const HiddenVideoPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // just_audio (mobile) is headless — no widget needed.
    // youtube_player_iframe (web) requires a real DOM node in the tree.
    if (!kIsWeb) return const SizedBox.shrink();

    return SizedBox(
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0.01,
        child: context.read<PlaybackController>().buildPlayerView(context),
      ),
    );
  }
}
