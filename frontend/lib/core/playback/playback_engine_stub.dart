import 'package:flutter/material.dart';
import 'playback_engine.dart';

class PlaybackEngineImpl implements PlaybackEngine {
  @override
  Stream<Duration> get positionStream => throw UnimplementedError();

  @override
  Stream<Duration> get durationStream => throw UnimplementedError();
  
  @override
  Stream<bool> get playingStream => throw UnimplementedError();

  @override
  Stream<void> get completionStream => throw UnimplementedError();

  @override
  Future<void> initialize() async {
    throw UnimplementedError();
  }

  @override
  Future<void> load(String videoId) async {
    throw UnimplementedError();
  }

  @override
  Future<void> pause() async {
    throw UnimplementedError();
  }

  @override
  Future<void> play() async {
    throw UnimplementedError();
  }

  @override
  Future<void> seek(Duration position) async {
    throw UnimplementedError();
  }
  
  @override
  void dispose() {}
  
  @override
  Widget buildPlayerView(BuildContext context) {
    throw UnimplementedError();
  }
}
