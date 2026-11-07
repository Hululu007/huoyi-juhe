import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_site_search.dart';

/// 标签搜索回归：计数后缀剥离 + 限定站搜索不向全站扇出。
///
/// 背景：统一分类页点标签曾把标签名原样当关键词向 200 多站全量扇出，
/// 请求在 RequestGate（16 并发）后排队，站表尾部的站 45 秒预算耗在
/// 排队上、一个都没跑到就超时回空，页上只剩「站源里没有搜到相关内容」。
/// 修法：只搜该标签名下的站；搜索词去资产里带的站方计数后缀。
void main() {
  test('tagSearchQuery 去尾部计数后缀，其余一字不动', () {
    expect(tagSearchQuery('1080p (896)'), '1080p');
    expect(tagSearchQuery('1080 hd (306)'), '1080 hd');
    expect(tagSearchQuery('18 (3122)'), '18');
    expect(tagSearchQuery('18 teens (18+) (101)'), '18 teens (18+)');
    expect(tagSearchQuery('校服'), '校服');
    expect(tagSearchQuery('  中出  '), '中出');
    // 名字中间的括号不是计数后缀，不动。
    expect(tagSearchQuery('a (b) c'), 'a (b) c');
  });

  test('限定站搜索：站 id 不在站表里时直接回空，不联网', () async {
    SharedPreferences.setMockInitialValues({});
    final results = await searchAllDramaSites(
      '校服',
      siteIds: {'no-such-site'},
    );
    expect(results, isEmpty);
  });

  test('空查询直接回空，不取站表', () async {
    SharedPreferences.setMockInitialValues({});
    final results = await searchAllDramaSites(
      '   ',
      siteIds: {'no-such-site'},
    );
    expect(results, isEmpty);
  });
}
