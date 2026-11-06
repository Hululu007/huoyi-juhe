import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/unified_video_categories.dart';

/// 统一分类服务测试：解析（纯函数）+ 资产加载（注入假 bundle）。
/// 不联网、不读真实资产。
void main() {
  const sampleJson = '''
{
  "version": 1,
  "site_count": 3,
  "total_site_count": 5,
  "sites_without_categories": ["no_cat_a", "no_cat_b"],
  "categories": {
    "热门甲": [
      {"siteId": "a", "path": "/cat/1"},
      {"siteId": "b", "path": "/cat/1"},
      {"siteId": "c", "path": "/cat/1"},
      {"siteId": "d", "path": "/cat/1"},
      {"siteId": "e", "path": "/cat/1"}
    ],
    "冷门乙": [{"siteId": "a", "path": "/cat/2"}],
    "中热丙": [
      {"siteId": "a", "path": "/cat/3"},
      {"siteId": "b", "path": "/cat/3"}
    ]
  },
  "tags": {
    "可看标签": [
      {"siteId": "a", "url": "/tag/x", "browsable": true},
      {"siteId": "b", "url": "/tag/x", "browsable": false},
      {"siteId": "c", "url": "/tag/x"}
    ],
    "全不可看": [
      {"siteId": "a", "url": "/tag/y", "browsable": false}
    ]
  }
}
''';

  test('解析：分类按名归并，热门与全部按站数排', () {
    final data = parseUnifiedVideoCategories(sampleJson);

    expect(data.siteCount, 3);
    expect(data.totalSiteCount, 5);
    expect(data.sitesWithoutCategories, ['no_cat_a', 'no_cat_b']);
    expect(data.categories.keys, {'热门甲', '冷门乙', '中热丙'});
    expect(data.sitesFor('热门甲').length, 5);
    expect(data.sitesFor('热门甲').first.siteId, 'a');
    expect(data.sitesFor('热门甲').first.path, '/cat/1');
    expect(data.siteCountFor('中热丙'), 2);
    expect(data.sitesFor('不存在'), isEmpty);

    // 热门 = >=5 站：只有「热门甲」。
    expect(data.hotNames, ['热门甲']);
    // 全部按站数降序：热门甲 5、中热丙 2、冷门乙 1。
    expect(data.allNames, ['热门甲', '中热丙', '冷门乙']);
  });

  test('解析：标签只收 browsable 为真的站', () {
    final data = parseUnifiedVideoCategories(sampleJson);

    // 「可看标签」：a 可浏览收，b 明确 false 丢，c 缺字段丢。
    expect(data.tagNames, ['可看标签']);
    final sites = data.tagSitesFor('可看标签');
    expect(sites.length, 1);
    expect(sites.first.siteId, 'a');
    expect(sites.first.url, '/tag/x');
    expect(sites.first.browsable, isTrue);
    // 「全不可看」整组丢掉。
    expect(data.tagSitesFor('全不可看'), isEmpty);
  });

  test('解析：字段缺失/类型不对时容错，不抛错', () {
    expect(parseUnifiedVideoCategories('{}').categories, isEmpty);
    expect(parseUnifiedVideoCategories('[]').categories, isEmpty);
    expect(parseUnifiedVideoCategories('not json').categories, isEmpty);
    final odd = parseUnifiedVideoCategories('{"categories": {"甲": "不是列表", "乙": [{"siteId": "", "path": ""}, {"siteId": "a", "path": "/x"}]}}');
    expect(odd.categories.keys, ['乙']);
    expect(odd.sitesFor('乙').length, 1);
  });

  test('解析：兼容列表形标签', () {
    final data = parseUnifiedVideoCategories(
      '{"tags": [{"name": "表甲", "siteId": "a", "url": "/t/1", "browsable": true}, '
      '{"name": "表甲", "siteId": "b", "url": "/t/1", "browsable": false}]}',
    );
    expect(data.tagNames, ['表甲']);
    expect(data.tagSitesFor('表甲').length, 1);
  });

  test('加载：注入假 bundle 读资产，读不到返回空数据', () async {
    final loaded = await loadUnifiedVideoCategories(
      bundle: _FakeBundle(sampleJson),
    );
    expect(loaded.allNames, ['热门甲', '中热丙', '冷门乙']);
    expect(loaded.hotNames, ['热门甲']);

    final missing = await loadUnifiedVideoCategories(
      bundle: _FailingBundle(),
    );
    expect(missing, UnifiedVideoCategories.empty);
  });
}

class _FakeBundle extends AssetBundle {
  _FakeBundle(this.text);

  final String text;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.view(Uint8List.fromList(utf8.encode(text)).buffer);

  @override
  Future<String> loadString(String key, {bool cache = true}) async => text;
}

class _FailingBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) async {
    throw StateError('no asset');
  }
}
