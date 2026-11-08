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
  static const _doubleXpUntilKey = 'game_double_xp_until';
  static const _lastSeenKey = 'game_last_seen';
  static const _huntDateKey = 'game_hunt_date';
  static const _huntCountKey = 'game_hunt_count';
  static const _bottleDateKey = 'game_bottle_date';
  static const _totalKillsKey = 'game_total_kills';

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

  /// 已拥有的装备 id（可重复掉落时自动折成元宝，不重复记）。
  Set<String> ownedEquip = <String>{};

  /// 已穿戴：栏位名 -> 装备 id。
  Map<String, String> equipped = <String, String>{};

  /// 强化等级：装备 id -> 等级（0–5）。
  Map<String, int> refine = <String, int>{};

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

  /// 当前战力：100 基础 + 等级 ×12 + 装备属性（强化每级 +10%）。
  int get power {
    var value = 100 + level * 12;
    for (final entry in equipped.entries) {
      final equip = gameEquipmentById(entry.value);
      if (equip == null) continue;
      final levelBonus = 1 + (refine[equip.id] ?? 0) * 0.1;
      value += ((equip.attack + equip.defense) * levelBonus).round();
      value += (equip.hp * levelBonus ~/ 10).round();
    }
    return value;
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
      ownedEquip =
          (sp.getStringList(_ownedEquipKey) ?? const []).toSet();
      equipped = _decodeMap(sp.getStringList(_equippedKey) ?? const []);
      refine = _decodeIntMap(sp.getStringList(_refineKey) ?? const []);
      doubleXpUntilMillis = sp.getInt(_doubleXpUntilKey) ?? 0;
      totalKills = sp.getInt(_totalKillsKey) ?? 0;
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
  /// （已拥有的折成 10 元宝）；双倍符时修为 ×2。
  Future<KillResult> killMonster(GameMonster monster) async {
    await ensureInitialized();
    final mult = doubleXpActive ? 2 : 1;
    final xp = monster.xpReward * mult;
    await CultivationService.instance.addGameXp(xp);
    yuanbao += monster.yuanbaoReward;
    totalKills++;
    String? dropped;
    if (math.Random().nextDouble() < 0.12) {
      final pool = gameEquipments
          .where(
            (e) =>
                e.requiredRealmIndex <=
                CultivationService.instance.snapshot.realm.realmIndex + 1,
          )
          .toList();
      if (pool.isNotEmpty) {
        final equip = pool[math.Random().nextInt(pool.length)];
        if (ownedEquip.contains(equip.id)) {
          yuanbao += 10;
        } else {
          ownedEquip.add(equip.id);
          dropped = equip.id;
        }
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
    if (equipId != null) ownedEquip.add(equipId);
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
      final pool = gameEquipments
          .where(
            (e) =>
                e.requiredRealmIndex <=
                CultivationService.instance.snapshot.realm.realmIndex + 1,
          )
          .toList();
      if (pool.isNotEmpty) {
        final equip = pool[math.Random().nextInt(pool.length)];
        if (ownedEquip.contains(equip.id)) {
          yuanbao += 10;
        } else {
          ownedEquip.add(equip.id);
          dropped = equip.id;
        }
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

  /// 成人站看一次扣元宝：节点已解锁且元宝够时扣掉对应档位
  /// 的费用（第 1 档 5、第 2 档 10、第 3 档 15、第 4 档 20），
  /// 返回 true；未解锁或元宝不够返回 false、不扣。
  /// 普通影视站不走这里、不扣，只成人站扣。
  Future<bool> spendForAdultView(GameSiteNode node) async {
    await ensureInitialized();
    if (!node.unlocked(totalXp, towerFloor)) return false;
    if (yuanbao < node.viewCost) return false;
    yuanbao -= node.viewCost;
    await _persist();
    notifyListeners();
    return true;
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
        final pool = gameEquipments.toList();
        final equip = pool[math.Random().nextInt(pool.length)];
        if (ownedEquip.contains(equip.id)) {
          yuanbao += 50;
          await _persist();
          notifyListeners();
          return '已有${equip.name}，折成 50 元宝';
        }
        ownedEquip.add(equip.id);
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
    if (!ownedEquip.contains(equipId)) return false;
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

  /// 强化装备：每级 +10% 属性，满 5 级；费用 20×（等级+1）元宝。
  Future<bool> refineEquip(String equipId) async {
    await ensureInitialized();
    if (!ownedEquip.contains(equipId)) return false;
    final current = refine[equipId] ?? 0;
    if (current >= 5) return false;
    final cost = 20 * (current + 1);
    if (yuanbao < cost) return false;
    yuanbao -= cost;
    refine[equipId] = current + 1;
    await _persist();
    notifyListeners();
    return true;
  }

  String _todayString() {
    final now = DateTime.now();
    return '${now.year}-${now.month}-${now.day}';
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
      await sp.setStringList(_ownedEquipKey, ownedEquip.toList());
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
      await sp.setInt(
        _lastSeenKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    });
    _persistChain = run.catchError((Object _) {});
    return run;
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
    ownedEquip = <String>{};
    equipped = <String, String>{};
    refine = <String, int>{};
    doubleXpUntilMillis = 0;
    totalKills = 0;
    lastOfflineReward = null;
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
        _doubleXpUntilKey,
        _lastSeenKey,
        _huntDateKey,
        _huntCountKey,
        _bottleDateKey,
        _totalKillsKey,
      ]) {
        await sp.remove(key);
      }
    } catch (_) {}
    notifyListeners();
  }
}
