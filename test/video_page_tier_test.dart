import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_site_content.dart';

/// 影视页按境界过滤：成人站按修为分 4 档自动解锁，未解锁的站完全
/// 不在列表里出现（不灰掉、不占位、不露站名）；TG影视库不分档，
/// 原样保留；5 个果站是短剧站，已从影视区摘掉（短剧归短剧区）。
void main() {
  test('修为 0 时只剩 TG影视库，成人站一个都不露', () {
    final visible = visibleVideoZoneSites(const [], 0);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids, {'tgdrama'});
    expect(ids.contains('missav'), isFalse);
    expect(ids.contains('javrate'), isFalse);
    expect(ids.contains('aiye'), isFalse);
    expect(ids.contains('av18avmcg'), isFalse);
    // 列表里一个成人站都不剩：每个 id 都不在登记表里。
    for (final id in ids) {
      expect(coreVideoSiteIds.contains(id), isFalse);
    }
  });

  test('元婴 3000 时第 1 档出现，第 2 档还不出现', () {
    final visible = visibleVideoZoneSites(const [], 3000);
    final ids = visible.map((site) => site.id).toSet();
    // 登记表第 1 个站（mjv011）在第 1 档，3000 修为可见。
    expect(ids.contains('mjv011'), isTrue);
    // missav 与鉴黄师钉第 4 档末尾，3000 修为还看不到。
    expect(ids.contains('missav'), isFalse);
    expect(ids.contains('javrate'), isFalse);
  });

  test('合体 30000 时全部开完，missav 与鉴黄师都在', () {
    final visible = visibleVideoZoneSites(const [], 30000);
    final ids = visible.map((site) => site.id).toSet();
    expect(ids.contains('missav'), isTrue);
    expect(ids.contains('javrate'), isTrue);
    expect(ids.contains('aiye'), isTrue);
    expect(ids.contains('av18avmcg'), isTrue);
    // 全开 = 统一表原样，不多不少。
    expect(ids.length, unifiedVideoZoneSites(const []).length);
  });

  test('第 4 档末尾顺序：missav 在前、鉴黄师压最后', () {
    final tier4 = adultTierSiteIds(3, coreVideoSiteIds.toList());
    expect(tier4.indexOf('missav'), lessThan(tier4.indexOf('javrate')));
    expect(tier4.last, 'javrate');
  });
}
