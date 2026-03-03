class ApiConstants {
  static const String baseUrl = 'https://api.deezer.com';
  
  static const String chart = '/chart';
  static const String search = '/search';
  static const String searchAlbum = '/search/album';
  static const String searchArtist = '/search/artist';
  
  static String track(int id) => '/track/$id';
  static String album(int id) => '/album/$id';
  static String artist(int id) => '/artist/$id';
  static String artistTop(int id) => '/artist/$id/top';
}
