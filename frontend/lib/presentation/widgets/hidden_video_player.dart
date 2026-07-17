import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';

/// Renders the engine's platform view as a 300×300 widget.
///
/// The InAppWebView is configured with `allowBackgroundAudioPlaying: true`,
/// which means the plugin itself handles lifecycle correctly — it does NOT
/// pause the WebView when the Activity goes to background.
///
/// This widget just ensures the InAppWebView stays mounted in the tree.
class HiddenVideoPlayer extends StatelessWidget {
  const HiddenVideoPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 300,
      child: context.read<PlaybackController>().buildPlayerView(context),
    );
  }
}
