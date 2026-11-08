import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/services/game_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GameService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await GameService.instance.resetForTest();
    service = GameService.instance;
    await service.ensureInitialized();
  });

  tearDown(() async {
    await GameService.instance.resetForTest();
    await CultivationService.instance.resetForTest();
  });

  group('游戏服务', () {
    test('击杀给修为和元宝、计杀数、落盘', () async {
      final monster = gameMonsters.first;
      final xpBefore = service.totalXp;
      final result = await service.killMonster(monster);
      expect(result.xp, monster.xpReward);
      expect(result.yuanbao, monster.yuanbaoReward);
      expect(service.totalXp, xpBefore + monster.xpReward);
      expect(service.yuanbao, monster.yuanbaoReward);
      expect(service.totalKills, 1);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getInt('game_yuanbao'), monster.yuanbaoReward);
      expect(sp.getInt('game_total_kills'), 1);
    });

    test('推图按顺序打：第 1 章直接过，第 2 章修为不够过不了', () async {
      expect(await service.completeChapter(1), isNull);
      final xp = await service.completeChapter(0);
      expect(xp, 100);
      expect(service.mapChapterIndex, 0);
      expect(service.yuanbao, 10);
      expect(service.ownedEquip, contains('jin_guang_jian'));
      expect(await service.completeChapter(0), isNull);
      await CultivationService.instance.addGameXp(300);
      expect(await service.completeChapter(1), 200);
    });

    test('爬塔按顺序打：第 1 层过，第 2 层跳层过不了', () async {
      expect(await service.challengeTower(2), isNull);
      final result = await service.challengeTower(1);
      expect(result, isNotNull);
      expect(result!.xp, 80);
      expect(service.towerFloor, 1);
      expect(await service.challengeTower(1), isNull);
    });

    test('成人站扣费：未解锁不扣，元宝不够不扣，够了扣对应档位', () async {
      final node = gameSiteNodes.first;
      service.yuanbao = 100;
      expect(await service.spendForAdultView(node), isFalse);
      expect(service.yuanbao, 100);
      await CultivationService.instance.addGameXp(node.requiredRealmXp);
      service.towerFloor = node.requiredTowerFloor;
      service.yuanbao = node.viewCost - 1;
      expect(await service.spendForAdultView(node), isFalse);
      service.yuanbao = node.viewCost;
      expect(await service.spendForAdultView(node), isTrue);
      expect(service.yuanbao, 0);
    });

    test('商城：聚气丹扣 50 元宝加 300 修为，元宝不够/无此物买不了', () async {
      expect(await service.buyShop('no_such_item'), isNull);
      service.yuanbao = 10;
      expect(await service.buyShop('juqi_dan'), isNull);
      expect(service.yuanbao, 10);
      service.yuanbao = 100;
      final xpBefore = service.totalXp;
      expect(await service.buyShop('juqi_dan'), isNotNull);
      expect(service.yuanbao, 50);
      expect(service.totalXp, xpBefore + 300);
    });

    test('装备：穿上加战力、脱下还原；强化每级 +10% 费用递增、满 5 级', () async {
      service.ownedEquip.add('jin_guang_jian');
      final powerBefore = service.power;
      expect(await service.equip('jin_guang_jian'), isTrue);
      expect(service.equippedIn(GameEquipSlot.weapon)?.id, 'jin_guang_jian');
      expect(service.power, greaterThan(powerBefore));
      service.yuanbao = 1000;
      expect(await service.refineEquip('jin_guang_jian'), isTrue);
      expect(service.refine['jin_guang_jian'], 1);
      expect(service.yuanbao, 1000 - 20);
      for (var i = 0; i < 4; i++) {
        expect(await service.refineEquip('jin_guang_jian'), isTrue);
      }
      expect(service.refine['jin_guang_jian'], 5);
      expect(await service.refineEquip('jin_guang_jian'), isFalse);
      await service.unequip(GameEquipSlot.weapon);
      expect(service.equippedIn(GameEquipSlot.weapon), isNull);
      expect(service.power, powerBefore);
    });

    test('狩猎每天 3 次、掌天瓶每天 1 次', () async {
      expect(await service.huntsLeft(), 3);
      expect(await service.hunt(), isNotNull);
      expect(await service.hunt(), isNotNull);
      expect(await service.hunt(), isNotNull);
      expect(await service.hunt(), isNull);
      expect(await service.huntsLeft(), 0);
      expect(await service.bottle(), isTrue);
      expect(await service.bottle(), isFalse);
      expect(await service.bottleClaimed(), isTrue);
    });

    test('resetForTest 清干净', () async {
      service.yuanbao = 999;
      service.towerFloor = 7;
      await service.resetForTest();
      expect(service.yuanbao, 0);
      expect(service.towerFloor, 0);
      expect(service.mapChapterIndex, -1);
      expect(service.totalKills, 0);
    });
  });
}
