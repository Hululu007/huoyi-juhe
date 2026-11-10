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

/// 怪物原图比例（360x732 竖幅全身像）：卡片必须按这个比例
/// 开盒，图才能整幅显示不裁切、不拉伸；以前 120x140 的框
/// 配 BoxFit.cover 是横向撑满后上下裁掉约四成，怪的头尾
/// 全被裁掉只剩中间一段，看着像发飘的残片。
const double gameMonsterArtAspect = 360 / 732;

/// 怪物金框卡片：整幅原图按原比例显示，不裁切、不拉伸、
/// 不加半透明、不加模糊影——图本身是深蓝底全身像，
/// 描边和细节直接看得清。卡片只留 1.5 金边，不垫模糊黑影
/// （以前 boxShadow blur 8 的黑晕把卡片边缘罩虚了一层）。
class GameMonsterArt extends StatelessWidget {
  const GameMonsterArt({
    super.key,
    required this.monster,
    required this.width,
    this.artOverride,
  });

  final GameMonster monster;

  /// 卡片宽；高按原图比例算（width * 732 / 360）。
  final double width;

  /// 强制用这张图（小怪按槽位轮着用四张野兽图时用；
  /// 不传就按 [gameMonsterArtFor] 的种类映射取图）。
  final String? artOverride;

  @override
  Widget build(BuildContext context) {
    final height = width / gameMonsterArtAspect;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFD4A017),
          width: 1.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.asset(
          artOverride ?? gameMonsterArtFor(monster),
          fit: BoxFit.cover,
          alignment: Alignment.center,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}
