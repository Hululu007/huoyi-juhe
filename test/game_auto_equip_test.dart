import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_data.dart';
import 'package:fqapp/services/game_service.dart';

/// 背包自动合成 + 自动回收换元宝：自动触发路径、开关落盘、
///
/// 元宝补材料、回收规则（留够合一次的料、已穿戴不动、七彩不回收）。
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

  int countOf(GameEquipSlot slot, GameEquipQuality quality) {
    var total = 0;
    for (final item in gameEquipmentsOf(slot, quality)) {
      total += service.equipCount(item.id);
    }
    return total;
  }

  group('自动合成开关', () {
    test('默认开，开关写盘，读盘恢复', () async {
      expect(service.autoSynthesizeEnabled, isTrue);
      await service.setAutoSynthesize(false);
      expect(service.autoSynthesizeEnabled, isFalse);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('game_auto_synthesize'), isFalse);
      // 模拟重启：清内存、不清盘，再读盘（resetForTest 会清盘，
      // 所以清完内存再把开关值写回去，跟“旧存档兼容”那项同写法）。
      await GameService.instance.resetForTest();
      await sp.setBool('game_auto_synthesize', false);
      await service.ensureInitialized();
      expect(service.autoSynthesizeEnabled, isFalse);
    });

    test('得装备自动触发合成：3 件绿武器得 1 件蓝武器', () {
      expect(service.autoSynthesizeEnabled, isTrue);
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('qing_yuan_jian');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 2);
      expect(service.lastSynthesizeResults, isEmpty);
      service.obtainEquipForTest('jin_fu_zi_mu_ren');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 0);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
      expect(service.lastSynthesizeResults.length, 1);
      expect(
        service.lastSynthesizeResults.first.resultId,
        'qing_zhu_feng_yun_jian',
      );
      expect(service.lastSynthesizeResults.first.yuanbaoCost, 0);
    });

    test('开关关了得装备不自动合，手动“立即合成”还能合', () async {
      await service.setAutoSynthesize(false);
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('jin_fu_zi_mu_ren');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 3);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 0);
      final results = service.synthesizeAll();
      expect(results.length, 1);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
    });

    test('9 件白武器得装备时链式合到蓝（低级装备补）', () {
      for (var i = 0; i < 9; i++) {
        service.obtainEquipForTest('jin_guang_jian');
      }
      // 9 白 → 3 绿 → 1 蓝，终态与直接调 synthesizeAll 一次那项一致；
      // 记录是每次得装备覆盖、不是累计，所以只剩最后一次的 2 条
      // （第 9 件触发的那轮：1 白合绿 + 3 绿合蓝）。
      expect(service.equipCount('jin_guang_jian'), 0);
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 0);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
      expect(service.lastSynthesizeResults.length, 2);
    });
  });

  group('合成元宝补材料', () {
    test('差 1 件时花元宝补：2 绿 + 20 元宝合出 1 蓝', () {
      service.yuanbao = 20;
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('qing_yuan_jian');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 0);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
      expect(service.yuanbao, 0);
      expect(service.lastSynthesizeResults.length, 1);
      expect(service.lastSynthesizeResults.first.yuanbaoCost, 20);
    });

    test('元宝不够不补：2 绿 + 10 元宝原样留着', () {
      service.yuanbao = 10;
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('qing_yuan_jian');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.green), 2);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 0);
      expect(service.yuanbao, 10);
      expect(service.lastSynthesizeResults, isEmpty);
    });

    test('手动合成不花元宝：开关关了，2 绿 + 100 元宝也不补', () async {
      await service.setAutoSynthesize(false);
      service.yuanbao = 100;
      service.ownedEquip['qing_yuan_jian'] = 2;
      final results = service.synthesizeAll();
      expect(results, isEmpty);
      expect(service.equipCount('qing_yuan_jian'), 2);
      expect(service.yuanbao, 100);
    });

    test('2 红 + 320 元宝补出 1 件七彩武器', () {
      service.yuanbao = 320;
      service.obtainEquipForTest('jin_lei_zhu_jian');
      service.obtainEquipForTest('jin_lei_zhu_jian');
      expect(countOf(GameEquipSlot.weapon, GameEquipQuality.red), 0);
      expect(service.equipCount('xuan_tian_zhan_ling_jian'), 1);
      expect(service.yuanbao, 0);
      expect(service.lastSynthesizeResults.first.yuanbaoCost, 320);
    });
  });

  group('自动回收换元宝', () {
    test('默认开，开关写盘，读盘恢复', () async {
      expect(service.autoRecycleEnabled, isTrue);
      await service.setAutoRecycle(false);
      expect(service.autoRecycleEnabled, isFalse);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('game_auto_recycle'), isFalse);
      // 模拟重启：清内存、不清盘，再读盘（跟自动合成开关那项同写法）。
      await GameService.instance.resetForTest();
      await sp.setBool('game_auto_recycle', false);
      await service.ensureInitialized();
      expect(service.autoRecycleEnabled, isFalse);
    });

    test('自动合成关时：5 件绿武器留 3 件（一次手动合成的料），多余 2 件换 20 元宝', () async {
      await service.setAutoSynthesize(false);
      for (var i = 0; i < 5; i++) {
        service.obtainEquipForTest('qing_yuan_jian');
      }
      expect(service.equipCount('qing_yuan_jian'), 3);
      expect(service.yuanbao, 20);
      // 回收记录是每次触发覆盖、不是累计：最后一次只回收了 1 件。
      expect(service.lastAutoRecycleNames, ['青元剑']);
      expect(service.lastAutoRecycleYuanbao, 10);
      // 留下的 3 件还能手动合成。
      final results = service.synthesizeAll();
      expect(results.length, 1);
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
    });

    test('自动合成开时：4 件绿武器 3 件合 1 蓝，剩 1 绿正好是储备，不回收', () {
      for (var i = 0; i < 4; i++) {
        service.obtainEquipForTest('qing_yuan_jian');
      }
      expect(service.equipCount('qing_zhu_feng_yun_jian'), 1);
      expect(service.equipCount('qing_yuan_jian'), 1);
      expect(service.yuanbao, 0);
      expect(service.lastAutoRecycleNames, isEmpty);
    });

    test('已穿戴的不回收：穿 1 件、共 5 件，回收 1 件得 10 元宝，身上那件还在', () async {
      await service.setAutoSynthesize(false);
      // 青元剑要筑基（境界下标 1）才能穿，先加 300 修为升境。
      await CultivationService.instance.addGameXp(300);
      service.obtainEquipForTest('qing_yuan_jian');
      expect(await service.equip('qing_yuan_jian'), isTrue);
      for (var i = 0; i < 4; i++) {
        service.obtainEquipForTest('qing_yuan_jian');
      }
      expect(service.equipCount('qing_yuan_jian'), 4);
      expect(service.equippedIn(GameEquipSlot.weapon)?.id, 'qing_yuan_jian');
      expect(service.yuanbao, 10);
      expect(service.lastAutoRecycleNames, ['青元剑']);
    });

    test('七彩不回收：2 件掌天瓶一件不少、元宝不动', () {
      service.obtainEquipForTest('zhang_tian_ping');
      service.obtainEquipForTest('zhang_tian_ping');
      expect(service.equipCount('zhang_tian_ping'), 2);
      expect(service.yuanbao, 0);
      expect(service.lastAutoRecycleNames, isEmpty);
    });

    test('开关关了不自动回收，手动“立即回收”还能用', () async {
      await service.setAutoSynthesize(false);
      await service.setAutoRecycle(false);
      for (var i = 0; i < 5; i++) {
        service.obtainEquipForTest('qing_yuan_jian');
      }
      expect(service.equipCount('qing_yuan_jian'), 5);
      expect(service.yuanbao, 0);
      final gained = service.recycleSurplus();
      expect(gained, 20);
      expect(service.equipCount('qing_yuan_jian'), 3);
      expect(service.yuanbao, 20);
    });

    test('各档回收价：白 5 绿 10 蓝 20 紫 40 橙 80 红 160', () async {
      await service.setAutoSynthesize(false);
      await service.setAutoRecycle(false);
      // 每档 4 件同部位：留 3 件、回收 1 件，正好是该档回收价。
      service.ownedEquip['jin_guang_jian'] = 4;
      service.ownedEquip['qing_yuan_jian'] = 4;
      service.ownedEquip['qing_zhu_feng_yun_jian'] = 4;
      service.ownedEquip['xue_mo_jian'] = 4;
      service.ownedEquip['da_geng_jian'] = 4;
      service.ownedEquip['jin_lei_zhu_jian'] = 4;
      final gained = service.recycleSurplus();
      expect(gained, 5 + 10 + 20 + 40 + 80 + 160);
      expect(service.yuanbao, 315);
      for (final id in [
        'jin_guang_jian',
        'qing_yuan_jian',
        'qing_zhu_feng_yun_jian',
        'xue_mo_jian',
        'da_geng_jian',
        'jin_lei_zhu_jian',
      ]) {
        expect(service.equipCount(id), 3);
      }
    });

    test('没有多余的不回收：每组 2 件以下、元宝 0', () {
      service.obtainEquipForTest('qing_yuan_jian');
      service.obtainEquipForTest('qing_yuan_jian');
      expect(service.equipCount('qing_yuan_jian'), 2);
      expect(service.recycleSurplus(), 0);
      expect(service.yuanbao, 0);
    });
  });
}
