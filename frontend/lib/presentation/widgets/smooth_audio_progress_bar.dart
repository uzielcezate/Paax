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
        final durationKnown = duration > Duration.zero;
        final max = duration.inSeconds.toDouble();
        // When duration is unknown we set maxVal = 1.0 ONLY for the
        // disabled slider widget — the slider is non-interactive and
        // the value is locked to 0, so no fake 1-second progress appears.
        final maxVal = durationKnown ? max : 1.0;

        // Calculate current visual position
        double currentSeconds = 0.0;

        if (durationKnown) {
          if (_dragValue != null) {
            currentSeconds = _dragValue!;
          } else {
            // INTERPOLATION LOGIC
            if (_controller!.isPlaying) {
              final elapsed = DateTime.now().difference(_lastSyncedTime);
              currentSeconds =
                  (_lastSyncedPosition + elapsed).inMilliseconds / 1000.0;
            } else {
              currentSeconds = _lastSyncedPosition.inMilliseconds / 1000.0;
            }
            currentSeconds = currentSeconds.clamp(0.0, maxVal);
          }
        }
        // When duration is unknown, currentSeconds stays 0.0 — slider is disabled.

        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: durationKnown
                    ? const RoundSliderThumbShape(enabledThumbRadius: 6)
                    : const RoundSliderThumbShape(
                        enabledThumbRadius: 0), // hide thumb when unknown
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: durationKnown
                    ? AppColors.primaryStart
                    : Colors.white12, // dimmed when unknown
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                trackShape: CustomTrackShape(),
              ),
              child: Slider(
                value: durationKnown
                    ? currentSeconds.clamp(0.0, maxVal)
                    : 0.0, // locked to start when unknown
                min: 0,
                max: maxVal,
                // Disable all interaction when duration is unknown
                onChanged: durationKnown
                    ? (val) {
                        setState(() {
                          _dragValue = val;
                        });
                      }
                    : null,
                onChangeStart: durationKnown
                    ? (_) {
                        _controller!.startScrubbing();
                      }
                    : null,
                onChangeEnd: durationKnown
                    ? (val) {
                        _dragValue = null;
                        _controller!.endScrubbing(
                            Duration(seconds: val.toInt()));
                        _lastSyncedPosition =
                            Duration(seconds: val.toInt());
                        _lastSyncedTime = DateTime.now();
                      }
                    : null,
              ),
            ),
            Padding(
              padding: EdgeInsets.zero,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    durationKnown
                        ? _formatDuration(Duration(
                            milliseconds:
                                (currentSeconds * 1000).toInt()))
                        : '--:--',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
                  Text(
                    durationKnown ? _formatDuration(duration) : '--:--',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70)),
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
