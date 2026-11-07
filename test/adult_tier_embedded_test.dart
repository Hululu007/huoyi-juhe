import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/builtin_imported_sites.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

import 'embedded_test_entries.dart';

/// 境界成人分档（内嵌版）：批量转站后核心只剩 hgdj/hgdj58/hgdjv 3 站，
/// 分档改读 adultVideoSiteOrder（删核心前的核心登记顺序，201 站）。
/// 影视区统一表里的行 id（种子 `seed_<id>`、jar `jar:zakatv:<key>`、
/// 核心裸 id）查档位时先归一化成核心站 id。
///
/// 档位必须与删前一致：原来在第几档、现在还在第几档，不洗牌。
/// 原始 19 短剧站本来就不在分档表里，不受影响；从未进过核心的
/// jar/种子站也不分档，按非成人站原样保留。
void main() {
  /// 原始 19 短剧站（Dart 客户端，不在核心分档表里）。
  const original19 = [
    'original',
    'hongguo',
    'hgtv',
    'hgtvmirror',
    'huangdou',
    'huangju',
    'yeguo',
    'yaguo',
    'maoguo',
    'fanguo',
    'guanguo',
    'heguo',
    'xingguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'wuguo',
    'huangdou_yh',
  ];

  test('分档登记表：201 站、无重复、首站 mjv011、末站 wohs', () {
    expect(adultVideoSiteOrder.length, 201);
    expect(adultVideoSiteOrder.toSet().length, 201);
    expect(adultVideoSiteOrder.first, 'mjv011');
    expect(adultVideoSiteOrder.last, 'wohs');
  });

  test('3 个留站仍在分档里，原始 19 短剧站都不在', () {
    for (final id in ['hgdj', 'hgdj58', 'hgdjv']) {
      expect(adultVideoSiteOrder.contains(id), isTrue);
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNotNull);
    }
    for (final id in original19) {
      expect(adultVideoSiteOrder.contains(id), isFalse);
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNull);
    }
  });

  test('4 档规模与删前一致：49/50/50/52', () {
    expect(adultTierSiteIds(0, adultVideoSiteOrder).length, 49);
    expect(adultTierSiteIds(1, adultVideoSiteOrder).length, 50);
    expect(adultTierSiteIds(2, adultVideoSiteOrder).length, 50);
    expect(adultTierSiteIds(3, adultVideoSiteOrder).length, 52);
  });

  test('抽查档位与删前备份顺序一致', () {
    // 下标与档位按删除备份里的旧 coreVideoSiteIds 顺序算
    // （档 = min(3, 下标 × 4 ~/ 201)；missav/javrate 钉第 4 档）。
    const expected = <String, int>{
      'mjv011': 0,
      'missav': 3,
      'javrate': 3,
      'hgdj': 2,
      'hgdj58': 3,
      'hgdjv': 0,
      'aiye': 1,
      'av18avmcg': 1,
      'xj': 3,
      'xj2': 0,
      'haijiao': 0,
      'haijiao4k': 2,
      'rou': 1,
      'rouvideo': 3,
      'wohs': 3,
      '123av': 0,
      '321av': 1,
      '591av': 1,
      '99jj': 0,
      '17rip': 1,
      '69vj': 0,
      'txfans': 0,
      'hjapp': 1,
      'javplay': 1,
      'lissavcn': 3,
      'missavoff': 0,
      'hddj': 0,
      'huangguo': 0,
      'hgtvim': 0,
      'abjav': 3,
      'danai': 2,
      'caoliu': 3,
    };
    for (final entry in expected.entries) {
      expect(
        adultTierForSiteId(entry.key, adultVideoSiteOrder),
        entry.value,
        reason: entry.key,
      );
    }
  });

  test('统一表行 id 归一化成核心站 id', () {
    expect(adultSiteIdForUnifiedId('seed_abjav'), 'abjav');
    expect(adultSiteIdForUnifiedId('seed_missav'), 'missav');
    expect(adultSiteIdForUnifiedId('seed_yaguo'), 'yaguo');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaMjv011'), 'mjv011');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaMissav'), 'missav');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaJavrate'), 'javrate');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av123'), '123av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av321'), '321av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:av591'), '591av');
    expect(adultSiteIdForUnifiedId('jar:zakatv:jj99'), '99jj');
    expect(adultSiteIdForUnifiedId('jar:zakatv:rip17'), '17rip');
    expect(adultSiteIdForUnifiedId('jar:zakatv:vj69'), '69vj');
    expect(adultSiteIdForUnifiedId('jar:zakatv:zaketxfans'), 'txfans');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaWhos'), 'wohs');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaHjApp'), 'hjapp');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaHgdjV'), 'hgdjv');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaMissavOff'), 'missavoff');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaLissavCn'), 'lissavcn');
    expect(adultSiteIdForUnifiedId('jar:zakatv:ZakaJavPlay'), 'javplay');
    expect(adultSiteIdForUnifiedId('jar:zakatv:haijiao4k'), 'haijiao4k');
    expect(adultSiteIdForUnifiedId('jar:zakatv:hgdj58'), 'hgdj58');
    expect(adultSiteIdForUnifiedId('jar:zakatv:rouvideo'), 'rouvideo');
    expect(adultSiteIdForUnifiedId('jar:zakatv:wohs'), 'wohs');
    expect(adultSiteIdForUnifiedId('jar:zakatv:xj2'), 'xj2');
    expect(adultSiteIdForUnifiedId('jar:zakatv:dsav'), 'dsav');
    expect(adultSiteIdForUnifiedId('hgdj'), 'hgdj');
    expect(adultSiteIdForUnifiedId('tgdrama'), 'tgdrama');
    expect(adultSiteIdForUnifiedId('jar:youtube:youtube'), 'youtube');
    // 归一化后仍不在表里的站查档位是 null（从未进过核心）。
    expect(
      adultTierForSiteId('jar:zakatv:zakajavverse', adultVideoSiteOrder),
      isNull,
    );
    expect(
      adultTierForSiteId('seed_91sanji', adultVideoSiteOrder),
      isNull,
    );
    expect(
      adultTierForSiteId('seed_yaguo', adultVideoSiteOrder),
      isNull,
    );
  });

  test('199 个内嵌站全有档位：种子 + jar + 核心 3 站覆盖全部 201 个登记 id', () {
    // 198 个已转的 tiered 站（199 个删掉的模块里 yaguo 是短剧站，
    // 从不在分档表里）+ 3 个留站 = 201。
    final covered = <String>{};
    for (final seed in builtinImportedSeeds) {
      final id = 'seed_${seed.seedId}';
      if (adultTierForSiteId(id, adultVideoSiteOrder) != null) {
        covered.add(adultSiteIdForUnifiedId(id));
      }
    }
    for (final site in zakatvBuiltinSites) {
      final id = JarSiteSpec.siteIdFor(zakatvJarId, site.key);
      if (adultTierForSiteId(id, adultVideoSiteOrder) != null) {
        covered.add(adultSiteIdForUnifiedId(id));
      }
    }
    covered.addAll(['hgdj', 'hgdj58', 'hgdjv']);
    expect(covered.length, 201);
    expect(covered, adultVideoSiteOrder.toSet());
  });

  test('影视区可见站表：内嵌行按档位放，门禁开关开/关两态都正常', () {
    final wasDisabled = cultivationAdultTierGateDisabledForTesting;
    addTearDown(
      () => cultivationAdultTierGateDisabledForTesting = wasDisabled,
    );
    final entries = embeddedTestEntries();
    final allIds =
        unifiedVideoZoneSites(entries).map((site) => site.id).toList();
    // 开关开（测试期临时关闭）：修为 0 也全可见。
    cultivationAdultTierGateDisabledForTesting = true;
    expect(
      visibleVideoZoneSites(entries, 0).map((s) => s.id).toList(),
      allIds,
    );
    // 开关关：修为 0 时分档行一个都不露，只剩不分档行。
    cultivationAdultTierGateDisabledForTesting = false;
    final at0 = visibleVideoZoneSites(entries, 0).map((s) => s.id).toSet();
    expect(at0.contains('jar:zakatv:ZakaMjv011'), isFalse);
    expect(at0.contains('jar:zakatv:ZakaMissav'), isFalse);
    expect(at0.contains('seed_abjav'), isFalse);
    expect(at0.contains('tgdrama'), isTrue);
    expect(at0.contains('jar:zakatv:zakajavverse'), isTrue);
    // 3000 时第 1 档出现（mjv011 是 jar 行），第 4 档还不出现。
    final at3000 =
        visibleVideoZoneSites(entries, 3000).map((s) => s.id).toSet();
    expect(at3000.contains('jar:zakatv:ZakaMjv011'), isTrue);
    expect(at3000.contains('jar:zakatv:ZakaMissav'), isFalse);
    expect(at3000.contains('jar:zakatv:ZakaJavrate'), isFalse);
    // 30000 全开。
    expect(
      visibleVideoZoneSites(entries, 30000).map((s) => s.id).toList(),
      allIds,
    );
  });
}
