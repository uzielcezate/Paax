import 'package:flutter/material.dart';

/// ─── MarqueeController ─────────────────────────────────────────────────────
/// Optional sync controller. When two MarqueeText widgets share the same
/// controller, they start scrolling together and wait for the slower one
/// before restarting — keeping title and artist visually synchronized.
class MarqueeController extends ChangeNotifier {
  final Set<_MarqueeTextState> _members = {};
  bool _syncing = false;

  void _register(_MarqueeTextState m) => _members.add(m);
  void _unregister(_MarqueeTextState m) => _members.remove(m);

  /// Called by each member when its scroll cycle completes.
  void _onCycleComplete(_MarqueeTextState who) {
    if (_syncing) return;
    final scrolling = _members.where((m) => m._needsScroll);
    if (scrolling.every((m) => m._cycleComplete)) {
      _syncing = true;
      for (final m in scrolling) {
        m._cycleComplete = false;
      }
      _syncing = false;
      for (final m in scrolling) {
        m._restartCycle();
      }
    }
  }
}

/// ─── MarqueeText ───────────────────────────────────────────────────────────
/// Infinite seamless horizontal marquee with:
/// - Ticker-based 60fps animation
/// - Duplicated text for seamless looping — no visible reset
/// - Soft edge fade masks on left and right
/// - Optional sync via shared [MarqueeController]
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final double gap;
  final Duration pauseDuration;
  final double velocity;
  final double fadeMaskWidth;
  final MarqueeController? controller;
  /// Optional widget rendered before the text (e.g. ExplicitBadge).
  final Widget? prefix;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.gap = 48,
    this.pauseDuration = const Duration(seconds: 2),
    this.velocity = 35.0,
    this.fadeMaskWidth = 16.0,
    this.controller,
    this.prefix,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  double _textWidth = 0;
  double _containerWidth = 0;
  bool _needsScroll = false;
  bool _cycleComplete = false;
  bool _running = false;
  // Key to measure the inner content row for accurate scroll distance
  final GlobalKey _contentKey = GlobalKey();
  double _contentWidth = 0; // full width of [prefix + text]

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this);
    widget.controller?._register(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void didUpdateWidget(MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _anim.stop();
      _anim.value = 0;
      _running = false;
      _cycleComplete = false;
      _needsScroll = false;
      _textWidth = 0;
      _containerWidth = 0;
      _contentWidth = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    }
    if (old.controller != widget.controller) {
      old.controller?._unregister(this);
      widget.controller?._register(this);
    }
  }

  @override
  void dispose() {
    widget.controller?._unregister(this);
    _running = false;
    _anim.dispose();
    super.dispose();
  }

  void _measure() {
    if (!mounted) return;

    // Measure the INTRINSIC text width using TextPainter — not constrained
    final tp = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(); // unconstrained layout
    _textWidth = tp.width;
    tp.dispose();

    // Measure the available container width
    final parentRO = context.findRenderObject() as RenderBox?;
    _containerWidth = parentRO?.size.width ?? 0;

    final needs = _textWidth > _containerWidth + 1; // 1px tolerance
    if (needs != _needsScroll) {
      setState(() => _needsScroll = needs);
    }
    if (_needsScroll && !_running) {
      // Schedule another post-frame to get _contentWidth from rendered Row
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measureContent();
        if (!_running) _startCycle();
      });
    }
  }

  void _measureContent() {
    if (!mounted) return;
    final ro = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (ro != null) {
      _contentWidth = ro.size.width;
    }
    // Fallback: if we can't measure the rendered row, estimate from text alone
    if (_contentWidth <= 0) {
      _contentWidth = _textWidth;
    }
  }

  /// The scroll distance for one cycle: one full [prefix+text] block + gap.
  /// This ensures the second copy slides into exactly the same starting
  /// position, making the reset to value=0 completely invisible.
  double get _scrollDistance {
    if (_contentWidth > 0) return _contentWidth + widget.gap;
    return _textWidth + widget.gap;
  }

  Future<void> _startCycle() async {
    _running = true;
    while (mounted && _needsScroll) {
      // Pause at start
      await Future.delayed(widget.pauseDuration);
      if (!mounted || !_needsScroll) break;

      // Re-measure content in case layout changed
      _measureContent();

      final dist = _scrollDistance;
      final duration = Duration(
        milliseconds: (dist / widget.velocity * 1000).round(),
      );

      _anim.duration = duration;
      _anim.value = 0;

      try {
        await _anim.forward().orCancel;
      } on TickerCanceled {
        break;
      }
      if (!mounted || !_needsScroll) break;

      // Seamless reset: at value 1.0, offset = -scrollDistance.
      // The second [prefix+text] copy is now exactly at position 0.
      // Resetting to 0 is visually identical — no jump.
      _anim.value = 0;

      if (widget.controller != null) {
        _cycleComplete = true;
        widget.controller!._onCycleComplete(this);
        return; // controller will call _restartCycle
      }
    }
    _running = false;
  }

  void _restartCycle() {
    if (!mounted || !_needsScroll) return;
    _running = false;
    _startCycle();
  }

  @override
  Widget build(BuildContext context) {
    if (!_needsScroll) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Schedule re-measure after layout with actual constraints
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_containerWidth != constraints.maxWidth) {
              _containerWidth = constraints.maxWidth;
              final needs = _textWidth > _containerWidth + 1;
              if (needs != _needsScroll) {
                setState(() => _needsScroll = needs);
                if (_needsScroll && !_running) _startCycle();
              }
            }
          });
          return Row(
            children: [
              if (widget.prefix != null) widget.prefix!,
              Expanded(
                child: Text(
                  widget.text,
                  style: widget.style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
        },
      );
    }

    final dist = _scrollDistance;

    return ClipRect(
      child: ShaderMask(
        shaderCallback: (Rect bounds) {
          // Right fade edge pushed 2px further right for a cleaner disappearance
          final fadeW = widget.fadeMaskWidth;
          final rightEdge = ((fadeW + 2) / bounds.width).clamp(0.0, 0.15);
          final leftEdge = (fadeW / bounds.width).clamp(0.0, 0.15);
          return LinearGradient(
            colors: const [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent,
            ],
            stops: [0.0, leftEdge, 1.0 - rightEdge, 1.0],
          ).createShader(bounds);
        },
        blendMode: BlendMode.dstIn,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, child) {
            final offset = _anim.value * dist;
            return Transform.translate(
              offset: Offset(-offset, 0),
              child: child,
            );
          },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // First copy (measured via _contentKey)
              Row(
                key: _contentKey,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.prefix != null) widget.prefix!,
                  Text(
                    widget.text,
                    style: widget.style,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
              SizedBox(width: widget.gap),
              // Second copy (identical, for seamless looping)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.prefix != null) widget.prefix!,
                  Text(
                    widget.text,
                    style: widget.style,
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
