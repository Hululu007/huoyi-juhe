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

    test('装备 20 件：武器/法宝/防具/饰品四栏齐全，小说原物在列', () {
      expect(gameEquipments.length, 20);
      expect(
        gameEquipments.map((e) => e.id).toSet().length,
        20,
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

    test('站点节点 13 个：四档齐全，看一次扣费 5/10/15/20', () {
      expect(gameSiteNodes.length, 13);
      expect(
        gameSiteNodes.map((n) => n.coreId).toSet().length,
        13,
        reason: '节点 coreId 不重复',
      );
      for (final node in gameSiteNodes) {
        expect(node.tier, inInclusiveRange(0, 3));
        expect(node.viewCost, gameAdultViewCost(node.tier));
      }
      expect(gameAdultViewCost(0), 5);
      expect(gameAdultViewCost(1), 10);
      expect(gameAdultViewCost(2), 15);
      expect(gameAdultViewCost(3), 20);
      final first = gameSiteNodes.first;
      expect(first.unlocked(0, 0), isFalse);
      expect(first.unlocked(first.requiredRealmXp, first.requiredTowerFloor), isTrue);
    });

    test('机器人：组队 2 名各不同，托机器人 50 个名不重复', () {
      expect(gameTeamBots.length, 2);
      expect(gameTeamBots[0].name, isNot(gameTeamBots[1].name));
      expect(gameTeamBots[0].costumeId, isNot(gameTeamBots[1].costumeId));
      expect(gameTeamBots[0].profession, isNot(gameTeamBots[1].profession));
      expect(gameAmbientBotNames.length, 50);
      expect(gameAmbientBotNames.toSet().length, 50);
      expect(gameAmbientBotRealms.length, 8);
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
      expect(gameCheerLines, contains('老大！你一定能赢！'));
    });
  });
}
