import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import '../state/playback_controller.dart';

class PlatformYouTubePlayer extends StatefulWidget {
  const PlatformYouTubePlayer({super.key});

  @override
  State<PlatformYouTubePlayer> createState() => _PlatformYouTubePlayerState();
}

class _PlatformYouTubePlayerState extends State<PlatformYouTubePlayer> {
  late YoutubePlayerController _controller;
  String? _lastVideoId;
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController(
      initialVideoId: '', 
      flags: const YoutubePlayerFlags(
        autoPlay: false,
        mute: false,
        hideControls: true,
        controlsVisibleAtStart: false,
        hideThumbnail: true,
      ),
    );

    _controller.addListener(_videoListener);
    _isInit = true;
  }
  
  void _videoListener() {
      if (!mounted) return;
      final playback = context.read<PlaybackController>();

      // Sync State
      if (_controller.value.playerState == PlayerState.ended) {
          playback.onTrackFinished();
      }
      
      playback.syncPosition(_controller.value.position);
      playback.syncDuration(_controller.value.metaData.duration);
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final currentTrack = playback.currentTrack;

    if (currentTrack != null) {
       final videoId = currentTrack.id;
       if (videoId != _lastVideoId && videoId.isNotEmpty) {
           _lastVideoId = videoId;
           _controller.load(videoId);
       }
    }

    return YoutubePlayer(
      controller: _controller,
      width: 1, // Minimize visibility
    );
  }
  
  @override
  void didChangeDependencies() {
     super.didChangeDependencies();
     final playback = context.read<PlaybackController>();
     playback.addListener(_onPlaybackChange);
     // Sync seek
     playback.seekStream.listen((pos) {
         _controller.seekTo(pos);
     });
  }
  
  @override
  void dispose() {
     _controller.dispose();
     super.dispose();
  }
  
  void _onPlaybackChange() {
     if (!mounted) return;
     final playback = context.read<PlaybackController>();
     
     if (playback.isPlaying) {
         if (!_controller.value.isPlaying) _controller.play();
     } else {
         if (_controller.value.isPlaying) _controller.pause();
     }
  }
}
