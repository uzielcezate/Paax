import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';
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
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _controller = YoutubePlayerController(
      params: const YoutubePlayerParams(
        showControls: false,
        showFullscreenButton: false,
        mute: false,
        loop: false,
      ),
    );
    
    _controller.listen((event) {
        if (!mounted) return;
        final playback = context.read<PlaybackController>();
        
        // Sync Duration
        playback.syncDuration(event.metaData.duration);
        
        if (event.playerState == PlayerState.ended) {
           playback.onTrackFinished();
           _stopPositionTimer();
        } else if (event.playerState == PlayerState.playing) {
           _startPositionTimer();
        } else {
           _stopPositionTimer();
        }
    });

    _isInit = true;
  }
  
  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
       if (!mounted) return;
       final pos = await _controller.currentTime;
       final playback = context.read<PlaybackController>();
       playback.syncPosition(Duration(seconds: pos.toInt()));
    });
  }
  
  void _stopPositionTimer() {
    _positionTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    // Listen to PlaybackController changes
    final playback = context.watch<PlaybackController>();
    final currentTrack = playback.currentTrack;

    if (currentTrack != null) {
       final videoId = currentTrack.id;
       if (videoId != _lastVideoId && videoId.isNotEmpty) {
           _lastVideoId = videoId;
           _controller.loadVideoById(videoId: videoId);
       }
    }

    return YoutubePlayer(
      controller: _controller,
      aspectRatio: 16/9,
    );
  }
  
  @override
  void didChangeDependencies() {
     super.didChangeDependencies();
     final playback = context.read<PlaybackController>();
     playback.addListener(_onPlaybackChange);
     
     // Listen to seek stream
     playback.seekStream.listen((pos) {
        _controller.seekTo(seconds: pos.inSeconds.toDouble());
     });
  }
  
  @override
  void dispose() {
     _stopPositionTimer();
     final playback = context.read<PlaybackController>(); // Warning using context in dispose
     playback.removeListener(_onPlaybackChange);
     super.dispose();
  }
  
  void _onPlaybackChange() {
     if (!mounted) return;
     final playback = context.read<PlaybackController>();
     
     if (playback.isPlaying) {
        _controller.playVideo();
     } else {
        _controller.pauseVideo();
     }
  }
}
