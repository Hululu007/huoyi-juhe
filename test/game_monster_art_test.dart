import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/widgets/game_hero_portrait.dart';
import 'package:fqapp/widgets/game_monster_art.dart';

void main() {
  group('3D 写实怪物图映射（只换美术，不动数值与玩法）', () {
    test('蛟与蛟王固定墨蛟，首领放大', () {
      expect(
        gameMonsterArtFor(gameMonsterById('mo_jiao')),
        gameMonsterMoJiaoArt,
      );
      expect(
        gameMonsterArtFor(gameMonsterById('jin_jiao_wang')),
        gameMonsterMoJiaoArt,
      );
      expect(gameMonsterArtIsBoss(gameMonsterById('mo_jiao')), isTrue);
      expect(gameMonsterArtIsBoss(gameMonsterById('jin_jiao_wang')), isTrue);
    });

    test('蟒固定金光蟒，狼固定紫电妖狼', () {
      expect(
        gameMonsterArtFor(gameMonsterById('bing_huo_mang')),
        gameMonsterJinGuangMangArt,
      );
      expect(
        gameMonsterArtFor(gameMonsterById('ye_lang')),
        gameMonsterZiDianYaoLangArt,
      );
      expect(gameMonsterArtIsBoss(gameMonsterById('bing_huo_mang')), isFalse);
    });

    test('其余种类稳定取一张普通怪图，不超出四张', () {
      for (final monster in gameMonsters) {
        final art = gameMonsterArtFor(monster);
        expect(
          art == gameMonsterMoJiaoArt ||
              gameMonsterCommonArts.contains(art),
          isTrue,
          reason: '${monster.id} 的图应在五张之内',
        );
        // 同一只怪每次算出来是同一张，不会每帧乱跳。
        expect(gameMonsterArtFor(monster), art);
      }
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
