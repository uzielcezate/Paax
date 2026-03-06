import 'playback_engine.dart';

// Platform-conditional import — three branches:
//   dart.library.html  → web (youtube_player_iframe)
//   dart.library.io    → Android + iOS (just_audio — this file)
//   fallback           → stub (tests / desktop / unknown)
import 'playback_engine_stub.dart'
   if (dart.library.html) 'playback_engine_web.dart'
   if (dart.library.io) 'playback_engine_mobile.dart';

/// Returns the correct [PlaybackEngine] for the current platform.
PlaybackEngine getPlaybackEngine() => PlaybackEngineImpl();
