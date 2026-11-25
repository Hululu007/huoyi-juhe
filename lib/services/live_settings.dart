import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'live_sleep_timer.dart';

/// 直播设置（第 4 包）：只存直播独立的那部分偏好——睡眠定时
/// 默认时长。解码模式不另立直播专用键：设置页的直播分类里
/// 「解码模式」行直接读写全局 PlayerPreferences /
/// DecoderPreferenceCache（直播与点播共用那份，经 NativePlayer
/// 真实消费），见 settings_page 的直播分类。
///
/// 睡眠默认时长只管「进直播时自动起算」这一环：直播页与全屏页
/// initState 调 [applyLiveSleepDefault]，默认 >0 且计时器未激活
/// 时才起算；播放条上的一次性睡眠定时（live_sleep_timer 的
/// 弹层）不写这里、不受默认值变化冲掉，运行时倒计时机制不动。
class LiveSettingsStore extends ChangeNotifier {
  LiveSettingsStore._();

  static final LiveSettingsStore instance = LiveSettingsStore._();

  static const _sleepKey = 'juhe_live_sleep_minutes';

  /// 可选档位（分钟）：0 = 关闭。设置页单选与这里同表。
  static const sleepOptions = <int>[0, 15, 30, 60];

  int _sleepDefaultMinutes = 0;
  bool _loaded = false;

  int get sleepDefaultMinutes => _sleepDefaultMinutes;

  String get sleepDefaultLabel =>
      _sleepDefaultMinutes <= 0 ? '关闭' : '$_sleepDefaultMinutes 分钟';

  @visibleForTesting
  void resetForTest() {
    _sleepDefaultMinutes = 0;
    _loaded = false;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final saved = preferences.getInt(_sleepKey) ?? 0;
      _sleepDefaultMinutes = sleepOptions.contains(saved) ? saved : 0;
    } catch (_) {
      _sleepDefaultMinutes = 0;
    }
    notifyListeners();
  }

  Future<void> setSleepDefaultMinutes(int minutes) async {
    final value = sleepOptions.contains(minutes) ? minutes : 0;
    _loaded = true;
    if (value == _sleepDefaultMinutes) {
      notifyListeners();
      return;
    }
    _sleepDefaultMinutes = value;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_sleepKey, value);
    } catch (_) {
      // 落盘失败不掀设置页：内存值已改，本次运行内生效。
    }
    notifyListeners();
  }

  /// 恢复默认里直播独立的那一半（解码模式的复位在设置页走
  /// DecoderPreferenceCache.set(automatic)，不在这里）。
  Future<void> resetDefaults() => setSleepDefaultMinutes(0);
}

/// 进直播时应用睡眠默认时长：默认 >0 且计时器当前未激活才
/// 起算（已在倒计时的不重置、不叠加；魔蚁同口径）。直播页与
/// 全屏页共用同一个 LiveSleepTimer 单例，切页不会重复起算。
Future<void> applyLiveSleepDefault() async {
  await LiveSettingsStore.instance.load();
  final minutes = LiveSettingsStore.instance.sleepDefaultMinutes;
  if (minutes <= 0) return;
  final timer = LiveSleepTimer.instance;
  if (timer.active) return;
  timer.startMinutes(minutes);
}
