import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import '../state/playback_controller.dart';
import '../../core/theme/app_colors.dart';

class SmoothAudioProgressBar extends StatefulWidget {
  const SmoothAudioProgressBar({super.key});

  @override
  State<SmoothAudioProgressBar> createState() => _SmoothAudioProgressBarState();
}

class _SmoothAudioProgressBarState extends State<SmoothAudioProgressBar> with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  Duration _lastSyncedPosition = Duration.zero;
  DateTime _lastSyncedTime = DateTime.now();
  double? _dragValue;
  
  // Cache controller to remove listeners
  PlaybackController? _controller;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  void _onTick(Duration elapsed) {
    if (mounted) {
      setState(() {}); // Trigger rebuild frame
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newController = context.read<PlaybackController>();
    if (_controller != newController) {
      _removeListeners();
      _controller = newController;
      _addListeners();
    }
  }

  void _addListeners() {
    _controller?.positionNotifier.addListener(_onPositionChanged);
    _controller?.addListener(_onPlayerStateChanged); // listen to isPlaying
    
    // Initial sync
    if (_controller != null) {
      _lastSyncedPosition = _controller!.positionNotifier.value;
      _lastSyncedTime = DateTime.now();
      _updateTickerState();
    }
  }

  void _removeListeners() {
    _controller?.positionNotifier.removeListener(_onPositionChanged);
    _controller?.removeListener(_onPlayerStateChanged);
  }
  
  void _onPositionChanged() {
    if (_controller == null) return;
    final newPos = _controller!.positionNotifier.value;
    
    // Only verify monotonicity if not large jump (seek)
    // But here we just re-sync.
    setState(() {
       _lastSyncedPosition = newPos;
       _lastSyncedTime = DateTime.now();
    });
  }

  void _onPlayerStateChanged() {
    _updateTickerState();
  }

  void _updateTickerState() {
    if (_controller != null && _controller!.isPlaying) {
      if (!_ticker.isActive) _ticker.start();
    } else {
      if (_ticker.isActive) _ticker.stop();
      // One last sync drawing
      if (mounted) setState(() {}); 
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _removeListeners();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) return const SizedBox.shrink();

    return ValueListenableBuilder<Duration>(
      valueListenable: _controller!.durationNotifier,
      builder: (context, duration, _) {
        final max = duration.inSeconds.toDouble();
        final maxVal = max > 0 ? max : 1.0;
        
        // Calculate current visual position
        double currentSeconds = 0.0;
        
        if (_dragValue != null) {
          currentSeconds = _dragValue!;
        } else {
          // INTERPOLATION LOGIC
          if (_controller!.isPlaying) {
             final elapsed = DateTime.now().difference(_lastSyncedTime);
             currentSeconds = (_lastSyncedPosition + elapsed).inMilliseconds / 1000.0;
          } else {
             currentSeconds = _lastSyncedPosition.inMilliseconds / 1000.0;
          }
          currentSeconds = currentSeconds.clamp(0.0, maxVal);
        }

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppColors.primaryStart,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                trackShape: CustomTrackShape(),
              ),
              child: Slider(
                value: currentSeconds.clamp(0.0, maxVal),
                min: 0,
                max: maxVal,
                onChanged: (val) {
                  setState(() {
                    _dragValue = val;
                  });
                },
                onChangeStart: (_) {
                  _controller!.startScrubbing();
                },
                onChangeEnd: (val) {
                   _dragValue = null;
                   _controller!.endScrubbing(Duration(seconds: val.toInt()));
                   // Update sync point locally immediately for responsiveness
                   _lastSyncedPosition = Duration(seconds: val.toInt());
                   _lastSyncedTime = DateTime.now();
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.zero,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_formatDuration(Duration(milliseconds: (currentSeconds * 1000).toInt())), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  Text(_formatDuration(duration), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            )
          ],
        );
      }
    );
  }
  
  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }
}

class CustomTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final double trackHeight = sliderTheme.trackHeight!;
    final double trackLeft = offset.dx;
    final double trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
