import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';

class HiddenVideoPlayer extends StatelessWidget {
  const HiddenVideoPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Delegates to the engine's view (Mobile or Web specific) via Controller
    return SizedBox(
       width: 1, 
       height: 1, 
       child: Opacity(
         opacity: 0.01,
         child: context.read<PlaybackController>().buildPlayerView(context),
       )
    );
  }
}
