import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 站点健康学习（魔蚁同步批 A3，设计学 easytv-learn 的 site_health，
/// 按修仙版结构重写）：按搜索 / 详情 / 播放三类成败给每个站攒一份
/// 聚合记录，算健康分，用于搜索调度排序与选站弹窗的状态点 / 排序。
///
/// 口径与魔蚁落地版一致：
/// - 只存聚合计数、不存逐条日志；打点只改内存，2 秒防抖延迟落盘；
/// - 单类样本 < 3 按中性 0.5 计，总分 = 0.4 搜索 + 0.3 详情 + 0.3 播放；
/// - 记录保留 90 天：加载 / 落盘前整条丢弃过期记录，打点时对超期
///   记录做一次性计数减半（aged）；
/// - 总开关关闭时不打点、不排序，分数恒 0.5，行为与未接入时一致；
/// - 全程吞错：健康学习坏掉绝不影响搜索 / 详情 / 播放本身。

/// 保留期：最近活动距今超过此时长的记录整条丢弃。
const siteHealthRetention = Duration(days: 90);

/// 单类样本不足此数时该类成功率按中性值计。
const siteHealthMinSamples = 3;

/// 信息不足时的中性成功率 / 未知站分数。
const siteHealthNeutralRate = 0.5;

const siteHealthSearchWeight = 0.4;
const siteHealthDetailWeight = 0.3;
const siteHealthPlayWeight = 0.3;

/// 状态点分档阈值：绿 ≥ 0.7（且有过成功）、黄 ≥ 0.4、其余红；
/// 连续失败达到此数直接判红，优先于分数。
const siteHealthGreenThreshold = 0.7;
const siteHealthYellowThreshold = 0.4;
const siteHealthRedStreak = 5;

/// 健康档位（选站弹窗四色状态点）。
enum SiteHealthTier { good, fair, bad, unknown }

/// 一个站的健康聚合记录。字段与落盘短键一一对应（见 [toJson]）。
class SiteHealthRecord {
  SiteHealthRecord();

  int searchOk = 0;
  int searchFail = 0;
  int searchItemsTotal = 0;
  int searchMsTotal = 0;
  int detailOk = 0;
  int detailFail = 0;
  int detailMsTotal = 0;
  int playOk = 0;
  int playFail = 0;
  int lastOkAtMs = 0;
  int lastFailAtMs = 0;
  int consecutiveFails = 0;

  int get totalSamples =>
      searchOk + searchFail + detailOk + detailFail + playOk + playFail;

  int get lastActivityMs =>
      lastOkAtMs > lastFailAtMs ? lastOkAtMs : lastFailAtMs;

  static double _rate(int ok, int fail) {
    final samples = ok + fail;
    if (samples < siteHealthMinSamples) return siteHealthNeutralRate;
    return ok / samples;
  }

  double get searchRate => _rate(searchOk, searchFail);
  double get detailRate => _rate(detailOk, detailFail);
  double get playRate => _rate(playOk, playFail);

  double get score =>
      siteHealthSearchWeight * searchRate +
      siteHealthDetailWeight * detailRate +
      siteHealthPlayWeight * playRate;

  SiteHealthTier get tier {
    if (totalSamples == 0) return SiteHealthTier.unknown;
    if (consecutiveFails >= siteHealthRedStreak) return SiteHealthTier.bad;
    if (score >= siteHealthGreenThreshold && lastOkAtMs > 0) {
      return SiteHealthTier.good;
    }
    if (score >= siteHealthYellowThreshold) return SiteHealthTier.fair;
    return SiteHealthTier.bad;
  }

  /// 打点前的一次性老化：距最近活动已超保留期时把全部计数与累计
  /// 整除减半（时间戳与连续失败不动），随后由新事件刷新时间戳。
  void aged(DateTime now) {
    final last = lastActivityMs;
    if (last == 0) return;
    if (now.millisecondsSinceEpoch - last <=
        siteHealthRetention.inMilliseconds) {
      return;
    }
    searchOk ~/= 2;
    searchFail ~/= 2;
    searchItemsTotal ~/= 2;
    searchMsTotal ~/= 2;
    detailOk ~/= 2;
    detailFail ~/= 2;
    detailMsTotal ~/= 2;
    playOk ~/= 2;
    playFail ~/= 2;
  }

  Map<String, dynamic> toJson() => {
    'so': searchOk,
    'sf': searchFail,
    'si': searchItemsTotal,
    'sm': searchMsTotal,
    'do': detailOk,
    'df': detailFail,
    'dm': detailMsTotal,
    'po': playOk,
    'pf': playFail,
    'lo': lastOkAtMs,
    'lf': lastFailAtMs,
    'cf': consecutiveFails,
  };

  static SiteHealthRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int read(String key) {
      final value = raw[key];
      return value is num ? value.toInt() : 0;
    }

    final record = SiteHealthRecord()
      ..searchOk = read('so')
      ..searchFail = read('sf')
      ..searchItemsTotal = read('si')
      ..searchMsTotal = read('sm')
      ..detailOk = read('do')
      ..detailFail = read('df')
      ..detailMsTotal = read('dm')
      ..playOk = read('po')
      ..playFail = read('pf')
      ..lastOkAtMs = read('lo')
      ..lastFailAtMs = read('lf')
      ..consecutiveFails = read('cf');
    return record;
  }
}

/// 丢弃过期记录：最近活动距今超保留期的整条删；从无活动的保留。
Map<String, SiteHealthRecord> pruneExpiredSiteHealth(
  Map<String, SiteHealthRecord> records,
  DateTime now,
) {
  final cutoff = now.millisecondsSinceEpoch - siteHealthRetention.inMilliseconds;
  return {
    for (final entry in records.entries)
      if (entry.value.lastActivityMs == 0 ||
          entry.value.lastActivityMs >= cutoff)
        entry.key: entry.value,
  };
}

/// 稳定健康排序：分数降序、同分保原序。装饰-排序-还原实现，
/// 不依赖 List.sort 的稳定性。
List<T> stableHealthSort<T>(List<T> items, double Function(T item) scoreOf) {
  final decorated = [
    for (var i = 0; i < items.length; i++)
      (index: i, score: scoreOf(items[i]), item: items[i]),
  ];
  decorated.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });
  return [for (final entry in decorated) entry.item];
}

/// 健康偏好（设置页三项）：总开关（默认开）、选站弹窗按健康排序
/// （默认关）。ValueNotifier 供设置页开关直接监听，与
/// DramaMutePreferences 同款形态。
class SiteHealthPrefs {
  SiteHealthPrefs._();

  static final SiteHealthPrefs instance = SiteHealthPrefs._();

  static const _enabledKey = 'site_health_enabled';
  static const _pickerSortKey = 'site_picker_health_sort';

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);
  final ValueNotifier<bool> pickerSort = ValueNotifier<bool>(false);
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      enabled.value = preferences.getBool(_enabledKey) ?? true;
      pickerSort.value = preferences.getBool(_pickerSortKey) ?? false;
    } catch (_) {
      // 读不到就用默认值，不阻塞任何调用方。
    }
    SiteHealthStore.instance.enabled = enabled.value;
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    SiteHealthStore.instance.enabled = value;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_enabledKey, value);
    } catch (_) {
      // 落盘失败不回滚内存值，下次启动按盘上值走。
    }
  }

  Future<void> setPickerSort(bool value) async {
    pickerSort.value = value;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_pickerSortKey, value);
    } catch (_) {
      // 同上。
    }
  }

  @visibleForTesting
  void resetForTest() {
    _loaded = false;
    enabled.value = true;
    pickerSort.value = false;
  }
}

/// 健康记录的内存表 + 落盘门面。全局单例，测试可整体替换状态。
class SiteHealthStore {
  SiteHealthStore._();

  static final SiteHealthStore instance = SiteHealthStore._();

  static const _storageKey = 'site_health_v1';
  static const saveDelay = Duration(seconds: 2);

  final Map<String, SiteHealthRecord> _records = {};

  /// 总开关：关时打点短路、分数恒中性。由 [SiteHealthPrefs] 同步。
  bool enabled = true;

  /// 记录表变化计数（载入 / 打点 / 清空都 +1），选站弹窗监听它
  /// 重画状态点，不必轮询。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _loaded = false;
  bool _loading = false;
  bool _dirty = false;
  Timer? _saveTimer;

  /// 测试注入的时钟；为空用真实时间。
  DateTime Function()? clockForTest;

  DateTime _now() => clockForTest?.call() ?? DateTime.now();

  bool get isLoaded => _loaded;

  void _kickLoad() {
    if (_loaded || _loading) return;
    _loading = true;
    unawaited(
      load().whenComplete(() {
        _loading = false;
      }),
    );
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['sites'] is Map) {
          final sites = decoded['sites'] as Map;
          final parsed = <String, SiteHealthRecord>{};
          for (final entry in sites.entries) {
            final record = SiteHealthRecord.fromJson(entry.value);
            if (record != null && entry.key is String) {
              parsed[entry.key as String] = record;
            }
          }
          _records
            ..clear()
            ..addAll(pruneExpiredSiteHealth(parsed, _now()));
        }
      }
    } catch (_) {
      // 坏 JSON / 结构不对 → 整表当空，不抛错。
      _records.clear();
    }
    _loaded = true;
    revision.value++;
  }

  String encode() {
    final pruned = pruneExpiredSiteHealth(_records, _now());
    return jsonEncode({
      'v': 1,
      'sites': {for (final entry in pruned.entries) entry.key: entry.value.toJson()},
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty && _loaded) return;
    _dirty = false;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_storageKey, encode());
    } catch (_) {
      // 落盘失败只丢本次，内存照常可用。
    }
  }

  void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () => unawaited(flush()));
  }

  Future<void> clear() async {
    _records.clear();
    revision.value++;
    _dirty = true;
    await flush();
  }

  SiteHealthRecord? recordOf(String siteId) {
    _kickLoad();
    return _records[siteId];
  }

  double scoreOf(String siteId) {
    if (!enabled) return siteHealthNeutralRate;
    return _records[siteId]?.score ?? siteHealthNeutralRate;
  }

  SiteHealthTier? tierOf(String siteId) {
    final record = _records[siteId];
    if (record == null) return null;
    return record.tier;
  }

  /// 按健康分重排站 id（搜索调度用）：总开关关时原样返回副本。
  List<String> orderIds(List<String> ids) {
    if (!enabled) return List.of(ids);
    return stableHealthSort(ids, scoreOf);
  }

  SiteHealthRecord _touch(String siteId) {
    final now = _now();
    final record = _records.putIfAbsent(siteId, SiteHealthRecord.new);
    record.aged(now);
    return record;
  }

  void _afterEvent(SiteHealthRecord record, bool ok) {
    final nowMs = _now().millisecondsSinceEpoch;
    if (ok) {
      record.lastOkAtMs = nowMs;
      record.consecutiveFails = 0;
    } else {
      record.lastFailAtMs = nowMs;
      record.consecutiveFails++;
    }
    revision.value++;
    _scheduleSave();
  }

  /// 搜索打点：成功且有结果才记（本站搜索未实现的客户端默认回空，
  /// 记成功会把没搜索能力的站教成健康站；回空记中性不打点）。
  /// 抛错由调用方（记录客户端）在 catch 里记失败。
  void recordSearch(
    String siteId, {
    required bool ok,
    int items = 0,
    int elapsedMs = 0,
  }) {
    if (!enabled || siteId.isEmpty) return;
    _kickLoad();
    if (!_loaded) return;
    if (ok && items <= 0) return;
    final record = _touch(siteId);
    if (ok) {
      record.searchOk++;
      record.searchItemsTotal += items;
      record.searchMsTotal += elapsedMs;
    } else {
      record.searchFail++;
    }
    _afterEvent(record, ok);
  }

  void recordDetail(String siteId, {required bool ok, int elapsedMs = 0}) {
    if (!enabled || siteId.isEmpty) return;
    _kickLoad();
    if (!_loaded) return;
    final record = _touch(siteId);
    if (ok) {
      record.detailOk++;
      record.detailMsTotal += elapsedMs;
    } else {
      record.detailFail++;
    }
    _afterEvent(record, ok);
  }

  /// 播放打点：只记取流（playSource）成败，不记起播后的卡顿。
  void recordPlay(String siteId, {required bool ok}) {
    if (!enabled || siteId.isEmpty) return;
    _kickLoad();
    if (!_loaded) return;
    final record = _touch(siteId);
    if (ok) {
      record.playOk++;
    } else {
      record.playFail++;
    }
    _afterEvent(record, ok);
  }

  @visibleForTesting
  void resetForTest() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _records.clear();
    _loaded = false;
    _loading = false;
    _dirty = false;
    enabled = true;
    clockForTest = null;
    revision.value = 0;
  }

  @visibleForTesting
  void markLoadedForTest() {
    _loaded = true;
  }
}
