import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/widgets/game_hero_portrait.dart';
import 'package:fqapp/widgets/game_monster_art.dart';

void main() {
  group('机械魔蚁图映射（只换美术，不动数值与玩法）', () {
    test('魔蚁君王固定君王图，首领放大', () {
      expect(
        gameMonsterArtFor(gameMonsterById('mo_yi_jun_wang')),
        gameMonsterMoYiJunWangArt,
      );
      expect(gameMonsterArtIsBoss(gameMonsterById('mo_yi_jun_wang')), isTrue);
    });

    test('紫电魔蚁固定紫电图，熔岩魔蚁固定熔岩图', () {
      expect(
        gameMonsterArtFor(gameMonsterById('zi_dian_mo_yi')),
        gameMonsterZiDianMoYiArt,
      );
      expect(
        gameMonsterArtFor(gameMonsterById('rong_yan_mo_yi')),
        gameMonsterRongYanMoYiArt,
      );
      expect(gameMonsterArtIsBoss(gameMonsterById('zi_dian_mo_yi')), isFalse);
      expect(gameMonsterArtIsBoss(gameMonsterById('rong_yan_mo_yi')), isFalse);
    });

    test('名册只剩三只魔蚁，每只的图都在三张之内且稳定', () {
      expect(gameMonsters.length, 3);
      for (final monster in gameMonsters) {
        final art = gameMonsterArtFor(monster);
        expect(
          art == gameMonsterMoYiJunWangArt ||
              gameMonsterCommonArts.contains(art),
          isTrue,
          reason: '${monster.id} 的图应在三张魔蚁图之内',
        );
        // 同一只怪每次算出来是同一张，不会每帧乱跳。
        expect(gameMonsterArtFor(monster), art);
      }
      // 普通怪图就是紫电 + 熔岩两张，君王图不进小怪轮换。
      expect(
        gameMonsterCommonArts,
        [gameMonsterZiDianMoYiArt, gameMonsterRongYanMoYiArt],
      );
    });
  });

  group('3D 写实主角图', () {
    test('选男用男图、选女用女图，全身与半身各一套', () {
      expect(gameHeroAssetForGender(false), gameHeroMaleAsset);
      expect(gameHeroAssetForGender(true), gameHeroFemaleAsset);
      expect(gameHeroBustAssetForGender(false), gameHeroMaleBustAsset);
      expect(gameHeroBustAssetForGender(true), gameHeroFemaleBustAsset);
      expect(gameHeroMaleAsset, contains('hero_male_3d.jpg'));
      expect(gameHeroFemaleAsset, contains('hero_female_3d.jpg'));
      expect(gameHeroMaleBustAsset, contains('hero_male_3d_bust.jpg'));
      expect(gameHeroFemaleBustAsset, contains('hero_female_3d_bust.jpg'));
    });

    test('旧 Q 版图保留当回退，路径不变', () {
      expect(gameHeroMaleLegacyAsset, 'assets/images/game/hero_male.jpg');
      expect(
        gameHeroFemaleLegacyAsset,
        'assets/images/game/hero_female.jpg',
      );
    });
  });
}
