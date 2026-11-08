import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';

import 'embedded_test_entries.dart';

/// 影视页按境界过滤：成人站按修为分 4 档自动解锁，未解锁的站完全
/// 不在列表里出现（不灰掉、不占位、不露站名）；内嵌站的行 id 是种子
/// `seed_<id>` / jar `jar:zakatv:<key>`，查档位时归一化成核心站 id；
/// 从未进过核心的站不分档、原样保留。
void main() {
  /// 门禁开关：生产默认值 true（测试期临时关闭）会放行全部档位，
  /// 分档断言须先关掉，用完恢复。
  setUp(() {
    cultivationAdultTierGateDisabledForTesting = false;
  });
  tearDown(() {
    cultivationAdultTierGateDisabledForTesting = true;
  });

  /// 内嵌站测试条目（种子 + jar），与生产登记一致。
  final entries = embeddedTestEntries();

  test('修为 0 时只剩不分档站，第 1 档站一个都不露', () {
    final visible = visibleVideoZoneSites(entries, 0);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('jar:zakatv:ZakaMjv011'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaMissav'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isFalse);
    expect(ids.contains('seed_abjav'), isFalse);
    expect(ids.contains('jar:zakatv:zakaaiye'), isFalse);
    expect(ids.contains('jar:zakatv:av18avmcg'), isFalse);
    // 不分档的站原样保留：从未进核心的 jar 站与 YouTube。
    expect(ids.contains('jar:zakatv:zakajavverse'), isTrue);
    expect(ids.contains('jar:youtube:youtube'), isTrue);
    // 列表里一个分档站都不剩：每个 id 查档位都是 null。
    for (final id in ids) {
      expect(adultTierForSiteId(id, adultVideoSiteOrder), isNull);
    }
  });

  test('元婴 3000 时第 1 档出现，第 2 档还不出现', () {
    final visible = visibleVideoZoneSites(entries, 3000);
    final ids = visible.map((site) => site.id).toSet();
    // 登记表第 1 个站（mjv011，jar 行）在第 1 档，3000 修为可见。
    expect(ids.contains('jar:zakatv:ZakaMjv011'), isTrue);
    // missav 与鉴黄师钉第 4 档末尾，3000 修为还看不到。
    expect(ids.contains('jar:zakatv:ZakaMissav'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isFalse);
  });

  test('合体 30000 时全部开完，missav 与鉴黄师都在', () {
    final visible = visibleVideoZoneSites(entries, 30000);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('jar:zakatv:ZakaMissav'), isTrue);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isTrue);
    expect(ids.contains('jar:zakatv:zakaaiye'), isTrue);
    expect(ids.contains('jar:zakatv:av18avmcg'), isTrue);
    // 全开 = 统一表原样，不多不少。
    // 291 行 = 第 1 档 49 + 第 2 档 60 + 第 3 档 54 + 第 4 档 77
    // （240 个分档影视行）+ 51 个不分档影视行；
    // 短剧站已在统一表里摘掉：芽果/AI淫航/幻影AI 各 jar+种子两行
    // （6 行）都是短剧站，不分档，297→291 全是这 6 行。
    // 相对旧数 293 的变化：并行加站（种子 108→115、jar 登记 243→247）
    // 让不分档行 54→57、分档行 239→240；再减 AOXX69 一行（分档
    // 239→240 里已含摘站影响：aoxx69 本是第 1 档行，rou 1→0 与
    // hgdj 2→1 的档位移动见 adult_tier_embedded_test）。
    // 不分档原 58，已删站减 1。
    expect(ids.length, unifiedVideoZoneSites(entries).length);
    expect(ids.length, 291);
  });

  test('门禁开关开时修为 0 也全可见', () {
    cultivationAdultTierGateDisabledForTesting = true;
    final visible = visibleVideoZoneSites(entries, 0);
    expect(visible.length, unifiedVideoZoneSites(entries).length);
    expect(visible.length, 291);
  });

  test('第 4 档末尾顺序：missav 在前、鉴黄师压最后', () {
    final tier4 = adultTierSiteIds(3, adultVideoSiteOrder);
    expect(tier4.indexOf('missav'), lessThan(tier4.indexOf('javrate')));
    expect(tier4.last, 'javrate');
  });
}
