import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'throttled_http_client.dart';

class ThrottledCacheManager extends CacheManager {
  static const key = 'throttledCache';

  static final ThrottledCacheManager _instance = ThrottledCacheManager._();

  factory ThrottledCacheManager() {
    return _instance;
  }

  ThrottledCacheManager._()
      : super(
          Config(
            key,
            stalePeriod: const Duration(days: 7),
            maxNrOfCacheObjects: 2000, // Limit cache size (increased to 2000)
            repo: JsonCacheInfoRepository(databaseName: key),
            fileService: HttpFileService(
              httpClient: ThrottledHttpClient(), // Use our custom client
            ),
          ),
        );
}
