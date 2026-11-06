import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_identity.dart';

void main() {
  group('归一键', () {
    test('内容站地址按主机归一：大小写、www、前缀路径、端口都不另起键', () {
      expect(
        canonicalSiteKey(
          siteId: 'custom_1',
          address: 'https://WWW.HongGuoDuanJu.COM/api.php?ac=videolist',
          addressIsSiteAddress: true,
        ),
        'host:hongguoduanju.com',
      );
      expect(
        canonicalSiteKey(
          siteId: 'custom_2',
          address: 'https://www.zywest263.com:8443/api.php',
          addressIsSiteAddress: true,
        ),
        'host:zywest263.com',
      );
    });

    test('地址不是内容站地址时不按主机合并，退回登记 id', () {
      expect(
        canonicalSiteKey(
          siteId: 'py_1',
          address: 'https://files.example.com/x.jar',
        ),
        'id:py_1',
      );
      expect(
        canonicalSiteKey(siteId: 'py_1', address: 'example.py'),
        'id:py_1',
      );
      expect(canonicalSiteKey(siteId: 'py_1'), 'id:py_1');
    });

    test('内置站已核实主机进表，红果镜像同域也不合并', () {
      expect(canonicalSiteKey(siteId: 'hongguo'), 'host:hongguoduanju.com');
      expect(canonicalSiteKey(siteId: 'huaguo'), 'host:zywest263.com');
      expect(canonicalSiteKey(siteId: 'faguo'), 'host:xzyx168.com');
      expect(canonicalSiteKey(siteId: 'wuguo'), 'host:duanju55.com');
      expect(canonicalSiteKey(siteId: 'wangguo'), 'host:duanju2.com');
      expect(canonicalSiteKey(siteId: 'hgtvmirror'), 'id:hgtvmirror');
    });

    test('已是归一键时透传，不套第二层', () {
      expect(
        canonicalSiteKey(siteId: 'host:hongguoduanju.com'),
        'host:hongguoduanju.com',
      );
      expect(canonicalSiteKey(siteId: 'id:py_site'), 'id:py_site');
    });

    test('地址适用范围：只有采集站与书源站的地址是内容站地址', () {
      expect(addressIsSiteAddressForKind('customMaccms'), isTrue);
      expect(addressIsSiteAddressForKind('legadoImport'), isTrue);
      for (final kind in [
        'pyImport',
        'jarImport',
        'jsImport',
        'xbpqImport',
        'remoteJson',
        'builtinDrama',
      ]) {
        expect(addressIsSiteAddressForKind(kind), isFalse);
      }
    });
  });

  group('选站去重', () {
    test('同站多入口只留第一行，镜像与不同地址不折掉', () {
      final rows = dedupeByCanonicalKey(
        [
          ('hongguo', '', false),
          ('custom_1', 'https://hongguoduanju.com/api.php', true),
          ('hgtvmirror', '', false),
          ('py_9', 'https://files.example.com/a.py', false),
          ('custom_2', 'https://www.zywest263.com/api.php', true),
          ('huaguo', '', false),
        ],
        (row) => canonicalSiteKey(
          siteId: row.$1,
          address: row.$2,
          addressIsSiteAddress: row.$3,
        ),
      );
      expect(
        [for (final row in rows) row.$1],
        ['hongguo', 'hgtvmirror', 'py_9', 'custom_2'],
      );
    });
  });

}
