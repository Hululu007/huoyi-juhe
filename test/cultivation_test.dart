import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/cultivation.dart';

void main() {
  group('境界换算（凡人修仙传）', () {
    test('炼气期三档（初期 0～99、中期 100～199、后期 200～299）', () {
      expect(realmForXp(0).displayName, '炼气期 初期');
      expect(realmForXp(0).badgeLine1, '炼气期');
      expect(realmForXp(0).badgeLine2, '初期');
      expect(realmForXp(0).groupName, '下境界·人界');
      expect(realmForXp(0).xpToNext, 300);
      expect(realmForXp(0).nextRealmName, '筑基期');
      expect(realmForXp(0).level, 10);
      expect(realmForXp(99).displayName, '炼气期 初期');
      expect(realmForXp(99).level, 16);
      expect(realmForXp(100).displayName, '炼气期 中期');
      expect(realmForXp(100).level, 17);
      expect(realmForXp(199).displayName, '炼气期 中期');
      expect(realmForXp(199).level, 23);
      expect(realmForXp(200).displayName, '炼气期 后期');
      expect(realmForXp(200).level, 24);
      expect(realmForXp(299).displayName, '炼气期 后期');
      expect(realmForXp(299).level, 29);
      expect(realmForXp(299).realm.name, '炼气期');
    });

    test('筑基期起初期/中期/后期三等分', () {
      expect(realmForXp(300).displayName, '筑基期 初期');
      expect(realmForXp(533).displayName, '筑基期 初期');
      expect(realmForXp(534).displayName, '筑基期 中期');
      expect(realmForXp(766).displayName, '筑基期 中期');
      expect(realmForXp(767).displayName, '筑基期 后期');
      expect(realmForXp(999).displayName, '筑基期 后期');
      expect(realmForXp(1000).displayName, '结丹期 初期');
      expect(realmForXp(1000).badgeLine1, '结丹期');
      expect(realmForXp(1000).badgeLine2, '初期');
      expect(realmForXp(3000).displayName, '元婴期 初期');
      expect(realmForXp(8000).displayName, '化神期 初期');
    });

    test('中境界·灵界与上境界·仙界', () {
      expect(realmForXp(15000).displayName, '炼虚期 初期');
      expect(realmForXp(15000).groupName, '中境界·灵界');
      expect(realmForXp(30000).displayName, '合体期 初期');
      expect(realmForXp(60000).displayName, '大乘期 初期');
      expect(realmForXp(100000).displayName, '渡劫期 初期');
      expect(realmForXp(100000).groupName, '上境界·仙界');
    });

    test('渡劫之后各仙境换算', () {
      expect(realmForXp(200000).displayName, '真仙初期');
      expect(realmForXp(200000).groupName, '上境界·仙界');
      expect(realmForXp(400000).displayName, '金仙初期');
      expect(realmForXp(800000).displayName, '太乙玉仙初期');
      expect(realmForXp(1600000).displayName, '大罗金仙初期');
      expect(realmForXp(1600000).badgeLine1, '大罗金仙');
      expect(realmForXp(1600000).badgeLine2, '初期');
      // 仙境后期：真仙区间 200000～399999 三等分。
      expect(realmForXp(333333).displayName, '真仙中期');
      expect(realmForXp(399999).displayName, '真仙后期');
    });

    test('道祖封顶', () {
      final info = realmForXp(3200000);
      expect(info.displayName, '道祖');
      expect(info.badgeLine1, '道祖');
      expect(info.badgeLine2, '顶峰');
      expect(info.level, 270);
      expect(info.levelLabel, 'Lv.270');
      expect(info.xpToNext, 0);
      expect(info.nextRealmName, isNull);
      expect(info.progress, 1.0);
      expect(realmForXp(99999999).displayName, '道祖');
      expect(realmForXp(99999999).level, 270);
      expect(realmForXp(-5).displayName, '炼气期 初期');
      expect(realmForXp(-5).level, 10);
    });

    test('到下一境界进度', () {
      expect(realmForXp(150).progress, closeTo(0.5, 0.001));
      expect(realmForXp(0).progress, 0.0);
      expect(realmForXp(300).progress, 0.0);
      expect(realmForXp(650).progress, closeTo(0.5, 0.001));
    });
  });

  group('人物等级（每境 20 级）', () {
    test('炼气 Lv.10-29：新建人物 Lv.10', () {
      expect(levelForXp(0), 10);
      expect(realmForXp(0).levelLabel, 'Lv.10');
      expect(levelForXp(99), 16);
      expect(levelForXp(100), 17);
      expect(levelForXp(199), 23);
      expect(levelForXp(200), 24);
      expect(levelForXp(299), 29);
    });

    test('筑基 Lv.30-49：筑基到 49', () {
      expect(levelForXp(300), 30);
      expect(levelForXp(533), 36);
      expect(levelForXp(534), 37);
      expect(levelForXp(766), 43);
      expect(levelForXp(767), 44);
      expect(levelForXp(999), 49);
    });

    test('结丹 Lv.50-69：初期 50-56、中期 57-63、后期 64-69', () {
      expect(levelForXp(1000), 50);
      expect(levelForXp(1666), 56);
      expect(levelForXp(1667), 57);
      expect(levelForXp(2333), 63);
      expect(levelForXp(2334), 64);
      expect(levelForXp(2999), 69);
    });

    test('元婴 Lv.70-89、化神后期 109', () {
      expect(levelForXp(3000), 70);
      expect(levelForXp(7999), 89);
      expect(levelForXp(8000), 90);
      expect(levelForXp(14999), 109);
      expect(levelForXp(15000), 110);
    });

    test('道祖 Lv.270 封顶', () {
      expect(levelForXp(3200000), 270);
      expect(levelForXp(99999999), 270);
      expect(maxCultivationLevel, 270);
      expect(levelForXp(1600000), 250);
      expect(levelForXp(3199999), 269);
    });
  });

  group('成人站 4 档解锁', () {
    test('档位换算：下标/总数→档位', () {
      expect(adultTierForIndex(0, 146), 0);
      expect(adultTierForIndex(36, 146), 0);
      expect(adultTierForIndex(37, 146), 1);
      expect(adultTierForIndex(72, 146), 1);
      expect(adultTierForIndex(73, 146), 2);
      expect(adultTierForIndex(109, 146), 2);
      expect(adultTierForIndex(110, 146), 3);
      expect(adultTierForIndex(145, 146), 3);
      expect(adultTierForIndex(0, 0), 0);
      expect(adultTierForIndex(-1, 146), 0);
      expect(adultTierForIndex(0, 1), 0);
      expect(adultTierForIndex(3, 4), 3);
    });

    test('各档门槛前后', () {
      expect(adultTierUnlocked(0, 2999), isFalse);
      expect(adultTierUnlocked(0, 3000), isTrue);
      expect(adultTierUnlocked(1, 7999), isFalse);
      expect(adultTierUnlocked(1, 8000), isTrue);
      expect(adultTierUnlocked(2, 14999), isFalse);
      expect(adultTierUnlocked(2, 15000), isTrue);
      expect(adultTierUnlocked(3, 29999), isFalse);
      expect(adultTierUnlocked(3, 30000), isTrue);
      expect(adultTierUnlocked(-1, 999999), isFalse);
      expect(adultTierUnlocked(4, 999999), isFalse);
    });

    test('档位对应境界名', () {
      expect(adultTierRealmNames, ['元婴期', '化神期', '炼虚期', '合体期']);
      expect(adultTierForSiteId('b', ['a', 'b', 'c', 'd']), 1);
      expect(adultTierForSiteId('z', ['a', 'b', 'c', 'd']), isNull);
    });

    test('未解锁的站完全隐藏：修为不够时不在结果里', () {
      // 登记表 8 个站：下标 0,1→第 1 档；2,3→第 2 档；4,5→第 3 档；6,7→第 4 档。
      const registry = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7'];
      const all = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', 'fruit'];
      // 元婴期之前：成人站一条都不露，非成人站（fruit）照常在。
      final before = visibleSiteIds(all, registry, 2999);
      expect(before, ['fruit']);
      expect(before, isNot(contains('s0')));
      // 元婴期：只列第 1 档。
      expect(visibleSiteIds(all, registry, 3000), ['s0', 's1', 'fruit']);
      expect(visibleSiteIds(all, registry, 3000), isNot(contains('s2')));
      // 化神期：第 1、2 档。
      expect(visibleSiteIds(all, registry, 8000), ['s0', 's1', 's2', 's3', 'fruit']);
      expect(visibleSiteIds(all, registry, 8000), isNot(contains('s4')));
      // 炼虚期：第 1、2、3 档。
      expect(
        visibleSiteIds(all, registry, 15000),
        ['s0', 's1', 's2', 's3', 's4', 's5', 'fruit'],
      );
      expect(visibleSiteIds(all, registry, 15000), isNot(contains('s6')));
      // 合体期：全部。
      expect(visibleSiteIds(all, registry, 30000), all);
    });

    test('146 站分档：修为一到门槛对应档的站出现', () {
      final registry = List.generate(146, (i) => 'site$i');
      final atYuanYing = visibleSiteIds(registry, registry, 3000);
      expect(atYuanYing.length, 37);
      expect(atYuanYing, contains('site0'));
      expect(atYuanYing, contains('site36'));
      expect(atYuanYing, isNot(contains('site37')));
      final atHuaShen = visibleSiteIds(registry, registry, 8000);
      expect(atHuaShen.length, 73);
      expect(atHuaShen, contains('site72'));
      expect(atHuaShen, isNot(contains('site73')));
      final atLianXu = visibleSiteIds(registry, registry, 15000);
      expect(atLianXu.length, 110);
      expect(atLianXu, contains('site109'));
      expect(atLianXu, isNot(contains('site110')));
      final atHeTi = visibleSiteIds(registry, registry, 30000);
      expect(atHeTi.length, 146);
    });
  });

  group('missav 与鉴黄师强制最后一档', () {
    // 200 站登记表（鉴黄师 javrate 第 16 位、missav 第 41 位，
    // 与主线注册表顺序一致；uu 未注册、不在表里）。
    List<String> registry200() {
      final registry = List.generate(200, (i) => 'site$i');
      registry[15] = 'javrate';
      registry[40] = 'missav';
      return registry;
    }

    test('两站不管在表里多靠前都钉到第 4 档', () {
      final registry = registry200();
      expect(adultTierForSiteId('javrate', registry), 3);
      expect(adultTierForSiteId('missav', registry), 3);
      // 表里位置不变（不改注册表顺序），只是分档被覆盖。
      expect(registry.indexOf('javrate'), 15);
      expect(registry.indexOf('missav'), 40);
      // 别的站仍按表顺序分档。
      expect(adultTierForSiteId('site0', registry), 0);
      expect(adultTierForSiteId('site120', registry), 2);
    });

    test('第 4 档末尾两站的先后：missav 在前、鉴黄师压最后', () {
      final registry = registry200();
      final tier4 = adultTierSiteIds(3, registry);
      expect(tier4.length, 52);
      expect(tier4[tier4.length - 2], 'missav');
      expect(tier4.last, 'javrate');
      // 其余第 4 档站仍按表顺序排在前面（200 站时第 4 档从下标 150 起）。
      expect(tier4.first, 'site150');
    });

    test('200 站分档规模：48/50/50/52（钉尾两站各占原档一位）', () {
      final registry = registry200();
      // 比例分档（钉尾前）是 50/50/50/50；javrate 与 missav 原都在
      // 第 1 档，两站被钉到第 4 档后变成 48/50/50/52。
      expect(adultTierSiteIds(0, registry).length, 48);
      expect(adultTierSiteIds(1, registry).length, 50);
      expect(adultTierSiteIds(2, registry).length, 50);
      expect(adultTierSiteIds(3, registry).length, 52);
      // 表尾的两站按表顺序进第 4 档（下标 198、199 都在第 4 档），
      // 排在钉尾两站之前。
      final tier4 = adultTierSiteIds(3, registry);
      expect(tier4[tier4.length - 4], 'site198');
      expect(tier4[tier4.length - 3], 'site199');
    });

    test('修为不到合体两站完全隐藏，到了才出现', () {
      final registry = registry200();
      final before = visibleSiteIds(registry, registry, 29999);
      expect(before, isNot(contains('missav')));
      expect(before, isNot(contains('javrate')));
      final atHeTi = visibleSiteIds(registry, registry, 30000);
      expect(atHeTi, contains('missav'));
      expect(atHeTi, contains('javrate'));
      // 影视区列表本身仍按登记表顺序（不改显示顺序），
      // “排最后”只针对第 4 档分组列表（见上一条）与解锁弹窗。
      expect(atHeTi.indexOf('javrate'), 15);
      expect(atHeTi.indexOf('missav'), 40);
    });
  });

  group('升境解锁计算', () {
    test('跨过的境界下标', () {
      expect(crossedRealmIndexes(0, 300), [1]);
      expect(crossedRealmIndexes(299, 300), [1]);
      expect(crossedRealmIndexes(300, 300), isEmpty);
      expect(crossedRealmIndexes(0, 8000), [1, 2, 3, 4]);
      expect(crossedRealmIndexes(7999, 8000), [4]);
      expect(crossedRealmIndexes(0, 3200000), [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
      ]);
      expect(crossedRealmIndexes(5000, 100), isEmpty);
    });

    test('各境界新解锁的内容区', () {
      expect(realmUnlockZones(1), ['漫画区']);
      expect(realmUnlockZones(2), ['听书区']);
      expect(realmUnlockZones(3), ['影视区（第 1 档站）', '直播成人源']);
      expect(realmUnlockZones(4), ['影视全部分类', '称号', '影视区第 2 档站']);
      expect(realmUnlockZones(5), ['影视区第 3 档站']);
      expect(realmUnlockZones(6), ['影视区第 4 档站（全部开完）']);
      expect(realmUnlockZones(0), isEmpty);
      expect(realmUnlockZones(13), isEmpty);
    });

    test('各境界新解锁的成人站档位', () {
      expect(realmUnlockAdultTier(3), 0);
      expect(realmUnlockAdultTier(4), 1);
      expect(realmUnlockAdultTier(5), 2);
      expect(realmUnlockAdultTier(6), 3);
      expect(realmUnlockAdultTier(1), isNull);
      expect(realmUnlockAdultTier(13), isNull);
    });
  });

  group('称号排行榜（游戏真实称号）', () {
    test('榜单共 14 档，每境一行，称号与修为里程碑对应对', () {
      final ladder = cultivationTitleLadder(sect: '落云宗');
      expect(ladder.length, 14);
      // 炼气期：无称号。
      expect(ladder[0].rank, 1);
      expect(ladder[0].realmName, '炼气期');
      expect(ladder[0].requiredXp, 0);
      expect(ladder[0].titleName, isNull);
      expect(ladder[0].effect, CultivationTitleEffect.none);
      // 六个里程碑称号。
      expect(ladder[1].realmName, '筑基期');
      expect(ladder[1].requiredXp, 300);
      expect(ladder[1].titleName, '黄枫谷精英');
      expect(ladder[1].effect, CultivationTitleEffect.greenGlow);
      expect(ladder[2].realmName, '结丹期');
      expect(ladder[2].requiredXp, 1000);
      expect(ladder[2].titleName, '落云宗精英');
      expect(ladder[2].effect, CultivationTitleEffect.blueGlow);
      expect(ladder[3].realmName, '元婴期');
      expect(ladder[3].requiredXp, 3000);
      expect(ladder[3].titleName, '一马当先');
      expect(ladder[3].effect, CultivationTitleEffect.goldShine);
      expect(ladder[4].realmName, '化神期');
      expect(ladder[4].requiredXp, 8000);
      expect(ladder[4].titleName, '虚天殿魁首');
      expect(ladder[4].effect, CultivationTitleEffect.purpleGlowDots);
      expect(ladder[5].realmName, '炼虚期');
      expect(ladder[5].requiredXp, 15000);
      expect(ladder[5].titleName, '升仙会魁首');
      expect(ladder[5].effect, CultivationTitleEffect.flameGlowDots);
      expect(ladder[6].realmName, '合体期');
      expect(ladder[6].requiredXp, 30000);
      expect(ladder[6].titleName, '仙界接引');
      expect(ladder[6].effect, CultivationTitleEffect.rainbowGlowDots);
      // 大乘/渡劫/真仙/金仙不配新称号，仍是仙界接引；到太乙才换
      // 前三特效称号。
      for (var i = 7; i <= 10; i++) {
        expect(ladder[i].titleName, isNull);
        expect(ladder[i].effect, CultivationTitleEffect.none);
        expect(ladder[i].isTopThree, isFalse);
      }
      expect(ladder[7].realmName, '大乘期');
      expect(ladder[7].requiredXp, 60000);
      expect(ladder[10].realmName, '金仙');
      expect(ladder[10].requiredXp, 400000);
      // 前三特效称号：太乙 800000、大罗 1600000、道祖 3200000。
      expect(ladder[11].realmName, '太乙玉仙');
      expect(ladder[11].requiredXp, 800000);
      expect(ladder[11].titleName, '待补充·前三称号之三');
      expect(ladder[11].effect, CultivationTitleEffect.grandGlowDots);
      expect(ladder[11].isTopThree, isTrue);
      expect(ladder[11].isPlaceholderTitle, isTrue);
      expect(ladder[12].realmName, '大罗金仙');
      expect(ladder[12].requiredXp, 1600000);
      expect(ladder[12].titleName, '超凡入化');
      expect(ladder[12].effect, CultivationTitleEffect.grandGlowDots);
      expect(ladder[12].isTopThree, isTrue);
      expect(ladder[12].isPlaceholderTitle, isFalse);
      expect(ladder[13].realmName, '道祖');
      expect(ladder[13].requiredXp, 3200000);
      expect(ladder[13].titleName, '唯我独尊');
      expect(ladder[13].effect, CultivationTitleEffect.grandGlowDots);
      expect(ladder[13].isTopThree, isTrue);
      expect(ladder[13].isPlaceholderTitle, isFalse);
      // 所需修为严格递增。
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i].requiredXp, greaterThan(ladder[i - 1].requiredXp));
      }
    });

    test('宗门精英称号按所选宗门套格式', () {
      expect(sectEliteTitleName('落云宗'), '落云宗精英');
      expect(sectEliteTitleName('天魔宗'), '天魔宗精英');
      expect(sectEliteTitleName('黄枫谷'), '黄枫谷精英');
      expect(sectEliteTitleName(null), '宗门精英');
      expect(sectEliteTitleName(''), '宗门精英');
      expect(cultivationTitleLadder(sect: '天魔宗')[2].titleName, '天魔宗精英');
      expect(cultivationTitleLadder()[2].titleName, '宗门精英');
    });

    test('当前称号定位对', () {
      expect(currentTitleTier(0), isNull);
      expect(currentTitleTier(299), isNull);
      expect(currentTitleTier(300)?.titleName, '黄枫谷精英');
      expect(currentTitleTier(999)?.titleName, '黄枫谷精英');
      expect(currentTitleTier(1000, sect: '落云宗')?.titleName, '落云宗精英');
      expect(currentTitleTier(2999, sect: '落云宗')?.titleName, '落云宗精英');
      expect(currentTitleTier(3000)?.titleName, '一马当先');
      expect(currentTitleTier(7999)?.titleName, '一马当先');
      expect(currentTitleTier(8000)?.titleName, '虚天殿魁首');
      expect(currentTitleTier(15000)?.titleName, '升仙会魁首');
      expect(currentTitleTier(30000)?.titleName, '仙界接引');
      // 大乘/渡劫/真仙/金仙不配新称号，仍是仙界接引；到太乙才换
      // 前三特效称号。
      expect(currentTitleTier(60000)?.titleName, '仙界接引');
      expect(currentTitleTier(799999)?.titleName, '仙界接引');
      expect(currentTitleTier(800000)?.titleName, '待补充·前三称号之三');
      expect(currentTitleTier(1599999)?.titleName, '待补充·前三称号之三');
      expect(currentTitleTier(1600000)?.titleName, '超凡入化');
      expect(currentTitleTier(3199999)?.titleName, '超凡入化');
      expect(currentTitleTier(3200000)?.titleName, '唯我独尊');
      expect(currentTitleTier(99999999)?.titleName, '唯我独尊');
    });

    test('前三特效称号是占位不是编名，头顶称号取当前称号', () {
      final ladder = cultivationTitleLadder();
      final topThree = [for (final t in ladder) if (t.isTopThree) t];
      expect(topThree.length, 3);
      // 第三名是占位：名字写明待补充，不是编出来的称号名。
      expect(topThree[0].titleName, '待补充·前三称号之三');
      expect(topThree[0].isPlaceholderTitle, isTrue);
      expect(topThree[1].titleName, '超凡入化');
      expect(topThree[1].isPlaceholderTitle, isFalse);
      expect(topThree[2].titleName, '唯我独尊');
      expect(topThree[2].isPlaceholderTitle, isFalse);
      // 前三称号都用最华丽的大辉光+流光+光点+描边特效。
      for (final tier in topThree) {
        expect(tier.effect, CultivationTitleEffect.grandGlowDots);
      }
      // 头顶称号取的是当前称号：修为不到太乙时是仙界接引，
      // 到了太乙/大罗/道祖依次换前三称号。
      expect(
        const CultivationSnapshot(
          bonusXp: 799999,
        ).currentTitle?.titleName,
        '仙界接引',
      );
      expect(
        const CultivationSnapshot(
          bonusXp: 800000,
        ).currentTitle?.titleName,
        '待补充·前三称号之三',
      );
      expect(
        const CultivationSnapshot(
          bonusXp: 1600000,
        ).currentTitle?.titleName,
        '超凡入化',
      );
      expect(
        const CultivationSnapshot(
          bonusXp: 3200000,
        ).currentTitle?.titleName,
        '唯我独尊',
      );
      expect(const CultivationSnapshot().currentTitle, isNull);
    });

    test('当前境界行定位与已达成/未达成', () {
      final ladder = cultivationTitleLadder(sect: '落云宗');
      expect(currentTitleTierIndex(0, ladder), 0);
      expect(currentTitleTierIndex(299, ladder), 0);
      expect(currentTitleTierIndex(300, ladder), 1);
      expect(currentTitleTierIndex(1000, ladder), 2);
      expect(currentTitleTierIndex(30000, ladder), 6);
      expect(currentTitleTierIndex(60000, ladder), 7);
      expect(currentTitleTierIndex(3200000, ladder), 13);
      expect(currentTitleTierIndex(99999999, ladder), 13);
      const xp = 1000;
      final current = currentTitleTierIndex(xp, ladder);
      expect(current, 2);
      for (var i = 0; i < ladder.length; i++) {
        final achieved = ladder[i].requiredXp <= xp;
        expect(achieved, i <= current);
      }
    });
  });

  group('古代服饰（打坐小人换装）', () {
    final service = CultivationService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await service.resetForTest();
    });

    test('6 套服饰都有定义，名字与颜色不重复', () {
      expect(cultivationCostumes.length, 6);
      expect(
        [for (final c in cultivationCostumes) c.name],
        ['青色道袍', '白色汉服', '紫色锦袍', '玄色法袍', '月白儒衫', '朱红战袍'],
      );
      expect(
        {for (final c in cultivationCostumes) c.id}.length,
        6,
      );
      for (final costume in cultivationCostumes) {
        expect(costume.robe, isNot(costume.trim));
        expect(costume.robe, isNot(costume.belt));
      }
    });

    test('默认是青色道袍，未知 id 退化为默认', () {
      expect(defaultCultivationCostumeId, 'qing');
      expect(cultivationCostumeById(null).id, 'qing');
      expect(cultivationCostumeById('').id, 'qing');
      expect(cultivationCostumeById('不存在').id, 'qing');
      expect(cultivationCostumeById('zhu').name, '朱红战袍');
      expect(
        const CultivationSnapshot().costumeId,
        defaultCultivationCostumeId,
      );
      expect(const CultivationSnapshot().costume.name, '青色道袍');
    });

    test('改选后落盘与读取一致，二次启动还是那套', () async {
      final service = CultivationService.instance;
      await service.resetForTest();
      await service.createProfile(
        gender: CultivationGender.female,
        sect: '黄枫谷',
        profession: '天道',
        costumeId: 'zi',
      );
      expect(service.snapshot.costumeId, 'zi');
      expect(service.snapshot.costume.name, '紫色锦袍');
      await service.reloadForTest();
      expect(service.snapshot.costumeId, 'zi');
      expect(service.snapshot.costume.name, '紫色锦袍');
      await service.setCostume('zhu');
      expect(service.snapshot.costume.name, '朱红战袍');
      await service.reloadForTest();
      expect(service.snapshot.costumeId, 'zhu');
      await service.setCostume('不存在');
      expect(service.snapshot.costumeId, 'qing');
      await service.resetForTest();
    });

    test('建档时不传服饰默认青色道袍', () async {
      final service = CultivationService.instance;
      await service.resetForTest();
      await service.createProfile(
        gender: CultivationGender.male,
        sect: '掩月宗',
        profession: '逍遥',
      );
      expect(service.snapshot.costumeId, 'qing');
      expect(service.snapshot.costume.name, '青色道袍');
      await service.resetForTest();
    });
  });

  group('解锁判定', () {
    test('漫画/听书/影视区门槛', () {
      expect(realmForXp(299).realm.name, '炼气期');
      // 新速率：2 秒 1 修为（1000/小时 ×1.8），600 秒 = 300 修为。
      expect(CultivationSnapshot(seconds: const {CultivationCategory.novel: 600}).unlockedComic, isTrue);
      expect(CultivationSnapshot(seconds: const {CultivationCategory.novel: 598}).unlockedComic, isFalse);
      const audioAt = CultivationSnapshot(seconds: {CultivationCategory.novel: 2000});
      expect(audioAt.unlockedAudio, isTrue);
      expect(audioAt.unlockedVideo, isFalse);
      const videoAt = CultivationSnapshot(seconds: {CultivationCategory.novel: 6000});
      expect(videoAt.unlockedVideo, isTrue);
      expect(videoAt.unlockedVideoAllCategories, isFalse);
      const allAt = CultivationSnapshot(seconds: {CultivationCategory.novel: 16000});
      expect(allAt.unlockedVideoAllCategories, isTrue);
    });

    test('到影视区还差多少修为与约多少集', () {
      const snap = CultivationSnapshot(seconds: {CultivationCategory.novel: 200});
      expect(snap.totalXp, 100);
      expect(snap.xpToVideoZone, 2900);
      // 1 集 +300 修为，2900 修为约 10 集。
      expect(snap.episodesToVideoZone, 10);
      const unlocked = CultivationSnapshot(seconds: {CultivationCategory.novel: 6000});
      expect(unlocked.xpToVideoZone, 0);
      expect(unlocked.episodesToVideoZone, 0);
    });

    test('主修与灵根', () {
      expect(CultivationSnapshot.empty.mainCategory, isNull);
      expect(CultivationSnapshot.empty.spiritRoot, '未觉醒');
      const snap = CultivationSnapshot(seconds: {
        CultivationCategory.novel: 3600,
        CultivationCategory.comic: 60,
        CultivationCategory.drama: 120,
      });
      expect(snap.mainCategory, CultivationCategory.novel);
      expect(snap.spiritRoot, '文灵根');
      const comicMain = CultivationSnapshot(seconds: {
        CultivationCategory.comic: 3600,
        CultivationCategory.novel: 60,
      });
      expect(comicMain.spiritRoot, '画灵根');
      expect(spiritRootName(CultivationCategory.audio), '音灵根');
      expect(spiritRootName(CultivationCategory.video), '影灵根');
      expect(spiritRootName(CultivationCategory.drama), '剧灵根');
    });
  });

  group('随机身份', () {
    test('用户 ID 与用户名格式', () {
      expect(generateCultivationUserId(), matches(RegExp(r'^HY\d{8}$')));
      expect(generateCultivationUsername(), matches(RegExp(r'^道友\d{4}$')));
      expect(
        generateCultivationUserId(Random(1)),
        generateCultivationUserId(Random(1)),
      );
      expect(
        generateCultivationUserId(Random(1)),
        isNot(generateCultivationUserId(Random(2))),
      );
    });
  });

  group('修为累计（落盘）', () {
    final service = CultivationService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await service.resetForTest();
    });

    test('首次安装不静默注册：未建档时无身份', () async {
      await service.ensureInitialized();
      expect(service.snapshot.hasProfile, isFalse);
      expect(service.snapshot.userId, '');
      expect(service.snapshot.username, '');
      expect(service.snapshot.gender, isNull);
      expect(service.totalXp, 0);
      expect(service.snapshot.realm.displayName, '炼气期 初期');
      expect(service.snapshot.level, 10);
      expect(service.snapshot.realm.levelLabel, 'Lv.10');
    });

    test('创建道友档案：性别/宗门/职业与随机 ID/用户名都落盘', () async {
      await service.ensureInitialized();
      await service.createProfile(
        gender: CultivationGender.female,
        sect: '掩月宗',
        profession: '逍遥',
      );
      expect(service.snapshot.hasProfile, isTrue);
      expect(service.snapshot.userId, matches(RegExp(r'^HY\d{8}$')));
      expect(service.snapshot.username, matches(RegExp(r'^道友\d{4}$')));
      expect(service.snapshot.gender, CultivationGender.female);
      expect(service.snapshot.sect, '掩月宗');
      expect(service.snapshot.profession, '逍遥');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('cultivation_user_id'), service.snapshot.userId);
      expect(sp.getString('cultivation_username'), service.snapshot.username);
      expect(sp.getString('cultivation_gender'), 'female');
      expect(sp.getString('cultivation_sect'), '掩月宗');
      expect(sp.getString('cultivation_profession'), '逍遥');
      // 二次启动：重读落盘，档案还在、身份不变，不再弹创建弹窗。
      final userId = service.snapshot.userId;
      final username = service.snapshot.username;
      await service.reloadForTest();
      expect(service.snapshot.hasProfile, isTrue);
      expect(service.snapshot.userId, userId);
      expect(service.snapshot.username, username);
      expect(service.snapshot.gender, CultivationGender.female);
      expect(service.snapshot.sect, '掩月宗');
    });

    test('宗门与职业选项（三职业：天道/逍遥/金刚）', () {
      expect(cultivationSects, [
        '黄枫谷',
        '掩月宗',
        '清虚门',
        '化刀坞',
        '天阙堡',
        '巨剑门',
        '灵兽山',
      ]);
      // 老版《凡人修仙传》网游三职业：天道、逍遥、金刚；
      // 之前剑修/体修/魔修/法修四职业已作废，没有御兽。
      expect(cultivationProfessions, ['天道', '逍遥', '金刚']);
      expect(cultivationProfessions, isNot(contains('御兽')));
      expect(cultivationProfessions, isNot(contains('剑修')));
      expect(cultivationProfessions, isNot(contains('法修')));
      expect(defaultCultivationProfession, '天道');
      expect(cultivationGenderName(CultivationGender.male), '男');
      expect(cultivationGenderName(CultivationGender.female), '女');
    });

    test('每个职业对应招牌技能名对，改职业后技能跟着换', () async {
      expect(cultivationProfessionSkill('天道'), '万剑归宗');
      expect(cultivationProfessionSkill('逍遥'), '真魔功');
      expect(cultivationProfessionSkill('金刚'), '泰阳诀');
      expect(cultivationProfessionSkill(null), '万剑归宗');
      expect(cultivationProfessionSkill('不存在'), '万剑归宗');
      expect(isCultivationProfession('天道'), isTrue);
      expect(isCultivationProfession('逍遥'), isTrue);
      expect(isCultivationProfession('金刚'), isTrue);
      expect(isCultivationProfession('剑修'), isFalse);
      expect(isCultivationProfession('御兽'), isFalse);
      // 建档后换职业：技能跟着换，落盘与二次启动一致。
      await service.ensureInitialized();
      await service.createProfile(
        gender: CultivationGender.male,
        sect: '黄枫谷',
        profession: '天道',
      );
      expect(cultivationProfessionSkill(service.snapshot.profession), '万剑归宗');
      await service.setProfession('逍遥');
      expect(service.snapshot.profession, '逍遥');
      expect(cultivationProfessionSkill(service.snapshot.profession), '真魔功');
      await service.setProfession('金刚');
      expect(service.snapshot.profession, '金刚');
      expect(cultivationProfessionSkill(service.snapshot.profession), '泰阳诀');
      await service.reloadForTest();
      expect(service.snapshot.profession, '金刚');
      // 不在三项里的职业不改。
      await service.setProfession('剑修');
      expect(service.snapshot.profession, '金刚');
      await service.setProfession('御兽');
      expect(service.snapshot.profession, '金刚');
      // 建档时传了已作废的职业，退化为默认天道。
      await service.resetForTest();
      await service.createProfile(
        gender: CultivationGender.female,
        sect: '掩月宗',
        profession: '剑修',
      );
      expect(service.snapshot.profession, '天道');
      expect(cultivationProfessionSkill(service.snapshot.profession), '万剑归宗');
    });

    test('时长、集数、章数累计成修为', () async {
      await service.ensureInitialized();
      // 新速率：2 秒 1 修为（活动 1 小时 1000 修为 ×1.8 = 1800 修为）。
      await service.addSeconds(CultivationCategory.novel, 600);
      expect(service.totalXp, 300);
      expect(service.snapshot.minutesFor(CultivationCategory.novel), 10);
      expect(service.snapshot.unlockedComic, isTrue);
      expect(service.snapshot.unlockedAudio, isFalse);
      await service.addSeconds(CultivationCategory.novel, 1400);
      expect(service.totalXp, 1000);
      expect(service.snapshot.unlockedAudio, isTrue);
      await service.addSeconds(CultivationCategory.novel, 4000);
      expect(service.totalXp, 3000);
      expect(service.snapshot.unlockedVideo, isTrue);
      expect(service.snapshot.realm.displayName, '元婴期 初期');
      await service.addDramaEpisodeCompleted();
      await service.addDramaEpisodeCompleted();
      await service.addDramaEpisodeCompleted();
      expect(service.snapshot.dramaEpisodes, 3);
      expect(service.totalXp, 3900);
      await service.addChapterCompleted(CultivationCategory.novel);
      await service.addChapterCompleted(CultivationCategory.novel);
      expect(service.snapshot.novelChapters, 2);
      expect(service.totalXp, 4200);
      await service.addChapterCompleted(CultivationCategory.audio);
      expect(service.snapshot.audioChapters, 1);
      expect(service.totalXp, 4350);
      // 落盘：秒数与奖励都在 prefs 里。
      final sp = await SharedPreferences.getInstance();
      expect(sp.getDouble('cultivation_seconds_novel'), 6000);
      expect(sp.getInt('cultivation_bonus_xp'), 1350);
    });

    test('改名落盘，空名不改', () async {
      await service.ensureInitialized();
      final before = service.snapshot.username;
      await service.renameUser('韩立');
      expect(service.snapshot.username, '韩立');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('cultivation_username'), '韩立');
      await service.renameUser('   ');
      expect(service.snapshot.username, '韩立');
      expect(before, isNot('韩立'));
    });

    test('无效时长不计', () async {
      await service.ensureInitialized();
      await service.addSeconds(CultivationCategory.novel, 0);
      await service.addSeconds(CultivationCategory.novel, -60);
      await service.addSeconds(CultivationCategory.novel, double.nan);
      expect(service.totalXp, 0);
      expect(service.snapshot.minutesFor(CultivationCategory.novel), 0);
    });
  });

  group('新人大礼包兑换码', () {
    final service = CultivationService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await service.resetForTest();
    });

    test('四码各到一境', () {
      expect(cultivationGiftCodes, {
        'VIP666': 300,
        'VIP888': 1000,
        'VIP6666': 3000,
        'VIP8888': 8000,
      });
    });

    test('兑换成功：修为补到目标境界', () async {
      await service.ensureInitialized();
      final first = await service.redeemCode('VIP666');
      expect(first.result, CultivationRedeemResult.success);
      expect(first.targetXp, 300);
      expect(first.oldXp, 0);
      expect(first.newXp, 300);
      expect(service.totalXp, 300);
      expect(service.snapshot.realm.displayName, '筑基期 初期');
      final second = await service.redeemCode('VIP8888');
      expect(second.result, CultivationRedeemResult.success);
      expect(second.newXp, 8000);
      expect(service.snapshot.realm.displayName, '化神期 初期');
    });

    test('每个码只能用一次', () async {
      await service.ensureInitialized();
      await service.redeemCode('VIP666');
      final again = await service.redeemCode('VIP666');
      expect(again.result, CultivationRedeemResult.alreadyUsed);
      expect(again.newXp, 300);
      expect(service.totalXp, 300);
      // 大小写不敏感，同一个码换个写法也算用过。
      final lower = await service.redeemCode('vip666');
      expect(lower.result, CultivationRedeemResult.alreadyUsed);
      // 二次启动后已用码还在。
      await service.reloadForTest();
      final afterReload = await service.redeemCode('VIP666');
      expect(afterReload.result, CultivationRedeemResult.alreadyUsed);
      expect(service.usedCodes, contains('VIP666'));
    });

    test('码不对不消耗', () async {
      await service.ensureInitialized();
      final result = await service.redeemCode('VIP999');
      expect(result.result, CultivationRedeemResult.invalid);
      expect(service.totalXp, 0);
      expect(service.usedCodes, isEmpty);
    });

    test('已达到目标境界时不消耗', () async {
      await service.ensureInitialized();
      await service.addSeconds(CultivationCategory.novel, 20000);
      expect(service.totalXp, 10000);
      final result = await service.redeemCode('VIP888');
      expect(result.result, CultivationRedeemResult.alreadyAtRealm);
      expect(result.newXp, 10000);
      // 没消耗：码不在已用表里，以后修为掉了（不会掉）也不影响。
      expect(service.usedCodes, isNot(contains('VIP888')));
      // 再兑一次还是已达到，不是已用过。
      final again = await service.redeemCode('VIP888');
      expect(again.result, CultivationRedeemResult.alreadyAtRealm);
    });
  });

  group('打坐给经验', () {
    final service = CultivationService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await service.resetForTest();
    });

    test('打坐与看/读/听同一速率：1 小时 1800 修为', () async {
      await service.ensureInitialized();
      await service.addMeditationSeconds(3600);
      expect(service.totalXp, 1800);
      expect(service.snapshot.meditationMinutes, 60);
      expect(service.snapshot.meditationSeconds, 3600);
      // 打坐 10 分钟 = 300 修为，与看完 1 集短剧等价。
      await service.addMeditationSeconds(600);
      expect(service.totalXp, 2100);
    });

    test('打坐落盘，二次启动还在', () async {
      await service.ensureInitialized();
      await service.addMeditationSeconds(600);
      await service.reloadForTest();
      expect(service.snapshot.meditationSeconds, 600);
      expect(service.totalXp, 300);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getDouble('cultivation_meditation_seconds'), 600);
    });

    test('无效打坐时长不计', () async {
      await service.ensureInitialized();
      await service.addMeditationSeconds(0);
      await service.addMeditationSeconds(-10);
      await service.addMeditationSeconds(double.nan);
      expect(service.totalXp, 0);
      expect(service.snapshot.meditationSeconds, 0);
    });
  });
}
