// test/unit/playback_transaction_test.dart
//
// Phase 3.3.1 §4 — the play transaction must never present a track as playing
// until a non-empty videoId is accepted by the iframe (buffering/playing/cued).
// An empty/invalid id or a load failure must keep/restore the previously
// confirmed track and surface the safe error — never leave new metadata over
// the prior (still-playing) audio. Races are guarded by a generation token.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:beaty/domain/entities/track.dart';
import 'package:beaty/core/playback/playback_engine.dart';
import 'package:beaty/presentation/state/playback_controller.dart';

Track _track(String id, {String title = 't'}) => Track(
      id: id,
      title: title,
      artistName: 'a',
      albumId: 'al',
      albumTitle: 'alt',
      artworkUrl: '',
      duration: 100,
    );

/// Fake engine that records loads and lets the test drive state/error events.
class FakeEngine implements PlaybackEngine {
  final _state = StreamController<int>.broadcast();
  final _error = StreamController<int>.broadcast();
  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _completion = StreamController<void>.broadcast();

  final List<String> loads = [];
  bool throwOnLoad = false;

  void emitState(int s) => _state.add(s);
  void emitError(int e) => _error.add(e);
  void emitPlaying(bool p) => _playing.add(p);
  void emitPosition(Duration d) => _pos.add(d);
  void emitDuration(Duration d) => _dur.add(d);
  // Simulate a normal successful start: unstarted → buffering → playing.
  void emitStarted() {
    _state.add(-1);
    _state.add(3);
    _state.add(1);
  }

  @override
  Stream<int> get playerStateStream => _state.stream;
  @override
  Stream<int> get errorStream => _error.stream;
  @override
  Stream<Duration> get positionStream => _pos.stream;
  @override
  Stream<Duration> get durationStream => _dur.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<void> get completionStream => _completion.stream;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> load(String videoId) async {
    if (throwOnLoad) throw Exception('load failed');
    loads.add(videoId);
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  void prefetchNext(String videoId) {}
  @override
  void dispose() {}
  @override
  Widget buildPlayerView(BuildContext context) => const SizedBox();
}

Future<PlaybackController> _make(FakeEngine engine) async {
  final c = PlaybackController(engine: engine);
  await c.initialized;
  return c;
}

/// Yield so `_playCurrent` progresses past `await load()` and attaches its
/// state/error listener before the test emits into the broadcast streams.
Future<void> _pump() => Future.delayed(Duration.zero);

void main() {
  test('valid track: confirmed only after iframe accepts (buffering)', () async {
    final e = FakeEngine();
    final c = await _make(e);

    final fut = c.playQueue([_track('vid1')]);
    await _pump();
    expect(c.isLoadingTrack, isTrue); // not yet confirmed
    e.emitState(3); // buffering the new video
    await fut;

    expect(e.loads, ['vid1']);
    expect(c.currentTrack?.id, 'vid1');
    expect(c.isLoadingTrack, isFalse);
    expect(c.errorMessage, isNull);
  });

  test('empty videoId: never loads, previous confirmed track preserved', () async {
    final e = FakeEngine();
    final c = await _make(e);

    // Confirm A first.
    final a = c.playQueue([_track('vidA', title: 'A')]);
    await _pump();
    e.emitState(3);
    await a;
    expect(c.currentTrack?.id, 'vidA');

    // Tap B with an empty id (the JACKBOYS "CHAMPAIN & VAC…" case).
    await c.playQueue([_track('', title: 'B')]);

    expect(e.loads, ['vidA']); // B never issued a load
    expect(c.currentTrack?.id, 'vidA'); // restored to the still-playing track
    expect(c.currentTrack?.title, 'A');
    // A was confirmed (load autoplays) → restored as PLAYING, not paused (H1).
    expect(c.isPlaying, isTrue);
    expect(c.errorMessage, 'Unable to play this track');
  });

  test('iframe error: not committed as playing, error surfaced', () async {
    final e = FakeEngine();
    final c = await _make(e);

    final fut = c.playQueue([_track('vidA', title: 'A')]);
    await _pump();
    e.emitState(3);
    await fut;

    final bad = c.playQueue([_track('bad', title: 'B')]);
    await _pump();
    e.emitError(150); // video unavailable
    await bad;

    expect(c.currentTrack?.id, 'vidA'); // restored
    expect(c.errorMessage, 'Unable to play this track');
  });

  test('load throwing is handled as failure', () async {
    final e = FakeEngine()..throwOnLoad = true;
    final c = await _make(e);
    await c.playQueue([_track('vid1')]);
    expect(c.errorMessage, 'Unable to play this track');
    expect(c.isPlaying, isFalse);
  });

  test('error before any valid start → failure', () async {
    final e = FakeEngine();
    final c = await _make(e);
    final fut = c.playQueue([_track('vid1')]);
    await _pump();
    e.emitError(2);
    await fut;
    expect(c.errorMessage, 'Unable to play this track');
  });

  test('rapid A→B: only B is confirmed; stale A callback ignored', () async {
    final e = FakeEngine();
    final c = await _make(e);

    // Start A but do NOT confirm yet.
    final aFut = c.playQueue([_track('vidA', title: 'A')]);
    // Start B (supersedes A).
    final bFut = c.playQueue([_track('vidB', title: 'B')]);
    await _pump();
    // A single buffering event: A's listener sees gen mismatch → false;
    // B's listener confirms.
    e.emitState(3);
    await Future.wait([aFut, bFut]);

    expect(c.currentTrack?.id, 'vidB');
    expect(c.currentTrack?.title, 'B');
    expect(c.errorMessage, isNull);
  });

  test('retry after failure succeeds', () async {
    final e = FakeEngine();
    final c = await _make(e);

    await c.playQueue([_track('', title: 'B')]);
    expect(c.errorMessage, 'Unable to play this track');

    // Retry with a valid id.
    final good = c.playQueue([_track('vidB', title: 'B')]);
    await _pump();
    e.emitState(3);
    await good;
    expect(c.currentTrack?.id, 'vidB');
    expect(c.errorMessage, isNull);
  });

  // ── Phase 3.3.2 issue 1: full confirmed-state restore after a failed track ──

  // Confirm A and mark it actively playing.
  Future<PlaybackController> _playing(FakeEngine e, Track a) async {
    final c = await _make(e);
    final fut = c.playQueue([a]);
    await _pump();
    e.emitState(3); // buffering → confirm
    await fut;
    e.emitPlaying(true); // engine reports playing (not gated post-confirm)
    await _pump();
    return c;
  }

  test('A playing → invalid (empty-id) B → A stays the confirmed PLAYING track', () async {
    final e = FakeEngine();
    final c = await _playing(e, _track('vidA', title: 'A'));
    expect(c.isPlaying, isTrue);
    expect(c.currentTrack?.id, 'vidA');

    // Tap invalid B (JACKBOYS "CHAMPAIN & VAC…" — empty videoId).
    await c.playQueue([_track('', title: 'B')]);

    // Full state restored: identity AND play state — not just the track.
    expect(c.currentTrack?.id, 'vidA');
    expect(c.isPlaying, isTrue); // the reported bug: was showing Play/paused
    expect(c.errorMessage, 'Unable to play this track');
    expect(e.loads, ['vidA']); // B never loaded; A untouched (still playing)
  });

  test('A paused → invalid B → A stays paused', () async {
    final e = FakeEngine();
    final c = await _playing(e, _track('vidA', title: 'A'));
    e.emitPlaying(false); // user paused A
    await _pump();
    expect(c.isPlaying, isFalse);

    await c.playQueue([_track('', title: 'B')]);
    expect(c.currentTrack?.id, 'vidA');
    expect(c.isPlaying, isFalse); // remains paused
    expect(c.errorMessage, 'Unable to play this track');
  });

  test('stale playing(false) from the failed transaction is ignored during load',
      () async {
    final e = FakeEngine();
    final c = await _playing(e, _track('vidA', title: 'A'));

    // Start B (non-empty) — enters loading; a stale paused/false from the
    // loading video must NOT flip the confirmed state while loading.
    final bFut = c.playQueue([_track('vidB', title: 'B')]);
    await _pump();
    e.emitPlaying(false); // gated by _isLoadingTrack → ignored
    await _pump();
    e.emitError(150); // B fails
    await bFut;

    // A restored as the confirmed track; re-cue issued (engine reloaded A).
    expect(c.currentTrack?.id, 'vidA');
    expect(c.errorMessage, 'Unable to play this track');
    expect(e.loads.contains('vidB'), isTrue);
    expect(e.loads.last, 'vidA'); // re-cued the confirmed track
  });

  test('valid C after a failed B plays normally', () async {
    final e = FakeEngine();
    final c = await _playing(e, _track('vidA', title: 'A'));
    await c.playQueue([_track('', title: 'B')]); // fail
    expect(c.currentTrack?.id, 'vidA');

    final cc = c.playQueue([_track('vidC', title: 'C')]);
    await _pump();
    e.emitState(3);
    await cc;
    expect(c.currentTrack?.id, 'vidC');
    expect(c.errorMessage, isNull);
  });

  test('rapid A → slow B → C-fail restores A at its CONFIRMED playing state (H1)',
      () async {
    // Regression for the review H1: the rollback snapshot must come from the
    // confirmed store, not the live fields that an in-flight B already zeroed.
    final e = FakeEngine();
    final c = await _playing(e, _track('vidA', title: 'A'));
    expect(c.isPlaying, isTrue);

    // B starts loading (zeroes live isPlaying/position) but never confirms…
    final bFut = c.playQueue([_track('vidB', title: 'B')]);
    await _pump();
    // …then C supersedes B and fails.
    final cFut = c.playQueue([_track('vidC', title: 'C')]);
    await _pump();
    e.emitError(150);
    await Future.wait([bFut, cFut]);

    // A restored as the confirmed PLAYING track (not paused at 0:00).
    expect(c.currentTrack?.id, 'vidA');
    expect(c.isPlaying, isTrue);
    expect(c.errorMessage, 'Unable to play this track');
    expect(e.loads.last, 'vidA'); // re-cued
  });

  test('auto-advance skips an unplayable (empty-id) track mid-queue', () async {
    final e = FakeEngine();
    final c = await _make(e);

    // Queue A(ok), B(empty id), C(ok); confirm A.
    final a = c.playQueue([
      _track('vidA', title: 'A'),
      _track('', title: 'B'),
      _track('vidC', title: 'C'),
    ]);
    await _pump();
    e.emitState(3);
    await a;
    expect(c.currentTrack?.id, 'vidA');

    // Next should skip B and confirm C — not stall on the empty track.
    final next = c.playNext();
    await _pump();
    e.emitState(3);
    await next;
    expect(c.currentTrack?.id, 'vidC');
    expect(c.currentTrack?.title, 'C');
    expect(c.errorMessage, isNull);
  });

  test('stale "playing" from prior video does not confirm during load', () async {
    final e = FakeEngine();
    final c = await _make(e);
    final fut = c.playQueue([_track('vid1')]);
    await _pump();
    // A stray "playing" with no fresh load-begin must be ignored...
    e.emitState(1);
    await _pump();
    expect(c.isLoadingTrack, isTrue); // still loading, not confirmed
    // ...then a real load-begin + buffering confirms.
    e.emitState(-1);
    e.emitState(3);
    await fut;
    expect(c.currentTrack?.id, 'vid1');
    expect(c.errorMessage, isNull);
  });
}
