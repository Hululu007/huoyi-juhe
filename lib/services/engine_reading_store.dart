import 'package:shared_preferences/shared_preferences.dart';

class EngineReadingStore {
  EngineReadingStore._();

  static final EngineReadingStore instance = EngineReadingStore._();

  static String keyFor(String siteId, String seriesId) =>
      'engine_last_chapter:$siteId:$seriesId';

  Future<int> lastIndex(String siteId, String seriesId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyFor(siteId, seriesId)) ?? 0;
  }

  Future<void> saveIndex(
    String siteId,
    String seriesId,
    int index,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyFor(siteId, seriesId), index);
  }
}
