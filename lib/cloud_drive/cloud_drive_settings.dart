/// 网盘轻量设置（修仙版）：存网盘侧要读的布尔——是否显示
/// 疑似广告视频、详情页自动离线开关。用 SharedPreferences，
/// 键名自洽，不挂魔蚁的 LocalStore。
///
/// 同步读口径：引擎构造时要的是 `bool Function()`，所以这里在
/// [load] 时把值读进内存缓存，之后同步读缓存；设置页改值时
/// 先落盘再更新缓存，引擎下一次取目录就按新值过滤。
library;

import 'package:shared_preferences/shared_preferences.dart';

class CloudDriveSettings {
  CloudDriveSettings._(this._prefs);

  static const showSuspectedAdVideosKey =
      'cloud_drive_show_suspected_ad_videos';

  /// 详情页自动离线开关（演员库详情页打开拿到下载链接后
  /// 自动提交 115 离线）：默认开，网盘页 115 区可关。
  static const actressAutoOfflineKey = 'cloud_drive_actress_auto_offline';

  final SharedPreferences _prefs;

  bool _showSuspectedAdVideos = false;
  bool _actressAutoOffline = true;

  /// 已加载的单例（引擎工厂与设置界面共用同一份缓存）。
  static CloudDriveSettings? _instance;
  static Future<CloudDriveSettings>? _loading;

  static Future<CloudDriveSettings> load() {
    final existing = _instance;
    if (existing != null) return Future.value(existing);
    return _loading ??= () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = CloudDriveSettings._(prefs);
      settings._showSuspectedAdVideos =
          prefs.getBool(showSuspectedAdVideosKey) ?? false;
      settings._actressAutoOffline =
          prefs.getBool(actressAutoOfflineKey) ?? true;
      _instance = settings;
      return settings;
    }();
  }

  /// 同步读（引擎的 `showSuspectedAds` 回调）：未加载完时按缺省
  /// false（隐藏疑似广告，与魔蚁缺省一致）。
  static bool get showSuspectedAdVideosNow =>
      _instance?._showSuspectedAdVideos ?? false;

  bool get showSuspectedAdVideos => _showSuspectedAdVideos;

  Future<void> setShowSuspectedAdVideos(bool value) async {
    _showSuspectedAdVideos = value;
    await _prefs.setBool(showSuspectedAdVideosKey, value);
  }

  bool get actressAutoOffline => _actressAutoOffline;

  Future<void> setActressAutoOffline(bool value) async {
    _actressAutoOffline = value;
    await _prefs.setBool(actressAutoOfflineKey, value);
  }
}
