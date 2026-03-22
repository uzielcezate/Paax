import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/playback/playback_diagnostics.dart';

// ============================================================================
// TEMPORARY DEBUG OVERLAY — remove before production release.
// ============================================================================

class PlaybackDebugOverlay extends StatefulWidget {
  const PlaybackDebugOverlay({super.key});

  @override
  State<PlaybackDebugOverlay> createState() => _PlaybackDebugOverlayState();
}

class _PlaybackDebugOverlayState extends State<PlaybackDebugOverlay> {
  PlaybackDiagnostics? _diag;
  Timer?               _ticker;
  bool                 _stalled = false;

  @override
  void initState() {
    super.initState();
    _diag = PlaybackDiagnosticsNotifier.value;
    PlaybackDiagnosticsNotifier.addListener(_onDiag);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final d = _diag;
      if (d == null) { setState(() {}); return; }
      const stuck = {
        PlaybackStage.resolving, PlaybackStage.retryResolving,
        PlaybackStage.settingSource, PlaybackStage.buffering,
      };
      setState(() { _stalled = stuck.contains(d.stage) && d.stageAge.inSeconds >= 5; });
    });
  }

  void _onDiag() {
    if (!mounted) return;
    setState(() { _diag = PlaybackDiagnosticsNotifier.value; _stalled = false; });
  }

  @override
  void dispose() {
    PlaybackDiagnosticsNotifier.removeListener(_onDiag);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _diag;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.90),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderColor(d), width: 1.8),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.white12),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          title: Row(children: [
            _StageChip(d?.stage, stalled: _stalled),
            const SizedBox(width: 6),
            if ((d?.attempt ?? 1) > 1)
              _Badge('retry#${d!.attempt}', Colors.amber),
            const SizedBox(width: 6),
            Expanded(
              child: Text(d?.videoId ?? '—',
                  style: const TextStyle(color: Colors.white60, fontFamily: 'monospace', fontSize: 11),
                  overflow: TextOverflow.ellipsis),
            ),
            if (_stalled) const Text('⏱', style: TextStyle(color: Colors.orange, fontSize: 13)),
          ]),
          children: [_buildBody(d)],
        ),
      ),
    );
  }

  Widget _buildBody(PlaybackDiagnostics? d) {
    if (d == null) return const _R('status', 'waiting for first play…');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Stage ────────────────────────────────────────────────────────────
        _R('stage',       '${d.stage.name}  (+${d.stageAge.inSeconds}s)'),
        _R('attempt',     '${d.attempt}'),
        _R('failureSrc',  d.failureSource.name, warn: d.failureSource != FailureSource.none),

        const _Div(),

        // ── Resolve info ─────────────────────────────────────────────────────
        _R('source',      d.resolveSource),
        _R('resolveMs',   d.resolveMs != null ? '${d.resolveMs} ms' : '—'),
        _R('itag',        d.itag == 0    ? '—' : '${d.itag}'),
        _R('mimeType',    d.mimeType),
        _R('sourceType',  d.sourceType),
        _R('bitrate',     d.bitrate == 0 ? '—' : '${d.bitrate ~/ 1000} kbps'),
        _R('host',        d.urlHost),
        _R('expiresAt',   _fmtExpiry(d.expiresAt), warn: d.isUrlExpired),

        const _Div(),

        // ── setAudioSource ───────────────────────────────────────────────────
        _R('setSrc?',  d.setSourceCalled    ? 'called' : 'not yet'),
        _R('setSrcOK', d.setSourceSucceeded ? '✓ yes'  : '—', ok: d.setSourceSucceeded),
        if (d.setSourceError != null) _R('setSrcErr', d.setSourceError!, err: true),

        // ── play() ───────────────────────────────────────────────────────────
        _R('play()?',  d.playCalled    ? 'called' : 'not yet'),
        _R('playOK',   d.playSucceeded ? '✓ yes'  : '—', ok: d.playSucceeded),
        if (d.playError != null) _R('playErr', d.playError!, err: true),

        const _Div(),

        // ── Live player ───────────────────────────────────────────────────────
        _R('exoState', d.processingState),
        _R('playing',  d.isPlaying ? '▶  true' : '⏸  false'),
        _R('position', _dur(d.position)),
        _R('buffered', _dur(d.buffered)),
        _R('duration', _dur(d.duration)),
        _R('advanced', d.position > Duration.zero || d.buffered > Duration.zero
            ? '✓ yes' : '✗ no',
            ok:  d.position > Duration.zero || d.buffered > Duration.zero,
            warn: d.playCalled && d.position == Duration.zero && d.buffered == Duration.zero),

        // ── Warning banners ───────────────────────────────────────────────────
        if (_isBannerStage(d.stage))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: double.infinity, padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.orange),
              ),
              child: Text(_stageWarning(d.stage, d),
                  style: const TextStyle(
                      color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),

        if (d.lastError != null) ...[
          const _Div(),
          _R('❌ error', d.lastError!, err: true),
        ],
      ],
    );
  }

  bool _isBannerStage(PlaybackStage s) => const {
    PlaybackStage.falsePlayingDetected,
    PlaybackStage.failedBuffering,
    PlaybackStage.retryFailed,
    PlaybackStage.failedResolve,
  }.contains(s);

  String _stageWarning(PlaybackStage s, PlaybackDiagnostics d) {
    switch (s) {
      case PlaybackStage.falsePlayingDetected:
        return '⚠ FALSE PLAYING — play() called but pos=0 + buf=0';
      case PlaybackStage.failedBuffering:
        return '⚠ STALL — no bytes in 3s (${d.failureSource.name})';
      case PlaybackStage.retryFailed:
        return '⚠ ALL RETRIES FAILED — ${d.attempt} attempt(s) tried';
      case PlaybackStage.failedResolve:
        return '⚠ RESOLVE FAILED — ${d.lastError ?? 'unknown error'}';
      default: return '';
    }
  }

  Color _borderColor(PlaybackDiagnostics? d) {
    if (d == null) return Colors.white24;
    if (_stalled)  return Colors.orange;
    switch (d.stage) {
      case PlaybackStage.playing:
      case PlaybackStage.retrySucceeded:   return Colors.greenAccent;
      case PlaybackStage.failedResolve:
      case PlaybackStage.failedSetSource:
      case PlaybackStage.failedBuffering:
      case PlaybackStage.falsePlayingDetected:
      case PlaybackStage.retryFailed:      return Colors.redAccent;
      case PlaybackStage.retryResolving:   return Colors.orange;
      case PlaybackStage.buffering:
      case PlaybackStage.settingSource:    return Colors.amber;
      case PlaybackStage.resolved:
      case PlaybackStage.sourceReady:      return Colors.blue;
      default:                             return Colors.white24;
    }
  }

  static String _dur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _fmtExpiry(int expiresAt) {
    if (expiresAt == 0) return '—';
    final exp  = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final diff = exp.difference(DateTime.now());
    if (diff.isNegative) {
      final a = diff.abs();
      return '⚠ EXPIRED ${a.inHours}h${a.inMinutes.remainder(60)}m ago';
    }
    return 'OK (+${diff.inHours}h${diff.inMinutes.remainder(60)}m)';
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String text;
  final Color  color;
  const _Badge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
    child: Text(text, style: const TextStyle(
        color: Colors.black87, fontSize: 10, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
  );
}

class _StageChip extends StatelessWidget {
  final PlaybackStage? stage;
  final bool stalled;
  const _StageChip(this.stage, {required this.stalled});
  @override
  Widget build(BuildContext context) {
    Color bg;
    if (stalled) { bg = Colors.orange; }
    else {
      switch (stage) {
        case PlaybackStage.playing:
        case PlaybackStage.retrySucceeded:   bg = Colors.green.shade700;      break;
        case PlaybackStage.failedResolve:
        case PlaybackStage.failedSetSource:
        case PlaybackStage.failedBuffering:
        case PlaybackStage.falsePlayingDetected:
        case PlaybackStage.retryFailed:      bg = Colors.red.shade700;        break;
        case PlaybackStage.retryResolving:   bg = Colors.deepOrange.shade700; break;
        case PlaybackStage.buffering:
        case PlaybackStage.settingSource:    bg = Colors.amber.shade800;      break;
        case PlaybackStage.resolved:
        case PlaybackStage.sourceReady:      bg = Colors.blue.shade700;       break;
        default:                             bg = Colors.grey.shade700;
      }
    }
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(stage?.name ?? 'idle',
          style: const TextStyle(color: Colors.white, fontSize: 10,
              fontWeight: FontWeight.bold, fontFamily: 'monospace')),
    );
  }
}

class _R extends StatelessWidget {
  final String label, value;
  final bool err, warn, ok;
  const _R(this.label, this.value, {this.err=false, this.warn=false, this.ok=false});
  @override
  Widget build(BuildContext context) {
    final Color col = err  ? Colors.redAccent
                    : warn ? Colors.orange
                    : ok   ? Colors.greenAccent
                           : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 88, child: Text(label,
            style: const TextStyle(color: Colors.white38, fontSize: 10.5, fontFamily: 'monospace'))),
        Expanded(child: Text(value,
            style: TextStyle(color: col, fontSize: 10.5, fontFamily: 'monospace',
                fontWeight: (err || warn) ? FontWeight.bold : FontWeight.normal),
            maxLines: 3, overflow: TextOverflow.fade)),
      ]),
    );
  }
}

class _Div extends StatelessWidget {
  const _Div();
  @override
  Widget build(BuildContext context) =>
      const Divider(height: 8, thickness: 0.4, color: Colors.white12);
}
