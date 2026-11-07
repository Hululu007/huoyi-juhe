import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/cultivation.dart';

/// 境界解锁门禁临时关闭开关（[cultivationAdultTierGateDisabledForTesting]）
/// 的开/关两种状态：
///
/// - 开关 true（门禁关闭，当前值）：修为 0 也能看见全部 4 档的站；
/// - 开关 false（门禁恢复）：修为不到门槛的档位继续隐藏。
///
/// 旧的“未解锁不显示”用例（test/cultivation_test.dart 里的
/// 「各档门槛前后」「未解锁的站完全隐藏」「146 站分档」与
/// 「修为不到合体两站完全隐藏」，以及 test/video_page_tier_test.dart、
/// test/home_film_zone_test.dart 里修为 0/3000 只露部分站的用例）
/// 写的是开关 false 时的行为，开关 true 时必然失效——那是开关
/// 生效的证明，不是回归，不改它们的预期；开关改回 false 后它们
/// 应重新通过。
void main() {
  group('境界门禁临时关闭开关', () {
    test('开关 true（门禁关闭）：修为 0 时 4 档全算已解锁', () {
      cultivationAdultTierGateDisabledForTesting = true;
      try {
        for (var tier = 0; tier < 4; tier++) {
          expect(adultTierUnlocked(tier, 0), isTrue);
        }
        // 门槛前一修为也不拦：第 4 档 29999 照样算解锁。
        expect(adultTierUnlocked(3, 29999), isTrue);
      } finally {
        cultivationAdultTierGateDisabledForTesting = true;
      }
    });

    test('开关 true（门禁关闭）：低修为也能看见全部档位的站', () {
      cultivationAdultTierGateDisabledForTesting = true;
      try {
        // 登记表 8 个站：下标 0,1→第 1 档；2,3→第 2 档；4,5→第 3 档；6,7→第 4 档。
        const registry = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7'];
        const all = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', 'fruit'];
        expect(visibleSiteIds(all, registry, 0), all);
        // missav 与鉴黄师钉在第 4 档，修为 0 也照样出现。
        expect(visibleSiteIds(registry, registry, 0), registry);
      } finally {
        cultivationAdultTierGateDisabledForTesting = true;
      }
    });

    test('开关 false（门禁恢复）：修为不到门槛的档位继续隐藏', () {
      cultivationAdultTierGateDisabledForTesting = false;
      try {
        expect(adultTierUnlocked(0, 2999), isFalse);
        expect(adultTierUnlocked(0, 3000), isTrue);
        expect(adultTierUnlocked(1, 7999), isFalse);
        expect(adultTierUnlocked(1, 8000), isTrue);
        expect(adultTierUnlocked(2, 14999), isFalse);
        expect(adultTierUnlocked(2, 15000), isTrue);
        expect(adultTierUnlocked(3, 29999), isFalse);
        expect(adultTierUnlocked(3, 30000), isTrue);
        const registry = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7'];
        const all = ['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7', 'fruit'];
        expect(visibleSiteIds(all, registry, 2999), ['fruit']);
        expect(visibleSiteIds(all, registry, 3000), ['s0', 's1', 'fruit']);
        expect(visibleSiteIds(all, registry, 30000), all);
      } finally {
        cultivationAdultTierGateDisabledForTesting = true;
      }
    });

    test('开关 true 时非法档位仍不放行', () {
      cultivationAdultTierGateDisabledForTesting = true;
      try {
        expect(adultTierUnlocked(-1, 999999), isFalse);
        expect(adultTierUnlocked(4, 999999), isFalse);
      } finally {
        cultivationAdultTierGateDisabledForTesting = true;
      }
    });
  });
}
