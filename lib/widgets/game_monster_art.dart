import 'package:flutter/material.dart';

import '../services/game_data.dart';

/// 机械魔蚁图（2026-11-26 用户令：怪物统一改魔蚁、出三只）：
/// 按用户发来的参考图风格生成——金属甲壳、巨眼、触角、
/// 紫红霓虹、火山熔岩氛围；图上不带任何文字与标志。
/// 三张原图 1920x1280，压成 960x640 WebP（约 100–140KB），
/// 四周做椭圆羽化透明：战场上没有卡片框，图缘直接融进
/// 厮杀场景，蚁身本体保持完整不透明。
const String gameMonsterZiDianMoYiArt =
    'assets/images/game/monster_zi_dian_mo_yi.webp';
const String gameMonsterRongYanMoYiArt =
    'assets/images/game/monster_rong_yan_mo_yi.webp';
const String gameMonsterMoYiJunWangArt =
    'assets/images/game/monster_mo_yi_jun_wang.webp';

/// 两张普通魔蚁图（首领魔蚁君王不在里面）。
const List<String> gameMonsterCommonArts = [
  gameMonsterZiDianMoYiArt,
  gameMonsterRongYanMoYiArt,
];

/// 某只怪用什么图（只换美术，不动数值与玩法）：
/// 魔蚁君王固定君王图；熔岩魔蚁固定熔岩图；其余（紫电魔蚁）
/// 固定紫电图。名册只剩三只，一只一图，不再按 id 取余轮换。
String gameMonsterArtFor(GameMonster monster) {
  switch (monster.kind) {
    case GameMonsterKind.antKing:
      return gameMonsterMoYiJunWangArt;
    case GameMonsterKind.ant:
      return monster.id == 'rong_yan_mo_yi'
          ? gameMonsterRongYanMoYiArt
          : gameMonsterZiDianMoYiArt;
  }
}

/// 首领（魔蚁君王）战场上放大一圈。
bool gameMonsterArtIsBoss(GameMonster monster) =>
    monster.kind == GameMonsterKind.antKing;

/// 魔蚁图比例（960x640 横幅全身像）：显示盒必须按这个比例
/// 开，图才能整幅显示不裁切、不拉伸（魔蚁是宽体型，
/// 以前的竖幅比例套不上）。
const double gameMonsterArtAspect = 960 / 640;

/// 怪物场景图：整幅原图按原比例显示，不裁切、不拉伸、
/// 不加半透明、不加模糊影。没有金框、没有圆角卡面——
/// 图本身四周已羽化透明，直接融进战场场景，脚下影子由
/// 战场的立绘容器（_FighterFigure）给。
class GameMonsterArt extends StatelessWidget {
  const GameMonsterArt({
    super.key,
    required this.monster,
    required this.width,
    this.artOverride,
  });

  final GameMonster monster;

  /// 图宽；高按原图比例算（width * 640 / 960）。
  final double width;

  /// 强制用这张图（小怪按槽位轮着用两张普通魔蚁图时用；
  /// 不传就按 [gameMonsterArtFor] 的映射取图）。
  final String? artOverride;

  @override
  Widget build(BuildContext context) {
    final height = width / gameMonsterArtAspect;
    return SizedBox(
      width: width,
      height: height,
      child: Image.asset(
        artOverride ?? gameMonsterArtFor(monster),
        fit: BoxFit.fill,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
      ),
    );
  }
}
