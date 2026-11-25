import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/site_thumb_cache.dart';

/// 站点透视封面缓存（C1）测试：命中不重拉、失败不记、并发去重、
/// 落盘往返、坏文件当空缓存。

void main() {
  late Directory tempDir;
  late SiteThumbCache cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('site_thumb_cache_test');
    cache = SiteThumbCache(directoryProvider: () async => tempDir);
  });

  tearDown(() async {
    cache.resetForTest();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('命中后不再走取数', () async {
    var calls = 0;
    Future<String?> fetcher(String siteId) async {
      calls++;
      return 'https://example.com/$siteId.jpg';
    }

    final first = await cache.thumbUrlFor('s1', fetcher);
    final second = await cache.thumbUrlFor('s1', fetcher);
    expect(first, 'https://example.com/s1.jpg');
    expect(second, first);
    expect(calls, 1);
    expect(cache.cachedUrl('s1'), first);
  });

  test('取数回 null 不记缓存，下次重拉', () async {
    var calls = 0;
    Future<String?> fetcher(String siteId) async {
      calls++;
      return calls < 2 ? null : 'https://example.com/late.jpg';
    }

    expect(await cache.thumbUrlFor('dead', fetcher), isNull);
    expect(cache.cachedUrl('dead'), isNull);
    expect(await cache.thumbUrlFor('dead', fetcher), 'https://example.com/late.jpg');
    expect(calls, 2);
  });

  test('取数抛错不记缓存、不把异常抛给调用方', () async {
    Future<String?> fetcher(String siteId) async =>
        throw StateError('site down');
    expect(await cache.thumbUrlFor('boom', fetcher), isNull);
    expect(cache.cachedUrl('boom'), isNull);
  });

  test('同站并发只拉一次', () async {
    var calls = 0;
    Future<String?> fetcher(String siteId) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return 'https://example.com/one.jpg';
    }

    final results = await Future.wait([
      cache.thumbUrlFor('s1', fetcher),
      cache.thumbUrlFor('s1', fetcher),
      cache.thumbUrlFor('s1', fetcher),
    ]);
    expect(calls, 1);
    expect(results.toSet(), {'https://example.com/one.jpg'});
  });

  test('落盘后新实例直读', () async {
    await cache.put('s7', 'https://example.com/s7.jpg');
    await cache.settleWrites();
    final file = File('${tempDir.path}/site_thumbs.json');
    expect(await file.exists(), isTrue);

    final reopened = SiteThumbCache(directoryProvider: () async => tempDir);
    var calls = 0;
    final url = await reopened.thumbUrlFor('s7', (siteId) async {
      calls++;
      return 'https://example.com/other.jpg';
    });
    expect(url, 'https://example.com/s7.jpg');
    expect(calls, 0);
  });

  test('磁盘文件损坏当空缓存', () async {
    final file = File('${tempDir.path}/site_thumbs.json');
    await file.writeAsString('{{{ not json');
    final url = await cache.thumbUrlFor(
      's1',
      (siteId) async => 'https://example.com/fresh.jpg',
    );
    expect(url, 'https://example.com/fresh.jpg');
  });

  test('默认取数对伪条目直接回 null', () async {
    expect(await fetchSiteHomeCover('__all__'), isNull);
    expect(await fetchSiteHomeCover(''), isNull);
  });
}
