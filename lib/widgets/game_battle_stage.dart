import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/cultivation.dart';
import '../services/game_data.dart';
import '../services/game_sound.dart';
import 'game_hero_portrait.dart';
import 'game_monster_art.dart';

/// 浮空仙山战场背景（竖版 1152x2048 压成 864x1536 JPG）：
/// 圆形石台约在图高 52% 处，主角（49%）与队友（44%）
/// 脚下正好落在石台上，怪物站石台远端。
const String _battlefieldBgAsset = 'assets/images/game/battlefield_bg.jpg';

/// 一次出招的结算（页面用来记修为/元宝时可忽略，真正结算
/// 走 [GameBattleStage.onMonsterKilled] 后的服务层）。
class BattleStrike {
  /// 本次伤害。
  final int damage;

  /// 是否暴击。
  final bool isCrit;

  /// 是否大招。
  final bool isUlt;

  /// 大招名（非大招为空）。
  final String skillName;

  const BattleStrike({
    required this.damage,
    required this.isCrit,
    required this.isUlt,
    required this.skillName,
  });
}

/// 全屏 2.5D 俯视厮杀战场：竖屏斜俯视约 45 度，背景是
/// 浮空仙山圆形石台图（仙门牌坊 + 云海），人物和怪物
/// 站在石台上打，脚下有影子；人物很小（约占画面十分之一），
/// 3-4 人紧贴 BOSS 围成半弧贴身打，BOSS 居中偏上；全程自动
/// 战斗自动寻路，不用手操作。
/// 人物改小（用户看截图说原来太大互相重叠）：主角 46×58、
/// 队友 38×48、BOSS 全幅 96×195（原图 360x732 比例，整幅
/// 显示不裁切），名牌栏 96 宽、9px 小字不截断不压叠；
/// 战场上没有虚拟玩家托机器人，只有 14 只小怪铺满全场。
///
/// 人物图：3D 写实白发剑修背影（男 / 女两张，见
/// [gameHeroAssetForGender]），战场上用半身裁切图缩成
/// 金环圆形徽章（只占画面高度十分之一左右），创建页 /
/// 人物页 / 档案卡用整幅图；旧 Q 版豆包图保留在资源里当回退。
/// 怪物：3D 写实野兽五格图按格切分（见 [gameMonsterArtFor]），
/// 章节怪固定种类映射（蛟 / 蛟王是墨蛟）；小怪 14 只，数值
/// 用妖兽表里本章战力及以下的怪（蛟 / 蛟王除外），图按槽位
/// 轮着用金光蟒 / 紫电妖狼 / 赤焰火虎 / 金刚巨猿四张，
/// 死后 1.2 秒在场上随机点重刷，挂机一直有怪打。
///
/// 技能特效要酷：剑气又长又亮带拖尾，万剑归宗满屏飞剑，
/// 大庚剑阵金色剑阵铺开，乾蓝冰焰蓝白冰火球飞、命中冰晶爆开，
/// 辟邪神雷紫白闪电从天劈下、命中三道竖劈，绝招全屏大光效加
/// 震屏，命中爆裂光加飘字。
///
/// 界面布局照视频里来：
/// - 中央金字“自动战斗中…/自动寻路中…”；
/// - 右上半透明黑面板：副本名、击败 BOSS 0/1、用时；
/// - 右下横排圆形蓝光符文技能钮 4 个（剑影分光 / 雷法 / 大庚剑阵 /
///   万剑归宗，只做冷却展示，自动放）；
/// - 左下金色竖排书法章节标题 + 红色小印章（地图 + 境界自动换）；
/// - 底部红命条蓝灵条，最右下角修为进度；
/// - 右侧中部黑色箭头标签列（和平/状态/药品/目标），下面
///   黑色“功能”按钮；左下黑菱形喇叭、绝招、自动；
/// - 头顶名字很小白色紧贴头顶，格式境界+名字；BOSS 名只在
///   右上副本面板里，不飘在 BOSS 头顶；
/// - 伤害数字橙黄粗体带黑边，从受击点向上飘，多个同时错开。
///
/// 没有虚拟摇杆（全自动找怪、自动寻路、自动战斗，摇杆整个
/// 删掉）；没有聊天（单机游戏不联网：没有聊天条、聊天气泡、
/// 宗门聊天、世界聊天、聊天角标，左下也没有聊天图标）。
///
/// 队友是固定的 2 名机器人：道友 + 2 名队友（紫灵、厉飞雨）
/// 3 人满队进副本围打 BOSS；队友名字衣服武器各不一样，
/// 会走位、会放技能，不喊话（喊话气泡已删）。
/// 战场上另有 14 只小怪铺满全场：主角普攻优先打最近的小怪，
/// 小怪死后原地 1.2 秒重刷一只，挂机一直有怪打。
///
/// 技能特效以金色为主：巨大金色螺旋光环罩全队、中央白黄闪光，
/// 另有紫漩涡、蓝剑气、白闪电、红爆炸。
/// 打法分两档，照挂机版 2.5D 那个感觉：
/// - 低阶靠身法走位近身突袭：快速前冲、贴身一斩、立刻撤回；
/// - 高阶靠法宝法术对轰：原地施法，青竹蜂云剑剑雨、
///   辟邪神雷、乾蓝冰焰轮着轰过去；
/// 每 4 剑放一次大招（万剑归宗 / 青元剑诀 / 大庚剑阵 /
/// 真魔功 / 泰阳诀 / 惊蛰十二变轮着放），大招有完整动画：
/// 金字横幅 → 金色螺旋光环罩全队 → 三波法宝齐轰 →
/// 中央白黄闪光收尾，不是瞬间结算。
///
/// 全屏说明：本组件自己铺满父级给的全部空间（不固定高度），
/// 父级（游戏页）负责把它放到全屏、藏掉底部导航；摇杆与
/// 技能键按系统边距垫高。切到别的 tab 时父级传 active=false，
/// 本组件停掉自动战斗定时器与音效，不在后台偷打。
class GameBattleStage extends StatefulWidget {
  const GameBattleStage({
    super.key,
    required this.monster,
    required this.heroPower,
    required this.heroMaxHp,
    required this.profession,
    required this.heroName,
    required this.heroRealm,
    required this.heroIsFemale,
    required this.heroXp,
    required this.dungeonName,
    required this.xpLabel,
    required this.xpRatio,
    this.heroCostume,
    this.active = true,
    required this.onMonsterKilled,
    required this.onMinionKilled,
    required this.onHeroStrike,
    required this.onOpenShop,
    required this.onOpenTasks,
    required this.onOpenProfile,
    required this.onOpenFunctions,
    required this.onOpenAnnounce,
    this.manualCastRequest,
  });

  /// 当前妖兽（BOSS）。
  final GameMonster monster;

  /// 道友战力。
  final int heroPower;

  /// 道友满血。
  final int heroMaxHp;

  /// 道友职业（天道/逍遥/金刚），决定大招表。
  final String profession;

  /// 道友名字（创建时起的名字，不加数字后缀，头顶飘这个名）。
  final String heroName;

  /// 道友境界名（头顶飘，如“筑基后期”）。
  final String heroRealm;

  /// 道友性别（人物立绘用）。
  final bool heroIsFemale;

  /// 道友总修为（队友境界按它 + 偏移算）。
  final int heroXp;

  /// 副本名（右上黑面板第一行，如“血色禁地”）。
  final String dungeonName;

  /// 修为进度文案（右下角，如“筑基后期 1250/3000”）。
  final String xpLabel;

  /// 修为进度（0..1，右下角金条）。
  final double xpRatio;

  /// 道友服饰（创建时选的；不传用默认青色道袍）。
  final CultivationCostume? heroCostume;

  /// 是否当前可见 tab（切走时停自动战斗与音效）。
  final bool active;

  /// 妖兽被击杀。
  final VoidCallback onMonsterKilled;

  /// 一只小怪被击杀（父级按这只怪自己的表结算修为 / 元宝 /
  /// 掉落，走原来 [GameService.killMonster] 那套）。
  final ValueChanged<GameMonster> onMinionKilled;

  /// 道友出招命中一次。
  final ValueChanged<BattleStrike> onHeroStrike;

  /// 药品标签 → 打开商城/药品。
  final VoidCallback onOpenShop;

  /// 目标标签 → 打开任务。
  final VoidCallback onOpenTasks;

  /// 状态标签 → 打开人物状态。
  final VoidCallback onOpenProfile;

  /// 功能按钮 → 打开功能菜单。
  final VoidCallback onOpenFunctions;

  /// 喇叭 → 打开公告。
  final VoidCallback onOpenAnnounce;

  /// 主页技能圆盘点过来的手动施放请求（技能 id；舞台消费后
  /// 把值清回空）。主页点技能时先切进战场再由这路施放，走
  /// 的还是 [_castSkill] 那条现有施放路径，不另造数值。
  final ValueNotifier<String?>? manualCastRequest;

  @override
  State<GameBattleStage> createState() => _GameBattleStageState();
}

class _GameBattleStageState extends State<GameBattleStage>
    with TickerProviderStateMixin {
  late int _monsterHp;
  late int _heroHp;

  /// 灵力（蓝条，0..100）：放技能扣 8，自动回 3/秒。
  double _spirit = 100;

  Timer? _tickTimer;
  Timer? _bannerTimer;
  Timer? _toastTimer;
  // 寻路 1.4 秒收尾定时器：原来是裸 Future.delayed，dispose 时
  // 取消不掉，widget 测试体末 _verifyInvariants 报 Timer 仍挂起；
  // 改存 Timer，dispose 与重寻路时都取消。
  Timer? _seekTimer;
  DateTime _fightStart = DateTime.now();
  DateTime _lastBasicAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 各技能冷却好时间（自动放：冷却好了就放）。
  final Map<String, DateTime> _skillReadyAt = {};

  /// 队友上次出招时间。
  final Map<String, DateTime> _botLastStrikeAt = {};

  /// 寻路阶段：true 还在往 BOSS 身边走，false 贴身开打。
  bool _seeking = true;

  /// 寻路代次（防旧的延时回调把新一局的寻路提前清掉）。
  int _seekToken = 0;
  int _hitCount = 0;
  bool _heroFlash = false;
  bool _monsterDying = false;
  bool _slashArcShowing = false;

  /// 御剑剑光（亮剑光从道友处斜劈向 BOSS）：只做特效，不结算
  /// 伤害；伤害仍走飞剑法宝命中那路的 [_applyDamage] 与飘字。
  _BeamSlash? _beamSlash;

  /// 剑光落到 BOSS 身上那一下，怪闪一下（只闪剑光命中这一瞬；
  /// 普攻命中仍只靠飘字 + 爆裂星光，不加半透明）。
  bool _monsterFlash = false;

  /// 斩弧落点（普攻打小怪时落在那只小怪身上，打 BOSS 时
  /// 落在 BOSS 身上）。
  Offset _slashCenter = Offset.zero;
  bool _impactFlash = false;
  bool _autoBattle = true;
  String? _ultBanner;
  String? _toast;

  final List<_Floater> _floaters = [];
  int _floaterId = 0;

  /// 飞行中的法宝 / 法术（飞剑、辟邪神雷、乾蓝冰焰）。
  final List<_Projectile> _projectiles = [];
  int _projectileId = 0;

  /// 一次性特效（紫漩涡、红爆炸、金闪光、金环）。
  final List<_Burst> _bursts = [];
  int _burstId = 0;

  /// 战场上的小怪（14 只铺满全场，见 [_makeMinions]）。
  late List<_Minion> _minions;

  /// 小怪重刷定时器（按槽位记，换章 / 销毁时全取消）。
  final Map<int, Timer> _minionRespawnTimers = {};

  /// 小怪布阵代次（防旧的死亡回调把新一章的小怪结算掉）。
  int _minionGeneration = 0;

  late final AnimationController _lunge;
  late final AnimationController _shake;

  /// 妖兽扑咬的前冲。
  late final AnimationController _monsterLunge;

  /// 走位：半弧小队左右踱步的慢动画（道友与妖兽反相）。
  late final AnimationController _walk;

  /// 寻路：从出生点走到半弧站位（1.4 秒缓动）。
  late final AnimationController _seek;

  /// 大招金色螺旋光环（1.6 秒旋转淡出）。
  late final AnimationController _halo;

  /// 小怪走动（6 秒循环，位置由时间函数算）。
  late final AnimationController _minionWander;

  /// 高阶（战力 >= 1500）看法宝法术对轰，低阶看身法近身突袭。
  bool get _isHighTier => widget.heroPower >= 1500;

  /// 当前场景尺寸（build 里记下，飘字与法宝落点用）。
  Size _arenaSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _monsterHp = widget.monster.hp;
    _heroHp = widget.heroMaxHp;
    _minions = _makeMinions();
    _lunge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _monsterLunge = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _walk = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _seek = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _halo = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _minionWander = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    widget.manualCastRequest?.addListener(_onManualCastRequest);
    _startSeeking();
    _startTick();
  }

  /// 战场小怪一共 14 只（铺满全场，够打）：
  /// 数值用妖兽表里本章战力及以下的怪（蛟 / 蛟王是 BOSS，
  /// 不进小怪池），同章每次进场是同一套怪、同一批位置
  /// （种子取章节怪 id 各字符码求和，不会每进一次就乱变）；
  /// 图按槽位轮着用金光蟒 / 紫电妖狼 / 赤焰火虎 / 金刚巨猿
  /// 四张（槽位 i 用 gameMonsterCommonArts[i % 4]），四种
  /// 从第一章起就全在场上；位置用带排除的随机采样：避开
  /// 右上副本面板、避开 BOSS 身边、互相之间不重叠。
  static const int _minionCount = 14;

  List<_Minion> _makeMinions() {
    final seed = widget.monster.id.codeUnits.fold(0, (sum, unit) => sum + unit);
    final random = math.Random(seed);
    final templates = _minionTemplates();
    final made = <_Minion>[];
    for (var i = 0; i < _minionCount; i++) {
      final (x, y) = _sampleMinionSpot(random, made);
      made.add(
        _Minion(
          index: i,
          monster:
              templates[(i + random.nextInt(templates.length)) %
                  templates.length],
          art: gameMonsterCommonArts[i % gameMonsterCommonArts.length],
          baseX: x,
          baseY: y,
          phase: random.nextDouble() * math.pi * 2,
          speed: 0.5 + random.nextDouble() * 0.8,
        ),
      );
    }
    return made;
  }

  /// 小怪数值池：妖兽表里战力不超过本章怪、且不是蛟 /
  /// 蛟王的怪（小怪必须打得动，不能比章节怪还硬）。
  List<GameMonster> _minionTemplates() {
    final cap = widget.monster.power;
    final list = gameMonsters
        .where(
          (monster) =>
              monster.kind != GameMonsterKind.jiao &&
              monster.kind != GameMonsterKind.king &&
              monster.power <= cap,
        )
        .toList();
    return list.isEmpty ? [gameMonsters.first] : list;
  }

  /// 采一个小怪落点：石台带 y 0.20..0.58、x 0.07..0.93；
  /// 避开右上副本面板（x > 0.54 且 y < 0.30）、避开 BOSS
  /// 身边 0.13、与已布好的小怪之间不小于 0.13（y 按 1.4
  /// 加权，屏是竖的）；40 次采不到就放一个保底点。
  (double, double) _sampleMinionSpot(math.Random random, List<_Minion> others) {
    for (var attempt = 0; attempt < 40; attempt++) {
      final x = 0.07 + random.nextDouble() * 0.86;
      final y = 0.20 + random.nextDouble() * 0.38;
      if (x > 0.54 && y < 0.30) continue;
      final dBoss = math.sqrt(
        math.pow(x - 0.5, 2) + math.pow((y - 0.30) * 1.4, 2),
      );
      if (dBoss < 0.13) continue;
      var ok = true;
      for (final other in others) {
        if (other.dying) continue;
        final dx = x - other.baseX;
        final dy = (y - other.baseY) * 1.4;
        if (math.sqrt(dx * dx + dy * dy) < 0.13) {
          ok = false;
          break;
        }
      }
      if (ok) return (x, y);
    }
    return (
      0.10 + random.nextDouble() * 0.80,
      0.24 + random.nextDouble() * 0.30,
    );
  }

  /// 换章：小怪池（战力上限）变了，整批小怪重布；
  /// 旧的死亡 / 重刷回调用代次拦住，不结算旧怪。
  void _resetMinions() {
    _minionGeneration++;
    for (final timer in _minionRespawnTimers.values) {
      timer.cancel();
    }
    _minionRespawnTimers.clear();
    _minions = _makeMinions();
  }

  /// 一只小怪死后重刷：换一张表里的怪（同池随机）、
  /// 换一个新落点、满血，图仍按槽位轮四张。
  void _respawnMinion(int index) {
    final minion = _minions[index];
    if (!minion.dying) return;
    final random = math.Random(DateTime.now().microsecondsSinceEpoch ^ index);
    final templates = _minionTemplates();
    final others = _minions.where((m) => m.index != index).toList();
    final (x, y) = _sampleMinionSpot(random, others);
    setState(() {
      minion.monster = templates[random.nextInt(templates.length)];
      minion.art = gameMonsterCommonArts[index % gameMonsterCommonArts.length];
      minion.hp = minion.monster.hp;
      minion.baseX = x;
      minion.baseY = y;
      minion.phase = random.nextDouble() * math.pi * 2;
      minion.speed = 0.5 + random.nextDouble() * 0.8;
      minion.dying = false;
      minion.diedAt = null;
    });
  }

  /// 离主角最近的活小怪（普攻目标）；没有活小怪时
  /// 返回 null，主角改打 BOSS。
  _Minion? _nearestMinion() {
    _Minion? best;
    var bestDist = double.infinity;
    for (final minion in _minions) {
      if (minion.dying) continue;
      final dx = minion.baseX - 0.5;
      final dy = (minion.baseY - 0.49) * 1.4;
      final dist = dx * dx + dy * dy;
      if (dist < bestDist) {
        bestDist = dist;
        best = minion;
      }
    }
    return best;
  }

  /// 某只小怪当前在屏上的中心点（走动漂移算进去，
  /// 法宝落点 / 飘字 / 斩弧都落这儿）。
  Offset _minionCenter(_Minion minion) {
    final wander =
        _minionWander.value * math.pi * 2 * minion.speed + minion.phase;
    final size = _arenaSize;
    return Offset(
      (minion.baseX + math.sin(wander) * 0.012) * size.width,
      (minion.baseY + math.cos(wander * 0.9) * 0.01) * size.height,
    );
  }

  @override
  void didUpdateWidget(GameBattleStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monster.id != widget.monster.id) {
      _monsterHp = widget.monster.hp;
      _monsterDying = false;
      _heroHp = widget.heroMaxHp;
      _fightStart = DateTime.now();
      _skillReadyAt.clear();
      _resetMinions();
      _startSeeking();
    }
    if (oldWidget.heroMaxHp != widget.heroMaxHp) {
      _heroHp = widget.heroMaxHp;
    }
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        _startTick();
      } else {
        _tickTimer?.cancel();
        _tickTimer = null;
      }
    }
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _bannerTimer?.cancel();
    _toastTimer?.cancel();
    _seekTimer?.cancel();
    for (final timer in _minionRespawnTimers.values) {
      timer.cancel();
    }
    _minionRespawnTimers.clear();
    _lunge.dispose();
    _shake.dispose();
    _monsterLunge.dispose();
    _walk.dispose();
    _seek.dispose();
    _halo.dispose();
    _minionWander.dispose();
    for (final projectile in _projectiles) {
      projectile.controller.dispose();
    }
    for (final floater in _floaters) {
      floater.controller.dispose();
    }
    for (final burst in _bursts) {
      burst.controller.dispose();
    }
    widget.manualCastRequest?.removeListener(_onManualCastRequest);
    _beamSlash?.controller.dispose();
    super.dispose();
  }

  /// 进副本：3 人小队从出生点自动寻路走到 BOSS 身边半弧站位。
  void _startSeeking() {
    _seeking = true;
    final token = ++_seekToken;
    _seek.forward(from: 0);
    _seekTimer?.cancel();
    _seekTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && token == _seekToken) {
        setState(() => _seeking = false);
      }
    });
  }

  /// 全自动战斗心跳（400ms）：普攻 1.6 秒一剑、技能冷却好了
  /// 自动放、队友轮着出招、灵力自动回、面板用时与冷却条刷新。
  void _startTick() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      if (mounted) setState(() {});
      if (!widget.active || !_autoBattle || _seeking || _monsterDying) {
        return;
      }
      _spirit = (_spirit + 1.2).clamp(0.0, 100.0);
      final now = DateTime.now();
      if (now.difference(_lastBasicAt).inMilliseconds >= 1600) {
        _heroStrike();
      }
      _autoCastSkills(now);
      for (final bot in gameTeamBots) {
        final last = _botLastStrikeAt[bot.name];
        final interval = bot.name == '紫灵' ? 2000 : 2400;
        if (last == null || now.difference(last).inMilliseconds >= interval) {
          _botLastStrikeAt[bot.name] = now;
          _botStrike(bot);
        }
      }
    });
  }

  /// 技能自动放：冷却好了就放，不用手点（绝招也自动放）。
  /// 优先级：惊蛰十二变 > 本职业招 > 辟邪神雷 / 乾蓝冰焰。
  void _autoCastSkills(DateTime now) {
    if (_spirit < 10) return;
    final ult = gameSkillsById('jingzhe');
    if (ult != null && _skillReady(ult.id, now)) {
      _castSkill(ult, const Duration(seconds: 20));
      return;
    }
    for (final skill in gameSkillsForProfession(widget.profession)) {
      if (skill.profession == '共用') continue;
      if (_skillReady(skill.id, now)) {
        _castSkill(skill, const Duration(seconds: 6));
        return;
      }
    }
    for (final id in ['bixie', 'qianlan']) {
      final skill = gameSkillsById(id);
      if (skill != null && _skillReady(skill.id, now)) {
        _castSkill(skill, const Duration(seconds: 8));
        return;
      }
    }
  }

  bool _skillReady(String skillId, DateTime now) {
    final readyAt = _skillReadyAt[skillId];
    return readyAt == null || !now.isBefore(readyAt);
  }

  /// 自动放一招：扣灵力、记冷却、玩法宝特效与音效、结算伤害。
  void _castSkill(GameSkill skill, Duration cooldown) {
    _skillReadyAt[skill.id] = DateTime.now().add(cooldown);
    _spirit = (_spirit - 8).clamp(0.0, 100.0);
    final random = math.Random();
    final isCrit = random.nextDouble() < 0.15;
    var damage =
        (widget.heroPower ~/ 8 + random.nextInt(widget.heroPower ~/ 8 + 1)) *
        3 ~/
        2;
    if (isCrit) damage *= 2;
    if (skill.id == 'jingzhe') {
      _ultStrike(skill, damage * 2, isCrit);
      return;
    }
    // 万剑归宗：满屏飞剑落下，单独走剑雨，不走单发。
    if (skill.id == 'wanjian') {
      unawaited(GameSoundService.instance.playSkill(skill.id));
      _swordRain(damage, isCrit);
      return;
    }
    final kind = switch (skill.id) {
      'bixie' => _ProjectileKind.lightning,
      'qianlan' || 'zhenmo' => _ProjectileKind.flame,
      'taiyang' => _ProjectileKind.lightning,
      _ => _ProjectileKind.sword,
    };
    // 御剑（青元剑诀）：亮剑光从道友处斜劈向 BOSS。
    if (skill.id == 'qingyuan') _fireBeamSlash();
    // 出招音效：辟邪神雷与惊蛰十二变走打雷音，其余走合成音
    // （见 [GameSoundService.playSkill]）。
    unawaited(GameSoundService.instance.playSkill(skill.id));
    if (skill.id == 'zhenmo') {
      _spawnBurst(_BurstKind.purpleVortex, _monsterCenter);
    }
    if (skill.id == 'taiyang') {
      _spawnBurst(_BurstKind.goldRing, _monsterCenter);
    }
    // 大庚剑阵：金色剑阵铺开 + 金环罩队。
    if (skill.id == 'dageng') {
      _spawnBurst(_BurstKind.swordArray, _monsterCenter);
      _halo.forward(from: 0);
    }
    // 乾蓝冰焰：命中炸开一团冰晶（冰晶爆开）。
    if (skill.id == 'qianlan') {
      _spawnBurst(_BurstKind.iceBlast, _monsterCenter);
    }
    // 辟邪神雷：命中三道闪电竖劈而下。
    if (skill.id == 'bixie') {
      _spawnBurst(_BurstKind.lightningStrike, _monsterCenter);
      _spawnBurst(
        _BurstKind.lightningStrike,
        _monsterCenter + const Offset(-40, 0),
      );
      _spawnBurst(
        _BurstKind.lightningStrike,
        _monsterCenter + const Offset(40, 0),
      );
    }
    _launchProjectile(
      kind,
      _heroCenter,
      () => _applyDamage(damage, isCrit: isCrit, skillName: skill.name),
    );
  }

  /// 主页技能圆盘点过来的手动施放请求：消费掉（清回空），
  /// 再走 [_manualCast]。
  void _onManualCastRequest() {
    final skillId = widget.manualCastRequest?.value;
    if (skillId == null) return;
    widget.manualCastRequest?.value = null;
    _manualCast(skillId);
  }

  /// 手动施放一招（主页技能圆盘点过来）：冷却与灵力门槛和
  /// 自动放同一套（惊蛰 20 秒 / 本职业招 6 秒 / 辟邪神雷与
  /// 乾蓝冰焰 8 秒，灵力要 10 以上），过了门槛就走
  /// [_castSkill] 那条现有施放路径；没过只给一句提示。
  void _manualCast(String skillId) {
    final skill = gameSkillsById(skillId);
    if (skill == null || _monsterDying || !mounted) return;
    final now = DateTime.now();
    if (!_skillReady(skill.id, now)) {
      _showToast('${skill.name}冷却中');
      return;
    }
    if (_spirit < 10) {
      _showToast('灵力不足');
      return;
    }
    final cooldown = switch (skill.id) {
      'jingzhe' => const Duration(seconds: 20),
      'bixie' || 'qianlan' => const Duration(seconds: 8),
      _ => const Duration(seconds: 6),
    };
    _castSkill(skill, cooldown);
  }

  /// 御剑剑光：亮剑光从道友处斜劈向目标（默认 BOSS；普攻打小怪
  /// 时劈向那只小怪）。450ms 伸出再淡出，落点星芒；劈中 BOSS
  /// 时怪闪一下 + 金闪光。只做特效，不结算伤害。
  void _fireBeamSlash({Offset? target, bool hitsBoss = true}) {
    if (!mounted || _arenaSize == Size.zero) return;
    _beamSlash?.controller.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    final beam = _BeamSlash(
      from: _heroCenter,
      to: target ?? _monsterCenter,
      controller: controller,
    );
    setState(() => _beamSlash = beam);
    // 剑光落到 BOSS 身上时怪闪一下 + 金闪光（约在飞剑法宝
    // 命中前后脚，不改伤害与飘字那路）；打小怪不闪 BOSS。
    if (hitsBoss) {
      Future<void>.delayed(const Duration(milliseconds: 340), () {
        if (!mounted || _beamSlash != beam) return;
        setState(() => _monsterFlash = true);
        _spawnBurst(_BurstKind.goldFlash, _monsterCenter);
        Future<void>.delayed(const Duration(milliseconds: 180), () {
          if (mounted) setState(() => _monsterFlash = false);
        });
      });
    }
    unawaited(
      controller.forward().then((_) {
        if (!mounted) return;
        if (_beamSlash == beam) setState(() => _beamSlash = null);
        controller.dispose();
      }),
    );
  }

  /// 万剑归宗：12 把飞剑从屏幕上方满屏落下，只最后一把结算
  /// 伤害，其余只看剑雨特效。
  void _swordRain(
    int damage,
    bool isCrit, {
    bool isUlt = false,
    String skillName = '',
  }) {
    final random = math.Random();
    for (var i = 0; i < 12; i++) {
      final isLast = i == 11;
      Future<void>.delayed(Duration(milliseconds: 70 * i), () {
        if (!mounted || _monsterDying) return;
        _launchProjectile(
          _ProjectileKind.sword,
          Offset(_arenaSize.width * (0.12 + random.nextDouble() * 0.76), -10),
          isLast
              ? () => _applyDamage(
                  damage,
                  isCrit: isCrit,
                  isUlt: isUlt,
                  skillName: skillName,
                )
              : null,
          dyOffset: random.nextDouble() * 40 - 20,
        );
      });
    }
  }

  /// 队友机器人出招：从队友站位发一枚小法宝，打中飘小伤害数字。
  void _botStrike(GameTeamBot bot) {
    if (_monsterDying || !mounted) return;
    final random = math.Random();
    final damage =
        (widget.heroPower * 0.25).round() +
        random.nextInt(widget.heroPower ~/ 10 + 1);
    final kind = bot.profession == '天道'
        ? _ProjectileKind.sword
        : _ProjectileKind.flame;
    if (random.nextDouble() < 0.3) {
      unawaited(GameSoundService.instance.playSword());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
    }
    _launchProjectile(
      kind,
      _botCenter(bot),
      () => _applyDamage(damage, isBot: true),
    );
  }

  /// 出手一次（普攻）：目标优先离主角最近的活小怪，
  /// 没活小怪才打 BOSS；低阶身法近身突袭，高阶法宝法术
  /// 对轰；每 4 击一次大招（完整动画：横幅 → 金环罩队 →
  /// 三波齐轰 → 中央白黄闪光收尾）。
  void _heroStrike() {
    if (_monsterDying || !mounted) return;
    _lastBasicAt = DateTime.now();
    _hitCount++;
    final isUlt = _hitCount % 4 == 0;
    final skills = gameSkillsForProfession(widget.profession);
    final skill = skills[(_hitCount ~/ 4) % skills.length];
    final random = math.Random();
    final isCrit = random.nextDouble() < 0.15;
    var damage =
        widget.heroPower ~/ 8 + random.nextInt(widget.heroPower ~/ 8 + 1);
    if (isUlt) damage *= 3;
    if (isCrit) damage *= 2;
    if (isUlt) {
      _ultStrike(skill, damage, isCrit);
      return;
    }
    // 普攻目标：最近的活小怪，没有就打 BOSS。
    final minion = _nearestMinion();
    final targetCenter = minion == null
        ? _monsterCenter
        : _minionCenter(minion);
    if (_isHighTier) {
      // 高阶：原地施法，法宝法术对轰——青竹蜂云剑剑雨、
      // 辟邪神雷、乾蓝冰焰轮着轰过去。
      const kinds = <_ProjectileKind>[
        _ProjectileKind.sword,
        _ProjectileKind.lightning,
        _ProjectileKind.flame,
      ];
      final kind = kinds[_hitCount % kinds.length];
      // 普攻飞剑（剑影分光）：亮剑光从道友处斜劈向当前目标
      // （最近的小怪，没有才打 BOSS；打小怪时 BOSS 不闪）。
      if (kind == _ProjectileKind.sword) {
        _fireBeamSlash(target: targetCenter, hitsBoss: minion == null);
      }
      _launchProjectile(
        kind,
        _heroCenter,
        () => _applyDamage(
          damage,
          isCrit: isCrit,
          minion: minion,
          targetCenter: targetCenter,
        ),
        target: targetCenter,
      );
      unawaited(GameSoundService.instance.playSword());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
    } else {
      // 低阶：身法走位近身突袭——快速前冲、贴身一斩、立刻撤回。
      _lunge.forward(from: 0);
      _slashCenter = targetCenter;
      setState(() => _slashArcShowing = true);
      unawaited(GameSoundService.instance.playSword());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
      Future<void>.delayed(const Duration(milliseconds: 280), () {
        if (!mounted || _monsterDying) return;
        setState(() => _slashArcShowing = false);
        _applyDamage(
          damage,
          isCrit: isCrit,
          minion: minion,
          targetCenter: targetCenter,
        );
      });
    }
  }

  /// 大招完整动画：金字横幅 → 巨大金色螺旋光环罩全队 →
  /// 三波法宝齐轰（每波命中结算一段伤害）→ 中央白黄闪光
  /// + 震屏收尾。不是瞬间结算。
  void _ultStrike(GameSkill skill, int damage, bool isCrit) {
    unawaited(GameSoundService.instance.playSkill(skill.id));
    _showUltBanner(skill.name);
    _halo.forward(from: 0);
    // 绝招：全屏大光效 + 震屏（开场先闪一下，350ms 后收）。
    setState(() => _impactFlash = true);
    _shake.forward(from: 0);
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _impactFlash = false);
    });
    // 万剑归宗当绝招：满屏剑雨。
    if (skill.id == 'wanjian') {
      _swordRain(damage, isCrit, isUlt: true, skillName: skill.name);
      return;
    }
    // 大庚剑阵当绝招：金色剑阵铺开。
    if (skill.id == 'dageng') {
      _spawnBurst(_BurstKind.swordArray, _monsterCenter);
    }
    final perWave = (damage / 3).ceil();
    // 大庚剑阵三波全是飞剑，其余三波剑 / 辟邪神雷 / 乾蓝冰焰轮着轰。
    final kinds = skill.id == 'dageng'
        ? const <_ProjectileKind>[_ProjectileKind.sword]
        : const <_ProjectileKind>[
            _ProjectileKind.sword,
            _ProjectileKind.lightning,
            _ProjectileKind.flame,
          ];
    for (var wave = 0; wave < 3; wave++) {
      final waveDamage = wave == 2 ? damage - perWave * 2 : perWave;
      Future<void>.delayed(Duration(milliseconds: 350 * wave), () {
        if (!mounted || _monsterDying) return;
        // 每波三枚法宝齐落（中间那枚结算伤害，另两枚只看特效）。
        for (var extra = -1; extra <= 1; extra++) {
          _launchProjectile(
            kinds[(wave + _hitCount) % kinds.length],
            _heroCenter,
            extra == 0
                ? () {
                    if (wave == 2) {
                      _spawnBurst(_BurstKind.goldFlash, _monsterCenter);
                      setState(() => _impactFlash = true);
                      _shake.forward(from: 0);
                      Future<void>.delayed(
                        const Duration(milliseconds: 220),
                        () {
                          if (mounted) {
                            setState(() => _impactFlash = false);
                          }
                        },
                      );
                    }
                    _applyDamage(
                      waveDamage,
                      isCrit: isCrit,
                      isUlt: true,
                      skillName: skill.name,
                    );
                  }
                : null,
            dyOffset: extra * 26,
          );
        }
      });
    }
  }

  /// 发一枚法宝 / 一道法术：从 from 处飞向目标（不传默认
  /// 打 BOSS），命中时结算（onImpact 为空时只看特效不结算，
  /// 大招齐轰时用）。
  void _launchProjectile(
    _ProjectileKind kind,
    Offset from,
    VoidCallback? onImpact, {
    double dyOffset = 0,
    Offset? target,
  }) {
    // 雷声：辟邪神雷 / 泰阳诀出招时放一声雷（playThunder 由另一路
    // 在 game_sound.dart 里补，方法名已对好，这里只管调）。
    if (kind == _ProjectileKind.lightning) {
      unawaited(GameSoundService.instance.playThunder());
    }
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    final projectile = _Projectile(
      id: _projectileId++,
      kind: kind,
      controller: controller,
      from: from,
      to: target ?? _monsterCenter,
      dyOffset: dyOffset,
    );
    setState(() => _projectiles.add(projectile));
    unawaited(
      controller.forward().then((_) {
        if (!mounted) return;
        setState(() => _projectiles.remove(projectile));
        controller.dispose();
        if (!_monsterDying) onImpact?.call();
      }),
    );
  }

  /// 派一个一次性特效（紫漩涡 / 红爆炸 / 金闪光 / 金环），
  /// 默认 700ms 播完即撤。
  void _spawnBurst(_BurstKind kind, Offset center) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    final burst = _Burst(
      id: _burstId++,
      kind: kind,
      center: center,
      controller: controller,
    );
    setState(() {
      _bursts.add(burst);
      if (_bursts.length > 5) {
        final old = _bursts.removeAt(0);
        old.controller.dispose();
      }
    });
    unawaited(
      controller.forward().then((_) {
        if (!mounted) return;
        // 播完才撤：还挂在列表里才 dispose；已被超量
        // 顶掉的（上面已 dispose 过）不再 dispose 第二次，
        // 否则 debug 下报 dispose() called more than once。
        if (_bursts.remove(burst)) {
          setState(() {});
          controller.dispose();
        }
      }),
    );
  }

  /// 一次命中结算：目标掉血、受击点飘橙黄伤害数字、音效、
  /// 暴击红爆炸 + 震屏。目标不传就是 BOSS；传了小怪就打
  /// 那只小怪（小怪不反咬，死后走 [_killMinion] 重刷）。
  /// 受击不加半透明（以前每中一剑 BOSS 就 0.6 闪一下，
  /// 看着发虚）：命中反馈只靠飘字 + 爆裂星光。
  void _applyDamage(
    int damage, {
    bool isCrit = false,
    bool isUlt = false,
    String skillName = '',
    bool isBot = false,
    _Minion? minion,
    Offset? targetCenter,
  }) {
    if (!mounted || _monsterDying) return;
    if (minion != null && minion.dying) return;
    final center = targetCenter ?? _monsterCenter;
    setState(() {
      if (minion != null) {
        minion.hp -= damage;
      } else {
        _monsterHp -= damage;
      }
    });
    if (isUlt) {
      // 大招音效已在出招时放过，这里只补命中音。
      unawaited(GameSoundService.instance.playHit());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
    } else if (isCrit) {
      // 暴击：红爆炸 + 金闪光 + 震屏，命中爆裂光加飘字。
      unawaited(GameSoundService.instance.playCrit());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
      _spawnBurst(_BurstKind.redBlast, center);
      _spawnBurst(_BurstKind.goldFlash, center);
      _shake.forward(from: 0);
    } else if (!isBot) {
      unawaited(GameSoundService.instance.playHit());
      // 刀剑拼杀音（另一路在 game_sound.dart 里加
      // playSwordClash，播 sword_clash.mp3）。
      unawaited(GameSoundService.instance.playSwordClash());
      // 普通命中也有白金爆裂星光。
      _spawnBurst(_BurstKind.hitSpark, center);
    } else {
      // 队友命中：也补一声刀剑拼杀音。
      unawaited(GameSoundService.instance.playSwordClash());
    }
    _addFloater(
      '-$damage',
      isCrit ? const Color(0xFFFFD54F) : const Color(0xFFFFB300),
      isCrit ? 24 : (isBot ? 12 : 18),
      anchor: center,
    );
    if (isCrit) _shake.forward(from: 0);
    if (!isBot) {
      widget.onHeroStrike(
        BattleStrike(
          damage: damage,
          isCrit: isCrit,
          isUlt: isUlt,
          skillName: skillName,
        ),
      );
    }
    if (minion != null) {
      if (minion.hp <= 0) _killMinion(minion);
      return;
    }
    if (_monsterHp <= 0) {
      _killMonster();
      return;
    }
    if (isBot) return;
    // 妖兽扑回来咬一口（前冲 + 撕咬）。
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || _monsterDying) return;
      _monsterLunge.forward(from: 0);
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!mounted || _monsterDying) return;
        final hurt =
            widget.monster.power ~/ 20 +
            math.Random().nextInt(widget.monster.power ~/ 20 + 1);
        setState(() {
          _heroHp -= hurt;
          _heroFlash = true;
        });
        _addFloater('-$hurt', const Color(0xFFEF5350), 13, anchor: _heroCenter);
        Future<void>.delayed(const Duration(milliseconds: 160), () {
          if (mounted) setState(() => _heroFlash = false);
        });
        if (_heroHp <= 0) {
          // 道友倒下不罚：重整旗鼓回满血，继续打。
          setState(() => _heroHp = widget.heroMaxHp);
          _showToast('重整旗鼓，继续战斗');
        }
      });
    });
  }

  void _killMonster() {
    setState(() => _monsterDying = true);
    unawaited(GameSoundService.instance.playMonsterCry());
    _spawnBurst(_BurstKind.redBlast, _monsterCenter);
    _spawnBurst(_BurstKind.goldFlash, _monsterCenter);
    Future<void>.delayed(const Duration(milliseconds: 680), () {
      if (!mounted) return;
      widget.onMonsterKilled();
      setState(() {
        _monsterHp = widget.monster.hp;
        _monsterDying = false;
      });
    });
  }

  /// 一只小怪被打死：红爆炸 + 金闪光，680ms 后按这只怪
  /// 自己的表结算（父级调 [GameService.killMonster]），
  /// 再过 1.2 秒在场上随机点重刷一只新的；换章时旧的
  /// 回调用代次拦住，不结算、不重刷。
  void _killMinion(_Minion minion) {
    final generation = _minionGeneration;
    setState(() {
      minion.dying = true;
      minion.diedAt = DateTime.now();
    });
    unawaited(GameSoundService.instance.playMonsterCry());
    final center = _minionCenter(minion);
    _spawnBurst(_BurstKind.redBlast, center);
    _spawnBurst(_BurstKind.goldFlash, center);
    Future<void>.delayed(const Duration(milliseconds: 680), () {
      if (!mounted || generation != _minionGeneration) return;
      widget.onMinionKilled(minion.monster);
      final timer = Timer(const Duration(milliseconds: 1200), () {
        if (!mounted || generation != _minionGeneration) return;
        _respawnMinion(minion.index);
      });
      _minionRespawnTimers[minion.index] = timer;
    });
  }

  void _showUltBanner(String skillName) {
    _bannerTimer?.cancel();
    setState(() => _ultBanner = skillName);
    _bannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _ultBanner = null);
    });
  }

  /// 中央小提示（2 秒消失）。
  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  /// 伤害数字：橙黄粗体带黑边，从受击点向上飘，多个同时错开。
  void _addFloater(String text, Color color, double size, {Offset? anchor}) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    final random = math.Random();
    final floater = _Floater(
      id: _floaterId++,
      text: text,
      color: color,
      size: size,
      anchor:
          (anchor ?? _monsterCenter) +
          Offset(random.nextDouble() * 28 - 14, random.nextDouble() * 10 - 5),
      controller: controller,
    );
    setState(() {
      _floaters.add(floater);
      if (_floaters.length > 8) {
        final old = _floaters.removeAt(0);
        old.controller.dispose();
      }
    });
    unawaited(
      controller.forward().then((_) {
        if (!mounted) return;
        // 同 _spawnBurst：已被超量顶掉的已 dispose 过，
        // 不再 dispose 第二次。
        if (_floaters.remove(floater)) {
          setState(() {});
          floater.controller.dispose();
        }
      }),
    );
  }

  // ---------- 站位（斜俯视 45 度场景里的点位） ----------

  double get _topPad => MediaQuery.paddingOf(context).top;
  double get _bottomPad => MediaQuery.paddingOf(context).bottom;

  /// 道友立绘宽高（人物很小，只占画面高度约十分之一，
  /// 照网页版改小那轮：主角 46 宽）。
  static const double _heroW = 46;
  static const double _heroH = 58;

  /// 队友立绘宽高（照网页版改小那轮：队友 38 宽）。
  static const double _botW = 38;
  static const double _botH = 48;

  /// BOSS 立绘宽（全幅原图比例，高 = 宽 × 732 / 360 ≈ 195，
  /// 整幅显示不裁切；以前 120×140 的框裁掉了怪的头尾）。
  static const double _bossW = 96;

  /// 普通章节怪立绘宽（全幅原图比例，高 ≈ 163）。
  static const double _monsterW = 80;

  /// 小怪立绘宽（全幅原图比例，高 ≈ 122）。
  static const double _minionW = 60;

  /// 头顶名牌栏宽（比立绘宽，名字才放得下不截断；
  /// 三人名牌各隔 0.26 屏宽，96 宽不互相压叠）。
  static const double _nameTagW = 96;

  /// 寻路缓动（0 出生点 → 1 半弧站位）。
  double get _seekT {
    final t = _seek.value;
    return 1 - math.pow(1 - t, 3).toDouble();
  }

  /// BOSS 中心点（居中偏上，站在圆形石台远端；
  /// 全幅图高了，中心再往上挪一点，脚不压主角名牌；
  /// 怪站着不动，不左右摇摆——以前每 3 秒一个来回的
  /// 正弦摇摆让怪看着发飘）。
  Offset get _monsterCenter {
    final size = _arenaSize;
    final lunge = -_monsterLunge.value * 12;
    final heightRatio = gameMonsterArtIsBoss(widget.monster) ? 0.29 : 0.31;
    return Offset(size.width * 0.5 + lunge, size.height * heightRatio);
  }

  /// 道友中心点（半弧正下方；寻路时从出生点走上来）。
  Offset get _heroCenter {
    final size = _arenaSize;
    final walk = math.sin(_walk.value * math.pi * 2) * 3;
    final lunge = _lunge.value * 12;
    final arc = Offset(size.width * 0.5 + walk + lunge, size.height * 0.49);
    final spawn = Offset(size.width * 0.5 + walk, size.height * 0.86);
    return Offset.lerp(spawn, arc, _seekT)!;
  }

  /// 某队友中心点（半弧左右两边；寻路时从出生点走上来）。
  Offset _botCenter(GameTeamBot bot) {
    final size = _arenaSize;
    final index = gameTeamBots.indexOf(bot);
    final side = index == 0 ? -1.0 : 1.0;
    final walk = math.sin(_walk.value * math.pi * 2 + index * 2.1) * 3;
    final arc = Offset(
      size.width * 0.5 + side * size.width * 0.26 + walk,
      size.height * 0.44,
    );
    final spawn = Offset(
      size.width * 0.5 + side * size.width * 0.30,
      size.height * 0.86,
    );
    return Offset.lerp(spawn, arc, _seekT)!;
  }

  /// 队友境界名（道友总修为 + 偏移算，看着像水平接近的真人）。
  String _botRealm(GameTeamBot bot) =>
      realmForXp(widget.heroXp + bot.xpOffset).displayName;

  /// 用时（从进这个 BOSS 起算，mm:ss）。
  String get _fightClock {
    final seconds = DateTime.now().difference(_fightStart).inSeconds;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final monster = widget.monster;
    return LayoutBuilder(
      builder: (context, constraints) {
        _arenaSize = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          // 点一下战场亲手补一剑（全自动照常跑，点按只是加一剑）。
          onTap: _heroStrike,
          behavior: HitTestBehavior.opaque,
          child: Container(
            color: const Color(0xFF0D0A24),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 浮空仙山战场背景：仙门牌坊 + 云海 + 圆形石台，
                // 人物和怪物站在石台上打（石台约在图高 52% 处）。
                Positioned.fill(
                  child: Image.asset(
                    _battlefieldBgAsset,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  ),
                ),
                // 底部渐隐到深色：技能钮与命条 / 灵条压在上面才看得清。
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          const Color(0xFF0D0A24).withValues(alpha: 0.55),
                          const Color(0xFF0D0A24).withValues(alpha: 0.85),
                        ],
                        stops: const [0.0, 0.55, 0.8, 1.0],
                      ),
                    ),
                  ),
                ),
                // 14 只小怪（铺满全场，位置随走动轻微漂移）。
                AnimatedBuilder(
                  animation: _minionWander,
                  builder: (context, _) => Positioned.fill(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final minion in _minions) _buildMinion(minion),
                      ],
                    ),
                  ),
                ),
                // 震屏：整场左右轻晃（HUD 按钮不动）。
                AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    final t = _shake.value;
                    final dx = t == 0
                        ? 0.0
                        : math.sin(t * math.pi * 6) * 4 * (1 - t);
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: child,
                    );
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 走位 / 冲锋 / 寻路是动画值驱动的站位，每帧重算。
                      AnimatedBuilder(
                        animation: Listenable.merge([_walk, _lunge, _seek]),
                        builder: (context, _) => _buildHero(),
                      ),
                      for (final bot in gameTeamBots)
                        AnimatedBuilder(
                          animation: Listenable.merge([_walk, _seek]),
                          builder: (context, _) => _buildBot(bot),
                        ),
                      AnimatedBuilder(
                        animation: Listenable.merge([_walk, _monsterLunge]),
                        builder: (context, _) => _buildBoss(monster),
                      ),
                      if (_slashArcShowing) _buildSlashArc(),
                      ..._projectiles.map(_buildProjectile),
                      ..._bursts.map(_buildBurst),
                      // 御剑剑光（亮剑光从道友处斜劈向 BOSS）。
                      if (_beamSlash != null) _buildBeamSlash(_beamSlash!),
                      ..._floaters.map(_buildFloater),
                    ],
                  ),
                ),
                // 大招金色螺旋光环（罩全队；t==0 时透明，不占视觉）。
                AnimatedBuilder(
                  animation: _halo,
                  builder: (context, _) {
                    final t = _halo.value;
                    return Positioned(
                      left: _arenaSize.width / 2 - 190,
                      top: _arenaSize.height * 0.27 - 125,
                      width: 380,
                      height: 380,
                      child: Opacity(
                        opacity: t == 0 ? 0 : (1 - t) * 0.9,
                        child: CustomPaint(
                          painter: _GoldHaloPainter(rotation: t * math.pi * 2),
                        ),
                      ),
                    );
                  },
                ),
                // 右上副本面板：副本名、击败 BOSS 0/1、用时。
                _buildDungeonPanel(monster),
                // 顶部 BOSS 血条：名 + 红色血条 + 真实血量，贴在
                // 游戏顶栏下方，左边这条、右边副本面板，不重叠。
                _buildBossHpBar(),
                // 中央金字：自动寻路中… / 自动战斗中…（移到 62% 处，
                // 避开小队头顶的名牌）。
                Positioned(
                  top: _arenaSize.height * 0.62,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Text(
                      _seeking ? '自动寻路中…' : '自动战斗中…',
                      style: const TextStyle(
                        color: Color(0xFFFFD54F),
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                      ),
                    ),
                  ),
                ),
                // 大招金字横幅（移到 68% 处，避开“自动战斗中…”）。
                if (_ultBanner != null)
                  Positioned(
                    top: _arenaSize.height * 0.68,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.amber.shade700.withValues(alpha: 0.9),
                              Colors.amber.shade400.withValues(alpha: 0.9),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.amber.withValues(alpha: 0.5),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Text(
                          _ultBanner!,
                          style: const TextStyle(
                            color: Color(0xFF2A1A00),
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 4,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 最后一击白闪。
                if (_impactFlash)
                  Positioned.fill(
                    child: Container(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                // 中央小提示（移到 74% 处，避开大招横幅）。
                if (_toast != null)
                  Positioned(
                    top: _arenaSize.height * 0.74,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _toast!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 右侧中部黑色箭头标签列：和平 / 状态 / 药品 / 目标。
                _buildSideTags(),
                // 左下金色竖排书法章节标题 + 红色小印章。
                _buildChapterTitle(),
                // 左下黑菱形：喇叭、绝招、自动。
                _buildBottomLeftDiamonds(),
                // 右下横排圆形蓝光符文技能钮（只做冷却展示，自动放）。
                _buildSkillDiamonds(),
                // 底部红命条蓝灵条 + 右下角修为进度。
                _buildBottomBars(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 右上副本面板（半透明黑）：副本名、击败 BOSS 0/1、用时。
  /// 顶栏现在是两排（头像行 + 菱形功能图标行），面板顶到
  /// _topPad + 118 才不撞第二排图标。
  Widget _buildDungeonPanel(GameMonster monster) {
    final killed = _monsterDying || _monsterHp <= 0;
    return Positioned(
      top: _topPad + 118,
      right: 12,
      width: 172,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.dungeonName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '击败${monster.name} ${killed ? 1 : 0}/1',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              '用时 $_fightClock',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部 BOSS 血条：名 + 红色血条 + 真实血量（当前血 / 满血）。
  /// 贴在游戏顶栏下方：左边这条、右边是副本面板（右 196 起），
  /// 两条并排不重叠。
  Widget _buildBossHpBar() {
    final monster = widget.monster;
    return Positioned(
      top: _topPad + 118,
      left: 12,
      right: 196,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${monster.name} · BOSS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$_monsterHp/${monster.hp}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (context, constraints) {
                return _HpBar(
                  ratio: (_monsterHp / monster.hp).clamp(0.0, 1.0),
                  width: constraints.maxWidth,
                  color: const Color(0xFFE53935),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 道友：头顶小白字“境界+名字”紧贴头顶，脚下有影子。
  /// 名牌栏比立绘宽（96），名字放得下不截断，三人名牌互不压叠。
  Widget _buildHero() {
    final center = _heroCenter;
    return Positioned(
      left: center.dx - _nameTagW / 2,
      top: center.dy - _heroH / 2 - 14,
      width: _nameTagW,
      child: Opacity(
        opacity: _heroFlash ? 0.55 : 1.0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NameTag(text: '${widget.heroRealm} ${widget.heroName}'),
            const SizedBox(height: 2),
            _FighterFigure(
              width: _heroW,
              height: _heroH,
              child: GameHeroPortrait(
                isFemale: widget.heroIsFemale,
                size: _heroW,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 队友机器人：名字衣服武器各不一样，头顶“境界+名字”
  /// （不喊话，喊话气泡已删）。
  Widget _buildBot(GameTeamBot bot) {
    final center = _botCenter(bot);
    return Positioned(
      left: center.dx - _nameTagW / 2,
      top: center.dy - _botH / 2 - 14,
      width: _nameTagW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _NameTag(text: '${_botRealm(bot)} ${bot.name}'),
          const SizedBox(height: 2),
          _FighterFigure(
            width: _botW,
            height: _botH,
            child: GameHeroPortrait(isFemale: bot.isFemale, size: _botW),
          ),
        ],
      ),
    );
  }

  /// 一只小怪：头顶小血条 + 全幅野兽图（60×122，原图比例，
  /// 不裁切不拉伸不加半透明）；死时不淡出，只往下沉一点，
  /// 红爆炸 + 金闪光已经说明它死了。
  Widget _buildMinion(_Minion minion) {
    final center = _minionCenter(minion);
    const width = _minionW;
    final height = width / gameMonsterArtAspect;
    return Positioned(
      left: center.dx - width / 2,
      top: center.dy - height / 2 - 8,
      width: width,
      child: Transform.translate(
        offset: Offset(0, minion.dying ? 14 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HpBar(
              ratio: (minion.hp / minion.monster.hp).clamp(0.0, 1.0),
              width: 44,
              color: const Color(0xFFE53935),
            ),
            const SizedBox(height: 2),
            _FighterFigure(
              width: width,
              height: height,
              child: GameMonsterArt(
                monster: minion.monster,
                width: width,
                artOverride: minion.art,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// BOSS：居中偏上，头顶只有小血条（名字在右上副本面板里）。
  /// 全幅原图按原比例显示，不裁切、不拉伸、不加半透明：
  /// 受击不再 0.6 闪一下，死时不再 0.25 淡出（只往下沉 20），
  /// 命中反馈只靠飘字 + 爆裂星光，怪全程实实在在站在石台上。
  /// 只有御剑剑光劈中那一下例外：怪闪一下（见 [_monsterFlash]）。
  Widget _buildBoss(GameMonster monster) {
    final center = _monsterCenter;
    // 首领（蛟 / 蛟王）用墨蛟图，全幅 96×195；普通章节怪
    // 全幅 80×163。
    final isBoss = gameMonsterArtIsBoss(monster);
    final width = isBoss ? _bossW : _monsterW;
    final height = width / gameMonsterArtAspect;
    return Positioned(
      left: center.dx - width / 2,
      top: center.dy - height / 2 - 8,
      width: width,
      child: Transform.translate(
        offset: Offset(0, _monsterDying ? 20 : 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HpBar(
              ratio: (_monsterHp / monster.hp).clamp(0.0, 1.0),
              width: 70,
              color: const Color(0xFFE53935),
            ),
            const SizedBox(height: 2),
            Opacity(
              // 剑光劈中那一下怪闪一下（平时不受击闪，见上面注释）。
              opacity: _monsterFlash ? 0.55 : 1.0,
              child: _FighterFigure(
                width: width,
                height: height,
                child: GameMonsterArt(monster: monster, width: width),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 低阶近身突袭的贴身斩弧（落在当前目标——小怪或 BOSS 身上）。
  Widget _buildSlashArc() {
    final center = _slashCenter;
    return Positioned(
      left: center.dx - 58,
      top: center.dy - 58,
      width: 116,
      height: 116,
      child: const CustomPaint(painter: _SlashPainter()),
    );
  }

  /// 御剑剑光：亮剑光从道友处斜劈向目标，铺满整个战场画。
  Widget _buildBeamSlash(_BeamSlash beam) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: beam.controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _BeamSlashPainter(
              from: beam.from,
              to: beam.to,
              progress: beam.controller.value,
            ),
          );
        },
      ),
    );
  }

  /// 一枚飞行中的法宝 / 一道法术（带弧线飞过去）。
  Widget _buildProjectile(_Projectile projectile) {
    return AnimatedBuilder(
      animation: projectile.controller,
      builder: (context, _) {
        final t = projectile.controller.value;
        final from = projectile.from;
        final to = projectile.to;
        final x = from.dx + (to.dx - from.dx) * t;
        final y =
            from.dy +
            (to.dy - from.dy) * t -
            math.sin(t * math.pi) * 30 +
            projectile.dyOffset * (1 - t);
        // 飞行方向：对弧线轨迹求导，剑尖始终朝向飞行方向
        // （剑雨从天落下时剑尖朝下，从主角飞出时剑尖朝怪）。
        final dx = to.dx - from.dx;
        final dy =
            (to.dy - from.dy) -
            30 * math.pi * math.cos(t * math.pi) -
            projectile.dyOffset;
        final angle = math.atan2(dy, dx);
        // 真飞剑 110x28（带拖尾），辟邪神雷从天劈下（56x120 竖着），
        // 乾蓝冰焰是蓝白冰火球（64x40，沿飞行方向转）。
        final (w, h) = switch (projectile.kind) {
          _ProjectileKind.sword => (110.0, 28.0),
          _ProjectileKind.lightning => (56.0, 120.0),
          _ProjectileKind.flame => (64.0, 40.0),
        };
        return Positioned(
          left: x - w / 2,
          top: y - h / 2,
          width: w,
          height: h,
          child: switch (projectile.kind) {
            _ProjectileKind.sword => _SwordMissile(angle: angle),
            _ProjectileKind.lightning => const CustomPaint(
              size: Size(56, 120),
              painter: _LightningPainter(),
            ),
            _ProjectileKind.flame => _FlameMissile(angle: angle),
          },
        );
      },
    );
  }

  /// 一次性特效（紫漩涡 / 红爆炸 / 金闪光 / 金环）。
  /// 竖劈闪电是 56x120，其余仍按进度从 60 长到 150。
  Widget _buildBurst(_Burst burst) {
    return AnimatedBuilder(
      animation: burst.controller,
      builder: (context, _) {
        final t = burst.controller.value;
        final (w, h) = switch (burst.kind) {
          _BurstKind.lightningStrike => (56.0, 120.0),
          _ => (60 + t * 90, 60 + t * 90),
        };
        return Positioned(
          left: burst.center.dx - w / 2,
          top: burst.center.dy - h / 2,
          width: w,
          height: h,
          child: Opacity(
            opacity: 1 - t,
            child: switch (burst.kind) {
              _BurstKind.purpleVortex => CustomPaint(
                painter: _VortexPainter(rotation: t * math.pi * 2),
              ),
              _BurstKind.redBlast => Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.red.withValues(alpha: 0.85),
                      Colors.orange.withValues(alpha: 0.4),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              _BurstKind.goldFlash => Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Color(0xFFFFFFFF),
                      Color(0xFFFFD54F),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              _BurstKind.goldRing => Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFFFD54F), width: 3),
                ),
              ),
              _BurstKind.iceBlast => CustomPaint(
                painter: _IceBlastPainter(progress: t),
              ),
              _BurstKind.lightningStrike => const CustomPaint(
                size: Size(56, 120),
                painter: _LightningPainter(),
              ),
              _BurstKind.swordArray => CustomPaint(
                painter: _SwordArrayPainter(progress: t),
              ),
              _BurstKind.hitSpark => CustomPaint(
                painter: _SparkPainter(progress: t),
              ),
            },
          ),
        );
      },
    );
  }

  /// 伤害数字：橙黄粗体带黑边，从受击点向上飘，多个同时错开。
  Widget _buildFloater(_Floater floater) {
    return AnimatedBuilder(
      animation: floater.controller,
      builder: (context, _) {
        final t = floater.controller.value;
        final anchor = floater.anchor;
        return Positioned(
          left: anchor.dx - 50,
          top: anchor.dy - 40 - 46 * t,
          width: 100,
          child: Opacity(
            opacity: 1 - t,
            child: Text(
              floater.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: floater.color,
                fontSize: floater.size,
                fontWeight: FontWeight.w900,
                shadows: const [
                  Shadow(color: Colors.black, offset: Offset(1, 1)),
                  Shadow(color: Colors.black, offset: Offset(-1, 1)),
                  Shadow(color: Colors.black, offset: Offset(1, -1)),
                  Shadow(color: Colors.black, offset: Offset(-1, -1)),
                  Shadow(color: Colors.black87, blurRadius: 4),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 右侧中部黑色箭头标签列：和平 / 状态 / 药品 / 目标，
  /// 下面黑色“功能”按钮。
  Widget _buildSideTags() {
    return Positioned(
      right: 0,
      top: _arenaSize.height * 0.40,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _ArrowTag(label: '和平', onTap: () => _showToast('单机模式：和平')),
          const SizedBox(height: 6),
          _ArrowTag(label: '状态', onTap: widget.onOpenProfile),
          const SizedBox(height: 6),
          _ArrowTag(label: '药品', onTap: widget.onOpenShop),
          const SizedBox(height: 6),
          _ArrowTag(label: '目标', onTap: widget.onOpenTasks),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: widget.onOpenFunctions,
            child: Container(
              width: 56,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomLeft: Radius.circular(6),
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
              ),
              child: const Text(
                '功能',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 左下金色竖排书法章节标题 + 红色小印章（人界篇式）：
  /// 地图（副本名）+ 境界前两字竖排，如“天南大陆·炼气”，
  /// 印章一个字取境界首字（炼 / 筑 / 丹 / 婴…）；
  /// 地图推进或境界突破，标题与印章都自动换。
  Widget _buildChapterTitle() {
    final realm = widget.heroRealm;
    final realmShort2 = realm.length >= 2 ? realm.substring(0, 2) : realm;
    final title = '${widget.dungeonName}·$realmShort2';
    final seal = realm.isNotEmpty ? realm[0] : '道';
    return Positioned(
      left: 10,
      bottom: _bottomPad + 118,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ch in title.split(''))
                Text(
                  ch,
                  style: const TextStyle(
                    color: Color(0xFFFFD54F),
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                    shadows: [
                      Shadow(color: Colors.black87, blurRadius: 4),
                      Shadow(color: Colors.black, offset: Offset(1, 1)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(width: 4),
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFC62828),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFFFD54F), width: 1),
            ),
            child: Text(
              seal,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 左下黑菱形：喇叭、绝招、自动。
  Widget _buildBottomLeftDiamonds() {
    final ult = gameSkillsById('jingzhe');
    final ultReady = ult == null || _skillReady(ult.id, DateTime.now());
    return Positioned(
      left: 10,
      bottom: _bottomPad + 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DiamondButton(
            label: '喇叭',
            icon: LucideIcons.megaphone,
            gold: false,
            onTap: widget.onOpenAnnounce,
          ),
          const SizedBox(width: 6),
          _DiamondButton(
            label: '绝招',
            icon: LucideIcons.zap,
            gold: false,
            onTap: () => _showToast(
              ult == null
                  ? '绝招：自动释放中'
                  : '绝招：${ult.name}${ultReady ? ' · 自动释放中' : ' · 冷却中'}',
            ),
          ),
          const SizedBox(width: 6),
          _DiamondButton(
            label: '自动',
            icon: LucideIcons.bot,
            gold: _autoBattle,
            onTap: () {
              setState(() => _autoBattle = !_autoBattle);
              _showToast(_autoBattle ? '自动战斗开启' : '自动战斗关闭');
            },
          ),
        ],
      ),
    );
  }

  /// 右下横排圆形蓝光符文技能钮：4 个，只做冷却展示，
  /// 冷却好了自动放，不用手点。显示名按用户原型定：
  /// 剑影分光（普攻飞剑，1.6 秒一剑）、雷法（辟邪神雷）、
  /// 大庚剑阵、万剑归宗；只改显示名，不动数值与冷却。
  /// 注意：大庚剑阵 / 万剑归宗是天道本职业招，逍遥与金刚
  /// 的自动战斗不放这两招，菱形只作冷却展示（一直亮着）。
  Widget _buildSkillDiamonds() {
    final now = DateTime.now();
    // 普攻：1.6 秒一剑。
    final basicElapsed = now.difference(_lastBasicAt).inMilliseconds / 1600;
    final skills = <({String shortName, double progress})>[
      (shortName: '剑影分光', progress: basicElapsed.clamp(0.0, 1.0)),
      (
        shortName: '雷法',
        progress: _skillProgress('bixie', const Duration(seconds: 8), now),
      ),
      (
        shortName: '大庚剑阵',
        progress: _skillProgress('dageng', const Duration(seconds: 6), now),
      ),
      (
        shortName: '万剑归宗',
        progress: _skillProgress('wanjian', const Duration(seconds: 6), now),
      ),
    ];
    return Positioned(
      right: 10,
      bottom: _bottomPad + 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < skills.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            _SkillDiamond(
              label: skills[i].shortName,
              progress: skills[i].progress,
            ),
          ],
        ],
      ),
    );
  }

  /// 某技能冷却进度（0 刚放完 → 1 冷却好了）。
  double _skillProgress(String skillId, Duration total, DateTime now) {
    final readyAt = _skillReadyAt[skillId];
    if (readyAt == null) return 1.0;
    final remaining = readyAt.difference(now).inMilliseconds;
    if (remaining <= 0) return 1.0;
    return (1 - remaining / total.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 底部红命条蓝灵条 + 右下角修为进度。
  Widget _buildBottomBars() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: _bottomPad + 10,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.xpLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
              const SizedBox(width: 6),
              Container(
                width: 110,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: widget.xpRatio.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFD4A017),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _BottomBar(
            label: '命',
            ratio: (_heroHp / widget.heroMaxHp).clamp(0.0, 1.0),
            color: const Color(0xFFE53935),
          ),
          const SizedBox(height: 4),
          _BottomBar(
            label: '灵',
            ratio: (_spirit / 100).clamp(0.0, 1.0),
            color: const Color(0xFF1E88E5),
          ),
        ],
      ),
    );
  }
}

/// 飞行法宝的种类（飞剑、辟邪神雷、乾蓝冰焰三系）。
enum _ProjectileKind {
  /// 青竹蜂云剑：绿光飞剑。
  sword,

  /// 辟邪神雷：天上劈下的紫白闪电（单体雷）。
  lightning,

  /// 乾蓝冰焰：蓝白冰火球（单体火）。
  flame,
}

/// 一枚飞行中的法宝 / 一道法术。
class _Projectile {
  _Projectile({
    required this.id,
    required this.kind,
    required this.controller,
    required this.from,
    required this.to,
    this.dyOffset = 0,
  });

  final int id;
  final _ProjectileKind kind;
  final AnimationController controller;
  final Offset from;
  final Offset to;
  final double dyOffset;
}

/// 一道御剑剑光：从施放者斜劈向目标的亮剑光（只做特效）。
class _BeamSlash {
  _BeamSlash({
    required this.from,
    required this.to,
    required this.controller,
  });

  /// 起点（施放者，道友处）。
  final Offset from;

  /// 终点（BOSS 或当前那只小怪）。
  final Offset to;

  /// 450ms：前 60% 伸出，后 40% 淡出。
  final AnimationController controller;
}

/// 一个飘字（伤害数字）。
class _Floater {
  _Floater({
    required this.id,
    required this.text,
    required this.color,
    required this.size,
    required this.anchor,
    required this.controller,
  });

  final int id;
  final String text;
  final Color color;
  final double size;

  /// 飘字起点（受击点）。
  final Offset anchor;
  final AnimationController controller;
}

/// 一次性特效的种类。
enum _BurstKind {
  /// 真魔功：紫漩涡。
  purpleVortex,

  /// 暴击 / 击杀：红爆炸。
  redBlast,

  /// 大招收尾：中央白黄闪光。
  goldFlash,

  /// 泰阳诀：金环。
  goldRing,

  /// 乾蓝冰焰：命中炸开的冰晶（冰晶爆开）。
  iceBlast,

  /// 辟邪神雷：命中竖劈而下的闪电（三道竖劈）。
  lightningStrike,

  /// 大庚剑阵：金色剑阵铺开。
  swordArray,

  /// 命中：白金爆裂星光。
  hitSpark,
}

/// 一个一次性特效。
class _Burst {
  _Burst({
    required this.id,
    required this.kind,
    required this.center,
    required this.controller,
  });

  final int id;
  final _BurstKind kind;
  final Offset center;
  final AnimationController controller;
}

/// 战场上的一只小怪：数值用妖兽表里的怪（见
/// [_GameBattleStageState._minionTemplates]），图按槽位
/// 轮着用四张野兽图（见 [gameMonsterCommonArts]）。
class _Minion {
  _Minion({
    required this.index,
    required this.monster,
    required this.art,
    required this.baseX,
    required this.baseY,
    required this.phase,
    required this.speed,
  }) : hp = monster.hp;

  /// 槽位（0..9，图按槽位轮，定时器按槽位记）。
  final int index;

  /// 数值来源（血量 / 奖励按这只怪的表算）。
  GameMonster monster;

  /// 显示用的图（四张野兽图之一，与数值怪的种类无关）。
  String art;

  /// 当前血量（满血 = monster.hp）。
  int hp;

  /// 基准位置（0..1 相对值，走动漂移以此为中心）。
  double baseX;
  double baseY;
  double phase;
  double speed;

  /// 正在播放死亡动画（不吃伤害，主角会换目标）。
  bool dying = false;

  /// 死于何时（重刷定时器用）。
  DateTime? diedAt;
}

/// 头顶名字：很小白色紧贴头顶，格式境界+名字（9px，
/// 名牌栏 96 宽刚好放得下“筑基后期 道友5572”）。
class _NameTag extends StatelessWidget {
  const _NameTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 9,
        fontWeight: FontWeight.w600,
        shadows: [
          Shadow(color: Colors.black, offset: Offset(1, 1)),
          Shadow(color: Colors.black87, blurRadius: 3),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 头顶小血条（BOSS 用）。
class _HpBar extends StatelessWidget {
  const _HpBar({required this.ratio, required this.width, required this.color});

  final double ratio;
  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 4,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: ratio.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// 底部命条 / 灵条。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.label,
    required this.ratio,
    required this.color,
  });

  final String label;
  final double ratio;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 14,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Container(
            height: 9,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 人物立绘 + 脚下影子。
class _FighterFigure extends StatelessWidget {
  const _FighterFigure({
    required this.width,
    required this.height,
    required this.child,
  });

  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          Positioned(
            bottom: 0,
            child: Container(
              width: width * 0.7,
              height: 7,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// 右侧黑色箭头标签（左侧尖角，点开对应功能）。
class _ArrowTag extends StatelessWidget {
  const _ArrowTag({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(size: const Size(10, 30), painter: _ArrowHeadPainter()),
          Container(
            width: 52,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 箭头标签的尖角。
class _ArrowHeadPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.75)
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(0, size.height / 2)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 菱形按钮（左下喇叭 / 绝招 / 自动）：黑菱形 + 白字/图标。
class _DiamondButton extends StatelessWidget {
  const _DiamondButton({
    required this.label,
    required this.icon,
    required this.gold,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool gold;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: gold
                    ? const Color(0xFF8D6E00)
                    : Colors.black.withValues(alpha: 0.75),
                border: Border.all(
                  color: gold
                      ? const Color(0xFFFFD54F)
                      : Colors.white.withValues(alpha: 0.4),
                  width: 1.2,
                ),
                boxShadow: gold
                    ? [
                        BoxShadow(
                          color: Colors.amber.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Transform.rotate(
                angle: -math.pi / 4,
                child: Icon(icon, size: 15, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 9),
          ),
        ],
      ),
    );
  }
}

/// 技能钮（只做冷却展示）：圆形蓝光符文钮，冷却时蒙黑 + 秒数，
/// 冷却好了亮蓝光。
class _SkillDiamond extends StatelessWidget {
  const _SkillDiamond({required this.label, required this.progress});

  final String label;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final ready = progress >= 1.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(
              colors: [Color(0xFF64B5F6), Color(0xFF1565C0), Color(0xFF0D47A1)],
              stops: [0.0, 0.6, 1.0],
            ),
            border: Border.all(
              color: ready
                  ? const Color(0xFFBBDEFB)
                  : Colors.white.withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: ready
                ? [
                    BoxShadow(
                      color: Colors.lightBlueAccent.withValues(alpha: 0.7),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (!ready)
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(
                      alpha: 0.65 * (1 - progress),
                    ),
                  ),
                ),
              Text(
                ready ? '●' : '${((1 - progress) * 10).ceil()}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 9)),
      ],
    );
  }
}

/// 青竹蜂云剑飞弹：真飞剑造型（3D 写实风，不画卡通简笔画）。
/// 剑尖朝飞行方向（调用处按 from→to 的轨迹方向传 angle）。
class _SwordMissile extends StatelessWidget {
  const _SwordMissile({required this.angle});

  /// 飞行角度（弧度，0 = 剑尖朝右）。
  final double angle;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: const SizedBox(
        width: 110,
        height: 28,
        child: CustomPaint(painter: _SwordPainter()),
      ),
    );
  }
}

/// 真飞剑画法（画布 110x28，剑尖朝右 +x 方向）：
/// 从左到右是青绿剑光拖尾 → 金色剑首 → 深色剑柄 →
/// 金色剑格 → 钢色剑身（白→青绿渐变）+ 中央剑脊亮线，
/// 整剑垫一层青绿光晕。
class _SwordPainter extends CustomPainter {
  const _SwordPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // 剑身轮廓：剑格 x=40，剑尖 x=106，脊线 y=14。
    final blade = Path()
      ..moveTo(40, 10.5)
      ..lineTo(96, 12.0)
      ..lineTo(106, 14)
      ..lineTo(96, 16.0)
      ..lineTo(40, 17.5)
      ..close();
    // 青绿光晕（垫在剑身下面）。
    final glowPaint = Paint()
      ..color = const Color(0xFF69F0AE).withValues(alpha: 0.45)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    canvas.drawPath(blade, glowPaint);
    // 剑光拖尾：从剑格向后渐隐的青绿光带。
    final trail = Path()
      ..moveTo(40, 14)
      ..lineTo(2, 10.5)
      ..lineTo(0, 14)
      ..lineTo(2, 17.5)
      ..close();
    final trailPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x0069F0AE), Color(0xFF69F0AE), Color(0xFFE8F5E9)],
        stops: [0.0, 0.75, 1.0],
      ).createShader(Rect.fromLTWH(0, 10, 40, 8))
      ..style = PaintingStyle.fill;
    canvas.drawPath(trail, trailPaint);
    // 剑身：钢色渐变（白 → 青绿），从剑格亮到剑尖。
    final bladePaint = Paint()
      ..shader = const LinearGradient(
        colors: [
          Color(0xFFFFFFFF),
          Color(0xFFD8F5E3),
          Color(0xFF69F0AE),
          Color(0xFF00C853),
        ],
        stops: [0.0, 0.45, 0.8, 1.0],
      ).createShader(Rect.fromLTWH(40, 10, 66, 8))
      ..style = PaintingStyle.fill;
    canvas.drawPath(blade, bladePaint);
    // 剑刃边：上下两道深绿刃线。
    final edgePaint = Paint()
      ..color = const Color(0xFF1B5E20).withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(
      Path()
        ..moveTo(40, 10.5)
        ..lineTo(96, 12.0)
        ..lineTo(106, 14),
      edgePaint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(40, 17.5)
        ..lineTo(96, 16.0)
        ..lineTo(106, 14),
      edgePaint,
    );
    // 剑脊亮线：剑身中央一条亮白线。
    final ridgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(44, 14), const Offset(100, 14), ridgePaint);
    // 剑格：金色横杠（竖向金条，上下各出头）。
    final guardPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFE082), Color(0xFFFFB300), Color(0xFFFF8F00)],
        stops: [0.0, 0.5, 1.0],
      ).createShader(const Rect.fromLTWH(35, 4, 6, 20))
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(35, 4, 6, 20),
        const Radius.circular(2),
      ),
      guardPaint,
    );
    // 剑柄：深色缠柄，两道金丝。
    final hiltPaint = Paint()
      ..color = const Color(0xFF212121)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(27, 11.5, 8, 5),
        const Radius.circular(2),
      ),
      hiltPaint,
    );
    final wrapPaint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawLine(
      const Offset(29.5, 11.5),
      const Offset(29.5, 16.5),
      wrapPaint,
    );
    canvas.drawLine(
      const Offset(32.5, 11.5),
      const Offset(32.5, 16.5),
      wrapPaint,
    );
    // 剑首：金色小圆珠 + 高光点。
    final pommelPaint = Paint()
      ..color = const Color(0xFFFFB300)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(25, 14), 3.2, pommelPaint);
    final pommelHiPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(24, 13), 1, pommelHiPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 乾蓝冰焰飞弹：蓝白冰火球拖着冰晶尾飞出去打怪（画布 64x40，
/// 球头朝 +x，调用处按飞行方向传 angle 转过去）。
class _FlameMissile extends StatelessWidget {
  const _FlameMissile({required this.angle});

  /// 飞行角度（弧度，0 = 球头朝右）。
  final double angle;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: const SizedBox(
        width: 64,
        height: 40,
        child: CustomPaint(painter: _FlamePainter()),
      ),
    );
  }
}

/// 冰火球画法：球头白蓝冰核 + 浅蓝冰晶三层拖尾向后渐隐，
/// 整球垫一层淡蓝光晕。
class _FlamePainter extends CustomPainter {
  const _FlamePainter();

  /// 一道冰尾：从球头向后收窄的冰晶形。
  void _tongue(
    Canvas canvas,
    double tipX,
    double baseY,
    double len,
    double w,
    Color color,
  ) {
    final path = Path()
      ..moveTo(48, baseY - w)
      ..quadraticBezierTo(48 - len * 0.55, baseY - w * 0.4, tipX, baseY)
      ..quadraticBezierTo(48 - len * 0.55, baseY + w * 0.4, 48, baseY + w)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 光晕：球头下一圈淡蓝柔光。
    final glowPaint = Paint()
      ..color = const Color(0xFF42A5F5).withValues(alpha: 0.45)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    canvas.drawCircle(const Offset(46, 20), 13, glowPaint);
    // 冰尾：外深蓝 → 中蓝 → 内浅蓝三层冰晶，越往后越细。
    _tongue(
      canvas,
      4,
      20,
      44,
      11,
      const Color(0xFF1565C0).withValues(alpha: 0.85),
    );
    _tongue(
      canvas,
      12,
      20,
      36,
      8,
      const Color(0xFF42A5F5).withValues(alpha: 0.9),
    );
    _tongue(canvas, 22, 20, 26, 5, const Color(0xFFBBDEFB));
    // 冰核：白蓝实心球，蓝边收口。
    final corePaint = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFFFFF), Color(0xFFBBDEFB), Color(0xFF42A5F5)],
        stops: [0.0, 0.55, 1.0],
      ).createShader(const Rect.fromLTWH(32, 6, 28, 28))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(46, 20), 12, corePaint);
    // 冰晶：两点亮白冰晶溅在球头边。
    final sparkPaint = Paint()
      ..color = const Color(0xFFE3F2FD)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(56, 10), 2.2, sparkPaint);
    canvas.drawCircle(const Offset(58, 28), 1.6, sparkPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // 外圈青白光晕 + 内圈亮白斩弧，双弧更炸。
    final glowPaint = Paint()
      ..color = const Color(0xFF69F0AE).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: size.width * 0.95,
        height: size.height * 0.95,
      ),
      -0.6,
      2.4,
      false,
      glowPaint,
    );
    final arcPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: size.width * 0.9,
        height: size.height * 0.9,
      ),
      -0.6,
      2.2,
      false,
      arcPaint,
    );
    final sparkPaint = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width * 0.82, size.height * 0.3),
      5,
      sparkPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 御剑剑光画法：亮剑光从施放者斜劈向目标——前 60% 沿直线
/// 快速伸出，后 40% 停在目标身上淡出；三层描边（外层宽而淡
/// 的青光、中层亮青、内层白芯）+ 尖端拖尾光带 + 落点星芒。
class _BeamSlashPainter extends CustomPainter {
  _BeamSlashPainter({
    required this.from,
    required this.to,
    required this.progress,
  });

  /// 起点（施放者，道友处）。
  final Offset from;

  /// 终点（BOSS 或当前那只小怪）。
  final Offset to;

  /// 0..1（伸出 0..0.6，淡出 0.6..1）。
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0);
    final extend = (t / 0.6).clamp(0.0, 1.0);
    final fade = t <= 0.6 ? 1.0 : (1 - (t - 0.6) / 0.4).clamp(0.0, 1.0);
    final delta = to - from;
    if (delta.distance < 1 || fade <= 0) return;
    final end = Offset.lerp(from, to, extend)!;
    // 尖端拖尾光带：比剑光本体短一截、更淡更宽。
    final tailStart = Offset.lerp(from, to, (extend - 0.25).clamp(0.0, 1.0))!;
    void stroke(Offset a, Offset b, double width, Color color) {
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    stroke(
      tailStart,
      end,
      18,
      const Color(0xFFB3E5FC).withValues(alpha: 0.25 * fade),
    );
    stroke(
      from,
      end,
      10,
      const Color(0xFF4DD0E1).withValues(alpha: 0.75 * fade),
    );
    stroke(from, end, 4, Colors.white.withValues(alpha: 0.95 * fade));
    // 落点星芒（剑光伸到目标才出现）。
    if (extend >= 1) {
      final r = 6 + 14 * fade;
      final star = Paint()
        ..color = Colors.white.withValues(alpha: 0.9 * fade)
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(to + Offset(-r, 0), to + Offset(r, 0), star);
      canvas.drawLine(to + Offset(0, -r), to + Offset(0, r), star);
    }
  }

  @override
  bool shouldRepaint(_BeamSlashPainter old) => old.progress != progress;
}

/// 辟邪神雷：紫白闪电从天劈下——主电弧 + 3 条分叉电弧，
/// 外层紫色光晕描边、内芯亮白，落点加一圈闪光。
class _LightningPainter extends CustomPainter {
  const _LightningPainter();

  /// 一道电弧：外层紫晕 → 中层紫电 → 内芯亮白，三层描边。
  void _drawBolt(Canvas canvas, List<Offset> points, double coreWidth) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    final glow = Paint()
      ..color = const Color(0xFFAB47BC).withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = coreWidth * 3.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, glow);
    final mid = Paint()
      ..color = const Color(0xFFCE93D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = coreWidth * 1.6
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, mid);
    final core = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = coreWidth
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, core);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 主电弧：从顶到底的锯齿。
    _drawBolt(canvas, [
      Offset(w * 0.52, 0),
      Offset(w * 0.64, h * 0.20),
      Offset(w * 0.44, h * 0.34),
      Offset(w * 0.66, h * 0.56),
      Offset(w * 0.42, h * 0.70),
      Offset(w * 0.58, h * 0.86),
      Offset(w * 0.48, h),
    ], 2.0);
    // 分叉 1：从主干上段斜向左下，细一点、短一点。
    _drawBolt(canvas, [
      Offset(w * 0.50, h * 0.30),
      Offset(w * 0.32, h * 0.44),
      Offset(w * 0.16, h * 0.58),
    ], 1.2);
    // 分叉 2：从主干中段斜向右下。
    _drawBolt(canvas, [
      Offset(w * 0.58, h * 0.52),
      Offset(w * 0.74, h * 0.66),
      Offset(w * 0.86, h * 0.80),
    ], 1.2);
    // 分叉 3：从主干上段斜向右上短叉。
    _drawBolt(canvas, [
      Offset(w * 0.58, h * 0.18),
      Offset(w * 0.74, h * 0.28),
      Offset(w * 0.88, h * 0.34),
    ], 1.0);
    // 落点闪光：白光圆心 + 紫环。
    final impact = Offset(w * 0.48, h * 0.96);
    final flash = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(impact, w * 0.14, flash);
    final ring = Paint()
      ..color = const Color(0xFFCE93D8).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(impact, w * 0.20, ring);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 冰晶爆开：命中炸开的一团冰晶——白蓝冰核 + 浅蓝冰晶向外翻，
/// 8 道冰刺随进度向外窜。
class _IceBlastPainter extends CustomPainter {
  const _IceBlastPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    final blastR = maxR * (0.55 + progress * 0.45);
    // 外层冰团：白蓝 → 浅蓝 → 蓝径向渐变，随进度胀大变淡。
    final blastPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFE3F2FD).withValues(alpha: 1 - progress),
          const Color(0xFF90CAF9).withValues(alpha: (1 - progress) * 0.85),
          const Color(0xFF42A5F5).withValues(alpha: (1 - progress) * 0.5),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: blastR))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, blastR, blastPaint);
    // 冰核：亮白实心，随进度缩小。
    final corePaint = Paint()
      ..color = Colors.white.withValues(alpha: (1 - progress) * 0.95)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, maxR * 0.22 * (1 - progress * 0.5), corePaint);
    // 8 道冰刺：向外窜的细长冰晶。
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4 + progress * 0.5;
      final dist = maxR * (0.42 + progress * 0.42);
      final tip =
          center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
      final base =
          center +
          Offset(math.cos(angle) * maxR * 0.25, math.sin(angle) * maxR * 0.25);
      final side =
          Offset(-math.sin(angle), math.cos(angle)) *
          maxR *
          0.05 *
          (1 - progress * 0.5);
      final mid =
          center +
          Offset(math.cos(angle) * dist * 0.7, math.sin(angle) * dist * 0.7);
      final shard = Path()
        ..moveTo(base.dx + side.dx, base.dy + side.dy)
        ..quadraticBezierTo(mid.dx + side.dx, mid.dy + side.dy, tip.dx, tip.dy)
        ..quadraticBezierTo(
          mid.dx - side.dx,
          mid.dy - side.dy,
          base.dx - side.dx,
          base.dy - side.dy,
        )
        ..close();
      canvas.drawPath(
        shard,
        Paint()
          ..color =
              (i.isEven ? const Color(0xFF90CAF9) : const Color(0xFFE3F2FD))
                  .withValues(alpha: 1 - progress)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _IceBlastPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 大庚剑阵铺开：金色法阵圆环 + 8 把金剑向外辐射。
class _SwordArrayPainter extends CustomPainter {
  const _SwordArrayPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ring = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 1 - progress)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, size.width * (0.2 + progress * 0.28), ring);
    final inner = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, size.width * 0.18, inner);
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4;
      final dist = size.width * (0.3 + progress * 0.12);
      final pos =
          center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angle + math.pi / 2);
      final sword = Path()
        ..moveTo(0, -16)
        ..lineTo(5, -4)
        ..lineTo(3, 12)
        ..lineTo(-3, 12)
        ..lineTo(-5, -4)
        ..close();
      final paint = Paint()
        ..color = const Color(0xFFFFD54F).withValues(alpha: 1 - progress)
        ..style = PaintingStyle.fill;
      canvas.drawPath(sword, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _SwordArrayPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 命中白金爆裂星光：四角星 + 光晕。
class _SparkPainter extends CustomPainter {
  const _SparkPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final glow = Paint()
      ..color = Colors.white.withValues(alpha: (1 - progress) * 0.8)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, size.width * 0.2 * (1 - progress * 0.4), glow);
    final star = Path();
    final r = size.width * (0.28 + progress * 0.2);
    final inner = r * 0.25;
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4 - math.pi / 2;
      final rad = i.isEven ? r : inner;
      final p = center + Offset(math.cos(angle) * rad, math.sin(angle) * rad);
      if (i == 0) {
        star.moveTo(p.dx, p.dy);
      } else {
        star.lineTo(p.dx, p.dy);
      }
    }
    star.close();
    final paint = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 1 - progress)
      ..style = PaintingStyle.fill;
    canvas.drawPath(star, paint);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 大招金色螺旋光环：三圈金环 + 十二道旋转金芒 + 一道弧光，罩全队。
class _GoldHaloPainter extends CustomPainter {
  _GoldHaloPainter({required this.rotation});

  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    for (var i = 0; i < 3; i++) {
      final ringPaint = Paint()
        ..color = const Color(0xFFFFD54F).withValues(alpha: 0.75 - i * 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5 - i * 1.5;
      canvas.drawCircle(center, maxR * (0.55 + i * 0.18), ringPaint);
    }
    final rayPaint = Paint()
      ..color = const Color(0xFFFFE082).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final angle = rotation + i * math.pi / 6;
      final inner = maxR * 0.62;
      final outer = maxR * 0.92;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        rayPaint,
      );
    }
    final arcPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: maxR * 0.73),
      rotation,
      2.2,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _GoldHaloPainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}

/// 真魔功紫漩涡：三层紫色螺旋弧跟着转，中心一个紫光点。
class _VortexPainter extends CustomPainter {
  _VortexPainter({required this.rotation});

  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;
    const colors = <Color>[
      Color(0xFFCE93D8),
      Color(0xFFAB47BC),
      Color(0xFF7B1FA2),
    ];
    for (var i = 0; i < 3; i++) {
      final arcPaint = Paint()
        ..color = colors[i].withValues(alpha: 0.85 - i * 0.2)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 - i * 2
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: maxR * (0.9 - i * 0.22)),
        rotation + i * 0.7,
        3.6,
        false,
        arcPaint,
      );
    }
    canvas.drawCircle(
      center,
      maxR * 0.12,
      Paint()..color = const Color(0xFFE1BEE7).withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(covariant _VortexPainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}
