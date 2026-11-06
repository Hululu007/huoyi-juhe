import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/pages/video_page.dart';

/// 核心侧返回的 canned 数据（与 Rust 影视区路由的字段一致）。
class FakeApiClient extends ApiClient {
  FakeApiClient({this.throwCore = false})
      : super(
          client: MockClient((_) async => http.Response('{}', 200)),
          baseUrl: 'http://localhost',
        );

  final bool throwCore;

  Future<Map<String, dynamic>> _orThrow(Map<String, dynamic> payload) async {
    if (throwCore) throw const ApiException('核心未起');
    return payload;
  }

  @override
  Future<Map<String, dynamic>> dramaCategories(String siteId) => _orThrow({
        'categories': [
          {'id': 'c1', 'name': '核心分类'},
          {'id': 'c2', 'name': '核心榜单'},
        ],
      });

  @override
  Future<Map<String, dynamic>> dramaCatalog(
    String siteId,
    String categoryId,
    int page,
  ) =>
      _orThrow({
        'items': [
          {'id': 'i1', 'title': '核心剧', 'cover': 'cov', 'remark': '共10集'},
        ],
        'has_more': true,
      });

  @override
  Future<Map<String, dynamic>> dramaDetail(String siteId, String id) =>
      _orThrow({
        'id': 's1',
        'title': '核心详情',
        'cover': 'cov',
        'synopsis': '简介',
        'extra': {'actor': '甲'},
        'episodes': [
          {'video_id': 'https://x/1.m3u8', 'title': '第1集', 'series_id': 's1'},
        ],
      });

  @override
  Future<Map<String, dynamic>> dramaSearch(String siteId, String query) =>
      _orThrow({
        'items': [
          {'id': 'i2', 'title': '搜索剧', 'cover': '', 'remark': ''},
        ],
      });

  @override
  Future<Map<String, dynamic>> dramaPlay(String siteId, String videoId) =>
      _orThrow({'url': 'https://x/1.m3u8'});
}

/// 原 Dart 版芽果的兜底 Mock：登录 + 分类。响应体用字节 + UTF-8
/// 头：http.Response(字符串) 在本工程的 http 版本里按 Latin-1 编码，
/// 含中文的响应体会直接抛错（兜底客户端 catch 后误回 1/9）。
MockClient fallbackClient() {
  const headers = {'content-type': 'application/json; charset=utf-8'};
  return MockClient((request) async {
    final url = request.url.toString();
    if (request.method == 'POST' && url.contains('account/login')) {
      return http.Response.bytes(
        utf8.encode(jsonEncode({'token': 'fallback-token'})),
        200,
        headers: headers,
      );
    }
    if (url.contains('theater/classes')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'data': [
              {
                'alg_class': [
                  {'id': 'f1', 'class_name': '兜底分类'},
                ],
              },
            ],
          }),
        ),
        200,
        headers: headers,
      );
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('factory routes yaguo to the core client', () {
    expect(dramaSiteContentClient('yaguo'), isA<CoreDramaContentClient>());
  });

  test('factory routes all core video sites to the core client', () {
    expect(coreVideoSiteIds.length, 170);
    for (final siteId in coreVideoSiteIds) {
      final client = dramaSiteContentClient(siteId);
      expect(client, isA<CoreDramaContentClient>(), reason: siteId);
      expect(
        (client as CoreDramaContentClient).siteId,
        siteId,
        reason: siteId,
      );
    }
  });

  test('core video sites are registered in dramaSites with adult prefix', () {
    final byId = {for (final site in dramaSites) site.id: site};
    for (final siteId in coreVideoSiteIds) {
      expect(byId.containsKey(siteId), isTrue, reason: siteId);
      expect(
        byId[siteId]!.name.startsWith('🔞'),
        isTrue,
        reason: siteId,
      );
    }
  });

  test('video zone lists all core video sites', () {
    final ids = videoZoneSites().map((site) => site.id).toSet();
    expect(ids.containsAll(coreVideoSiteIds), isTrue);
    expect(ids.contains('yaguo'), isTrue);
  });

  test('factory routes the four fixed sites to the core client', () {
    for (final entry in {
      'huangju': 'huangju',
      'yeguo': 'yeguo',
      'niuguo': 'niuguo',
      'huangdou': 'huangdou',
    }.entries) {
      final client = dramaSiteContentClient(entry.key);
      expect(client, isA<CoreDramaContentClient>());
      expect((client as CoreDramaContentClient).siteId, entry.value);
    }
    // huangdou_yh 是黄豆变体，不进核心，仍走原 Dart 客户端。
    expect(
      dramaSiteContentClient('huangdou_yh'),
      isA<HuangdouContentClient>(),
    );
  });

  test('core failure falls back to the per-site client, not yaguo', () async {
    final client = CoreDramaContentClient(
      siteId: 'huangju',
      api: FakeApiClient(throwCore: true),
      fallback: _StubFallbackClient(),
    );
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['stub1']);
    expect(categories.single.name, '桩分类');
  });

  test('core categories map to models', () async {
    final client = CoreDramaContentClient(api: FakeApiClient());
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['c1', 'c2']);
    expect(categories.first.name, '核心分类');
  });

  test('core catalog/detail/search/play map to models', () async {
    final client = CoreDramaContentClient(api: FakeApiClient());
    final page = await client.catalog('c1', 1);
    expect(page.items.single.title, '核心剧');
    expect(page.items.single.remark, '共10集');
    expect(page.hasMore, isTrue);
    final detail = await client.detail('s1');
    expect(detail.title, '核心详情');
    expect(detail.extra['actor'], '甲');
    expect(detail.episodes.single.videoId, 'https://x/1.m3u8');
    final found = await client.search('核心');
    expect(found.single.id, 'i2');
    final source = await client.playSource(detail.episodes.single);
    expect(source.url, 'https://x/1.m3u8');
  });

  test('core failure falls back to the original Dart client', () async {
    final client = CoreDramaContentClient(
      api: FakeApiClient(throwCore: true),
      fallbackClient: fallbackClient(),
    );
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['f1']);
    expect(categories.single.name, '兜底分类');
  });

  test('malformed core payload falls back too', () async {
    final client = CoreDramaContentClient(
      api: _MalformedApiClient(),
      fallbackClient: fallbackClient(),
    );
    final categories = await client.categories();
    expect(categories.map((c) => c.id), ['f1']);
  });
}

class _MalformedApiClient extends FakeApiClient {
  @override
  Future<Map<String, dynamic>> dramaCategories(String siteId) async =>
      {'categories': '不是列表'};
}

/// 桩回退客户端：只验核心失败时是否走到“本站的回退”，不走任何真实站流。
class _StubFallbackClient implements DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      [const DramaSiteCategory('stub1', '桩分类')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) =>
      throw UnimplementedError();

  @override
  Future<DramaSiteDetail> detail(String seriesId) =>
      throw UnimplementedError();

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) =>
      throw UnimplementedError();

  @override
  Future<List<DramaSiteItem>> search(String query) async => const [];
}
