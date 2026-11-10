import 'package:flutter/material.dart';

import '../services/game_data.dart';

/// 3D 写实怪物图：五格图按格切分（见
/// ~/workspace/game_ref/renjiepian/art/
/// media-generation-monsters-sheet-*.png，2480x992，
/// 5 格各 496x992，顺序就是下面这五张）。
/// 每格裁掉细边框、压成 360x732 JPG（约 50KB）。
/// 格子底是深蓝底，不是透明图，战场上用金框圆角卡片装，
/// 不直接抠图（黑蛟与紫狼本身就是深色，抠底会吃掉身体）。
const String gameMonsterMoJiaoArt = 'assets/images/game/monster_mo_jiao.jpg';
const String gameMonsterJinGuangMangArt =
    'assets/images/game/monster_jin_guang_mang.jpg';
const String gameMonsterZiDianYaoLangArt =
    'assets/images/game/monster_zi_dian_yao_lang.jpg';
const String gameMonsterChiYanHuoHuArt =
    'assets/images/game/monster_chi_yan_huo_hu.jpg';
const String gameMonsterJinGangJuYuanArt =
    'assets/images/game/monster_jin_gang_ju_yuan.jpg';

/// 四张普通怪图（首领墨蛟不在里面）。
const List<String> gameMonsterCommonArts = [
  gameMonsterJinGuangMangArt,
  gameMonsterZiDianYaoLangArt,
  gameMonsterChiYanHuoHuArt,
  gameMonsterJinGangJuYuanArt,
];

/// 某只怪用什么图（只换美术，不动数值与玩法）：
/// 蛟 / 蛟王固定墨蛟；蟒固定金光蟒；狼固定紫电妖狼；
/// 其余种类按 id 稳定取一只普通怪（id 各字符码求和取余，
/// 同一只怪每次进战场都是同一张，不会每帧乱跳）。
String gameMonsterArtFor(GameMonster monster) {
  switch (monster.kind) {
    case GameMonsterKind.jiao:
    case GameMonsterKind.king:
      return gameMonsterMoJiaoArt;
    case GameMonsterKind.python:
      return gameMonsterJinGuangMangArt;
    case GameMonsterKind.wolf:
      return gameMonsterZiDianYaoLangArt;
    case GameMonsterKind.spider:
    case GameMonsterKind.mantis:
    case GameMonsterKind.ant:
    case GameMonsterKind.demon:
    case GameMonsterKind.ghost:
      final stableHash =
          monster.id.codeUnits.fold(0, (sum, unit) => sum + unit);
      return gameMonsterCommonArts[
          stableHash % gameMonsterCommonArts.length];
  }
}

/// 首领（蛟 / 蛟王）用墨蛟图，战场上放大一圈。
bool gameMonsterArtIsBoss(GameMonster monster) =>
    monster.kind == GameMonsterKind.jiao ||
    monster.kind == GameMonsterKind.king;

/// 怪物金框卡片：圆角 + 金边，图按中央裁切填满。
class GameMonsterArt extends StatelessWidget {
  const GameMonsterArt({
    super.key,
    required this.monster,
    required this.width,
    required this.height,
  });

  final GameMonster monster;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFD4A017),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          gameMonsterArtFor(monster),
          fit: BoxFit.cover,
          alignment: Alignment.center,
        ),
      ),
    );
  }
}
