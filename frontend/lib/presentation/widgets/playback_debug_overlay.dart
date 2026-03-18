import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/playback/playback_diagnostics.dart';

// ============================================================================
// TEMPORARY DEBUG OVERLAY — remove before production release
//
// Drop-in widget for the Now Playing screen.
// Reads from [PlaybackDiagnosticsNotifier] (ValueNotifier) which the engine
// updates at every stage. The player live state (position/buffered/playing)
// is fed via [audioPlayer], which this widget polls every 500ms.
// ============================================================================

/// Wrap with [kDebugMode] guard at call-site so it tree-shakes in release.
///
/// Usage (inside PlayerScreen Column):
///   if (kDebugMode) PlaybackDebugOverlay(audioPlayer: _engine.player),
///
/// Since we can't expose the player directly, the overlay uses the
/// [PlaybackDiagnosticsNotifier] for player live-state too (engine pushes
/// copyWith updates via a periodic callback).
class PlaybackDebugOverlay extends StatefulWidget {
  const PlaybackDebugOverlay({super.key});

  @override
  State<PlaybackDebugOverlay> createState() => _PlaybackDebugOverlayState();
}

class _PlaybackDebugOverlayState extends State<PlaybackDebugOverlay> {
  PlaybackDiagnostics? _diag;
  Timer? _stallTimer;
  bool _stalled = false;

  @override
  void initState() {
    super.initState();
    _diag = PlaybackDiagnosticsNotifier.value;
    PlaybackDiagnosticsNotifier.addListener(_onDiagUpdate);
    // Stall check: fires every second, marks stall if stage age > 5s
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final d = PlaybackDiagnosticsNotifier.value;
      if (d == null) return;
      final isStuckStage = d.stage == PlaybackStage.resolving ||
          d.stage == PlaybackStage.settingSource ||
          d.stage == PlaybackStage.buffering;
      final nowStalled = isStuckStage && d.stageAge.inSeconds >= 5;
      if (nowStalled != _stalled) {
        setState(() => _stalled = nowStalled);
      } else {
        // Still force rebuild to update stageAge timer
        if (mounted) setState(() {});
      }
    });
  }

  void _onDiagUpdate() {
    if (!mounted) return;
    setState(() {
      _diag = PlaybackDiagnosticsNotifier.value;
      _stalled = false; // reset stall flag on any update
    });
  }

  @override
  void dispose() {
    PlaybackDiagnosticsNotifier.removeListener(_onDiagUpdate);
    _stallTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _diag;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _borderColor(d),
          width: 1.5,
        ),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.white12,
        ),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          title: Row(
            children: [
              _StageChip(d?.stage, stalled: _stalled),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d?.videoId ?? '—',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_stalled)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Text('⏱ STALL',
                      style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          children: [
            if (d == null)
              const _Row('status', 'waiting for first play…')
            else ...[
              _Row('stage',       d.stageName + (d.stageAge.inSeconds > 0 ? '  (+${d.stageAge.inSeconds}s)' : '')),
              _Row('sourceType',  d.sourceType),
              _Row('mimeType',    d.mimeType),
              _Row('urlHost',     d.urlHost),
              _Row('expiresAt',   d.expiresAt == 0 ? '—' : _fmtExpiry(d.expiresAt)),
              const Divider(height: 8, color: Colors.white12),
              _Row('playerState', d.processingState),
              _Row('playing',     d.isPlaying ? '▶  true' : '⏸  false'),
              _Row('position',    _fmtDuration(d.position)),
              _Row('buffered',    _fmtDuration(d.buffered)),
              _Row('duration',    _fmtDuration(d.duration)),
              if (d.lastError != null) ...[
                const Divider(height: 8, color: Colors.white12),
                _Row('❌ error', d.lastError!, isError: true),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Color _borderColor(PlaybackDiagnostics? d) {
    if (d == null) return Colors.white24;
    if (_stalled) return Colors.orange;
    switch (d.stage) {
      case PlaybackStage.playing:     return Colors.greenAccent;
      case PlaybackStage.failedResolve:
      case PlaybackStage.failedPlayer: return Colors.redAccent;
      case PlaybackStage.buffering:   return Colors.amber;
      default:                        return Colors.white24;
    }
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _fmtExpiry(int expiresAt) {
    final exp  = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
    final diff = exp.difference(DateTime.now());
    final sign = diff.isNegative ? '−' : '+';
    final abs  = diff.abs();
    final h    = abs.inHours;
    final m    = abs.inMinutes.remainder(60);
    return diff.isNegative
        ? '⚠ EXPIRED ${sign}${h}h${m}m ago'
        : 'OK (${sign}${h}h${m}m left)';
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _StageChip extends StatelessWidget {
  final PlaybackStage? stage;
  final bool stalled;
  const _StageChip(this.stage, {required this.stalled});

  @override
  Widget build(BuildContext context) {
    final label = stage?.name ?? 'idle';
    Color bg;
    if (stalled) {
      bg = Colors.orange;
    } else {
      switch (stage) {
        case PlaybackStage.playing:
          bg = Colors.green.shade700;
          break;
        case PlaybackStage.failedResolve:
        case PlaybackStage.failedPlayer:
          bg = Colors.red.shade700;
          break;
        case PlaybackStage.buffering:
        case PlaybackStage.settingSource:
          bg = Colors.amber.shade700;
          break;
        case PlaybackStage.resolved:
        case PlaybackStage.sourceReady:
          bg = Colors.blue.shade700;
          break;
        default:
          bg = Colors.grey.shade700;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;
  const _Row(this.label, this.value, {this.isError = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white38, fontSize: 11, fontFamily: 'monospace')),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: isError ? Colors.redAccent : Colors.white,
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: isError ? FontWeight.bold : FontWeight.normal),
                overflow: TextOverflow.fade,
                maxLines: 3),
          ),
        ],
      ),
    );
  }
}
