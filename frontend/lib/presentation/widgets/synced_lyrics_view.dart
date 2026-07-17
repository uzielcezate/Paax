import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A single synced lyric line with timestamp.
class LyricLine {
  final Duration time;
  final Duration? endTime;
  final String text;
  final bool isInstrumentalGap;

  const LyricLine({
    required this.time,
    this.endTime,
    required this.text,
    this.isInstrumentalGap = false,
  });
}

/// Full lyrics track container.
class LyricsTrack {
  final String trackId;
  final List<LyricLine> lines;
  final String? source;
  final bool isSynced;

  const LyricsTrack({
    required this.trackId,
    required this.lines,
    this.source,
    this.isSynced = false,
  });
}

/// Lyrics view for the Full Player.
///
/// Supports two modes:
/// - **Synced** (isSynced: true): Auto-advances with playback, glow on active line,
///   centered scroll, back-to-current button.
/// - **Plain** (isSynced: false): Manual scroll only, no auto-advance, uniform
///   opacity, no glow — clean reading experience.
class SyncedLyricsView extends StatefulWidget {
  final List<LyricLine> lyrics;
  final ValueListenable<Duration> positionNotifier;
  final ValueChanged<Duration>? onSeekToLine;
  final bool isSynced;

  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    required this.positionNotifier,
    this.onSeekToLine,
    this.isSynced = true,
  });

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> {
  final ScrollController _scrollController = ScrollController();
  bool _userScrolling = false;
  int _playbackIndex = -1;
  int _focusIndex = -1;
  bool _initialScrollDone = false;

  // Keys for each lyric line — used for ensureVisible centering.
  List<GlobalKey> _lineKeys = [];

  // Estimated average line height for approximate center detection and scroll fallback.
  static const double _estimatedLineHeight = 56.0;

  @override
  void initState() {
    super.initState();
    _buildKeys();
    if (widget.isSynced) {
      widget.positionNotifier.addListener(_onPositionChanged);
      _scrollController.addListener(_onScrollUpdate);

      // Compute initial index immediately so the glow is correct on first frame.
      final idx = _computeIndex(widget.positionNotifier.value);
      if (idx >= 0) {
        _playbackIndex = idx;
        _focusIndex = idx;
      }
    }
  }

  @override
  void dispose() {
    if (widget.isSynced) {
      widget.positionNotifier.removeListener(_onPositionChanged);
      _scrollController.removeListener(_onScrollUpdate);
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _buildKeys() {
    _lineKeys = List.generate(widget.lyrics.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(SyncedLyricsView old) {
    super.didUpdateWidget(old);
    if (old.positionNotifier != widget.positionNotifier) {
      old.positionNotifier.removeListener(_onPositionChanged);
      widget.positionNotifier.addListener(_onPositionChanged);
    }
    if (old.lyrics != widget.lyrics) {
      _playbackIndex = -1;
      _focusIndex = -1;
      _userScrolling = false;
      _initialScrollDone = false;
      _buildKeys();
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    } else if (widget.isSynced) {
      // Same lyrics but widget was rebuilt (e.g. toggling between cover and lyrics).
      // Re-sync to current playback position immediately without resetting state.
      _resyncToPlayback();
    }
  }

  /// Re-sync to the current playback position. Called on widget rebuild
  /// (e.g. switching from cover art back to lyrics) to prevent lyrics
  /// from resetting to the beginning.
  void _resyncToPlayback() {
    final idx = _computeIndex(widget.positionNotifier.value);
    if (idx >= 0 && idx != _focusIndex) {
      _playbackIndex = idx;
      _focusIndex = idx;
      _userScrolling = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {});
        _scrollToIndex(idx);
      });
    }
  }

  int _computeIndex(Duration position) {
    if (widget.lyrics.isEmpty) return -1;
    int idx = -1;
    for (int i = 0; i < widget.lyrics.length; i++) {
      if (position >= widget.lyrics[i].time) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _onPositionChanged() {
    final newIndex = _computeIndex(widget.positionNotifier.value);
    if (newIndex != _playbackIndex) {
      _playbackIndex = newIndex;
      if (!_userScrolling && newIndex >= 0) {
        if (_focusIndex != newIndex) {
          setState(() => _focusIndex = newIndex);
        }
        _scrollToIndex(newIndex);
      } else {
        setState(() {});
      }
    }
  }

  /// Scroll listener — approximate which line is at viewport center during manual scroll.
  void _onScrollUpdate() {
    if (!_userScrolling) return;
    if (!_scrollController.hasClients) return;

    final viewportHeight = _scrollController.position.viewportDimension;
    final scrollOffset = _scrollController.offset;
    final topPad = viewportHeight / 2;
    final centerContentOffset = scrollOffset + (viewportHeight / 2) - topPad;
    final centerIndex = (centerContentOffset / _estimatedLineHeight).round()
        .clamp(0, widget.lyrics.length - 1);

    if (centerIndex != _focusIndex) {
      setState(() => _focusIndex = centerIndex);
    }
  }

  /// Scroll a given index to the viewport center.
  /// First tries ensureVisible (precise), falls back to estimated offset
  /// when the target line widget isn't built (far-off in ListView.builder).
  void _scrollToIndex(int index) {
    if (index < 0 || index >= _lineKeys.length) return;

    final ctx = _lineKeys[index].currentContext;
    if (ctx != null) {
      // Widget is built — use ensureVisible for pixel-perfect centering
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5, // center of viewport
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOutQuart,
      );
    } else if (_scrollController.hasClients) {
      // Widget not built (scrolled far away) — estimate position
      final viewportHeight = _scrollController.position.viewportDimension;
      final centerPad = viewportHeight / 2;
      final targetOffset = (index * _estimatedLineHeight) - centerPad + (_estimatedLineHeight / 2) + centerPad;
      final clampedOffset = targetOffset.clamp(
        _scrollController.position.minScrollExtent,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onUserScrollStart() {
    _userScrolling = true;
  }

  void _onUserScrollEnd() {
    // No auto-return. User stays in manual mode.
  }

  void _recenterNow() {
    _userScrolling = false;
    if (_playbackIndex >= 0) {
      setState(() => _focusIndex = _playbackIndex);
      _scrollToIndex(_playbackIndex);
    }
  }

  bool get _isAway {
    return _userScrolling && _playbackIndex >= 0 && _focusIndex != _playbackIndex;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lyrics.isEmpty) {
      return const Center(
        child: Text(
          'No lyrics available',
          style: TextStyle(color: Colors.white38, fontSize: 16),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        // Padding so the first and last lines can reach exact viewport center.
        final centerPad = viewportHeight / 2;

        // Scroll to the current playback line on first build
        if (!_initialScrollDone) {
          _initialScrollDone = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // Re-compute in case position advanced between initState and layout
            final idx = _computeIndex(widget.positionNotifier.value);
            if (idx >= 0) {
              _playbackIndex = idx;
              _focusIndex = idx;
              setState(() {}); // Ensure glow renders on correct line
              _scrollToIndex(idx);
            }
          });
        }

        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _onUserScrollStart();
                } else if (notification is ScrollEndNotification) {
                  _onUserScrollEnd();
                }
                return false;
              },
              child: ShaderMask(
                shaderCallback: (Rect bounds) {
                  return const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0.0, 0.10, 0.90, 1.0],
                  ).createShader(bounds);
                },
                blendMode: BlendMode.dstIn,
                child: ListView.builder(
                  controller: _scrollController,
                  padding: widget.isSynced
                      ? EdgeInsets.only(top: centerPad, bottom: centerPad)
                      : const EdgeInsets.symmetric(vertical: 20),
                  physics: const BouncingScrollPhysics(),
                  itemCount: widget.lyrics.length,
                  itemBuilder: (context, index) {
                    if (!widget.isSynced) {
                      // Plain mode: uniform style, no focus tracking
                      return _LyricLineWidget(
                        key: _lineKeys[index],
                        line: widget.lyrics[index],
                        isCurrent: false,
                        distance: 0,
                        isPast: false,
                        isPlainMode: true,
                        onTap: () {},
                      );
                    }
                    return _LyricLineWidget(
                      key: _lineKeys[index],
                      line: widget.lyrics[index],
                      isCurrent: index == _focusIndex,
                      distance: _focusIndex >= 0 ? (index - _focusIndex).abs() : index,
                      isPast: _focusIndex >= 0 && index < _focusIndex,
                      isPlainMode: false,
                      onTap: () {
                        if (widget.onSeekToLine != null) {
                          widget.onSeekToLine!(widget.lyrics[index].time);
                          _userScrolling = false;
                        }
                      },
                    );
                  },
                ),
              ),
            ),

            // Floating "back to current" icon-only button (synced mode only)
            if (widget.isSynced && _isAway)
              Positioned(
                bottom: 12,
                right: 12,
                child: GestureDetector(
                  onTap: _recenterNow,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                        width: 0.5,
                      ),
                    ),
                    child: Icon(
                      Icons.vertical_align_center_rounded,
                      size: 16,
                      color: Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Individual lyric line widget with cinematic highlighting.
/// No fixed height — wraps naturally. Padding provides comfortable spacing.
class _LyricLineWidget extends StatelessWidget {
  final LyricLine line;
  final bool isCurrent;
  final int distance;
  final bool isPast;
  final bool isPlainMode;
  final VoidCallback onTap;

  const _LyricLineWidget({
    super.key,
    required this.line,
    required this.isCurrent,
    required this.distance,
    required this.isPast,
    this.isPlainMode = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isGap = line.isInstrumentalGap ||
        line.text == '...' ||
        line.text == '♪' ||
        line.text.trim().isEmpty;

    double opacity;
    if (isPlainMode) {
      // Plain mode: uniform readable opacity for all lines
      opacity = isGap ? 0.25 : 0.65;
    } else if (isCurrent) {
      opacity = 1.0;
    } else if (distance == 1) {
      opacity = 0.45;
    } else if (distance == 2) {
      opacity = 0.28;
    } else if (isPast) {
      opacity = 0.15;
    } else {
      opacity = 0.22;
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // Vertical padding: enough for descenders/accents + separation between lines
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: isGap
            ? _buildGapDots()
            : _buildLyricText(opacity),
      ),
    );
  }

  Widget _buildGapDots() {
    return Center(
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 80),
        style: TextStyle(
          color: Colors.white.withValues(alpha: isCurrent ? 0.8 : 0.15),
          fontSize: 18,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
          letterSpacing: 5,
          shadows: (isCurrent && !isPlainMode)
              ? [
                  Shadow(
                    color: Colors.white.withValues(alpha: 0.3),
                    blurRadius: 18,
                  ),
                ]
              : null,
        ),
        child: const Text('· · ·'),
      ),
    );
  }

  Widget _buildLyricText(double opacity) {
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOutCubic,
      style: TextStyle(
        color: Colors.white.withValues(alpha: opacity),
        fontSize: 22.0,
        fontWeight: (isCurrent && !isPlainMode) ? FontWeight.w800 : FontWeight.w500,
        height: 1.4,
        shadows: (isCurrent && !isPlainMode)
            ? [
                Shadow(
                  color: Colors.white.withValues(alpha: 0.35),
                  blurRadius: 24,
                ),
                Shadow(
                  color: Colors.white.withValues(alpha: 0.12),
                  blurRadius: 48,
                ),
              ]
            : null,
      ),
      child: Text(
        line.text,
        textAlign: TextAlign.center,
        softWrap: true,
        overflow: TextOverflow.visible,
      ),
    );
  }
}
