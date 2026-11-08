import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/cultivation.dart';
import '../services/game_data.dart';
import '../services/game_sound.dart';
import 'standing_character.dart';

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

/// 全屏 2.5D 俯视厮杀战场：照 4399 打 BOSS 视频那个界面做——
/// 竖屏斜俯视约 45 度，地面青灰石板有纵深、脚下有影子，
/// 人物很小（约占画面十分之一），3-4 人紧贴 BOSS 围成半弧
/// 贴身打，BOSS 居中偏上；全程自动战斗自动寻路，不用手操作。
/// 人物改小（用户看截图说原来太大互相重叠）：主角 46×58、
/// 队友 38×48、BOSS 96×112，名牌栏 96 宽、9px 小字不截断
/// 不压叠；50 个托机器人只在地图五条边缘带活动，不进中央。
///
/// 界面布局照视频里来：
/// - 中央金字“自动战斗中…/自动寻路中…”；
/// - 右上半透明黑面板：副本名、击败 BOSS 0/1、用时；
/// - 右下横排金棕菱形技能按钮 6-7 个（只做冷却展示，自动放）；
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
/// 队友全是机器人：道友 + 2 名虚拟队友（紫灵、厉飞雨）3 人
/// 满队进副本围打 BOSS；每张地图另有 50 个托机器人随机走动、
/// 随机找怪打、随机放技能、随机跑图，名字境界各不一样，像
/// 真人一样在地图里活动；队友名字衣服武器各不一样，会走位、
/// 会放技能、会喊话（“老大！你一定能赢！”），旁人看屏幕
/// 以为是好几个人在组队玩，其实全是机器人单机。
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
    required this.onHeroStrike,
    required this.onOpenShop,
    required this.onOpenTasks,
    required this.onOpenProfile,
    required this.onOpenFunctions,
    required this.onOpenAnnounce,
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
  Timer? _cheerTimer;
  Timer? _bannerTimer;
  Timer? _toastTimer;
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
  bool _monsterFlash = false;
  bool _heroFlash = false;
  bool _monsterDying = false;
  bool _slashArcShowing = false;
  bool _impactFlash = false;
  bool _autoBattle = true;
  bool _lowHpCheered = false;
  String? _ultBanner;
  String? _cheer;
  int _cheerBotIndex = 0;
  String? _toast;

  final List<_Floater> _floaters = [];
  int _floaterId = 0;

  /// 飞行中的法宝 / 法术（飞剑、神雷、冰焰）。
  final List<_Projectile> _projectiles = [];
  int _projectileId = 0;

  /// 一次性特效（紫漩涡、红爆炸、金闪光、金环）。
  final List<_Burst> _bursts = [];
  int _burstId = 0;

  /// 50 个托机器人（每图随机走动打怪）。
  late final List<_AmbientBot> _ambientBots;

  /// 托机器人名字排版缓存（State 里持有，不随每帧重建）。
  final Map<int, TextPainter> _ambientLabelCache = {};

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

  /// 托机器人走动（6 秒循环，位置由时间函数算）。
  late final AnimationController _ambient;

  /// 高阶（战力 >= 1500）看法宝法术对轰，低阶看身法近身突袭。
  bool get _isHighTier => widget.heroPower >= 1500;

  /// 当前场景尺寸（build 里记下，飘字与法宝落点用）。
  Size _arenaSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _monsterHp = widget.monster.hp;
    _heroHp = widget.heroMaxHp;
    _ambientBots = _makeAmbientBots();
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
    _ambient = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _startSeeking();
    _startTick();
    _cheerTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted || !widget.active) return;
      _showCheer(
        gameCheerLines[math.Random().nextInt(gameCheerLines.length)],
      );
    });
  }

  /// 50 个托机器人：固定种子随机，保证每图一样又各不一样。
  /// 只在地图五条边缘带活动（左带 / 右带 / 左下角 / 右下角 /
  /// 左上带），绝不进主战场中央，主战场只留道友加两个队友。
  List<_AmbientBot> _makeAmbientBots() {
    final random = math.Random(20261108);
    return List<_AmbientBot>.generate(50, (index) {
      final zone = index % 5;
      final (baseX, baseY) = switch (zone) {
        // 左边缘带。
        0 => (
            0.02 + random.nextDouble() * 0.07,
            0.32 + random.nextDouble() * 0.50,
          ),
        // 右边缘带。
        1 => (
            0.91 + random.nextDouble() * 0.07,
            0.32 + random.nextDouble() * 0.50,
          ),
        // 左下角。
        2 => (
            0.03 + random.nextDouble() * 0.20,
            0.84 + random.nextDouble() * 0.06,
          ),
        // 右下角。
        3 => (
            0.77 + random.nextDouble() * 0.20,
            0.84 + random.nextDouble() * 0.06,
          ),
        // 左上带。
        _ => (
            0.02 + random.nextDouble() * 0.16,
            0.08 + random.nextDouble() * 0.12,
          ),
      };
      return _AmbientBot(
        name: gameAmbientBotNames[index % gameAmbientBotNames.length],
        realm: gameAmbientBotRealms[
            index % gameAmbientBotRealms.length],
        baseX: baseX,
        baseY: baseY,
        phase: random.nextDouble() * math.pi * 2,
        speed: 0.5 + random.nextDouble() * 0.8,
        colorIndex: index % 6,
      );
    });
  }

  @override
  void didUpdateWidget(GameBattleStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.monster.id != widget.monster.id) {
      _monsterHp = widget.monster.hp;
      _monsterDying = false;
      _lowHpCheered = false;
      _heroHp = widget.heroMaxHp;
      _fightStart = DateTime.now();
      _skillReadyAt.clear();
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
    _cheerTimer?.cancel();
    _bannerTimer?.cancel();
    _toastTimer?.cancel();
    _lunge.dispose();
    _shake.dispose();
    _monsterLunge.dispose();
    _walk.dispose();
    _seek.dispose();
    _halo.dispose();
    _ambient.dispose();
    for (final projectile in _projectiles) {
      projectile.controller.dispose();
    }
    for (final floater in _floaters) {
      floater.controller.dispose();
    }
    for (final burst in _bursts) {
      burst.controller.dispose();
    }
    super.dispose();
  }

  /// 进副本：3 人小队从出生点自动寻路走到 BOSS 身边半弧站位。
  void _startSeeking() {
    _seeking = true;
    final token = ++_seekToken;
    _seek.forward(from: 0);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
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
        if (last == null ||
            now.difference(last).inMilliseconds >= interval) {
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
    var damage = (widget.heroPower ~/ 8 +
            random.nextInt(widget.heroPower ~/ 8 + 1)) *
        3 ~/
        2;
    if (isCrit) damage *= 2;
    if (skill.id == 'jingzhe') {
      _ultStrike(skill, damage * 2, isCrit);
      return;
    }
    final kind = switch (skill.id) {
      'bixie' => _ProjectileKind.lightning,
      'qianlan' || 'zhenmo' => _ProjectileKind.flame,
      'taiyang' => _ProjectileKind.lightning,
      _ => _ProjectileKind.sword,
    };
    unawaited(GameSoundService.instance.playSkill(skill.id));
    if (skill.id == 'zhenmo') {
      _spawnBurst(_BurstKind.purpleVortex, _monsterCenter);
    }
    if (skill.id == 'taiyang') {
      _spawnBurst(_BurstKind.goldRing, _monsterCenter);
    }
    _launchProjectile(
      kind,
      _heroCenter,
      () => _applyDamage(damage, isCrit: isCrit, skillName: skill.name),
    );
  }

  /// 队友机器人出招：从队友站位发一枚小法宝，打中飘小伤害数字。
  void _botStrike(GameTeamBot bot) {
    if (_monsterDying || !mounted) return;
    final random = math.Random();
    final damage = (widget.heroPower * 0.25).round() +
        random.nextInt(widget.heroPower ~/ 10 + 1);
    final kind = bot.profession == '天道'
        ? _ProjectileKind.sword
        : _ProjectileKind.flame;
    if (random.nextDouble() < 0.3) {
      unawaited(GameSoundService.instance.playSword());
    }
    _launchProjectile(
      kind,
      _botCenter(bot),
      () => _applyDamage(damage, isBot: true),
    );
  }

  /// 出手一次（普攻）：低阶身法近身突袭，高阶法宝法术对轰；
  /// 每 4 击一次大招（完整动画：横幅 → 金环罩队 → 三波齐轰 →
  /// 中央白黄闪光收尾）。
  void _heroStrike() {
    if (_monsterDying || !mounted) return;
    _lastBasicAt = DateTime.now();
    _hitCount++;
    final isUlt = _hitCount % 4 == 0;
    final skills = gameSkillsForProfession(widget.profession);
    final skill = skills[(_hitCount ~/ 4) % skills.length];
    final random = math.Random();
    final isCrit = random.nextDouble() < 0.15;
    var damage = widget.heroPower ~/ 8 +
        random.nextInt(widget.heroPower ~/ 8 + 1);
    if (isUlt) damage *= 3;
    if (isCrit) damage *= 2;
    if (isUlt) {
      _ultStrike(skill, damage, isCrit);
      return;
    }
    if (_isHighTier) {
      // 高阶：原地施法，法宝法术对轰——青竹蜂云剑剑雨、
      // 辟邪神雷、乾蓝冰焰轮着轰过去。
      const kinds = <_ProjectileKind>[
        _ProjectileKind.sword,
        _ProjectileKind.lightning,
        _ProjectileKind.flame,
      ];
      final kind = kinds[_hitCount % kinds.length];
      _launchProjectile(
        kind,
        _heroCenter,
        () => _applyDamage(damage, isCrit: isCrit),
      );
      unawaited(GameSoundService.instance.playSword());
    } else {
      // 低阶：身法走位近身突袭——快速前冲、贴身一斩、立刻撤回。
      _lunge.forward(from: 0);
      setState(() => _slashArcShowing = true);
      unawaited(GameSoundService.instance.playSword());
      Future<void>.delayed(const Duration(milliseconds: 280), () {
        if (!mounted || _monsterDying) return;
        setState(() => _slashArcShowing = false);
        _applyDamage(damage, isCrit: isCrit);
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
    final perWave = (damage / 3).ceil();
    const kinds = <_ProjectileKind>[
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

  /// 发一枚法宝 / 一道法术：从 from 处飞向妖兽，命中时结算
  /// （onImpact 为空时只看特效不结算，大招齐轰时用）。
  void _launchProjectile(
    _ProjectileKind kind,
    Offset from,
    VoidCallback? onImpact, {
    double dyOffset = 0,
  }) {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    final projectile = _Projectile(
      id: _projectileId++,
      kind: kind,
      controller: controller,
      from: from,
      to: _monsterCenter,
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

  /// 派一个一次性特效（紫漩涡 / 红爆炸 / 金闪光 / 金环）。
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
        setState(() => _bursts.remove(burst));
        controller.dispose();
      }),
    );
  }

  /// 一次命中结算：妖兽掉血、受击点飘橙黄伤害数字、音效、
  /// 暴击红爆炸 + 震屏；没死就扑回来咬一口；血到三成以下
  /// 队友喊一句助威。
  void _applyDamage(
    int damage, {
    bool isCrit = false,
    bool isUlt = false,
    String skillName = '',
    bool isBot = false,
  }) {
    if (!mounted || _monsterDying) return;
    setState(() {
      _monsterFlash = true;
      _monsterHp -= damage;
    });
    if (isUlt) {
      // 大招音效已在出招时放过，这里只补命中音。
      unawaited(GameSoundService.instance.playHit());
    } else if (isCrit) {
      unawaited(GameSoundService.instance.playCrit());
      _spawnBurst(_BurstKind.redBlast, _monsterCenter);
    } else if (!isBot) {
      unawaited(GameSoundService.instance.playHit());
    }
    _addFloater(
      '-$damage',
      isCrit
          ? const Color(0xFFFFD54F)
          : const Color(0xFFFFB300),
      isCrit ? 20 : (isBot ? 12 : 16),
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
    Future<void>.delayed(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _monsterFlash = false);
    });
    if (_monsterHp <= 0) {
      _killMonster();
      return;
    }
    if (!_lowHpCheered && _monsterHp * 10 < widget.monster.hp * 3) {
      _lowHpCheered = true;
      _showCheer('这老妖快不行了！');
    }
    if (isBot) return;
    // 妖兽扑回来咬一口（前冲 + 撕咬）。
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (!mounted || _monsterDying) return;
      _monsterLunge.forward(from: 0);
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (!mounted || _monsterDying) return;
        final hurt = widget.monster.power ~/ 20 +
            math.Random().nextInt(widget.monster.power ~/ 20 + 1);
        setState(() {
          _heroHp -= hurt;
          _heroFlash = true;
        });
        _addFloater(
          '-$hurt',
          const Color(0xFFEF5350),
          13,
          anchor: _heroCenter,
        );
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

  void _showUltBanner(String skillName) {
    _bannerTimer?.cancel();
    setState(() => _ultBanner = skillName);
    _bannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _ultBanner = null);
    });
  }

  /// 队友喊话：随机一名队友头顶飘气泡 3 秒（喊话不是聊天，
  /// 单机游戏没有聊天功能）。
  void _showCheer(String line) {
    setState(() {
      _cheer = line;
      _cheerBotIndex = math.Random().nextInt(gameTeamBots.length);
    });
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _cheer = null);
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
  void _addFloater(
    String text,
    Color color,
    double size, {
    Offset? anchor,
  }) {
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
      anchor: (anchor ?? _monsterCenter) +
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
        setState(() {
          _floaters.remove(floater);
        });
        floater.controller.dispose();
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

  /// BOSS 立绘宽高（比人物大，居中偏上；照网页版改小那轮：96 宽）。
  static const double _bossW = 96;
  static const double _bossH = 112;

  /// 头顶名牌栏宽（比立绘宽，名字才放得下不截断；
  /// 三人名牌各隔 0.26 屏宽，96 宽不互相压叠）。
  static const double _nameTagW = 96;

  /// 寻路缓动（0 出生点 → 1 半弧站位）。
  double get _seekT {
    final t = _seek.value;
    return 1 - math.pow(1 - t, 3).toDouble();
  }

  /// BOSS 中心点（居中偏上）。
  Offset get _monsterCenter {
    final size = _arenaSize;
    final walk = math.sin(_walk.value * math.pi * 2 + math.pi) * 4;
    final lunge = -_monsterLunge.value * 12;
    return Offset(size.width * 0.5 + walk + lunge, size.height * 0.27);
  }

  /// 道友中心点（半弧正下方；寻路时从出生点走上来）。
  Offset get _heroCenter {
    final size = _arenaSize;
    final walk = math.sin(_walk.value * math.pi * 2) * 3;
    final lunge = _lunge.value * 12;
    final arc = Offset(size.width * 0.5 + walk + lunge, size.height * 0.49);
    final spawn =
        Offset(size.width * 0.5 + walk, size.height * 0.86);
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
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF3A2E6E),
                  Color(0xFF171238),
                  Color(0xFF0D0A24),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 斜俯视 45 度场景：远山、青灰石板地面、纵深、法阵光。
                const Positioned.fill(
                  child: CustomPaint(painter: _ArenaPainter()),
                ),
                // 50 个托机器人（背景里随机走动打怪）。
                AnimatedBuilder(
                  animation: _ambient,
                  builder: (context, _) => Positioned.fill(
                    child: CustomPaint(
                      painter: _AmbientBotsPainter(
                        bots: _ambientBots,
                        time: _ambient.value,
                        labelCache: _ambientLabelCache,
                      ),
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
                        animation: Listenable.merge(
                            [_walk, _monsterLunge]),
                        builder: (context, _) => _buildBoss(monster),
                      ),
                      if (_slashArcShowing) _buildSlashArc(),
                      ..._projectiles.map(_buildProjectile),
                      ..._bursts.map(_buildBurst),
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
                      left: _arenaSize.width / 2 - 150,
                      top: _arenaSize.height * 0.27 - 100,
                      width: 300,
                      height: 300,
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
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 6),
                        ],
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
                // 左下黑菱形：喇叭、绝招、自动。
                _buildBottomLeftDiamonds(),
                // 右下横排金棕菱形技能栏（只做冷却展示，自动放）。
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
  Widget _buildDungeonPanel(GameMonster monster) {
    final killed = _monsterDying || _monsterHp <= 0;
    return Positioned(
      top: _topPad + 64,
      right: 12,
      width: 172,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
          ),
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
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '用时 $_fightClock',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
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
              child: StandingCharacter(
                width: _heroW,
                height: _heroH,
                isFemale: widget.heroIsFemale,
                costume: widget.heroCostume,
                profession: widget.profession,
                autoCastSkill: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 队友机器人：名字衣服武器各不一样，头顶“境界+名字”，
  /// 喊话气泡飘在喊话的队友头顶。
  Widget _buildBot(GameTeamBot bot) {
    final center = _botCenter(bot);
    final index = gameTeamBots.indexOf(bot);
    final cheering = _cheer != null && _cheerBotIndex == index;
    return Positioned(
      left: center.dx - _nameTagW / 2,
      top: center.dy - _botH / 2 - 14,
      width: _nameTagW,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cheering)
            Container(
              margin: const EdgeInsets.only(bottom: 2),
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _cheer!,
                style: const TextStyle(
                  color: Color(0xFF333333),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          _NameTag(text: '${_botRealm(bot)} ${bot.name}'),
          const SizedBox(height: 2),
          _FighterFigure(
            width: _botW,
            height: _botH,
            child: StandingCharacter(
              width: _botW,
              height: _botH,
              isFemale: bot.isFemale,
              costume: cultivationCostumeById(bot.costumeId),
              profession: bot.profession,
              autoCastSkill: true,
            ),
          ),
        ],
      ),
    );
  }

  /// BOSS：居中偏上，头顶只有小血条（名字在右上副本面板里）。
  Widget _buildBoss(GameMonster monster) {
    final center = _monsterCenter;
    return Positioned(
      left: center.dx - _nameTagW / 2,
      top: center.dy - _bossH / 2 - 12,
      width: _nameTagW,
      child: Opacity(
        opacity: _monsterDying ? 0.25 : (_monsterFlash ? 0.6 : 1.0),
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
              _FighterFigure(
                width: _bossW,
                height: _bossH,
                child: CustomPaint(
                  size: const Size(_bossW, _bossH),
                  painter: _BattleMonsterPainter(monster.kind),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 低阶近身突袭的贴身斩弧（落在 BOSS 身上）。
  Widget _buildSlashArc() {
    final center = _monsterCenter;
    return Positioned(
      left: center.dx - 36,
      top: center.dy - 36,
      width: 72,
      height: 72,
      child: const CustomPaint(painter: _SlashPainter()),
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
        final y = from.dy +
            (to.dy - from.dy) * t -
            math.sin(t * math.pi) * 30 +
            projectile.dyOffset * (1 - t);
        return Positioned(
          left: x - 20,
          top: y - 12,
          width: 40,
          height: 24,
          child: switch (projectile.kind) {
            _ProjectileKind.sword => _SwordMissile(),
            _ProjectileKind.lightning => const CustomPaint(
                size: Size(40, 24),
                painter: _LightningPainter(),
              ),
            _ProjectileKind.flame => _FlameMissile(),
          },
        );
      },
    );
  }

  /// 一次性特效（紫漩涡 / 红爆炸 / 金闪光 / 金环）。
  Widget _buildBurst(_Burst burst) {
    return AnimatedBuilder(
      animation: burst.controller,
      builder: (context, _) {
        final t = burst.controller.value;
        final size = 60 + t * 90;
        return Positioned(
          left: burst.center.dx - size / 2,
          top: burst.center.dy - size / 2,
          width: size,
          height: size,
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
                    border: Border.all(
                      color: const Color(0xFFFFD54F),
                      width: 3,
                    ),
                  ),
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
          _ArrowTag(
            label: '和平',
            onTap: () => _showToast('单机模式：和平'),
          ),
          const SizedBox(height: 6),
          _ArrowTag(
            label: '状态',
            onTap: widget.onOpenProfile,
          ),
          const SizedBox(height: 6),
          _ArrowTag(
            label: '药品',
            onTap: widget.onOpenShop,
          ),
          const SizedBox(height: 6),
          _ArrowTag(
            label: '目标',
            onTap: widget.onOpenTasks,
          ),
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
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                ),
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

  /// 右下横排金棕菱形技能栏：6-7 个，只做冷却展示，
  /// 冷却好了自动放，不用手点。
  Widget _buildSkillDiamonds() {
    final now = DateTime.now();
    final skills = <({String shortName, double progress})>[];
    // 普攻：1.6 秒一剑。
    final basicElapsed =
        now.difference(_lastBasicAt).inMilliseconds / 1600;
    skills.add((shortName: '普攻', progress: basicElapsed.clamp(0.0, 1.0)));
    for (final skill in gameSkillsForProfession(widget.profession)) {
      if (skill.profession == '共用') continue;
      skills.add((
        shortName: skill.name.substring(0, 2),
        progress: _skillProgress(skill.id, const Duration(seconds: 6), now),
      ));
    }
    for (final id in ['bixie', 'qianlan']) {
      final skill = gameSkillsById(id);
      if (skill == null) continue;
      skills.add((
        shortName: skill.name.substring(0, 2),
        progress: _skillProgress(id, const Duration(seconds: 8), now),
      ));
    }
    final ult = gameSkillsById('jingzhe');
    if (ult != null) {
      skills.add((
        shortName: '惊蛰',
        progress:
            _skillProgress(ult.id, const Duration(seconds: 20), now),
      ));
    }
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
  double _skillProgress(
    String skillId,
    Duration total,
    DateTime now,
  ) {
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
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                ),
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

/// 飞行法宝的种类。
enum _ProjectileKind {
  /// 青竹蜂云剑：绿光飞剑。
  sword,

  /// 辟邪神雷：黄色闪电。
  lightning,

  /// 乾蓝冰焰：蓝色火球。
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

/// 一个托机器人（地图里随机走动打怪）。
class _AmbientBot {
  _AmbientBot({
    required this.name,
    required this.realm,
    required this.baseX,
    required this.baseY,
    required this.phase,
    required this.speed,
    required this.colorIndex,
  });

  final String name;
  final String realm;

  /// 基准位置（0..1 相对值）。
  final double baseX;
  final double baseY;
  final double phase;
  final double speed;
  final int colorIndex;
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
  const _HpBar({
    required this.ratio,
    required this.width,
    required this.color,
  });

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
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
        ),
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
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
              ),
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
          CustomPaint(
            size: const Size(10, 30),
            painter: _ArrowHeadPainter(),
          ),
          Container(
            width: 52,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.75),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
              ),
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
                child: Icon(
                  icon,
                  size: 15,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 9,
            ),
          ),
        ],
      ),
    );
  }
}

/// 技能菱形（只做冷却展示）：金棕菱形，冷却时蒙黑 + 秒数，
/// 冷却好了亮金边。
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
        Transform.rotate(
          angle: math.pi / 4,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFB8860B), Color(0xFF6B4E00)],
              ),
              border: Border.all(
                color: ready
                    ? const Color(0xFFFFD54F)
                    : Colors.white.withValues(alpha: 0.35),
                width: 1.2,
              ),
              boxShadow: ready
                  ? [
                      BoxShadow(
                        color: Colors.amber.withValues(alpha: 0.5),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              children: [
                if (!ready)
                  Container(
                    color: Colors.black.withValues(
                      alpha: 0.65 * (1 - progress),
                    ),
                  ),
                Transform.rotate(
                  angle: -math.pi / 4,
                  child: Center(
                    child: Text(
                      ready ? '●' : '${((1 - progress) * 10).ceil()}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 9,
          ),
        ),
      ],
    );
  }
}

/// 青竹蜂云剑飞弹：绿光剑身。
class _SwordMissile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.35,
      child: Container(
        width: 38,
        height: 7,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          gradient: const LinearGradient(
            colors: [Color(0xFF69F0AE), Color(0xFF00C853), Color(0xFFE8F5E9)],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.greenAccent.withValues(alpha: 0.7),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

/// 乾蓝冰焰飞弹：蓝色火球。
class _FlameMissile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFF4FC3F7), Color(0xFF01579B)],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.lightBlueAccent.withValues(alpha: 0.8),
            blurRadius: 14,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}

/// 斜俯视 45 度场景：远山、青灰石板地面、纵深、法阵光。
class _ArenaPainter extends CustomPainter {
  const _ArenaPainter();

  @override
  void paint(Canvas canvas, Size size) {
    // 远山三层剪影。
    final mountainPaint = Paint()..style = PaintingStyle.fill;
    final ridges = [
      (0.72, const Color(0xFF241B4D)),
      (0.6, const Color(0xFF2E2358)),
      (0.5, const Color(0xFF3A2E6E)),
    ];
    for (final (top, color) in ridges) {
      mountainPaint.color = color;
      final path = Path()..moveTo(0, size.height * top);
      const peaks = [
        (0.0, 0.0),
        (0.12, -0.06),
        (0.25, 0.01),
        (0.38, -0.08),
        (0.52, 0.0),
        (0.66, -0.05),
        (0.8, 0.01),
        (0.92, -0.04),
        (1.0, 0.0),
      ];
      for (final (fx, dy) in peaks) {
        path.lineTo(size.width * fx, size.height * top + dy * size.height);
      }
      path
        ..lineTo(size.width, size.height * 0.62)
        ..lineTo(0, size.height * 0.62)
        ..close();
      canvas.drawPath(path, mountainPaint);
    }
    // 云雾。
    final cloudPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.fill;
    for (final (fx, fy, r) in [
      (0.2, 0.16, 46.0),
      (0.55, 0.10, 60.0),
      (0.85, 0.2, 40.0),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * fx, size.height * fy),
          width: r * 2.4,
          height: r,
        ),
        cloudPaint,
      );
    }
    // 地面：从 50% 高度起的青灰石板地（带纵深透视）。
    final groundTop = size.height * 0.5;
    final groundPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Color(0xFF3A4157), Color(0xFF232839)],
      ).createShader(
        Rect.fromLTWH(0, groundTop, size.width, size.height - groundTop),
      );
    canvas.drawRect(
      Rect.fromLTWH(0, groundTop, size.width, size.height - groundTop),
      groundPaint,
    );
    // 石板缝：横线越往下越疏（透视），竖线向灭点收。
    final linePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..strokeWidth = 1.2;
    for (var i = 1; i <= 5; i++) {
      final y =
          groundTop + (size.height - groundTop) * (i * i) / 25;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
    final vanishing = Offset(size.width / 2, groundTop - 30);
    for (final fx in [0.05, 0.2, 0.35, 0.65, 0.8, 0.95]) {
      canvas.drawLine(
        Offset(size.width * fx, size.height),
        vanishing,
        linePaint,
      );
    }
    // 石板色差：几块略深的板。
    final slabPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.08, groundTop + 40, size.width * 0.3, 60),
      slabPaint,
    );
    canvas.drawRect(
      Rect.fromLTWH(size.width * 0.6, groundTop + 130, size.width * 0.32, 70),
      slabPaint,
    );
    // 法阵光：小队脚下金阵、BOSS 脚下红阵（对到新站位）。
    _drawMagicCircle(
      canvas,
      Offset(size.width * 0.5, size.height * 0.47),
      100,
      const Color(0xFFD4A017),
    );
    _drawMagicCircle(
      canvas,
      Offset(size.width * 0.5, size.height * 0.27),
      76,
      const Color(0xFFE53935),
    );
    // 两边火把光晕。
    final torchPaint = Paint()
      ..color = Colors.orange.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    for (final fx in [0.04, 0.96]) {
      canvas.drawCircle(
        Offset(size.width * fx, size.height * 0.62),
        32,
        torchPaint,
      );
    }
    // 漂浮灵光（固定点位的小金点）。
    final motePaint = Paint()
      ..color = Colors.amber.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    const motes = [
      (0.1, 0.3),
      (0.3, 0.42),
      (0.62, 0.24),
      (0.9, 0.44),
      (0.45, 0.52),
      (0.75, 0.58),
      (0.18, 0.66),
    ];
    for (final (fx, fy) in motes) {
      canvas.drawCircle(
        Offset(size.width * fx, size.height * fy),
        2.5,
        motePaint,
      );
    }
  }

  void _drawMagicCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
  ) {
    final ring = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, ring);
    final inner = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.7, inner);
    final glow = Paint()
      ..color = color.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 1.25, glow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 50 个托机器人：随机走动、随机放技能的小人 + 名字境界。
/// 名字只排版一次缓存起来，每帧只重绘位置。
class _AmbientBotsPainter extends CustomPainter {
  _AmbientBotsPainter({
    required this.bots,
    required this.time,
    required this.labelCache,
  });

  final List<_AmbientBot> bots;

  /// 0..1 循环时间。
  final double time;

  /// 名字排版缓存（State 里持有，不随每帧重建）。
  final Map<int, TextPainter> labelCache;

  static const _robeColors = <Color>[
    Color(0xFF5B8C7B),
    Color(0xFF7B5BA6),
    Color(0xFFB03A2E),
    Color(0xFF5B7A9E),
    Color(0xFF8D6E00),
    Color(0xFF2B2B33),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < bots.length; i++) {
      final bot = bots[i];
      final t = time * math.pi * 2 * bot.speed + bot.phase;
      // 摆动幅度小（x 1.2% 屏宽、y 0.8% 屏高），托机器人只在
      // 各自的边缘带里晃，不会晃进主战场中央。
      final x = bot.baseX * size.width +
          math.sin(t) * size.width * 0.012;
      final y = bot.baseY * size.height +
          math.cos(t * 0.7) * size.height * 0.008;
      // 脚下影子。
      final shadow = Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, y + 11), width: 12, height: 3),
        shadow,
      );
      // 袍子（小三角）。
      final robe = Paint()
        ..color = _robeColors[bot.colorIndex]
        ..style = PaintingStyle.fill;
      final robePath = Path()
        ..moveTo(x, y - 10)
        ..lineTo(x - 5.5, y + 10)
        ..lineTo(x + 5.5, y + 10)
        ..close();
      canvas.drawPath(robePath, robe);
      // 头。
      final head = Paint()
        ..color = const Color(0xFFE8C39E)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(x, y - 12), 3.5, head);
      // 随机放技能：小金星一闪。
      if ((t % (math.pi * 2)) < 0.5) {
        final star = Paint()
          ..color = Colors.amber.withValues(alpha: 0.85)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(x + 8, y - 15), 2, star);
      }
      // 名字 + 境界（6px 小白字）。
      var label = labelCache[i];
      if (label == null) {
        label = TextPainter(
          text: TextSpan(
            text: '${bot.realm} ${bot.name}',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 6,
              shadows: [Shadow(color: Colors.black, offset: Offset(1, 1))],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        labelCache[i] = label;
      }
      label.paint(canvas, Offset(x - label.width / 2, y - 22));
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientBotsPainter oldDelegate) =>
      oldDelegate.time != time;
}

/// 大招金色螺旋光环：三圈金色虚线环 + 螺旋弧，罩全队。
class _GoldHaloPainter extends CustomPainter {
  const _GoldHaloPainter({required this.rotation});

  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final gold = Paint()
      ..color = const Color(0xFFFFD54F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final faint = Paint()
      ..color = const Color(0xFFFFD54F).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (var ring = 0; ring < 3; ring++) {
      final radius = size.width * (0.2 + ring * 0.11);
      final paint = ring == 1 ? gold : faint;
      for (var seg = 0; seg < 8; seg++) {
        final start = rotation + seg * math.pi / 4;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          math.pi / 5,
          false,
          paint,
        );
      }
    }
    // 螺旋弧：从内向外旋出去。
    final spiral = Paint()
      ..color = const Color(0xFFFFE082)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    for (var k = 0; k < 5; k++) {
      final path = Path();
      for (var a = 0.0; a <= math.pi * 1.5; a += 0.15) {
        final r = 20 + a * 14 + k * 6;
        final x = center.dx + r * math.cos(a + rotation + k);
        final y = center.dy + r * math.sin(a + rotation + k);
        if (a == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, spiral);
    }
  }

  @override
  bool shouldRepaint(covariant _GoldHaloPainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}

/// 紫漩涡：旋转的紫色弧光。
class _VortexPainter extends CustomPainter {
  const _VortexPainter({required this.rotation});

  final double rotation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = const Color(0xFFAB47BC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (var ring = 0; ring < 3; ring++) {
      final radius = size.width * (0.16 + ring * 0.1);
      for (var seg = 0; seg < 6; seg++) {
        final start = rotation + seg * math.pi / 3;
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius),
          start,
          math.pi / 4,
          false,
          paint,
        );
      }
    }
    final core = Paint()
      ..color = const Color(0xFF4A148C).withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, size.width * 0.12, core);
  }

  @override
  bool shouldRepaint(covariant _VortexPainter oldDelegate) =>
      oldDelegate.rotation != rotation;
}

/// 写实妖兽立绘：鳞甲、獠牙、利爪、发光兽瞳，没有腮红没有大圆眼。
class _BattleMonsterPainter extends CustomPainter {
  const _BattleMonsterPainter(this.kind);

  final GameMonsterKind kind;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.55;
    final bodyColor = switch (kind) {
      GameMonsterKind.wolf => const Color(0xFF5D4037),
      GameMonsterKind.jiao => const Color(0xFF1B5E20),
      GameMonsterKind.spider => const Color(0xFF311B92),
      GameMonsterKind.mantis => const Color(0xFF33691E),
      GameMonsterKind.ant => const Color(0xFF4E342E),
      GameMonsterKind.python => const Color(0xFF00695C),
      GameMonsterKind.demon => const Color(0xFF4A148C),
      GameMonsterKind.ghost => const Color(0xFF90A4AE),
      GameMonsterKind.king => const Color(0xFF8D6E00),
    };
    final bellyColor = switch (kind) {
      GameMonsterKind.ghost => const Color(0xFFECEFF1),
      GameMonsterKind.king => const Color(0xFFFFD54F),
      _ => const Color(0xFF212121),
    };
    // 尾巴（蛟 / 蟒 / 蛟王拖长尾）。
    if (kind == GameMonsterKind.jiao ||
        kind == GameMonsterKind.python ||
        kind == GameMonsterKind.king) {
      final tailPaint = Paint()
        ..color = bodyColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 14
        ..strokeCap = StrokeCap.round;
      final tail = Path()
        ..moveTo(cx - 26, cy + 34)
        ..quadraticBezierTo(cx - 60, cy + 60, cx - 44, cy + 82);
      canvas.drawPath(tail, tailPaint);
    }
    // 腿 / 爪（蜘蛛 8 条、螳螂刀臂、其余 4 条）。
    final legPaint = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final legCount = switch (kind) {
      GameMonsterKind.spider => 8,
      GameMonsterKind.mantis => 2,
      GameMonsterKind.ghost => 0,
      _ => 4,
    };
    for (var i = 0; i < legCount; i++) {
      final side = i.isEven ? -1 : 1;
      final spread = (i ~/ 2 + 1) * 12.0;
      final start = Offset(cx + side * 30, cy + 8 + spread * 0.4);
      final mid = Offset(cx + side * 50, cy + 28 + spread * 0.5);
      final end = Offset(cx + side * 45, cy + 52 + spread * 0.5);
      canvas.drawLine(start, mid, legPaint);
      canvas.drawLine(mid, end, legPaint);
    }
    // 身体：椭圆 + 鳞甲纹。
    final bodyPaint = Paint()
      ..color = bodyColor
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: size.width * 0.72,
        height: size.height * 0.52,
      ),
      bodyPaint,
    );
    final scalePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var row = 0; row < 3; row++) {
      for (var col = -2; col <= 2; col++) {
        canvas.drawArc(
          Rect.fromCenter(
            center: Offset(cx + col * 14, cy - 12 + row * 16),
            width: 16,
            height: 11,
          ),
          0,
          math.pi,
          false,
          scalePaint,
        );
      }
    }
    // 腹部。
    final bellyPaint = Paint()
      ..color = bellyColor.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, cy + 19),
        width: size.width * 0.4,
        height: size.height * 0.24,
      ),
      bellyPaint,
    );
    // 角（蛟 / 魔 / 王）。
    if (kind == GameMonsterKind.jiao ||
        kind == GameMonsterKind.king ||
        kind == GameMonsterKind.demon) {
      final hornPaint = Paint()
        ..color = kind == GameMonsterKind.king
            ? const Color(0xFFFFD54F)
            : const Color(0xFFD7CCC8)
        ..style = PaintingStyle.fill;
      for (final side in [-1, 1]) {
        final horn = Path()
          ..moveTo(cx + side * 16, cy - 38)
          ..lineTo(cx + side * 30, cy - 72)
          ..lineTo(cx + side * 9, cy - 50)
          ..close();
        canvas.drawPath(horn, hornPaint);
      }
    }
    // 狼耳。
    if (kind == GameMonsterKind.wolf) {
      final earPaint = Paint()
        ..color = bodyColor
        ..style = PaintingStyle.fill;
      for (final side in [-1, 1]) {
        final ear = Path()
          ..moveTo(cx + side * 22, cy - 34)
          ..lineTo(cx + side * 32, cy - 56)
          ..lineTo(cx + side * 12, cy - 44)
          ..close();
        canvas.drawPath(ear, earPaint);
      }
    }
    // 发光兽瞳：红 / 橙竖瞳，没有大圆眼。
    final eyeGlow = Paint()
      ..color = Colors.red.withValues(alpha: 0.45)
      ..style = PaintingStyle.fill;
    final eyePaint = Paint()
      ..color = const Color(0xFFFF1744)
      ..style = PaintingStyle.fill;
    final pupilPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    final eyeY = cy - 15;
    if (kind == GameMonsterKind.spider) {
      for (var i = -1; i <= 1; i++) {
        final ex = cx + i * 14;
        canvas.drawCircle(Offset(ex, eyeY), 6, eyeGlow);
        canvas.drawCircle(Offset(ex, eyeY), 3.5, eyePaint);
      }
    } else if (kind == GameMonsterKind.ghost) {
      // 鬼物：空洞黑眼 + 青光。
      final hollow = Paint()
        ..color = Colors.black.withValues(alpha: 0.85)
        ..style = PaintingStyle.fill;
      for (final side in [-1, 1]) {
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx + side * 14, eyeY),
            width: 14,
            height: 17,
          ),
          hollow,
        );
        canvas.drawCircle(
          Offset(cx + side * 14, eyeY + 2),
          2.5,
          Paint()..color = const Color(0xFF80DEEA),
        );
      }
    } else {
      for (final side in [-1, 1]) {
        final ex = cx + side * 15;
        canvas.drawCircle(Offset(ex, eyeY), 8, eyeGlow);
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(ex, eyeY),
            width: 11,
            height: 7,
          ),
          eyePaint,
        );
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(ex, eyeY),
            width: 3,
            height: 7,
          ),
          pupilPaint,
        );
      }
    }
    // 獠牙。
    final fangPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    for (final side in [-1, 1]) {
      final fang = Path()
        ..moveTo(cx + side * 12 - 4, cy + 5)
        ..lineTo(cx + side * 12 + 4, cy + 5)
        ..lineTo(cx + side * 12, cy + 17)
        ..close();
      canvas.drawPath(fang, fangPaint);
    }
    // 蟒信子。
    if (kind == GameMonsterKind.python) {
      final tonguePaint = Paint()
        ..color = const Color(0xFFE53935)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      final tongue = Path()
        ..moveTo(cx, cy + 19)
        ..lineTo(cx - 3, cy + 34)
        ..moveTo(cx, cy + 19)
        ..lineTo(cx + 3, cy + 34);
      canvas.drawPath(tongue, tonguePaint);
    }
    // 螳螂刀臂。
    if (kind == GameMonsterKind.mantis) {
      final bladePaint = Paint()
        ..color = const Color(0xFF9CCC65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      for (final side in [-1, 1]) {
        canvas.drawLine(
          Offset(cx + side * 31, cy - 5),
          Offset(cx + side * 53, cy - 29),
          bladePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BattleMonsterPainter oldDelegate) =>
      oldDelegate.kind != kind;
}

/// 近身斩弧：白色弧光。
class _SlashPainter extends CustomPainter {
  const _SlashPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final arcPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
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
    final glowPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
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
      glowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 辟邪神雷：黄色锯齿闪电。
class _LightningPainter extends CustomPainter {
  const _LightningPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(4, 2)
      ..lineTo(26, 2)
      ..lineTo(18, 12)
      ..lineTo(34, 12)
      ..lineTo(12, 26)
      ..lineTo(20, 15)
      ..lineTo(6, 15)
      ..close();
    final glow = Paint()
      ..color = Colors.yellow.withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, glow);
    final bolt = Paint()
      ..color = const Color(0xFFFFEA00)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, bolt);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
