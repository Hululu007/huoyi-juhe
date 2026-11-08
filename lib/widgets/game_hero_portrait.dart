import 'package:flutter/material.dart';

/// 用户发来的两张豆包 AI 生成图（战场人物 / 档案卡同源）：
/// 男——白发 Q 版小男孩，持剑，浅蓝道袍；
/// 女——白发 Q 版小女孩，浅蓝道袍，站云上。
/// 选男用男图、选女用女图。图是白底方图（2048x2048），
/// 战场上缩成金环圆形徽章用，创建页 / 人物页用整幅圆角卡片。
const String gameHeroMaleAsset = 'assets/images/game/hero_male.jpg';
const String gameHeroFemaleAsset = 'assets/images/game/hero_female.jpg';

String gameHeroAssetForGender(bool isFemale) =>
    isFemale ? gameHeroFemaleAsset : gameHeroMaleAsset;

/// 战场小头像：金环圆形徽章，图按头顶对齐裁，只占画面高度
/// 十分之一左右，白底边角被圆裁掉。
class GameHeroPortrait extends StatelessWidget {
  const GameHeroPortrait({
    super.key,
    required this.isFemale,
    required this.size,
  });

  final bool isFemale;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0xFFFFD54F),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.amber.withValues(alpha: 0.45),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          gameHeroAssetForGender(isFemale),
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      ),
    );
  }
}

/// 整幅立绘卡片：创建页 / 人物页用，金边圆角，头顶对齐。
class GameHeroFullPortrait extends StatelessWidget {
  const GameHeroFullPortrait({
    super.key,
    required this.isFemale,
    required this.width,
    required this.height,
  });

  final bool isFemale;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFD4AF37),
          width: 2,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image.asset(
          gameHeroAssetForGender(isFemale),
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      ),
    );
  }
}
