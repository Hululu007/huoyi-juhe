import 'package:flutter/material.dart';

/// 3D 写实主角图（网页版预览同款，见
/// ~/workspace/game_ref/renjiepian/art/）：
/// 男——白发剑修背影，米白长袍金纹、青竹蜂云剑；
/// 女——白发女修背影，同款白袍金纹、青剑。
/// 选男用男图、选女用女图。
/// 全身图 768x1152（原图 1280x1920 压成 JPG，约 170KB）；
/// 半身图是按头顶位置裁的上半身 512 方图，战场圆形徽章
/// 与顶栏头像用它，不会只裁到天空。
const String gameHeroMaleAsset = 'assets/images/game/hero_male_3d.jpg';
const String gameHeroFemaleAsset = 'assets/images/game/hero_female_3d.jpg';
const String gameHeroMaleBustAsset =
    'assets/images/game/hero_male_3d_bust.jpg';
const String gameHeroFemaleBustAsset =
    'assets/images/game/hero_female_3d_bust.jpg';

/// 旧 Q 版豆包图（保留在资源里不删，当回退）。
const String gameHeroMaleLegacyAsset = 'assets/images/game/hero_male.jpg';
const String gameHeroFemaleLegacyAsset =
    'assets/images/game/hero_female.jpg';

String gameHeroAssetForGender(bool isFemale) =>
    isFemale ? gameHeroFemaleAsset : gameHeroMaleAsset;

String gameHeroBustAssetForGender(bool isFemale) =>
    isFemale ? gameHeroFemaleBustAsset : gameHeroMaleBustAsset;

/// 战场小头像：金环圆形徽章，用半身裁切图，头顶在圆心偏上，
/// 只占画面高度十分之一左右。
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
          gameHeroBustAssetForGender(isFemale),
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            isFemale ? gameHeroFemaleLegacyAsset : gameHeroMaleLegacyAsset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
      ),
    );
  }
}

/// 整幅立绘卡片：创建页 / 人物页用，金边圆角。
/// 3D 图人物占画面下三分之二，底部对齐才能看到整个人，
/// 顶部对齐只会看到天空和牌坊。
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
          alignment: Alignment.bottomCenter,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            isFemale ? gameHeroFemaleLegacyAsset : gameHeroMaleLegacyAsset,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
      ),
    );
  }
}
