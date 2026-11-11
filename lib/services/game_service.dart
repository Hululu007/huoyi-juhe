import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cultivation.dart';
import 'game_data.dart';

/// 一次离线结算（切走 / 切后台 / 关掉重开后回来按离开时长算）。
class OfflineReward {
  /// 离开时长（秒，已按 [gameOfflineCapHours] 封顶）。
  final int seconds;

  /// 结算修为。
  final int xp;

  /// 结算元宝。
  final int yuanbao;

  const OfflineReward({
    required this.seconds,
    required this.xp,
    required this.yuanbao,
  });
}

/// 一次合成的结果：3 件同品质同部位合成 1 件高一档。
class EquipSynthesizeResult {
  /// 被消耗的装备 id -> 件数（3 件）。
  final Map<String, int> consumed;

  /// 合成出的装备 id（高一档，同部位）。
  final String resultId;

  const EquipSynthesizeResult({
    required this.consumed,
    required this.resultId,
  });
}

/// 一次击杀结算。
class KillResult {
  /// 本次修为。
  final int xp;

  /// 本次元宝。
  final int yuanbao;

  /// 掉落装备 id（没掉为空）。
  final String? droppedEquipId;

  const KillResult({
    required this.xp,
    required this.yuanbao,
    this.droppedEquipId,
  });
}

/// 成人站进站 / 看片扣费结果。
/// 进站现在免费：游戏节点与影视区进站都不扣，[tryEnterAdultSite]
/// 永远返回 free（cost 0）；只有看片费（进详情页扣 20 元宝，
/// [tryChargeAdultFilm]）还会返回 paid / alreadyPaid / insufficient。
enum AdultEntryStatus {
  /// 不扣（进站免费，或不是成人站）。
  free,

  /// 本次扣了看片费，放行。
  paid,

  /// 本启动内已扣过看片费，放行、不重复扣。
  alreadyPaid,

  /// 元宝不够扣看片费，拦住、不扣。
  insufficient,
}

/// 一次成人站进站扣费的判定结果。
class AdultSiteEntryOutcome {
  const AdultSiteEntryOutcome({
    required this.status,
    required this.coreId,
    required this.label,
    required this.tier,
    required this.cost,
    required this.balance,
  });

  final AdultEntryStatus status;

  /// 站点核心 id（归一化后的裸 id）。
  final String coreId;

  /// 站点显示名（记账与提示用）。
  final String label;

  /// 档位 0–3；非成人站为 -1。
  final int tier;

  /// 本次应扣元宝；非成人站为 0。
  final int cost;

  /// 判定时的元宝余额。
  final int balance;

  bool get allowed => status != AdultEntryStatus.insufficient;

  int get shortfall => cost - balance;

  String get tierLabel => tier < 0 ? '普通站' : '第 ${tier + 1} 档';
}

/// 一条成人站扣费记录：落盘可对账（余额变化能对上）。
class AdultSpendRecord {
  const AdultSpendRecord({
    required this.timeMillis,
    required this.coreId,
    required this.label,
    required this.tier,
    required this.cost,
    required this.balanceAfter,
    required this.source,
  });

  final int timeMillis;
  final String coreId;
  final String label;
  final int tier;
  final int cost;
  final int balanceAfter;

  /// 扣费入口：'detail'（影视区进详情页）、'play'（绕过详情页
  /// 直接开播时补扣）；'game' 与 'video' 是进站费取消前的旧来源，
  /// 新记录不再产生，旧记录保留展示（账本只追加看片费）。
  final String source;

  String encode() => [
        timeMillis,
        coreId,
        label,
        tier,
        cost,
        balanceAfter,
        source,
      ].join('|');

  static AdultSpendRecord? decode(String raw) {
    final parts = raw.split('|');
    if (parts.length != 7) return null;
    final time = int.tryParse(parts[0]);
    final tier = int.tryParse(parts[3]);
    final cost = int.tryParse(parts[4]);
    final balance = int.tryParse(parts[5]);
    if (time == null || tier == null || cost == null || balance == null) {
      return null;
    }
    return AdultSpendRecord(
      timeMillis: time,
      coreId: parts[1],
      label: parts[2],
      tier: tier,
      cost: cost,
      balanceAfter: balance,
      source: parts[6],
    );
  }
}

/// 成人站进站档位（游戏节点与影视区共用同一套，避免两边扣费对不上）：
/// 先认游戏节点档位（按修为门槛：3000 第 1 档、8000 第 2 档、
/// 15000 第 3 档、30000 第 4 档），不是节点的站再按影视区登记表
/// 档位（[adultTierForSiteId]，按注册顺序均分）；两边都不在表里
/// 返回 null（不是成人站，不扣）。
///
/// 注意两套档位对同一站会打架：xHamster 节点第 4 档、登记表第 1 档，
/// Jable/Pornhub/VJAV/ABJAV/AsexTV 节点第 2–3 档、登记表第 4 档，
/// 所以必须节点优先，否则同一站从游戏进和从影视区进扣的不一样。
int? adultViewTierForSite(String unifiedRowId) {
  final coreId = adultSiteIdForUnifiedId(unifiedRowId);
  for (final node in gameSiteNodes) {
    if (node.coreId == coreId) return node.tier;
  }
  return adultTierForSiteId(unifiedRowId, adultVideoSiteOrder);
}

/// 挂机游戏服务：元宝、爬塔、推图、装备、商城、挂机与离线结算，
/// 全部落盘 SharedPreferences，覆盖安装不丢。
///
/// 后台挂机说明（鸿蒙 NEXT 杀后台严，卓易通容器里的常驻服务也
/// 会被杀，所以不依赖后台常驻保活）：
/// - App 活着时（哪怕切到影视区看视频、切到别的 tab），服务里的
///   5 秒定时器一直在跑，修为与元宝照涨——游戏状态挂在服务上，
///   不挂在游戏页面上，切 tab 不停。
/// - App 切后台 / 被杀时，定时器停了，但每次 tick 与切后台时
///   都落盘记下 lastSeen；下次回来（包括彻底关掉重开）按离开
///   时长结算离线收益（封顶 8 小时），挂机进度不断。
class GameService extends ChangeNotifier with WidgetsBindingObserver {
  GameService._();

  static final GameService instance = GameService._();

  static const _yuanbaoKey = 'game_yuanbao';
  static const _towerFloorKey = 'game_tower_floor';
  static const _mapChapterKey = 'game_map_chapter';
  static const _completedChaptersKey = 'game_completed_chapters';
  static const _completedTrainingKey = 'game_completed_training';
  static const _ownedEquipKey = 'game_owned_equip';
  static const _equippedKey = 'game_equipped';
  static const _refineKey = 'game_refine';
  static const _autoSynthesizeKey = 'game_auto_synthesize';
  static const _autoRefineMaterialKey = 'game_auto_refine_material';
  static const _doubleXpUntilKey = 'game_double_xp_until';
  static const _lastSeenKey = 'game_last_seen';
  static const _huntDateKey = 'game_hunt_date';
  static const _huntCountKey = 'game_hunt_count';
  static const _bottleDateKey = 'game_bottle_date';
  static const _totalKillsKey = 'game_total_kills';
  static const _adultSpendsKey = 'game_adult_spends';

  /// 扣费记录最多留多少条（最新在前，超了丢最旧的）。
  static const _adultSpendsMax = 50;

  /// 本启动内已扣过看片费的片子（站核心 id + 片子 id）：
  /// 同一部片子同一次进入里重复进详情页、重复点播不再重复扣；
  /// 换一部片子再扣一次。重启 App 后清空。
  final Set<String> _paidAdultFilmKeys = <String>{};

  /// 成人站扣费记录（最新在前，最多 50 条），落盘可对账。
  List<AdultSpendRecord> get adultSpendHistory =>
      List<AdultSpendRecord>.unmodifiable(_adultSpends);
  final List<AdultSpendRecord> _adultSpends = <AdultSpendRecord>[];

  /// 元宝。
  int yuanbao = 0;

  /// 试炼塔已通最高层（0 = 还没打过）。
  int towerFloor = 0;

  /// 推图已通最高章下标（-1 = 还没通关）。
  int mapChapterIndex = -1;

  /// 已通关的推图章 id。
  Set<String> completedChapters = <String>{};

  /// 已完成的养成任务 id。
  Set<String> completedTraining = <String>{};

  /// 已拥有的装备：装备 id -> 件数（可重复掉落，重复件数叠加，
  /// 3 件同品质同部位自动合成高一档；旧存档是纯 id 列表，读盘时
  /// 按每件 1 件迁移，老装备一件不少）。
  Map<String, int> ownedEquip = <String, int>{};

  /// 已拥有的装备 id（去重后，页面与旧调用方用）。
  Set<String> get ownedEquipIds => ownedEquip.keys.toSet();

  /// 某件装备有几件。
  int equipCount(String equipId) => ownedEquip[equipId] ?? 0;

  /// 有没有这件装备。
  bool ownsEquip(String equipId) => (ownedEquip[equipId] ?? 0) > 0;

  /// 已穿戴：栏位名 -> 装备 id。
  Map<String, String> equipped = <String, String>{};

  /// 强化等级：装备 id -> 等级（0–[gameEquipRefineMax]）。
  Map<String, int> refine = <String, int>{};

  /// 自动合成开关（默认开）：得装备后自动把同品质同部位
  /// 满 3 件的合成高一档。关了可手动点“立即合成”。
  bool autoSynthesizeEnabled = true;

  /// 自动补材料开关（默认开）：强化元宝不够时，自动分解多余的
  /// 低级装备（多余件数、七彩除外）补元宝。关了则元宝不够就强化失败。
  bool autoRefineMaterialEnabled = true;

  /// 最近一次自动 / 手动合成的结果（页面用来弹提示，展示后调
  /// [clearSynthesizeResults] 清掉）。
  List<EquipSynthesizeResult> lastSynthesizeResults =
      <EquipSynthesizeResult>[];

  /// 最近一次强化自动分解补材料的装备名（页面用来弹提示）。
  List<String> lastAutoSalvageNames = <String>[];

  /// 双倍修为符到期时间（毫秒时间戳）。
  int doubleXpUntilMillis = 0;

  /// 总击杀数。
  int totalKills = 0;

  /// 最近一次离线结算（页面用来弹横幅，展示后调
  /// [clearOfflineReward] 清掉）。
  OfflineReward? lastOfflineReward;

  Timer? _timer;
  bool _ticking = false;
  bool _observerAdded = false;
  double _doubleXpAccum = 0;
  double _yuanbaoAccum = 0;
  int _lastPersistMillis = 0;

  Future<void>? _loadFuture;
  Future<void> _persistChain = Future<void>.value();

  /// 双倍修为符是否生效中。
  bool get doubleXpActive =>
      DateTime.now().millisecondsSinceEpoch < doubleXpUntilMillis;

  /// 当前境界等级（复用修仙体系快照）。
  int get level => CultivationService.instance.snapshot.level;

  /// 当前总修为（复用修仙体系快照）。
  int get totalXp => CultivationService.instance.totalXp;

  /// 当前战力：境界基础 + 装备贡献，装备占大头。
  /// 境界基础 = 50 + 等级 ×2（满级 270 级也只有 590）；
  /// 装备贡献 = Σ 已穿戴件（攻击 + 防御 + 血量 ÷10）
  ///   × 品质倍率（白 1.0 / 绿 1.3 / 蓝 1.7 / 紫 2.2 / 橙 2.8 /
  ///   红 3.6 / 七彩 4.8）×（1 + 强化等级 ×12%）。
  /// 满配七彩强化满级约 15200，其中装备占 96% 以上；
  /// 只靠境界白板（590）连第 4 章（要 700）都打不过。
  int get power => basePower + equipPower;

  /// 境界基础战力（小头）：50 + 等级 ×2。
  int get basePower => gamePowerBase + level * gamePowerPerLevel;

  /// 装备贡献战力（大头）：已穿戴件属性 × 品质倍率 × 强化加成。
  int get equipPower {
    var value = 0.0;
    for (final entry in equipped.entries) {
      final equip = gameEquipmentById(entry.value);
      if (equip == null) continue;
      final base = equip.attack +
          equip.defense +
          equip.hp / 10;
      final multiplier = gameEquipQualityPowerMultiplier(equip.quality);
      final refineBonus =
          1 + (refine[equip.id] ?? 0) * gameEquipRefineBonusPerLevel;
      value += base * multiplier * refineBonus;
    }
    return value.round();
  }

  /// 某栏位已穿戴的装备（未穿为空）。
  GameEquipment? equippedIn(GameEquipSlot slot) {
    final id = equipped[slot.name];
    if (id == null) return null;
    return gameEquipmentById(id);
  }

  /// 启动时调用：读盘、结算离线收益、起挂机定时器、注册
  /// 前后台监听。多次调用只跑一次。
  Future<void> ensureInitialized() =>
      _loadFuture ??= _load();

  Future<void> _load() async {
    await CultivationService.instance.ensureInitialized();
    try {
      final sp = await SharedPreferences.getInstance();
      yuanbao = sp.getInt(_yuanbaoKey) ?? 0;
      towerFloor = sp.getInt(_towerFloorKey) ?? 0;
      mapChapterIndex = sp.getInt(_mapChapterKey) ?? -1;
      completedChapters =
          (sp.getStringList(_completedChaptersKey) ?? const []).toSet();
      completedTraining =
          (sp.getStringList(_completedTrainingKey) ?? const []).toSet();
      ownedEquip = _decodeEquipCounts(
        sp.getStringList(_ownedEquipKey) ?? const [],
      );
      equipped = _decodeMap(sp.getStringList(_equippedKey) ?? const []);
      refine = _decodeIntMap(sp.getStringList(_refineKey) ?? const []);
      autoSynthesizeEnabled =
          sp.getBool(_autoSynthesizeKey) ?? true;
      autoRefineMaterialEnabled =
          sp.getBool(_autoRefineMaterialKey) ?? true;
      doubleXpUntilMillis = sp.getInt(_doubleXpUntilKey) ?? 0;
      totalKills = sp.getInt(_totalKillsKey) ?? 0;
      _adultSpends
        ..clear()
        ..addAll([
          for (final raw
              in sp.getStringList(_adultSpendsKey) ?? const <String>[])
            AdultSpendRecord.decode(raw),
        ].whereType<AdultSpendRecord>());
      final lastSeen = sp.getInt(_lastSeenKey) ?? 0;
      await _settleOffline(lastSeen);
      _touchSeen();
      _startTimer();
      if (!_observerAdded) {
        WidgetsBinding.instance.addObserver(this);
        _observerAdded = true;
      }
      notifyListeners();
    } catch (_) {
      // 读盘失败退化为空存档，不拖住启动。
      _startTimer();
    }
  }

  /// 离线结算：按离开时长算修为与元宝（封顶 8 小时），
  /// 60 秒以内不算（刚切走就回来不弹）。
  Future<void> _settleOffline(int lastSeenMillis) async {
    if (lastSeenMillis <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var elapsedSeconds = (now - lastSeenMillis) ~/ 1000;
    if (elapsedSeconds < 60) return;
    final cap = gameOfflineCapHours * 3600;
    if (elapsedSeconds > cap) elapsedSeconds = cap;
    final xp = (elapsedSeconds * cultivationXpPerSecond).floor();
    final bonus = elapsedSeconds ~/ 60 * gameIdleYuanbaoPerMinute;
    if (xp > 0) {
      await CultivationService.instance.addMeditationSeconds(
        elapsedSeconds.toDouble(),
      );
    }
    if (bonus > 0) yuanbao += bonus;
    lastOfflineReward = OfflineReward(
      seconds: elapsedSeconds,
      xp: xp,
      yuanbao: bonus,
    );
    await _persist();
  }

  /// 展示完离线结算横幅后清掉。
  void clearOfflineReward() {
    lastOfflineReward = null;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台 / 被系统挂起时落盘记时间并把零头收益结掉；
    // 回前台时按离开时长结算（见 [_settleOffline]）。
    // 鸿蒙 NEXT 杀后台也一样：进程被杀时 lastSeen 还在盘里，
    // 下次启动照样按时长结算，挂机不断。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_onPause());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onResume());
    }
  }

  Future<void> _onPause() async {
    await _flushAccum();
    _touchSeen();
    await _persist();
  }

  Future<void> _onResume() async {
    final sp = await SharedPreferences.getInstance();
    final lastSeen = sp.getInt(_lastSeenKey) ?? 0;
    await _settleOffline(lastSeen);
    _touchSeen();
    notifyListeners();
  }

  void _touchSeen() {
    _lastPersistMillis = DateTime.now().millisecondsSinceEpoch;
    unawaited(_persistSeenOnly());
  }

  Future<void> _persistSeenOnly() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(
        _lastSeenKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  void _startTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_tick());
    });
  }

  /// 挂机 tick（App 活着时一直跑，切 tab、切影视区都不停）：
  /// 每 5 秒按打坐速率涨修为、每分钟 +1 元宝；双倍符生效时
  /// 额外修为先攒着，满 10 再一次落盘。
  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      await CultivationService.instance.addMeditationSeconds(5);
      if (doubleXpActive) {
        _doubleXpAccum += 5 * cultivationXpPerSecond;
        if (_doubleXpAccum >= 10) {
          final whole = _doubleXpAccum.floor();
          _doubleXpAccum -= whole;
          await CultivationService.instance.addGameXp(whole);
        }
      }
      _yuanbaoAccum += 5 / 60 * gameIdleYuanbaoPerMinute;
      if (_yuanbaoAccum >= 1) {
        final whole = _yuanbaoAccum.floor();
        _yuanbaoAccum -= whole;
        yuanbao += whole;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastPersistMillis >= 60000) {
        _touchSeen();
        await _persist();
      }
      notifyListeners();
    } catch (_) {
    } finally {
      _ticking = false;
    }
  }

  /// 把零头收益结掉（切后台前调）。
  Future<void> _flushAccum() async {
    if (_doubleXpAccum >= 1) {
      final whole = _doubleXpAccum.floor();
      _doubleXpAccum = 0;
      await CultivationService.instance.addGameXp(whole);
    }
    if (_yuanbaoAccum >= 1) {
      yuanbao += _yuanbaoAccum.floor();
      _yuanbaoAccum = 0;
    }
  }

  /// 击杀一只妖兽：修为 + 元宝，12% 几率掉一件装备
  /// （重复掉落叠加件数，满 3 件同品质同部位自动合成高一档；
  /// 七彩不直接掉）；双倍符时修为 ×2。
  Future<KillResult> killMonster(GameMonster monster) async {
    await ensureInitialized();
    final mult = doubleXpActive ? 2 : 1;
    final xp = monster.xpReward * mult;
    await CultivationService.instance.addGameXp(xp);
    yuanbao += monster.yuanbaoReward;
    totalKills++;
    String? dropped;
    if (math.Random().nextDouble() < 0.12) {
      final pool = gameDropPoolForRealm(
        CultivationService.instance.snapshot.realm.realmIndex,
      );
      if (pool.isNotEmpty) {
        final equip = pool[math.Random().nextInt(pool.length)];
        _addEquip(equip.id);
        dropped = equip.id;
      }
    }
    await _persist();
    notifyListeners();
    return KillResult(xp: xp, yuanbao: monster.yuanbaoReward, droppedEquipId: dropped);
  }

  /// 推图通关一章：必须按顺序打，战力与修为够了才行。
  /// 成功返回通关奖励修为，失败返回 null。
  Future<int?> completeChapter(int index) async {
    await ensureInitialized();
    if (index < 0 || index >= gameChapters.length) return null;
    if (index != mapChapterIndex + 1) return null;
    final chapter = gameChapters[index];
    if (power < chapter.requiredPower) return null;
    if (totalXp < chapter.requiredRealmXp) return null;
    final mult = doubleXpActive ? 2 : 1;
    final xp = chapter.xpReward * mult;
    await CultivationService.instance.addGameXp(xp);
    yuanbao += chapter.yuanbaoReward;
    mapChapterIndex = index;
    completedChapters.add(chapter.id);
    final equipId = chapter.equipRewardId;
    if (equipId != null) _addEquip(equipId);
    await _persist();
    notifyListeners();
    return xp;
  }

  /// 完成一个养成任务（一次性）：仙法学习 / 法宝觉醒 /
  /// 妖兽培育 / 法器锻造 / 傀儡操纵。
  Future<bool> completeTraining(String questId) async {
    await ensureInitialized();
    if (completedTraining.contains(questId)) return false;
    GameTrainingQuest? quest;
    for (final item in gameTrainingQuests) {
      if (item.id == questId) quest = item;
    }
    if (quest == null) return false;
    if (totalXp < quest.requiredRealmXp) return false;
    final mult = doubleXpActive ? 2 : 1;
    await CultivationService.instance.addGameXp(quest.xpReward * mult);
    yuanbao += quest.yuanbaoReward;
    completedTraining.add(questId);
    await _persist();
    notifyListeners();
    return true;
  }

  /// 挑战试炼塔一层：必须按顺序打，战力够了才通关。
  /// 返回 null 表示战力不够或顺序不对。
  Future<KillResult?> challengeTower(int floor) async {
    await ensureInitialized();
    if (floor != towerFloor + 1) return null;
    final floors = gameTowerFloors;
    if (floor < 1 || floor > floors.length) return null;
    final target = floors[floor - 1];
    if (power < target.requiredPower) return null;
    final mult = doubleXpActive ? 2 : 1;
    final xp = target.xpReward * mult;
    await CultivationService.instance.addGameXp(xp);
    yuanbao += target.yuanbaoReward;
    towerFloor = floor;
    if (floor == gameTowerFloors.length) {
      // 通关 30 层：得一件七彩装备（随机部位，未拥有的优先）。
      // 七彩不直接掉落，这是除合成外的唯一来源。
      final pool = gameEquipmentsOfQuality(GameEquipQuality.rainbow);
      if (pool.isNotEmpty) {
        final unowned = [
          for (final e in pool) if (!ownsEquip(e.id)) e,
        ];
        final pick = (unowned.isNotEmpty ? unowned : pool)[
            math.Random().nextInt(
              (unowned.isNotEmpty ? unowned : pool).length,
            )];
        _addEquip(pick.id);
      }
    }
    await _persist();
    notifyListeners();
    return KillResult(xp: xp, yuanbao: target.yuanbaoReward);
  }

  /// 乱星海狩猎：每天 3 次，每次 +20 元宝、30% 掉装备。
  Future<KillResult?> hunt() async {
    await ensureInitialized();
    final today = _todayString();
    final sp = await SharedPreferences.getInstance();
    final savedDate = sp.getString(_huntDateKey) ?? '';
    var count = sp.getInt(_huntCountKey) ?? 0;
    if (savedDate != today) count = 0;
    if (count >= gameHuntPerDay) return null;
    count++;
    await sp.setString(_huntDateKey, today);
    await sp.setInt(_huntCountKey, count);
    yuanbao += 20;
    String? dropped;
    if (math.Random().nextDouble() < 0.3) {
      final pool = gameDropPoolForRealm(
        CultivationService.instance.snapshot.realm.realmIndex,
      );
      if (pool.isNotEmpty) {
        final equip = pool[math.Random().nextInt(pool.length)];
        _addEquip(equip.id);
        dropped = equip.id;
      }
    }
    await _persist();
    notifyListeners();
    return KillResult(xp: 0, yuanbao: 20, droppedEquipId: dropped);
  }

  /// 今天还剩几次狩猎。
  Future<int> huntsLeft() async {
    final sp = await SharedPreferences.getInstance();
    if ((sp.getString(_huntDateKey) ?? '') != _todayString()) {
      return gameHuntPerDay;
    }
    final count = sp.getInt(_huntCountKey) ?? 0;
    return math.max(0, gameHuntPerDay - count);
  }

  /// 掌天瓶：每天 1 次，+500 修为。
  Future<bool> bottle() async {
    await ensureInitialized();
    final today = _todayString();
    final sp = await SharedPreferences.getInstance();
    if ((sp.getString(_bottleDateKey) ?? '') == today) return false;
    await sp.setString(_bottleDateKey, today);
    await CultivationService.instance.addGameXp(gameBottleXp);
    await _persist();
    notifyListeners();
    return true;
  }

  /// 今天掌天瓶领过没有。
  Future<bool> bottleClaimed() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getString(_bottleDateKey) ?? '') == _todayString();
  }

  /// 游戏节点进成人站：进站免费，不扣元宝。
  /// 只看境界与塔层够不够：解锁了返回 true，没解锁返回 false、不扣。
  /// 普通影视站不走这里、不扣，只成人站节点走这里，同样不扣。
  /// 看片费另在进详情页时按片子收（[tryChargeAdultFilm]，20 元宝）。
  Future<bool> spendForAdultView(GameSiteNode node) async {
    await ensureInitialized();
    return node.unlocked(totalXp, towerFloor);
  }

  /// 游戏节点 / 影视区进成人站（进站免费）：
  /// - 非成人站：不扣，放行；
  /// - 成人站：不扣，放行（境界门槛在页面点按前已拦住，
  ///   这里只负责放行与回填档位信息，不扣费、不记账）。
  /// 档位只用来在看片扣费提示里写清是哪一档，不参与定价。
  /// 看片费另在进详情页时按片子收（[tryChargeAdultFilm]）。
  Future<AdultSiteEntryOutcome> tryEnterAdultSite(
    String unifiedRowId, {
    String? label,
    String source = 'video',
  }) async {
    await ensureInitialized();
    final coreId = adultSiteIdForUnifiedId(unifiedRowId);
    final tier = adultViewTierForSite(unifiedRowId);
    final name = label ?? coreId;
    return AdultSiteEntryOutcome(
      status: AdultEntryStatus.free,
      coreId: coreId,
      label: name,
      tier: tier ?? -1,
      cost: 0,
      balance: yuanbao,
    );
  }

  /// 影视区看片扣费（看一部片子 20 元宝，不分档）：
  /// 扣费点在进详情页——点一部片子进详情页时扣 20 元宝；
  /// 余额不足 20 就进不了详情页，拦住（返回 insufficient，带还差多少）。
  /// - 非成人站：不扣，放行；
  /// - 同一部片子本启动内已扣过：不重复扣，放行；
  /// - 元宝不够：不扣，拦住；
  /// - 够了：扣掉 20 元宝、记账、放行。
  /// [seriesId] 是片子 id（不是集 id）：同一部片子换集播不重复扣；
  /// 换一部片子（不同 seriesId）再扣 20。档位只用来在提示里
  /// 写清是哪一档，不参与定价：进站免费，看片费是唯一一笔，
  /// 游戏节点进站不扣费，进详情页才按片子扣。
  /// 详情页与直接播放共用同一把已扣判断：详情页扣过的片子再点播
  /// 不重复扣；绕过详情页直接开播的，在开播时补扣同一笔。
  Future<AdultSiteEntryOutcome> tryChargeAdultFilm(
    String siteRowId, {
    required String seriesId,
    String? label,
    String source = 'detail',
  }) async {
    await ensureInitialized();
    final coreId = adultSiteIdForUnifiedId(siteRowId);
    final tier = adultViewTierForSite(siteRowId);
    final name = label ?? seriesId;
    if (tier == null) {
      return AdultSiteEntryOutcome(
        status: AdultEntryStatus.free,
        coreId: coreId,
        label: name,
        tier: -1,
        cost: 0,
        balance: yuanbao,
      );
    }
    const cost = gameAdultFilmCost;
    final filmKey = '$coreId::$seriesId';
    if (_paidAdultFilmKeys.contains(filmKey)) {
      return AdultSiteEntryOutcome(
        status: AdultEntryStatus.alreadyPaid,
        coreId: coreId,
        label: name,
        tier: tier,
        cost: cost,
        balance: yuanbao,
      );
    }
    if (yuanbao < cost) {
      return AdultSiteEntryOutcome(
        status: AdultEntryStatus.insufficient,
        coreId: coreId,
        label: name,
        tier: tier,
        cost: cost,
        balance: yuanbao,
      );
    }
    yuanbao -= cost;
    _paidAdultFilmKeys.add(filmKey);
    _adultSpends.insert(
      0,
      AdultSpendRecord(
        timeMillis: DateTime.now().millisecondsSinceEpoch,
        coreId: coreId,
        label: name,
        tier: tier,
        cost: cost,
        balanceAfter: yuanbao,
        source: source,
      ),
    );
    if (_adultSpends.length > _adultSpendsMax) {
      _adultSpends.removeRange(_adultSpendsMax, _adultSpends.length);
    }
    await _persist();
    notifyListeners();
    return AdultSiteEntryOutcome(
      status: AdultEntryStatus.paid,
      coreId: coreId,
      label: name,
      tier: tier,
      cost: cost,
      balance: yuanbao,
    );
  }

  /// 元宝商城购买：聚气丹（+300 修为）、双倍修为符（双倍 1 小时）、
  /// 法宝盲盒（随机一件装备）。元宝不够返回 null。
  Future<String?> buyShop(String itemId) async {
    await ensureInitialized();
    GameShopItem? item;
    for (final entry in gameShopItems) {
      if (entry.id == itemId) item = entry;
    }
    if (item == null) return null;
    if (yuanbao < item.price) return null;
    yuanbao -= item.price;
    switch (itemId) {
      case 'juqi_dan':
        await CultivationService.instance.addGameXp(300);
      case 'double_fu':
        doubleXpUntilMillis =
            DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      case 'fabao_box':
        // 法宝盲盒：随机一件非七彩装备（七彩不直接掉，只能合成
        // 或通关试炼塔 30 层得）；重复件数叠加，可合成。
        final pool = [
          for (final e in gameEquipments)
            if (e.quality != GameEquipQuality.rainbow) e,
        ];
        final equip = pool[math.Random().nextInt(pool.length)];
        _addEquip(equip.id);
        await _persist();
        notifyListeners();
        return '开出${equip.name}';
    }
    await _persist();
    notifyListeners();
    return '已购买${item.name}';
  }

  /// 穿戴装备：同栏位只能穿一件；境界不够穿不上。
  Future<bool> equip(String equipId) async {
    await ensureInitialized();
    final equip = gameEquipmentById(equipId);
    if (equip == null) return false;
    if (!ownsEquip(equipId)) return false;
    if (CultivationService.instance.snapshot.realm.realmIndex <
        equip.requiredRealmIndex) {
      return false;
    }
    equipped[equip.slot.name] = equipId;
    await _persist();
    notifyListeners();
    return true;
  }

  /// 脱下某栏位的装备。
  Future<void> unequip(GameEquipSlot slot) async {
    equipped.remove(slot.name);
    await _persist();
    notifyListeners();
  }

  /// 强化装备：每级 +12% 属性，满 [gameEquipRefineMax] 级；
  /// 费用 20×（等级+1）元宝。元宝不够且自动补材料开着时，
  /// 自动分解多余的低级装备（多余件数、七彩除外、已穿戴那件不算）
  /// 补元宝；还不够则强化失败、不扣。
  /// 成功返回 true；分解掉的装备名记在 [lastAutoSalvageNames] 里。
  Future<bool> refineEquip(String equipId) async {
    await ensureInitialized();
    lastAutoSalvageNames = <String>[];
    if (!ownsEquip(equipId)) return false;
    final current = refine[equipId] ?? 0;
    if (current >= gameEquipRefineMax) return false;
    final cost = 20 * (current + 1);
    if (yuanbao < cost) {
      if (!autoRefineMaterialEnabled) return false;
      if (!_autoSalvageFor(cost - yuanbao, excludeId: equipId)) return false;
    }
    yuanbao -= cost;
    refine[equipId] = current + 1;
    await _persist();
    notifyListeners();
    return true;
  }

  /// 得一件装备（件数 +1）；自动合成开着时顺手把满 3 件的
  /// 同品质同部位合成高一档，结果记在 [lastSynthesizeResults] 里。
  void _addEquip(String equipId) {
    ownedEquip[equipId] = (ownedEquip[equipId] ?? 0) + 1;
    if (autoSynthesizeEnabled) {
      lastSynthesizeResults = synthesizeAll();
    }
  }

  /// 手动立即合成（自动合成关了也能用）：把所有满 3 件的
  /// 同品质同部位合成高一档，返回每次合成的结果。
  /// 规则：3 件绿 → 1 件蓝、3 件蓝 → 1 件紫，以此类推到七彩；
  /// 七彩是顶，没有更高档，不参与合成；合成目标优先选未拥有的
  /// 同部位高一档装备；已穿戴那件不算进可消耗数（不会把身上
  /// 穿的那件合掉）；七彩不可分解、不可当合成材料。
  List<EquipSynthesizeResult> synthesizeAll() {
    final results = <EquipSynthesizeResult>[];
    var changed = true;
    while (changed) {
      changed = false;
      for (var qi = 0; qi < GameEquipQuality.values.length - 1; qi++) {
        final quality = GameEquipQuality.values[qi];
        final next = GameEquipQuality.values[qi + 1];
        for (final slot in GameEquipSlot.values) {
          while (true) {
            final sources = gameEquipmentsOf(slot, quality);
            var available = 0;
            for (final item in sources) {
              var count = ownedEquip[item.id] ?? 0;
              if (equipped[slot.name] == item.id) count -= 1;
              if (count > 0) available += count;
            }
            if (available < gameEquipSynthesizeCount) break;
            final targets = gameEquipmentsOf(slot, next);
            if (targets.isEmpty) break;
            // 先消耗多余件数（同件有 2 件以上的先合多余的），
            // 再消耗单件；已穿戴那件留着不合。
            var need = gameEquipSynthesizeCount;
            final consumed = <String, int>{};
            final ordered = sources.toList()
              ..sort((a, b) {
                final ca = ownedEquip[a.id] ?? 0;
                final cb = ownedEquip[b.id] ?? 0;
                return cb.compareTo(ca);
              });
            for (final item in ordered) {
              if (need <= 0) break;
              var count = ownedEquip[item.id] ?? 0;
              if (equipped[slot.name] == item.id) count -= 1;
              if (count <= 0) continue;
              final take = count < need ? count : need;
              ownedEquip[item.id] = (ownedEquip[item.id] ?? 0) - take;
              if (ownedEquip[item.id] == 0) ownedEquip.remove(item.id);
              consumed[item.id] = take;
              need -= take;
            }
            if (need > 0) break;
            final unowned = [
              for (final e in targets) if (!ownsEquip(e.id)) e,
            ];
            final pick = (unowned.isNotEmpty ? unowned : targets)[
                math.Random().nextInt(
                  (unowned.isNotEmpty ? unowned : targets).length,
                )];
            ownedEquip[pick.id] = (ownedEquip[pick.id] ?? 0) + 1;
            results.add(
              EquipSynthesizeResult(consumed: consumed, resultId: pick.id),
            );
            changed = true;
          }
        }
      }
    }
    if (results.isNotEmpty) {
      lastSynthesizeResults = results;
    }
    return results;
  }

  /// 手动分解一件装备（多余件数才能分，已穿戴那件不能分，
  /// 七彩不能分）：得对应品质元宝（白 5 / 绿 10 / 蓝 20 /
  /// 紫 40 / 橙 80 / 红 160），返回得的元宝，分不了返回 0。
  Future<int> salvageEquip(String equipId) async {
    await ensureInitialized();
    final equip = gameEquipmentById(equipId);
    if (equip == null) return 0;
    if (equip.quality == GameEquipQuality.rainbow) return 0;
    var count = ownedEquip[equipId] ?? 0;
    if (equipped[equip.slot.name] == equipId) count -= 1;
    if (count <= 0) return 0;
    final value = gameEquipSalvageValue(equip.quality);
    ownedEquip[equipId] = (ownedEquip[equipId] ?? 0) - 1;
    if (ownedEquip[equipId] == 0) ownedEquip.remove(equipId);
    yuanbao += value;
    await _persist();
    notifyListeners();
    return value;
  }

  /// 强化自动补材料：按品质从低到高分解多余件数（已穿戴那件不算、
  /// 正在强化的那件不算、七彩不分），直到补够 [shortfall] 元宝；
  /// 多余装备总共换的元宝不够补时一分不动、直接返回 false。
  bool _autoSalvageFor(int shortfall, {String? excludeId}) {
    final candidates = [
      for (final entry in ownedEquip.entries)
        gameEquipmentById(entry.key),
    ].whereType<GameEquipment>().toList()
      ..sort(
        (a, b) => a.quality.index.compareTo(b.quality.index),
      );
    var total = 0;
    for (final equip in candidates) {
      if (equip.id == excludeId) continue;
      if (equip.quality == GameEquipQuality.rainbow) continue;
      var extra = ownedEquip[equip.id] ?? 0;
      if (equipped[equip.slot.name] == equip.id) extra -= 1;
      if (extra > 0) {
        total += extra * gameEquipSalvageValue(equip.quality);
      }
    }
    if (total < shortfall) return false;
    var need = shortfall;
    final salvaged = <String>[];
    for (final equip in candidates) {
      if (need <= 0) break;
      if (equip.id == excludeId) continue;
      if (equip.quality == GameEquipQuality.rainbow) continue;
      var extra = ownedEquip[equip.id] ?? 0;
      if (equipped[equip.slot.name] == equip.id) extra -= 1;
      while (extra > 0 && need > 0) {
        final value = gameEquipSalvageValue(equip.quality);
        ownedEquip[equip.id] = (ownedEquip[equip.id] ?? 0) - 1;
        if (ownedEquip[equip.id] == 0) ownedEquip.remove(equip.id);
        yuanbao += value;
        salvaged.add(equip.name);
        extra--;
        need -= value;
      }
    }
    lastAutoSalvageNames = salvaged;
    return true;
  }

  /// 自动合成开关。
  Future<void> setAutoSynthesize(bool value) async {
    autoSynthesizeEnabled = value;
    await _persist();
    notifyListeners();
  }

  /// 自动补材料开关。
  Future<void> setAutoRefineMaterial(bool value) async {
    autoRefineMaterialEnabled = value;
    await _persist();
    notifyListeners();
  }

  /// 手动合成后落盘（合成是同步内存操作，页面调完顺手落盘）。
  Future<void> persist() => _persist();

  /// 展示完合成结果提示后清掉。
  void clearSynthesizeResults() {
    lastSynthesizeResults = <EquipSynthesizeResult>[];
    notifyListeners();
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
  }

  /// 读盘：装备按件数记（'id=件数'）；旧存档是纯 id 列表，
  /// 没有 '=' 的按 1 件迁移，老装备一件不少。
  Map<String, int> _decodeEquipCounts(List<String> raw) {
    final out = <String, int>{};
    for (final entry in raw) {
      final parts = entry.split('=');
      if (parts.length == 2) {
        final value = int.tryParse(parts[1]);
        if (value != null && value > 0) out[parts[0]] = value;
      } else if (parts.length == 1 && entry.isNotEmpty) {
        out[entry] = (out[entry] ?? 0) + 1;
      }
    }
    return out;
  }

  Map<String, String> _decodeMap(List<String> raw) {
    final out = <String, String>{};
    for (final entry in raw) {
      final parts = entry.split('=');
      if (parts.length == 2) out[parts[0]] = parts[1];
    }
    return out;
  }

  Map<String, int> _decodeIntMap(List<String> raw) {
    final out = <String, int>{};
    for (final entry in raw) {
      final parts = entry.split('=');
      if (parts.length == 2) {
        final value = int.tryParse(parts[1]);
        if (value != null) out[parts[0]] = value;
      }
    }
    return out;
  }

  Future<void> _persist() {
    final run = _persistChain.then((_) async {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_yuanbaoKey, yuanbao);
      await sp.setInt(_towerFloorKey, towerFloor);
      await sp.setInt(_mapChapterKey, mapChapterIndex);
      await sp.setStringList(
        _completedChaptersKey,
        completedChapters.toList(),
      );
      await sp.setStringList(
        _completedTrainingKey,
        completedTraining.toList(),
      );
      await sp.setStringList(
        _ownedEquipKey,
        [for (final e in ownedEquip.entries) '${e.key}=${e.value}'],
      );
      await sp.setStringList(
        _equippedKey,
        [for (final e in equipped.entries) '${e.key}=${e.value}'],
      );
      await sp.setStringList(
        _refineKey,
        [for (final e in refine.entries) '${e.key}=${e.value}'],
      );
      await sp.setInt(_doubleXpUntilKey, doubleXpUntilMillis);
      await sp.setInt(_totalKillsKey, totalKills);
      await sp.setBool(_autoSynthesizeKey, autoSynthesizeEnabled);
      await sp.setBool(_autoRefineMaterialKey, autoRefineMaterialEnabled);
      await sp.setStringList(
        _adultSpendsKey,
        [for (final record in _adultSpends) record.encode()],
      );
      await sp.setInt(
        _lastSeenKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    });
    _persistChain = run.catchError((Object _) {});
    return run;
  }

  /// 测试用：只停掉 5 秒挂机计时器，不动 _loadFuture 与存档。
  /// widget 测试里 RootShell 一挂就起表，测试结束时表还挂着会报
  /// “A Timer is still pending”；pumpAndSettle 前不停表也永远等不到
  /// 安静。resetForTest 也会停表，但它还会清存档、把 _loadFuture 置
  /// 空（下次 ensureInitialized 会重载、重起表），不适合只停表。
  @visibleForTesting
  void stopTimerForTest() {
    _timer?.cancel();
    _timer = null;
  }

  /// 测试用：清掉内存与落盘的游戏数据。
  @visibleForTesting
  Future<void> resetForTest() async {
    _loadFuture = null;
    _persistChain = Future<void>.value();
    _timer?.cancel();
    _timer = null;
    yuanbao = 0;
    towerFloor = 0;
    mapChapterIndex = -1;
    completedChapters = <String>{};
    completedTraining = <String>{};
    ownedEquip = <String, int>{};
    equipped = <String, String>{};
    refine = <String, int>{};
    autoSynthesizeEnabled = true;
    autoRefineMaterialEnabled = true;
    lastSynthesizeResults = <EquipSynthesizeResult>[];
    lastAutoSalvageNames = <String>[];
    doubleXpUntilMillis = 0;
    totalKills = 0;
    lastOfflineReward = null;
    _paidAdultFilmKeys.clear();
    _adultSpends.clear();
    _doubleXpAccum = 0;
    _yuanbaoAccum = 0;
    try {
      final sp = await SharedPreferences.getInstance();
      for (final key in [
        _yuanbaoKey,
        _towerFloorKey,
        _mapChapterKey,
        _completedChaptersKey,
        _completedTrainingKey,
        _ownedEquipKey,
        _equippedKey,
        _refineKey,
        _autoSynthesizeKey,
        _autoRefineMaterialKey,
        _doubleXpUntilKey,
        _lastSeenKey,
        _huntDateKey,
        _huntCountKey,
        _bottleDateKey,
        _totalKillsKey,
        _adultSpendsKey,
      ]) {
        await sp.remove(key);
      }
    } catch (_) {}
    notifyListeners();
  }
}
