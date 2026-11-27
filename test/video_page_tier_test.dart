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
    expect(ids.contains('seed_missav'), isFalse);
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
    // missav 与鉴黄师钉第 4 档末尾，3000 修为还看不到
    //（missav 只剩种子行，jar 重复登记已于 2026-11-26 摘掉）。
    expect(ids.contains('seed_missav'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isFalse);
  });

  test('合体 30000 时全部开完，missav 与鉴黄师都在', () {
    final visible = visibleVideoZoneSites(entries, 30000);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('seed_missav'), isTrue);
    expect(ids.contains('jar:zakatv:ZakaJavrate'), isTrue);
    expect(ids.contains('jar:zakatv:zakaaiye'), isTrue);
    expect(ids.contains('jar:zakatv:av18avmcg'), isTrue);
    // 全开 = 统一表原样，不多不少。
    // 382 行 = 第 1 档 68 + 第 2 档 80 + 第 3 档 97 + 第 4 档 69
    // （314 个分档影视行）+ 68 个不分档影视行；
    // 短剧站已在统一表里摘掉：芽果/AI淫航/幻影AI 各 jar+种子两行
    // （6 行）都是短剧站，不分档；2026-11-09 复核又摘掉 AI不用钱
    // 与黄果漫剧 2 行种子（纯短剧/漫剧站，之前误判进影视区）。
    // 旧注的 289 行是种子 115 条、登记表 201 站时代的数；恢复树里
    // 种子已 207 条、登记表 273 站，改前真数是 381 行（分档
    // 68/79/95/71 + 不分档 68）。本次合入 5 行（missav/whos 种子、
    // YzAikan/One/TgPianku jar），新行全落第 4 档；分母 273→278
    // 使 8 行下移一档（jav777 1→0、hongxing jar+种子 2→1、
    // chaoliu/changzhangzy/ckzy/dadizy 3→2），第 4 档行数净不变。
    // 2026-11-26 MissAV 收拢再摘 4 个 jar 重复登记行（ZakaMissav/
    // ZakaMissavOff/ZakaMirror/missavt），分档表 278→275 使 airav
    // 1→0、shunvwang 2→1、danaizizy 3→2（heitaoduanju 同步换档但
    // 无统一表行），行数 386→382，逐行增减已核（IMPL_REPORT）。
    // 2026-11-27 站点库批：条目改按名单口径，行数 382→377。
    expect(ids.length, unifiedVideoZoneSites(entries).length);
    expect(ids.length, 377);
  });

  test('门禁开关开时修为 0 也全可见', () {
    cultivationAdultTierGateDisabledForTesting = true;
    final visible = visibleVideoZoneSites(entries, 0);
    expect(visible.length, unifiedVideoZoneSites(entries).length);
    expect(visible.length, 377);
  });

  test('第 4 档末尾顺序：missav 在前、鉴黄师压最后', () {
    final tier4 = adultTierSiteIds(3, adultVideoSiteOrder);
    expect(tier4.indexOf('missav'), lessThan(tier4.indexOf('javrate')));
    expect(tier4.last, 'javrate');
  });
}
