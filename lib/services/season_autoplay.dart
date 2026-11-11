import 'package:shared_preferences/shared_preferences.dart';

/// 跨季连播开关：对照 hongguoTV `ViewingPreferences.seasonAutoplay`
///（`kotlin-tv/.../ViewingPreferences.kt:9`）。
///
/// 对照的默认值是 **false（关）**，且跨季还要求自动连播（`autoNext`）
/// 同时开启（`MainActivity.finishSeason` 的门禁）；本地照抄这两条。
///
/// 注意树里目前没有「季」的数据模型（`SeriesDetail` 只有
/// `relatedAlbumId` 相关剧集，没有下一季）：开关与门禁先落位，
/// 下一季的数据源接上之前，门禁里的 [hasNextSeason] 恒为 false，
/// 本季播完仍停在末尾，不会误把「相关剧集」当成下一季播。
class SeasonAutoplayPreference {
  const SeasonAutoplayPreference._();

  static const storageKey = 'player_season_autoplay';

  /// 对照默认值：关。
  static Future<bool> load() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(storageKey) ?? false;
  }

  static Future<void> save(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(storageKey, enabled);
  }
}

/// 跨季连播的放行判据：对照 `MainActivity.finishSeason` 开头的
/// 五道门（在前台、没点过「取消本次跨季」、开了跨季、开了自动连播、
///
/// 没被定时停止拦住、同季），抽成纯函数方便单测。`hasNextSeason`
/// 是下一季数据源的占位——树里没季模型前调用方传 false。
bool shouldContinueToNextSeason({
  required bool seasonAutoplay,
  required bool autoAdvance,
  required bool isLastEpisode,
  required bool sleepStopped,
  required bool hasNextSeason,
}) =>
    seasonAutoplay &&
    autoAdvance &&
    isLastEpisode &&
    !sleepStopped &&
    hasNextSeason;
