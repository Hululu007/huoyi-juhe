import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/game_data.dart';

void main() {
  group('游戏数据表完整性', () {
    test('试炼塔 30 层：1–30 连续，5 个副本各 6 层', () {
      expect(gameTowerFloors.length, 30);
      for (var i = 0; i < 30; i++) {
        expect(gameTowerFloors[i].floor, i + 1);
      }
      const dungeons = ['血色禁地', '虚天殿', '坠魔谷', '昆吾山', '广寒界'];
      for (var i = 0; i < 5; i++) {
        final group = gameTowerFloors.sublist(i * 6, i * 6 + 6);
        expect(
          group.map((f) => f.dungeon).toSet(),
          {dungeons[i]},
          reason: '第 ${i * 6 + 1}–${i * 6 + 6} 层应同属${dungeons[i]}',
        );
        expect(group.first.requiredPower, greaterThan(0));
      }
    });

    test('主线推图 12 章：顺序与副本名照挂机版那套', () {
      expect(gameChapters.length, 12);
      expect(
        gameChapters.map((c) => c.id).toSet().length,
        12,
        reason: '章节 id 不重复',
      );
      expect(gameChapters.first.title, '七玄门试炼');
      expect(gameChapters.last.title, '小绿瓶之谜');
      expect(
        gameChapters.map((c) => c.title),
        containsAll(['血色禁地', '乱星海狩猎', '虚天殿·玄关']),
      );
      expect(
        gameChapters.map((c) => c.dungeon),
        containsAll(['血色禁地', '乱星海', '虚天殿']),
      );
      for (final chapter in gameChapters) {
        expect(chapter.requiredPower, greaterThan(0));
        expect(chapter.xpReward, greaterThan(0));
        expect(chapter.yuanbaoReward, greaterThan(0));
      }
    });

    test('装备 36 件：武器/法宝/防具/饰品四栏齐全，小说原物在列', () {
      expect(gameEquipments.length, 36);
      expect(
        gameEquipments.map((e) => e.id).toSet().length,
        36,
        reason: '装备 id 不重复',
      );
      for (final slot in GameEquipSlot.values) {
        expect(
          gameEquipments.any((e) => e.slot == slot),
          isTrue,
          reason: '栏位 $slot 至少有一件装备',
        );
      }
      final names = gameEquipments.map((e) => e.name).toSet();
      expect(
        names,
        containsAll([
          '青竹蜂云剑',
          '掌天瓶',
          '虚天鼎',
          '噬金虫',
          '风雷翅',
          '玄天斩灵剑',
        ]),
      );
    });

    test('妖兽 10 只：奖励为正', () {
      expect(gameMonsters.length, 10);
      expect(
        gameMonsters.map((m) => m.id).toSet().length,
        10,
        reason: '妖兽 id 不重复',
      );
      for (final monster in gameMonsters) {
        expect(monster.xpReward, greaterThan(0));
        expect(monster.yuanbaoReward, greaterThanOrEqualTo(0));
      }
    });

    test('养成任务 5 项、商城 3 件', () {
      expect(gameTrainingQuests.length, 5);
      expect(
        gameTrainingQuests.map((q) => q.id).toSet().length,
        5,
      );
      expect(gameShopItems.length, 3);
      expect(
        gameShopItems.map((s) => s.id).toSet(),
        {'juqi_dan', 'double_fu', 'fabao_box'},
      );
      for (final item in gameShopItems) {
        expect(item.price, greaterThan(0));
      }
    });

    test('站点节点 13 个：四档齐全，进站免费（没有进站费可扣）', () {
      expect(gameSiteNodes.length, 13);
      expect(
        gameSiteNodes.map((n) => n.coreId).toSet().length,
        13,
        reason: '节点 coreId 不重复',
      );
      for (final node in gameSiteNodes) {
        expect(node.tier, inInclusiveRange(0, 3));
      }
      final first = gameSiteNodes.first;
      expect(first.unlocked(0, 0), isFalse);
      expect(first.unlocked(first.requiredRealmXp, first.requiredTowerFloor), isTrue);
    });

    test('装备七档：白→七彩，倍率递增，最高七彩', () {
      expect(GameEquipQuality.values.length, 7);
      expect(gameEquipQualityName(GameEquipQuality.white), '普通');
      expect(gameEquipQualityName(GameEquipQuality.green), '优秀');
      expect(gameEquipQualityName(GameEquipQuality.blue), '精良');
      expect(gameEquipQualityName(GameEquipQuality.purple), '史诗');
      expect(gameEquipQualityName(GameEquipQuality.orange), '传说');
      expect(gameEquipQualityName(GameEquipQuality.red), '神话');
      expect(gameEquipQualityName(GameEquipQuality.rainbow), '至尊');
      var last = 0.0;
      for (final quality in GameEquipQuality.values) {
        final mult = gameEquipQualityPowerMultiplier(quality);
        expect(mult, greaterThan(last));
        last = mult;
      }
      expect(gameEquipQualityPowerMultiplier(GameEquipQuality.white), 1.0);
      expect(
        gameEquipQualityPowerMultiplier(GameEquipQuality.rainbow),
        4.8,
      );
      // 顶级法宝只在红 / 七彩档。
      expect(
        gameEquipmentById('zhang_tian_ping')?.quality,
        GameEquipQuality.rainbow,
      );
      expect(
        gameEquipmentById('xuan_tian_zhan_ling_jian')?.quality,
        GameEquipQuality.rainbow,
      );
      expect(
        gameEquipmentById('shi_jin_chong')?.quality,
        GameEquipQuality.red,
      );
      // 每档每栏位都有装备，合成链不断。
      for (final quality in GameEquipQuality.values) {
        for (final slot in GameEquipSlot.values) {
          expect(
            gameEquipmentsOf(slot, quality),
            isNotEmpty,
            reason: '${gameEquipQualityName(quality)}档${gameEquipSlotName(slot)}至少有一件',
          );
        }
      }
      // 七彩只能合成 / 通关塔 30 层得：掉落池里没有七彩。
      for (var realm = 0; realm < 14; realm++) {
        expect(
          gameDropPoolForRealm(realm)
              .any((e) => e.quality == GameEquipQuality.rainbow),
          isFalse,
        );
      }
      // 分解价按品质递增，七彩不可分解。
      expect(gameEquipSalvageValue(GameEquipQuality.white), 5);
      expect(gameEquipSalvageValue(GameEquipQuality.red), 160);
      expect(gameEquipSalvageValue(GameEquipQuality.rainbow), 0);
    });

    test('妖兽难度上调：BOSS 金蛟王只加一成，其余血量明显上调', () {
      final boss = gameMonsterById('jin_jiao_wang');
      expect(boss.power, 7900);
      expect(boss.hp, 13200);
      expect(gameMonsterById('ye_lang').power, 60);
      expect(gameMonsterById('ye_lang').hp, 180);
      expect(gameMonsterById('tian_gui').power, 6700);
      expect(gameMonsterById('tian_gui').hp, 13200);
      for (var i = 1; i < gameMonsters.length; i++) {
        expect(gameMonsters[i].power, greaterThan(gameMonsters[i - 1].power));
      }
    });

    test('推图与爬塔难度：白板境界打不过，必须靠装备', () {
      // 境界基础满级才 590（50 + 270×2），第 4 章要 700。
      expect(gamePowerBase + 270 * gamePowerPerLevel, 590);
      expect(gameChapters[3].requiredPower, 700);
      expect(
        gameChapters.map((c) => c.requiredPower).toList(),
        [80, 300, 450, 700, 1100, 1600, 2300, 3000, 4000, 5200, 6800, 8200],
      );
      // 通关奖励不再给七彩装备。
      for (final chapter in gameChapters) {
        final reward = chapter.equipRewardId == null
            ? null
            : gameEquipmentById(chapter.equipRewardId!);
        expect(reward?.quality, isNot(GameEquipQuality.rainbow));
      }
      // 爬塔每层 +65（原来 +60），第 1 层 165，第 30 层 2050。
      expect(gameTowerFloors.first.requiredPower, 165);
      expect(gameTowerFloors.last.requiredPower, 2050);
      for (var i = 1; i < 30; i++) {
        expect(
          gameTowerFloors[i].requiredPower -
              gameTowerFloors[i - 1].requiredPower,
          65,
        );
      }
    });

    test('机器人：组队 2 名各不同', () {
      expect(gameTeamBots.length, 2);
      expect(gameTeamBots[0].name, isNot(gameTeamBots[1].name));
      expect(gameTeamBots[0].costumeId, isNot(gameTeamBots[1].costumeId));
      expect(gameTeamBots[0].profession, isNot(gameTeamBots[1].profession));
    });

    test('战力定境界名：低阶炼气、高阶元婴', () {
      expect(monsterRealmForPower(100), '炼气中期');
      expect(monsterRealmForPower(500), '筑基初期');
      expect(monsterRealmForPower(1200), '筑基后期');
      expect(monsterRealmForPower(4000), '结丹后期');
      expect(monsterRealmForPower(99999), '元婴中期');
    });

    test('常量：挂机 1 元宝/分钟、离线封顶 8 小时、狩猎每天 3 次', () {
      expect(gameIdleYuanbaoPerMinute, 1);
      expect(gameOfflineCapHours, 8);
      expect(gameHuntPerDay, 3);
      expect(gameBottleXp, 500);
    });
  });
}
