import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 视频侧跳过片头片尾（同步批 A7）。设计学魔蚁 easytv-learn 的
/// IntroOutroSkip（按剧存秒数、判定序、防误跳总闸），按修仙版
/// 播放页（PlayerPage）的起播/完播结构重写：
/// - 片头在算起播位置时直接改写 startMs（原生 create 的初始位置），
///   不另发 seek；续播点已越过片头时绝不回拉。
/// - 片尾靠播放页 1 秒心跳判触发点，命中后 seek 到总时长，复用
///   completedStream 的既有完播流程（落进度、修为、定时、连播）。
/// - 防误跳总闸：片头+片尾超过总时长一半，整段抑制（比例未知时
///   片头先行、片尾等时长已知才判）。
/// 听书侧有自己的 AudioSkipPoints，两边互不相干。
class IntroOutroSkipSettings {
  const IntroOutroSkipSettings({this.introSeconds = 0, this.outroSeconds = 0});

  final int introSeconds;
  final int outroSeconds;

  bool get isEmpty => introSeconds <= 0 && outroSeconds <= 0;

  IntroOutroSkipSettings copyWith({int? introSeconds, int? outroSeconds}) {
    return IntroOutroSkipSettings(
      introSeconds: clampIntroOutroSeconds(introSeconds ?? this.introSeconds),
      outroSeconds: clampIntroOutroSeconds(outroSeconds ?? this.outroSeconds),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intro': introSeconds,
    'outro': outroSeconds,
  };

  factory IntroOutroSkipSettings.fromJson(Object? raw) {
    if (raw is! Map) return const IntroOutroSkipSettings();
    int read(String key) {
      final value = raw[key];
      return clampIntroOutroSeconds(value is num ? value.round() : 0);
    }

    return IntroOutroSkipSettings(
      introSeconds: read('intro'),
      outroSeconds: read('outro'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IntroOutroSkipSettings &&
      other.introSeconds == introSeconds &&
      other.outroSeconds == outroSeconds;

  @override
  int get hashCode => Object.hash(introSeconds, outroSeconds);
}

/// 单项秒数上限（1 小时），与魔蚁口径一致。
const int introOutroMaxSeconds = 3600;

/// 防误跳总闸比例：片头+片尾超过总时长这个比例就整段不跳。
const double introOutroMaxSkipRatio = 0.5;

int clampIntroOutroSeconds(int seconds) =>
    seconds.clamp(0, introOutroMaxSeconds).toInt();

bool _ratioExceeded(IntroOutroSkipSettings settings, int durationMs) {
  if (durationMs <= 0) return false;
  return (settings.introSeconds + settings.outroSeconds) * 1000 >
      durationMs * introOutroMaxSkipRatio;
}

/// 片头判定：返回起播应跳到的毫秒位置，不跳返回 null。
/// 判定序与魔蚁一致：总开关关 → 未设置 → 总闸超限 → 续播已越过
/// 片头（不重复跳、绝不回拉）→ 跳到片头秒数处。
int? introSkipTargetMs({
  required bool enabled,
  required IntroOutroSkipSettings settings,
  required int startMs,
  required int durationMs,
}) {
  if (!enabled) return null;
  if (settings.introSeconds <= 0) return null;
  if (_ratioExceeded(settings, durationMs)) return null;
  final targetMs = settings.introSeconds * 1000;
  if (startMs >= targetMs) return null;
  if (durationMs > 0 && targetMs >= durationMs) return null;
  return targetMs;
}

/// 片尾判定：当前位置是否已到「该跳片尾」的触发点。
/// 总时长未知不跳、没有下一集不跳（末集让它自然播完）。
bool outroSkipDue({
  required bool enabled,
  required IntroOutroSkipSettings settings,
  required int positionMs,
  required int durationMs,
  required bool hasNextEpisode,
}) {
  if (!enabled || !hasNextEpisode) return false;
  if (settings.outroSeconds <= 0) return false;
  if (durationMs <= 0) return false;
  if (_ratioExceeded(settings, durationMs)) return false;
  return positionMs >= durationMs - settings.outroSeconds * 1000;
}

/// 按剧存储：整表一张 JSON（键=剧键，值={intro,outro} 秒），
/// 总开关单独一个 bool 键、默认开。键名与魔蚁同名，方便两边对读。
class IntroOutroSkipStore {
  IntroOutroSkipStore._();

  static const String mapKey = 'introOutroSkipByDrama';
  static const String enabledKey = 'introOutroSkipEnabled';

  static Map<String, IntroOutroSkipSettings> decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, IntroOutroSkipSettings>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, IntroOutroSkipSettings>{};
      return <String, IntroOutroSkipSettings>{
        for (final entry in decoded.entries)
          entry.key.toString(): IntroOutroSkipSettings.fromJson(entry.value),
      }..removeWhere((_, settings) => settings.isEmpty);
    } catch (_) {
      return <String, IntroOutroSkipSettings>{};
    }
  }

  static String encodeMap(Map<String, IntroOutroSkipSettings> map) {
    return jsonEncode(<String, dynamic>{
      for (final entry in map.entries)
        if (!entry.value.isEmpty) entry.key: entry.value.toJson(),
    });
  }

  static Future<bool> loadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(enabledKey) ?? true;
  }

  static Future<void> saveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, enabled);
  }

  /// 设置页总开关的进程内镜像（与 DramaMutePreferences 同款套路）：
  /// 构建开关行时 sync 一次回落盘值，翻转走 [setEnabled] 同步两边。
  static final ValueNotifier<bool> enabledListenable = ValueNotifier<bool>(
    true,
  );

  static Future<void> syncEnabledListenable() async {
    enabledListenable.value = await loadEnabled();
  }

  static Future<void> setEnabled(bool enabled) async {
    enabledListenable.value = enabled;
    await saveEnabled(enabled);
  }

  static Future<IntroOutroSkipSettings> loadFor(String dramaKey) async {
    final prefs = await SharedPreferences.getInstance();
    return decodeMap(prefs.getString(mapKey))[dramaKey] ??
        const IntroOutroSkipSettings();
  }

  /// 存一剧的设置；设为空（两项都 0）即从表里剔除，不留空壳条目。
  static Future<void> saveFor(
    String dramaKey,
    IntroOutroSkipSettings settings,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final map = decodeMap(prefs.getString(mapKey));
    if (settings.isEmpty) {
      map.remove(dramaKey);
    } else {
      map[dramaKey] = settings;
    }
    await prefs.setString(mapKey, encodeMap(map));
  }
}
