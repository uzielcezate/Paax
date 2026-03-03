import 'playback_engine.dart';
import 'playback_engine_stub.dart'
   if (dart.library.html) 'playback_engine_web.dart'
   if (dart.library.io) 'playback_engine_mobile.dart';

PlaybackEngine getPlaybackEngine() => PlaybackEngineImpl();
