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

    test('推图按顺序打：第 1 章要配白装才过，第 2 章要配齐绿装', () async {
      expect(await service.completeChapter(1), isNull);
      // 白板 70 战力过不了第 1 章（要 80）。
      expect(await service.completeChapter(0), isNull);
      service.ownedEquip['jin_guang_jian'] = 1;
      expect(await service.equip('jin_guang_jian'), isTrue);
      final xp = await service.completeChapter(0);
      expect(xp, 100);
      expect(service.mapChapterIndex, 0);
      expect(service.yuanbao, 10);
      expect(service.ownsEquip('jin_guang_jian'), isTrue);
      expect(await service.completeChapter(0), isNull);
      await CultivationService.instance.addGameXp(300);
      // 绿装没配齐，第 2 章（要 300）过不了。
      expect(await service.completeChapter(1), isNull);
      for (final id in [
        'qing_yuan_jian',
        'yin_yang_zi_mu_huan',
        'jin_gang_zhao',
        'bai_xi_pei',
      ]) {
        service.ownedEquip[id] = 1;
        expect(await service.equip(id), isTrue);
      }
      expect(await service.completeChapter(1), 200);
    });

    test('爬塔按顺序打：第 1 层要配装，第 2 层跳层过不了', () async {
      expect(await service.challengeTower(2), isNull);
      // 白板 70 战力过不了第 1 层（要 165）。
      expect(await service.challengeTower(1), isNull);
      await CultivationService.instance.addGameXp(300);
      for (final id in ['qing_yuan_jian', 'jin_gang_zhao']) {
        service.ownedEquip[id] = 1;
        expect(await service.equip(id), isTrue);
      }
      final result = await service.challengeTower(1);
      expect(result, isNotNull);
      expect(result!.xp, 80);
      expect(service.towerFloor, 1);
      expect(await service.challengeTower(1), isNull);
    });

    test('成人站进站免费：未解锁拦住，解锁了放行、不扣元宝', () async {
      final node = gameSiteNodes.first;
      service.yuanbao = 100;
      expect(await service.spendForAdultView(node), isFalse);
      expect(service.yuanbao, 100);
      await CultivationService.instance.addGameXp(node.requiredRealmXp);
      service.towerFloor = node.requiredTowerFloor;
      service.yuanbao = 0;
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

    test('装备：穿上加战力、脱下还原；强化每级 +12% 费用递增、满 5 级', () async {
      service.ownedEquip['jin_guang_jian'] = 1;
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

    test('战力主要靠装备：境界基础满级 590，蓝装成套装备占 70% 以上', () async {
      expect(service.basePower, 70);
      expect(service.equipPower, 0);
      expect(service.power, 70);
      await CultivationService.instance.addGameXp(3000);
      for (final id in [
        'qing_zhu_feng_yun_jian',
        'pi_xie_shen_lei_zhu',
        'tian_can_bao_jia',
        'yang_hun_mu_pei',
      ]) {
        service.ownedEquip[id] = 1;
        expect(await service.equip(id), isTrue);
      }
      // 蓝装成套装备贡献约 620，境界基础约 190，装备占 76%。
      expect(service.equipPower, greaterThanOrEqualTo(615));
      expect(service.equipPower, lessThanOrEqualTo(625));
      expect(service.equipPower * 10, greaterThan(service.power * 7));
      expect(service.power, service.basePower + service.equipPower);
    });

    test('自动合成：3 件绿武器合成 1 件蓝武器，9 件白连锁合到蓝', () async {
      service.ownedEquip['qing_yuan_jian'] = 2;
      service.ownedEquip['jin_fu_zi_mu_ren'] = 1;
      final results = service.synthesizeAll();
      expect(results.length, 1);
      expect(results.first.resultId, 'qing_zhu_feng_yun_jian');
      expect(service.equipCount('qing_yuan_jian'), 0);
      expect(service.equipCount('jin_fu_zi_mu_ren'), 0);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);

      await service.resetForTest();
      await service.ensureInitialized();
      service.ownedEquip['jin_guang_jian'] = 9;
      final chained = service.synthesizeAll();
      // 9 白 → 3 绿 → 1 蓝，共 4 次合成。
      expect(chained.length, 4);
      expect(service.equipCount('jin_guang_jian'), 0);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
    });

    test('自动合成不合身上穿的那件：穿着的最后 1 件留着', () async {
      service.ownedEquip['jin_guang_jian'] = 3;
      expect(await service.equip('jin_guang_jian'), isTrue);
      final results = service.synthesizeAll();
      expect(results, isEmpty);
      expect(service.equipCount('jin_guang_jian'), 3);
      service.ownedEquip['jin_guang_jian'] = 4;
      final again = service.synthesizeAll();
      expect(again.length, 1);
      expect(service.equipCount('jin_guang_jian'), 1);
    });

    test('强化自动补材料：元宝不够时分解多余低级装备补，不够一分不动', () async {
      service.ownedEquip['jin_guang_jian'] = 1;
      service.ownedEquip['qing_yuan_jian'] = 3;
      service.yuanbao = 0;
      expect(await service.refineEquip('jin_guang_jian'), isTrue);
      expect(service.refine['jin_guang_jian'], 1);
      // 费用 20 元宝：分解 2 件多余绿武器（每件 10 元宝）补齐。
      expect(service.equipCount('qing_yuan_jian'), 1);
      expect(service.equipCount('jin_guang_jian'), 1);
      expect(service.yuanbao, 0);
      expect(service.lastAutoSalvageNames, ['青元剑', '青元剑']);

      await service.resetForTest();
      await service.ensureInitialized();
      service.ownedEquip['jin_guang_jian'] = 1;
      service.ownedEquip['chu_wu_zhuo'] = 1;
      service.yuanbao = 0;
      // 多余白装只值 5 元宝，补不够 20，不分解、不扣。
      expect(await service.refineEquip('jin_guang_jian'), isFalse);
      expect(service.equipCount('chu_wu_zhuo'), 1);
      expect(service.yuanbao, 0);
    });

    test('分解：多余件能分，七彩与身上最后 1 件不能分', () async {
      service.ownedEquip['qing_yuan_jian'] = 2;
      expect(await service.salvageEquip('qing_yuan_jian'), 10);
      expect(service.equipCount('qing_yuan_jian'), 1);
      expect(service.yuanbao, 10);
      service.ownedEquip['zhang_tian_ping'] = 1;
      expect(await service.salvageEquip('zhang_tian_ping'), 0);
      expect(service.equipCount('zhang_tian_ping'), 1);
    });

    test('通关试炼塔 30 层得一件七彩装备', () async {
      await CultivationService.instance.addGameXp(400000);
      for (final id in [
        'jin_lei_zhu_jian',
        'mo_ling_sheng_zhou',
        'xuan_tian_xian_jia',
        'shi_jin_chong',
      ]) {
        service.ownedEquip[id] = 1;
        expect(await service.equip(id), isTrue);
      }
      service.towerFloor = 29;
      final result = await service.challengeTower(30);
      expect(result, isNotNull);
      expect(service.towerFloor, 30);
      expect(
        gameEquipmentsOfQuality(GameEquipQuality.rainbow)
            .any((e) => service.ownsEquip(e.id)),
        isTrue,
      );
    });

    test('旧存档兼容：纯 id 列表读盘按每件 1 件迁移', () async {
      await GameService.instance.resetForTest();
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(
        'game_owned_equip',
        ['jin_guang_jian', 'qing_yuan_jian'],
      );
      await sp.setInt('game_yuanbao', 50);
      await service.ensureInitialized();
      expect(service.equipCount('jin_guang_jian'), 1);
      expect(service.equipCount('qing_yuan_jian'), 1);
      expect(service.yuanbao, 50);
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
