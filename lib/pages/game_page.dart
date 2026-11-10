import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/cultivation.dart';
import '../services/game_data.dart';
import '../services/game_service.dart';
import '../services/game_sound.dart';
import '../widgets/game_battle_stage.dart';
import '../widgets/game_hero_portrait.dart';

/// 凡人修仙挂机游戏页：全屏 2.5D 俯视战场（见 [GameBattleStage]），
/// 顶部是元宝 / 境界 + 静音 / 离开 / 金色“观影”切换钮，
/// 其余功能（商城、背包、任务、爬塔、人物、装备、领取、
/// 影视、设置、公告）全是浮在画面上的按钮，点开弹出来用，
/// 不单独占一页、不切走主画面；游戏切走后挂机照常跑
/// （[GameService] 的 5 秒定时器在服务层，不挂页面）。
///
/// 名字：直接用创建人物时起的名字（快照里的 username，原样
/// 显示，不加数字后缀）；ID（HY + 8 位数字）另外单独存、
/// 单独显示，不拼进名字里。观影区“我的”页读的是同一份
/// 快照，游戏里改了名那边跟着变。
///
/// 背景音乐：仙凡缘（实际文件是树里那首《修仙缘》15 秒片段，
/// 见 [GameSoundService]），进游戏 tab 自动播，切走停；
/// 打怪音效（剑气、命中、暴击、大招）与音乐同时播，音量
/// 分开，设置里能分别开关音乐和音效。
class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.active,
    required this.onExit,
    required this.onOpenFilmTab,
    required this.onOpenDramaTab,
    required this.onSwitchToVideo,
  });

  /// 是否当前可见 tab（切走时停背景乐，战场停自动战斗）。
  final bool active;

  /// 离开游戏（回首页 tab）。
  final VoidCallback onExit;

  /// 打开影视 tab（成人节点扣费成功后调）。
  final VoidCallback onOpenFilmTab;

  /// 打开短剧 tab（影视弹窗里的短剧入口调）。
  final VoidCallback onOpenDramaTab;

  /// 右上角“观影”切换钮：3D 翻转切到观影界面。
  final VoidCallback onSwitchToVideo;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  String? _killToast;
  Timer? _killToastTimer;
  bool _offlineBannerDismissed = false;

  GameService get _game => GameService.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_game.ensureInitialized());
    unawaited(GameSoundService.instance.ensureInitialized());
    if (widget.active) {
      unawaited(GameSoundService.instance.startBgm());
    }
  }

  @override
  void didUpdateWidget(GamePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      if (widget.active) {
        unawaited(GameSoundService.instance.startBgm());
      } else {
        unawaited(GameSoundService.instance.stopBgm());
      }
    }
  }

  @override
  void dispose() {
    _killToastTimer?.cancel();
    unawaited(GameSoundService.instance.stopBgm());
    super.dispose();
  }

  /// 当前 BOSS：按推图进度取（第 1 章打野狼，越往后越强）。
  GameMonster get _currentMonster {
    final index = (_game.mapChapterIndex + 1).clamp(0, gameMonsters.length - 1);
    return gameMonsters[index];
  }

  /// 当前副本名（右上黑面板第一行）。
  String get _dungeonName {
    final index = (_game.mapChapterIndex + 1).clamp(0, gameChapters.length - 1);
    return gameChapters[index].dungeon;
  }

  /// 境界短名（“筑基期 后期”→“筑基后期”，头顶与修为条用）。
  String _realmShort(String displayName) =>
      displayName.replaceAll('期', '').replaceAll(' ', '');

  /// 道友满血：1000 + 等级 ×100。
  int get _heroMaxHp => 1000 + _game.level * 100;

  void _showKillToast(String text) {
    _killToastTimer?.cancel();
    setState(() => _killToast = text);
    _killToastTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _killToast = null);
    });
  }

  Future<void> _onMonsterKilled() async {
    final result = await _game.killMonster(_currentMonster);
    final dropped = result.droppedEquipId == null
        ? ''
        : '，掉落${gameEquipmentById(result.droppedEquipId!)?.name ?? ''}';
    _showKillToast(
      '击杀 +${result.xp}修为 +${result.yuanbao}元宝$dropped',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _game,
        CultivationService.instance.snapshotNotifier,
        GameSoundService.instance.musicMutedNotifier,
        GameSoundService.instance.sfxMutedNotifier,
      ]),
      builder: (context, _) {
        final snapshot = CultivationService.instance.snapshot;
        final realm = snapshot.realm;
        final realmShort = _realmShort(realm.displayName);
        final currentThreshold = realm.realm.threshold;
        final nextThreshold = realm.xpToNext > 0
            ? currentThreshold + realm.xpToNext
            : null;
        final xpRatio = nextThreshold == null
            ? 1.0
            : ((snapshot.totalXp - currentThreshold) /
                    (nextThreshold - currentThreshold))
                .clamp(0.0, 1.0);
        final xpLabel = nextThreshold == null
            ? '$realmShort ${snapshot.totalXp}/封顶'
            : '$realmShort ${snapshot.totalXp}/$nextThreshold';
        final offline = _game.lastOfflineReward;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 全屏战场。
            GameBattleStage(
              monster: _currentMonster,
              heroPower: _game.power,
              heroMaxHp: _heroMaxHp,
              profession: snapshot.profession,
              heroName: snapshot.username,
              heroRealm: realmShort,
              heroIsFemale:
                  snapshot.gender == CultivationGender.female,
              heroXp: snapshot.totalXp,
              dungeonName: _dungeonName,
              xpLabel: xpLabel,
              xpRatio: xpRatio,
              heroCostume:
                  cultivationCostumeById(snapshot.costumeId),
              active: widget.active,
              onMonsterKilled: _onMonsterKilled,
              onHeroStrike: (_) {},
              onOpenShop: () => _openSheet(context, _ShopSheet()),
              onOpenTasks: () => _openSheet(context, _TasksSheet()),
              onOpenProfile: () => _openSheet(context, _ProfileSheet()),
              onOpenFunctions: () =>
                  _openSheet(context, _FunctionsSheet(
                    onOpen: (kind) => _openFunction(context, kind),
                  )),
              onOpenAnnounce: () =>
                  _openSheet(context, _AnnounceSheet()),
            ),
            // 顶部栏：元宝 / 境界 + 静音 / 离开 / 金色“观影”。
            Positioned(
              top: MediaQuery.paddingOf(context).top + 6,
              left: 12,
              right: 12,
              child: Row(
                children: [
                  _TopPill(
                    icon: LucideIcons.coins,
                    text: '${_game.yuanbao}',
                    color: const Color(0xFFFFD54F),
                  ),
                  const SizedBox(width: 8),
                  _TopPill(
                    icon: LucideIcons.sparkles,
                    text: realmShort,
                    color: const Color(0xFF69F0AE),
                  ),
                  const Spacer(),
                  _TopIconButton(
                    icon: GameSoundService.instance.allMuted
                        ? LucideIcons.volume_x
                        : LucideIcons.volume_2,
                    onTap: () async {
                      final target =
                          !GameSoundService.instance.allMuted;
                      await GameSoundService.instance.setAllMuted(target);
                    },
                  ),
                  const SizedBox(width: 8),
                  _TopTextButton(
                    label: '离开',
                    onTap: widget.onExit,
                  ),
                  const SizedBox(width: 8),
                  _SwitchVideoButton(onTap: widget.onSwitchToVideo),
                ],
              ),
            ),
            // 离线收益横幅（进游戏时弹一次）。
            if (offline != null && !_offlineBannerDismissed)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 58,
                left: 24,
                right: 24,
                child: GestureDetector(
                  onTap: () {
                    setState(() => _offlineBannerDismissed = true);
                    _game.clearOfflineReward();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.amber.shade700,
                          Colors.amber.shade500,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          LucideIcons.moon_star,
                          color: Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '离线${offline.seconds ~/ 3600}小时'
                            '${(offline.seconds % 3600) ~/ 60}分：'
                            '+${offline.xp}修为 +${offline.yuanbao}元宝',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Icon(
                          LucideIcons.x,
                          color: Colors.white,
                          size: 16,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 击杀结算提示。
            if (_killToast != null)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 108,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      _killToast!,
                      style: const TextStyle(
                        color: Color(0xFFFFD54F),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 功能菜单里点开某一项：先关菜单，再开对应弹窗。
  void _openFunction(BuildContext context, _FunctionKind kind) {
    Navigator.of(context).pop();
    switch (kind) {
      case _FunctionKind.shop:
        _openSheet(context, _ShopSheet());
      case _FunctionKind.inventory:
        _openSheet(context, _InventorySheet());
      case _FunctionKind.tasks:
        _openSheet(context, _TasksSheet());
      case _FunctionKind.tower:
        _openSheet(context, _TowerSheet());
      case _FunctionKind.profile:
        _openSheet(context, _ProfileSheet());
      case _FunctionKind.equipment:
        _openSheet(context, _EquipmentSheet());
      case _FunctionKind.rewards:
        _openSheet(context, _RewardsSheet());
      case _FunctionKind.film:
        _openSheet(context, _FilmSheet(
          onOpenFilmTab: widget.onOpenFilmTab,
          onOpenDramaTab: widget.onOpenDramaTab,
        ));
      case _FunctionKind.settings:
        _openSheet(context, _SettingsSheet(onExit: widget.onExit));
    }
  }

  /// 底部弹窗（深色底，内容可滚动，游戏在后面照常打）。
  Future<void> _openSheet(BuildContext context, Widget child) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF1B1535),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
          child: child,
        ),
      ),
    );
  }
}

/// 功能菜单项。
enum _FunctionKind {
  shop,
  inventory,
  tasks,
  tower,
  profile,
  equipment,
  rewards,
  film,
  settings,
}

/// 顶部小 pill（元宝 / 境界）。
class _TopPill extends StatelessWidget {
  const _TopPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部圆形图标钮（静音）。
class _TopIconButton extends StatelessWidget {
  const _TopIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}

/// 顶部文字钮（离开）。
class _TopTextButton extends StatelessWidget {
  const _TopTextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 右上角醒目的金色“观影”切换钮：点一下 3D 翻转切到观影界面。
class _SwitchVideoButton extends StatelessWidget {
  const _SwitchVideoButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Colors.amber.shade600, Colors.amber.shade400],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
          boxShadow: [
            BoxShadow(
              color: Colors.amber.withValues(alpha: 0.55),
              blurRadius: 14,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.clapperboard, size: 18, color: Colors.white),
            SizedBox(width: 6),
            Text(
              '观影',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹窗标题行。
class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              color: const Color(0xFFD4A017),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 弹窗里的小操作按钮。
class _SheetButton extends StatelessWidget {
  const _SheetButton({
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.gold = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: enabled
              ? (gold
                  ? const Color(0xFF8D6E00)
                  : Colors.white.withValues(alpha: 0.12))
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? const Color(0xFFD4A017)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.white : Colors.white38,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 弹窗里的一行（名 + 说明 + 右侧按钮）。
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          action,
        ],
      ),
    );
  }
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 功能菜单：商城 / 背包 / 任务 / 爬塔 / 人物 / 装备 /
/// 领取 / 影视 / 设置，点开对应弹窗。
class _FunctionsSheet extends StatelessWidget {
  const _FunctionsSheet({required this.onOpen});

  final ValueChanged<_FunctionKind> onOpen;

  @override
  Widget build(BuildContext context) {
    const items = <(_FunctionKind, String, IconData)>[
      (_FunctionKind.shop, '商城', LucideIcons.shopping_bag),
      (_FunctionKind.inventory, '背包', LucideIcons.backpack),
      (_FunctionKind.tasks, '任务', LucideIcons.scroll_text),
      (_FunctionKind.tower, '爬塔', LucideIcons.layers),
      (_FunctionKind.profile, '人物', LucideIcons.user),
      (_FunctionKind.equipment, '装备', LucideIcons.shield),
      (_FunctionKind.rewards, '领取', LucideIcons.gift),
      (_FunctionKind.film, '影视', LucideIcons.clapperboard),
      (_FunctionKind.settings, '设置', LucideIcons.settings),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SheetTitle(title: '功能'),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.25,
          children: [
            for (final (kind, label, icon) in items)
              GestureDetector(
                onTap: () => onOpen(kind),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: const Color(0xFFD4A017), size: 24),
                      const SizedBox(height: 6),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 商城：聚气丹 / 双倍修为符 / 法宝盲盒（元宝买）。
class _ShopSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(
              title: '商城',
              trailing: Text(
                '元宝 ${game.yuanbao}',
                style: const TextStyle(
                  color: Color(0xFFFFD54F),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final item in gameShopItems)
              _SheetRow(
                title: '${item.name} · ${item.price}元宝',
                subtitle: item.desc,
                action: _SheetButton(
                  label: '购买',
                  enabled: game.yuanbao >= item.price,
                  onTap: () async {
                    final result = await game.buyShop(item.id);
                    if (!context.mounted) return;
                    _snack(context, result ?? '元宝不够');
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 背包：已拥有的装备，穿戴 / 强化 / 分解；自动合成与自动补材料开关。
class _InventorySheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        final owned = game.ownedEquip.entries
            .map((e) => (equip: gameEquipmentById(e.key), count: e.value))
            .where((row) => row.equip != null)
            .toList();
        final synth = game.lastSynthesizeResults;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(
              title: '背包',
              trailing: Text(
                '元宝 ${game.yuanbao}',
                style: const TextStyle(
                  color: Color(0xFFFFD54F),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            if (synth.isNotEmpty)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFD4A017).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final result in synth)
                      Text(
                        '自动合成：${gameEquipmentById(result.resultId)?.name ?? ''}（${gameEquipQualityName(gameEquipmentById(result.resultId)?.quality ?? GameEquipQuality.white)}）',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    const SizedBox(height: 6),
                    _SheetButton(
                      label: '知道了',
                      gold: false,
                      onTap: () => game.clearSynthesizeResults(),
                    ),
                  ],
                ),
              ),
            _SheetRow(
              title: '自动合成：${game.autoSynthesizeEnabled ? '开' : '关'}',
              subtitle:
                  '3 件同品质同部位自动合成高一档（3 绿→1 蓝，以此类推到七彩）',
              action: Switch(
                value: game.autoSynthesizeEnabled,
                onChanged: (value) async {
                  await game.setAutoSynthesize(value);
                },
              ),
            ),
            _SheetRow(
              title: '自动补材料：${game.autoRefineMaterialEnabled ? '开' : '关'}',
              subtitle: '强化元宝不够时，自动分解多余的低级装备补元宝（七彩不分）',
              action: Switch(
                value: game.autoRefineMaterialEnabled,
                onChanged: (value) async {
                  await game.setAutoRefineMaterial(value);
                },
              ),
            ),
            _SheetRow(
              title: '立即合成',
              subtitle: '把背包里所有满 3 件的同品质同部位合成高一档',
              action: _SheetButton(
                label: '合成',
                onTap: () async {
                  final results = game.synthesizeAll();
                  await game.persist();
                  if (!context.mounted) return;
                  if (results.isEmpty) {
                    _snack(context, '没有满 3 件可合成的装备');
                  } else {
                    final names = [
                      for (final r in results)
                        gameEquipmentById(r.resultId)?.name ?? '',
                    ].join('、');
                    _snack(context, '合成出：$names');
                  }
                },
              ),
            ),
            if (owned.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '背包还是空的，去打怪掉装备吧',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ),
              ),
            for (final row in owned)
              _SheetRow(
                title:
                    '${row.equip!.name} · ${gameEquipQualityName(row.equip!.quality)}'
                    '${row.count > 1 ? ' ×${row.count}' : ''}',
                subtitle:
                    '${gameEquipSlotName(row.equip!.slot)} 攻+${row.equip!.attack} '
                    '防+${row.equip!.defense} 血+${row.equip!.hp}'
                    ' · 强化 Lv.${game.refine[row.equip!.id] ?? 0}'
                    ' · ${gameEquipDropSource(row.equip!.quality)}',
                action: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _SheetButton(
                      label:
                          game.equipped[row.equip!.slot.name] == row.equip!.id
                              ? '已穿戴'
                              : '穿戴',
                      gold: false,
                      enabled:
                          game.equipped[row.equip!.slot.name] != row.equip!.id,
                      onTap: () async {
                        final ok = await game.equip(row.equip!.id);
                        if (!context.mounted) return;
                        if (!ok) _snack(context, '境界不够，穿不上');
                      },
                    ),
                    const SizedBox(width: 8),
                    _SheetButton(
                      label:
                          '强化 ${20 * ((game.refine[row.equip!.id] ?? 0) + 1)}',
                      enabled: (game.refine[row.equip!.id] ?? 0) <
                              gameEquipRefineMax &&
                          (game.yuanbao >=
                                  20 *
                                      ((game.refine[row.equip!.id] ?? 0) + 1) ||
                              game.autoRefineMaterialEnabled),
                      onTap: () async {
                        final ok = await game.refineEquip(row.equip!.id);
                        if (!context.mounted) return;
                        if (!ok) {
                          _snack(context, '元宝不够或已满级');
                        } else if (game.lastAutoSalvageNames.isNotEmpty) {
                          _snack(
                            context,
                            '强化成功，自动分解补材料：${game.lastAutoSalvageNames.join('、')}',
                          );
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _SheetButton(
                      label:
                          '分解 +${gameEquipSalvageValue(row.equip!.quality)}',
                      gold: false,
                      enabled: row.equip!.quality !=
                              GameEquipQuality.rainbow &&
                          row.count >
                              (game.equipped[row.equip!.slot.name] ==
                                      row.equip!.id
                                  ? 1
                                  : 0),
                      onTap: () async {
                        final value =
                            await game.salvageEquip(row.equip!.id);
                        if (!context.mounted) return;
                        _snack(
                          context,
                          value > 0 ? '分解得 $value 元宝' : '这件不能分解',
                        );
                      },
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 任务：推图 12 章 + 养成 5 项 + 乱星海狩猎。
class _TasksSheet extends StatefulWidget {
  @override
  State<_TasksSheet> createState() => _TasksSheetState();
}

class _TasksSheetState extends State<_TasksSheet> {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        final nextChapter = game.mapChapterIndex + 1;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetTitle(title: '任务 · 主线推图'),
            for (var i = 0; i < gameChapters.length; i++)
              _SheetRow(
                title:
                    '第${i + 1}章 ${gameChapters[i].title} · ${gameChapters[i].dungeon}',
                subtitle:
                    '${gameChapters[i].subtitle} '
                    '奖励 +${gameChapters[i].xpReward}修为 '
                    '+${gameChapters[i].yuanbaoReward}元宝',
                action: _SheetButton(
                  label: i < nextChapter
                      ? '已通关'
                      : (i == nextChapter ? '挑战' : '未到'),
                  enabled: i == nextChapter,
                  onTap: () async {
                    final xp = await game.completeChapter(i);
                    if (!context.mounted) return;
                    _snack(
                      context,
                      xp == null ? '战力或修为不够' : '通关 +$xp修为',
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            const _SheetTitle(title: '养成任务'),
            for (final quest in gameTrainingQuests)
              _SheetRow(
                title: quest.title,
                subtitle:
                    '${quest.subtitle} 奖励 +${quest.xpReward}修为 '
                    '+${quest.yuanbaoReward}元宝',
                action: _SheetButton(
                  label: game.completedTraining.contains(quest.id)
                      ? '已完成'
                      : '领取',
                  enabled:
                      !game.completedTraining.contains(quest.id),
                  onTap: () async {
                    final ok = await game.completeTraining(quest.id);
                    if (!context.mounted) return;
                    if (!ok) _snack(context, '修为不够');
                  },
                ),
              ),
            const SizedBox(height: 8),
            FutureBuilder<int>(
              future: game.huntsLeft(),
              builder: (context, snapshot) {
                final left = snapshot.data ?? gameHuntPerDay;
                return _SheetRow(
                  title: '乱星海狩猎 · 今天还剩 $left 次',
                  subtitle: '每次 +20 元宝，30% 掉装备',
                  action: _SheetButton(
                    label: '狩猎',
                    enabled: left > 0,
                    onTap: () async {
                      final result = await game.hunt();
                      if (!context.mounted) return;
                      if (result == null) {
                        _snack(context, '今天次数用完了');
                      } else {
                        setState(() {});
                        _snack(context, '狩猎 +20元宝');
                      }
                    },
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// 爬塔：试炼塔 30 层，按副本分组。
class _TowerSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        final groups = <String, List<GameTowerFloor>>{};
        for (final floor in gameTowerFloors) {
          (groups[floor.dungeon] ??= []).add(floor);
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(
              title: '试炼塔 · 已通 ${game.towerFloor}/30 层',
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '每层难度随层数上涨，备好装备再来；通关 30 层得一件七彩装备。',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            for (final entry in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Text(
                  entry.key,
                  style: const TextStyle(
                    color: Color(0xFFD4A017),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              for (final floor in entry.value)
                _SheetRow(
                  title:
                      '第${floor.floor}层 · ${gameMonsterById(floor.monsterId).name}',
                  subtitle:
                      '建议战力 ${floor.requiredPower} · '
                      '奖励 +${floor.xpReward}修为 '
                      '+${floor.yuanbaoReward}元宝',
                  action: _SheetButton(
                    label: floor.floor <= game.towerFloor
                        ? '已过'
                        : (floor.floor == game.towerFloor + 1
                            ? '挑战'
                            : '未到'),
                    enabled: floor.floor == game.towerFloor + 1,
                    onTap: () async {
                      final result =
                          await game.challengeTower(floor.floor);
                      if (!context.mounted) return;
                      _snack(
                        context,
                        result == null
                            ? '战力不够'
                            : '通关 +${result.xp}修为',
                      );
                    },
                  ),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// 人物：全身立在发光台上（不是卡片头像），名字原样显示，
/// ID 另起一行，可改名、可换职业。
class _ProfileSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([
        game,
        CultivationService.instance.snapshotNotifier,
      ]),
      builder: (context, _) {
        final snapshot = CultivationService.instance.snapshot;
        final realm = snapshot.realm;
        final maxHp = 1000 + game.level * 100;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetTitle(title: '人物'),
            Center(
              child: Container(
                width: 180,
                height: 230,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      Colors.amber.withValues(alpha: 0.35),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Center(
                  child: ClipOval(
                    child: GameHeroFullPortrait(
                      isFemale:
                          snapshot.gender == CultivationGender.female,
                      width: 170,
                      height: 220,
                    ),
                  ),
                ),
              ),
            ),
            Center(
              child: Text(
                snapshot.username,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Center(
              child: Text(
                'ID：${snapshot.userId}',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '${realm.displayName} · ${realm.levelLabel} · ${snapshot.profession}',
                style: const TextStyle(
                  color: Color(0xFFD4A017),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SheetRow(
              title: '战力 ${game.power} · 血量 $maxHp',
              subtitle:
                  '攻击 ${game.power}（境界 +${game.basePower} / 装备 +${game.equipPower}）'
                  ' · 防御 ${game.level * 5} · '
                  '修为 ${snapshot.totalXp} · 元宝 ${game.yuanbao}',
              action: _SheetButton(
                label: '改名',
                gold: false,
                onTap: () => _showRenameDialog(context, snapshot.username),
              ),
            ),
            _SheetRow(
              title: '职业：${snapshot.profession}',
              subtitle: '换职业后打坐小人与游戏大招跟着换',
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final profession in cultivationProfessions)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _SheetButton(
                        label: profession,
                        gold: snapshot.profession == profession,
                        enabled: snapshot.profession != profession,
                        onTap: () async {
                          await CultivationService.instance
                              .setProfession(profession);
                        },
                      ),
                    ),
                ],
              ),
            ),
            _SheetRow(
              title: '击杀 ${game.totalKills} · 爬塔 ${game.towerFloor}/30 层',
              subtitle:
                  '推图第 ${game.mapChapterIndex + 1}/12 章',
              action: const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    String currentName,
  ) async {
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF241D47),
        title: const Text(
          '改名',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '输入新名字',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && name != currentName) {
      await CultivationService.instance.renameUser(name);
    }
  }
}

/// 装备：4 个栏位，强化 / 脱下。
class _EquipmentSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(
              title:
                  '装备 · 战力 ${game.power}（境界 ${game.basePower} + 装备 ${game.equipPower}）',
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                '战力主要靠装备：七彩只能合成（3 件红同部位）或通关试炼塔 30 层获得，不直接掉落；强化每级 +12% 属性。',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            for (final slot in GameEquipSlot.values)
              Builder(
                builder: (context) {
                  final equip = game.equippedIn(slot);
                  final refineLevel =
                      equip == null ? 0 : (game.refine[equip.id] ?? 0);
                  return _SheetRow(
                    title: equip == null
                        ? '${gameEquipSlotName(slot)}：空'
                        : '${gameEquipSlotName(slot)}：${equip.name} '
                            '· ${gameEquipQualityName(equip.quality)} '
                            'Lv.$refineLevel',
                    subtitle: equip == null
                        ? '背包里穿戴一件'
                        : '攻+${equip.attack} 防+${equip.defense} '
                            '血+${equip.hp}（品质倍率 ×${gameEquipQualityPowerMultiplier(equip.quality)}，强化每级 +12%）',
                    action: equip == null
                        ? const SizedBox.shrink()
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SheetButton(
                                label:
                                    '强化 ${20 * (refineLevel + 1)}',
                                enabled: refineLevel < gameEquipRefineMax &&
                                    (game.yuanbao >= 20 * (refineLevel + 1) ||
                                        game.autoRefineMaterialEnabled),
                                onTap: () async {
                                  final ok = await game
                                      .refineEquip(equip.id);
                                  if (!context.mounted) return;
                                  if (!ok) {
                                    _snack(context, '元宝不够或已满级');
                                  } else if (game
                                      .lastAutoSalvageNames.isNotEmpty) {
                                    _snack(
                                      context,
                                      '强化成功，自动分解补材料：${game.lastAutoSalvageNames.join('、')}',
                                    );
                                  }
                                },
                              ),
                              const SizedBox(width: 8),
                              _SheetButton(
                                label: '脱下',
                                gold: false,
                                onTap: () async {
                                  await game.unequip(slot);
                                },
                              ),
                            ],
                          ),
                  );
                },
              ),
          ],
        );
      },
    );
  }
}

/// 领取：离线收益、掌天瓶、狩猎、双倍符状态。
class _RewardsSheet extends StatefulWidget {
  @override
  State<_RewardsSheet> createState() => _RewardsSheetState();
}

class _RewardsSheetState extends State<_RewardsSheet> {
  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        final offline = game.lastOfflineReward;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetTitle(title: '领取'),
            if (offline != null)
              _SheetRow(
                title:
                    '离线收益：+${offline.xp}修为 +${offline.yuanbao}元宝',
                subtitle: '离开 ${offline.seconds ~/ 60} 分钟的挂机收益',
                action: _SheetButton(
                  label: '知道了',
                  gold: false,
                  onTap: () => game.clearOfflineReward(),
                ),
              ),
            FutureBuilder<bool>(
              future: game.bottleClaimed(),
              builder: (context, snapshot) {
                final claimed = snapshot.data ?? false;
                return _SheetRow(
                  title: '掌天瓶 · 每天 1 次 +500 修为',
                  subtitle: claimed ? '今天已经领过了' : '小绿瓶今天可以凝一滴了',
                  action: _SheetButton(
                    label: claimed ? '已领' : '领取',
                    enabled: !claimed,
                    onTap: () async {
                      final ok = await game.bottle();
                      if (!context.mounted) return;
                      if (ok) {
                        setState(() {});
                        _snack(context, '掌天瓶 +500修为');
                      }
                    },
                  ),
                );
              },
            ),
            FutureBuilder<int>(
              future: game.huntsLeft(),
              builder: (context, snapshot) {
                final left = snapshot.data ?? gameHuntPerDay;
                return _SheetRow(
                  title: '乱星海狩猎 · 今天还剩 $left 次',
                  subtitle: '每次 +20 元宝，30% 掉装备',
                  action: _SheetButton(
                    label: '狩猎',
                    enabled: left > 0,
                    onTap: () async {
                      final result = await game.hunt();
                      if (!context.mounted) return;
                      if (result == null) {
                        _snack(context, '今天次数用完了');
                      } else {
                        setState(() {});
                        _snack(context, '狩猎 +20元宝');
                      }
                    },
                  ),
                );
              },
            ),
            _SheetRow(
              title: game.doubleXpActive ? '双倍修为符：生效中' : '双倍修为符：未生效',
              subtitle: '商城 100 元宝买，双倍 1 小时',
              action: _SheetButton(
                label: '去商城',
                gold: false,
                onTap: () async {
                  final result = await game.buyShop('double_fu');
                  if (!context.mounted) return;
                  _snack(context, result ?? '元宝不够');
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 影视：短剧在前 + 13 个成人站点节点（通关节点，点亮能看，
/// 看一次扣元宝；普通影视站不扣，只成人站扣）。
/// 扣费记录里的时间：只显示时:分。
String _spendTimeText(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}

/// 扣费记录里的入口：游戏节点进站 / 影视区详情页 / 直接播放。
String _spendSourceText(String source) => switch (source) {
      'game' => '进站（旧）',
      'detail' => '详情页',
      'play' => '直接播放',
      _ => source,
    };

class _FilmSheet extends StatelessWidget {
  const _FilmSheet({
    required this.onOpenFilmTab,
    required this.onOpenDramaTab,
  });

  final VoidCallback onOpenFilmTab;
  final VoidCallback onOpenDramaTab;

  @override
  Widget build(BuildContext context) {
    final game = GameService.instance;
    return AnimatedBuilder(
      animation: game,
      builder: (context, _) {
        final xp = game.totalXp;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SheetTitle(
              title: '影视',
              trailing: Text(
                '元宝 ${game.yuanbao}',
                style: const TextStyle(
                  color: Color(0xFFFFD54F),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: _SheetButton(
                label: '短剧区（不扣元宝）',
                onTap: () {
                  Navigator.of(context).pop();
                  onOpenDramaTab();
                },
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '成人站点：进站免费（境界与塔层够了就能进，不扣元宝）；'
              '影视区进站免费，点一部片子进详情页再扣 20 元宝，同一部'
              '片子一次进入只扣一次。去打怪爬塔做任务赚元宝；普通影视站不扣。',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.1,
              children: [
                for (final node in gameSiteNodes)
                  Builder(
                    builder: (context) {
                      final unlocked =
                          node.unlocked(xp, game.towerFloor);
                      return GestureDetector(
                        onTap: unlocked
                            ? () async {
                                final outcome =
                                    await game.tryEnterAdultSite(
                                  node.coreId,
                                  label: node.label,
                                  source: 'game',
                                );
                                if (!context.mounted) return;
                                if (outcome.allowed) {
                                  Navigator.of(context).pop();
                                  onOpenFilmTab();
                                } else {
                                  _snack(context, '进站失败，稍后再试');
                                }
                              }
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            color: unlocked
                                ? const Color(0xFF8D6E00)
                                    .withValues(alpha: 0.5)
                                : Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: unlocked
                                  ? const Color(0xFFD4A017)
                                  : Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                unlocked
                                    ? LucideIcons.play
                                    : LucideIcons.lock,
                                color: unlocked
                                    ? const Color(0xFFFFD54F)
                                    : Colors.white38,
                                size: 20,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                node.label,
                                style: TextStyle(
                                  color: unlocked
                                      ? Colors.white
                                      : Colors.white54,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                unlocked
                                    ? '进站免费'
                                    : '还差 ${node.xpShort(xp)} 修为'
                                        '${node.floorShort(game.towerFloor) > 0 ? ' / ${node.floorShort(game.towerFloor)} 层塔' : ''}',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              '最近扣费',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedBuilder(
              animation: GameService.instance,
              builder: (context, _) {
                final spends =
                    GameService.instance.adultSpendHistory.take(5).toList();
                if (spends.isEmpty) {
                  return const Text(
                    '暂无扣费记录',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final spend in spends)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${_spendTimeText(spend.timeMillis)} '
                          '${spend.label} -${spend.cost}元宝'
                          '（${_spendSourceText(spend.source)}，'
                          '余额${spend.balanceAfter}）',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// 设置：背景音乐与打怪音效分开开关、分开音量。
class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final sound = GameSoundService.instance;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SheetTitle(title: '设置'),
        ValueListenableBuilder<bool>(
          valueListenable: sound.musicMutedNotifier,
          builder: (context, muted, _) => SwitchListTile(
            title: const Text(
              '背景音乐 · 仙凡缘',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              '进游戏自动播，切走停',
              style: TextStyle(color: Colors.white60),
            ),
            value: !muted,
            activeThumbColor: const Color(0xFFD4A017),
            onChanged: (value) => sound.setMusicMuted(!value),
          ),
        ),
        ValueListenableBuilder<double>(
          valueListenable: sound.musicVolumeNotifier,
          builder: (context, volume, _) => ListTile(
            title: const Text(
              '音乐音量',
              style: TextStyle(color: Colors.white),
            ),
            trailing: SizedBox(
              width: 180,
              child: Slider(
                value: volume,
                activeColor: const Color(0xFFD4A017),
                onChanged: (value) => sound.setMusicVolume(value),
              ),
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: sound.sfxMutedNotifier,
          builder: (context, muted, _) => SwitchListTile(
            title: const Text(
              '打怪音效',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              '剑气、命中、暴击、大招各有音效',
              style: TextStyle(color: Colors.white60),
            ),
            value: !muted,
            activeThumbColor: const Color(0xFFD4A017),
            onChanged: (value) => sound.setSfxMuted(!value),
          ),
        ),
        ValueListenableBuilder<double>(
          valueListenable: sound.sfxVolumeNotifier,
          builder: (context, volume, _) => ListTile(
            title: const Text(
              '音效音量',
              style: TextStyle(color: Colors.white),
            ),
            trailing: SizedBox(
              width: 180,
              child: Slider(
                value: volume,
                activeColor: const Color(0xFFD4A017),
                onChanged: (value) => sound.setSfxVolume(value),
              ),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '单机挂机游戏，不联网、不聊天；全自动找怪、自动寻路、'
            '自动战斗、技能自动放；队友全是机器人。',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ),
        Center(
          child: _SheetButton(
            label: '退出游戏',
            gold: false,
            onTap: () {
              Navigator.of(context).pop();
              onExit();
            },
          ),
        ),
      ],
    );
  }
}

/// 公告：喇叭点开的系统公告（不是聊天）。
class _AnnounceSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const notices = <(String, String)>[
      ('离线收益', '切走、切后台、关掉重开，回来都按离开时长结算修为与元宝，封顶 8 小时。'),
      ('境界解锁', '修为到 3000 解锁影视区，到 8000 解锁全部分类与称号；成人站按修为分 4 档。'),
      ('成人站扣费', '游戏节点与影视区进站都免费；点一部片子进详情页扣 20 元宝，同一部一次进入只扣一次。元宝不够不能看，去打怪爬塔做任务赚。'),
      ('全自动', '找怪、寻路、战斗、技能全自动，不用手操作；点一下战场可以亲手补一剑。'),
      ('单机', '游戏不联网、不聊天，队友与地图里的人全是机器人。'),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SheetTitle(title: '公告'),
        for (final (title, body) in notices)
          _SheetRow(
            title: title,
            subtitle: body,
            action: const SizedBox.shrink(),
          ),
      ],
    );
  }
}
