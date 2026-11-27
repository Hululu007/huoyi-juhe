/// 播放器内嵌菜单（照录屏改造批）新增的偏好：屏显、底部常驻进度
/// 展示、长按倍速倍率、播放顺序、字幕样式。
///
/// 统一口径：每项一个进程内 [ValueNotifier] + SharedPreferences 落盘；
/// 播放页/控制层进页时 [loadAll] 读一次，菜单里改动走 `set*` 立即
/// 更新 notifier 并落盘，消费方监听 notifier 即时生效，不必重进页面。
/// 读盘失败一律回默认值，不能挡播放。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'player_preferences.dart';

/// 屏显设置（SPEC M10）：时间/网速/进度/标题四个开关 + 字号步进。
class PlayerOsdSettings {
  const PlayerOsdSettings({
    this.showTime = true,
    this.showSpeed = true,
    this.showResolution = true,
    this.showTitle = true,
    this.fontSize = 12,
  });

  final bool showTime;
  final bool showSpeed;
  final bool showResolution;
  final bool showTitle;

  /// 屏显文字字号（步进器，8..20，默认 12，对照录屏「−｜12｜+」）。
  final int fontSize;

  PlayerOsdSettings copyWith({
    bool? showTime,
    bool? showSpeed,
    bool? showResolution,
    bool? showTitle,
    int? fontSize,
  }) => PlayerOsdSettings(
    showTime: showTime ?? this.showTime,
    showSpeed: showSpeed ?? this.showSpeed,
    showResolution: showResolution ?? this.showResolution,
    showTitle: showTitle ?? this.showTitle,
    fontSize: (fontSize ?? this.fontSize).clamp(8, 20),
  );

  @override
  bool operator ==(Object other) =>
      other is PlayerOsdSettings &&
      other.showTime == showTime &&
      other.showSpeed == showSpeed &&
      other.showResolution == showResolution &&
      other.showTitle == showTitle &&
      other.fontSize == fontSize;

  @override
  int get hashCode =>
      Object.hash(showTime, showSpeed, showResolution, showTitle, fontSize);
}

/// 底部常驻进度细条的展示方式（SPEC M11）。
enum PersistentProgressMode {
  /// 始终展示：连控制层在屏时也留着（与带圆点的进度条同屏）。
  always('始终展示'),

  /// 自动：控制层 seek 栏在屏时藏起来（改造前的现行行为）。
  auto('自动'),

  /// 不展示：常驻细条永不出现（seek 栏本身不受影响）。
  never('不展示');

  const PersistentProgressMode(this.label);

  final String label;
}

/// 播放顺序（SPEC M5）。
enum PlayOrderMode {
  /// 播完自动进下一集（现行「自动连播」开）。
  autoNext('自动连播'),

  /// 本集循环重播。
  singleLoop('单集循环'),

  /// 播完停在本集末尾（现行「自动连播」关）。
  stopAtEnd('播完暂停');

  const PlayOrderMode(this.label);

  final String label;
}

/// 字幕样式（SPEC M18）：宿主把字幕文本推给 Flutter 侧渲染
/// （见 NativePlayer.cuesStream），样式在这里定。
class SubtitleStyleSettings {
  const SubtitleStyleSettings({
    this.fontScale = 1,
    this.colorIndex = 0,
    this.positionTop = false,
    this.stroke = true,
  });

  /// 字号倍率（0.5..2，基准 16sp）。
  final double fontScale;

  /// 文字颜色档：0 白 / 1 黄 / 2 黑（黑字自动配白描边）。
  final int colorIndex;

  /// true = 显示在画面上方（顶栏下），false = 下方（底栏上）。
  final bool positionTop;

  /// 描边（亮画面上保可读性）。
  final bool stroke;

  static const colorLabels = ['白色', '黄色', '黑色'];

  SubtitleStyleSettings copyWith({
    double? fontScale,
    int? colorIndex,
    bool? positionTop,
    bool? stroke,
  }) => SubtitleStyleSettings(
    fontScale: (fontScale ?? this.fontScale).clamp(0.5, 2),
    colorIndex: (colorIndex ?? this.colorIndex).clamp(0, 2),
    positionTop: positionTop ?? this.positionTop,
    stroke: stroke ?? this.stroke,
  );

  @override
  bool operator ==(Object other) =>
      other is SubtitleStyleSettings &&
      other.fontScale == fontScale &&
      other.colorIndex == colorIndex &&
      other.positionTop == positionTop &&
      other.stroke == stroke;

  @override
  int get hashCode => Object.hash(fontScale, colorIndex, positionTop, stroke);
}

class PlayerMenuPreferences {
  PlayerMenuPreferences._();

  static const _osdShowTimeKey = 'player_osd_show_time';
  static const _osdShowSpeedKey = 'player_osd_show_speed';
  static const _osdShowResolutionKey = 'player_osd_show_resolution';
  static const _osdShowTitleKey = 'player_osd_show_title';
  static const _osdFontSizeKey = 'player_osd_font_size';
  static const _progressModeKey = 'player_persistent_progress_mode';
  static const _boostRateKey = 'player_long_press_boost_rate';
  static const _playOrderKey = 'player_play_order';
  static const _subtitleFontScaleKey = 'player_subtitle_font_scale';
  static const _subtitleColorKey = 'player_subtitle_color';
  static const _subtitlePositionTopKey = 'player_subtitle_position_top';
  static const _subtitleStrokeKey = 'player_subtitle_stroke';

  /// 长按倍速可选倍率（SPEC M9 参考默认 3.0x）。
  static const boostRates = <double>[1.5, 2, 2.5, 3];

  static final ValueNotifier<PlayerOsdSettings> osd =
      ValueNotifier<PlayerOsdSettings>(const PlayerOsdSettings());
  static final ValueNotifier<PersistentProgressMode> progressMode =
      ValueNotifier<PersistentProgressMode>(PersistentProgressMode.auto);
  static final ValueNotifier<double> boostRate = ValueNotifier<double>(3);
  static final ValueNotifier<PlayOrderMode> playOrder =
      ValueNotifier<PlayOrderMode>(PlayOrderMode.autoNext);
  static final ValueNotifier<SubtitleStyleSettings> subtitleStyle =
      ValueNotifier<SubtitleStyleSettings>(const SubtitleStyleSettings());

  static bool _loaded = false;

  static Future<void> loadAll() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      osd.value = PlayerOsdSettings(
        showTime: prefs.getBool(_osdShowTimeKey) ?? true,
        showSpeed: prefs.getBool(_osdShowSpeedKey) ?? true,
        showResolution: prefs.getBool(_osdShowResolutionKey) ?? true,
        showTitle: prefs.getBool(_osdShowTitleKey) ?? true,
        fontSize: (prefs.getInt(_osdFontSizeKey) ?? 12).clamp(8, 20),
      );
      progressMode.value = PersistentProgressMode.values.firstWhere(
        (mode) => mode.name == prefs.getString(_progressModeKey),
        orElse: () => PersistentProgressMode.auto,
      );
      final savedBoost = prefs.getDouble(_boostRateKey);
      boostRate.value = savedBoost != null && boostRates.contains(savedBoost)
          ? savedBoost
          : 3;
      final savedOrder = prefs.getString(_playOrderKey);
      if (savedOrder != null) {
        playOrder.value = PlayOrderMode.values.firstWhere(
          (mode) => mode.name == savedOrder,
          orElse: () => PlayOrderMode.autoNext,
        );
      } else {
        // 迁移：旧「自动连播」开关（设置页原行）决定初始播放顺序，
        // 开 = 自动连播、关 = 播完暂停；读不到按开。
        final autoAdvance = await PlayerPreferences.loadAutoAdvance()
            .catchError((Object _) => true);
        playOrder.value = autoAdvance
            ? PlayOrderMode.autoNext
            : PlayOrderMode.stopAtEnd;
      }
      subtitleStyle.value = SubtitleStyleSettings(
        fontScale: (prefs.getDouble(_subtitleFontScaleKey) ?? 1).clamp(0.5, 2),
        colorIndex: (prefs.getInt(_subtitleColorKey) ?? 0).clamp(0, 2),
        positionTop: prefs.getBool(_subtitlePositionTopKey) ?? false,
        stroke: prefs.getBool(_subtitleStrokeKey) ?? true,
      );
    } catch (_) {
      // 读盘失败保持默认值。
    }
  }

  /// 仅测试用：复位进程内状态，让下一次 [loadAll] 重新读盘。
  @visibleForTesting
  static void resetForTest() {
    _loaded = false;
    osd.value = const PlayerOsdSettings();
    progressMode.value = PersistentProgressMode.auto;
    boostRate.value = 3;
    playOrder.value = PlayOrderMode.autoNext;
    subtitleStyle.value = const SubtitleStyleSettings();
  }

  static Future<void> setOsd(PlayerOsdSettings value) async {
    osd.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_osdShowTimeKey, value.showTime);
      await prefs.setBool(_osdShowSpeedKey, value.showSpeed);
      await prefs.setBool(_osdShowResolutionKey, value.showResolution);
      await prefs.setBool(_osdShowTitleKey, value.showTitle);
      await prefs.setInt(_osdFontSizeKey, value.fontSize);
    } catch (_) {
      // 落盘失败不掀菜单：内存值已改，本次运行内生效。
    }
  }

  static Future<void> setProgressMode(PersistentProgressMode value) async {
    progressMode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_progressModeKey, value.name);
    } catch (_) {}
  }

  static Future<void> setBoostRate(double value) async {
    boostRate.value = boostRates.contains(value) ? value : 3;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_boostRateKey, boostRate.value);
    } catch (_) {}
  }

  static Future<void> setPlayOrder(PlayOrderMode value) async {
    playOrder.value = value;
    // 与旧「自动连播」键保持同写：回退阶梯/跨季门禁等仍读旧键的地方
    // 不会和新口径打架（自动连播 = 顺序为 autoNext）。
    _syncLegacyAutoAdvance(value == PlayOrderMode.autoNext);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_playOrderKey, value.name);
    } catch (_) {}
  }

  static Future<void> setSubtitleStyle(SubtitleStyleSettings value) async {
    subtitleStyle.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_subtitleFontScaleKey, value.fontScale);
      await prefs.setInt(_subtitleColorKey, value.colorIndex);
      await prefs.setBool(_subtitlePositionTopKey, value.positionTop);
      await prefs.setBool(_subtitleStrokeKey, value.stroke);
    } catch (_) {}
  }
}

/// 旧自动连播键的同写（失败静默：新键已落盘，旧键只是兼容镜像）。
void _syncLegacyAutoAdvance(bool enabled) {
  PlayerPreferences.saveAutoAdvance(enabled).catchError((Object _) {});
}
