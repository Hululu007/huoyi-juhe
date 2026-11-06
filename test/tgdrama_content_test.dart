import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/tgdrama_content.dart';
import 'package:fqapp/services/tgdrama_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假服务：继承正式 TgdramaService，只覆盖约定里的两个成员
/// （ensureRunning / lastError），不启动真服务、不联网。
/// 用 extends 而不用 implements：正式类除约定成员外还有
/// healthCheck/authStatus 等实例成员，implements 要全补上，
/// extends 只覆盖要改的两个，正式类加成员也不会把测试打碎。
class _FakeService extends TgdramaService {
  bool running;
  String? error;
  int calls = 0;

  _FakeService({this.running = true, this.error});

  @override
  Future<bool> ensureRunning() async {
    calls++;
    return running;
  }

  @override
  String? get lastError => error;
}

TgdramaContentClient _client(
  MockClient transport, {
  _FakeService? service,
}) {
  return TgdramaContentClient(
    httpClient: transport,
    service: service ?? _FakeService(),
  );
}

MockClient _jsonClient(
  Map<String, Object?> responses, {
  void Function(http.BaseRequest request)? onRequest,
}) {
  return MockClient((request) async {
    onRequest?.call(request);
    final key = request.url.path;
    final body = responses[key];
    if (body == null) return http.Response('not found', 404);
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

void main() {
  group('categories 标签解析', () {
    test('字符串数组成分类', () async {
      final transport = _jsonClient({
        '/api/tags': ['动作', '爱情'],
      });
      addTearDown(transport.close);
      final categories = await _client(transport).categories();
      expect(categories.map((c) => c.id).toList(), ['动作', '爱情']);
      expect(categories.map((c) => c.name).toList(), ['动作', '爱情']);
    });

    test('含 name/tag 的对象数组：id 取 tag、名取 name', () async {
      final transport = _jsonClient({
        '/api/tags': [
          {'name': '动作', 'tag': 'action'},
          {'name': '爱情', 'tag': 'love'},
          {'name': '', 'tag': ''},
        ],
      });
      addTearDown(transport.close);
      final categories = await _client(transport).categories();
      expect(categories.map((c) => c.id).toList(), ['action', 'love']);
      expect(categories.map((c) => c.name).toList(), ['动作', '爱情']);
    });

    test('空、失败、坏 JSON 都回 [全部]，不抛错', () async {
      for (final transport in [
        _jsonClient({'/api/tags': []}),
        MockClient((_) async => http.Response('nope', 500)),
        MockClient((_) async => http.Response('{bad json', 200)),
      ]) {
        addTearDown(transport.close);
        final categories = await _client(transport).categories();
        expect(categories.map((c) => c.id).toList(), ['all']);
        expect(categories.map((c) => c.name).toList(), ['全部']);
      }
      final down = _FakeService(running: false, error: '本地服务未拉起');
      final transport = _jsonClient({'/api/tags': ['动作']});
      addTearDown(transport.close);
      final categories = await _client(transport, service: down).categories();
      expect(categories.map((c) => c.id).toList(), ['all']);
    });
  });

  group('catalog 列表解析', () {
    test('list 键 + total：条数与 hasMore 按 total 算', () async {
      final shows = [
        for (var i = 1; i <= 20; i++)
          {
            'id': i,
            'name': '剧$i',
            'cover_path': '/api/covers/$i',
            'total': 30,
          },
      ];
      final transport = _jsonClient({
        '/api/shows': {'list': shows, 'total': 45},
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('all', 1);
      expect(page.items.length, 20);
      expect(page.items.first.id, '1');
      expect(page.items.first.title, '剧1');
      expect(page.items.first.remark, '共30集');
      expect(
        page.items.first.cover,
        'http://127.0.0.1:5278/api/covers/1',
      );
      expect(page.hasMore, isTrue);
    });

    test('shows 键 + total_count：封面相对路径补全、绝对地址不动', () async {
      final transport = _jsonClient({
        '/api/shows': {
          'shows': [
            {
              'show_id': 'a1',
              'title': '相对封面',
              'cover': 'covers/a1.jpg',
              'episode_count': 12,
            },
            {
              'id': 'a2',
              'name': '绝对封面',
              'poster': 'https://example.test/p.jpg',
            },
            {'id': '', 'name': '缺 id 跳过'},
            {'id': 'a3', 'name': ''},
          ],
          'total_count': 3,
        },
      });
      addTearDown(transport.close);
      final page = await _client(transport).catalog('all', 1);
      expect(page.items.length, 2);
      expect(
        page.items.first.cover,
        'http://127.0.0.1:5278/covers/a1.jpg',
      );
      expect(page.items.first.remark, '共12集');
      expect(page.items[1].cover, 'https://example.test/p.jpg');
      expect(page.hasMore, isFalse);
    });

    test('items 键 + episodes 长度拼集数', () async {
      final items = TgdramaContentClient.parseShows({
        'items': [
          {
            'id': 'b1',
            'name': '多集剧',
            'episodes': [
              {'id': 1},
              {'id': 2},
              {'id': 3},
            ],
          },
        ],
      });
      expect(items.length, 1);
      expect(items.first.remark, '共3集');
    });

    test('tag 参数：all 不带 tag，其他分类带 Url 编码后的 tag', () async {
      final seen = <Uri>[];
      final transport = _jsonClient({
        '/api/shows': {'list': [], 'total': 0},
      }, onRequest: (request) => seen.add(request.url));
      addTearDown(transport.close);
      final client = _client(transport);
      await client.catalog('all', 1);
      expect(seen.last.queryParameters.containsKey('tag'), isFalse);
      expect(seen.last.queryParameters['page'], '1');
      await client.catalog('动作片', 2);
      expect(seen.last.queryParameters['tag'], '动作片');
      expect(seen.last.queryParameters['page'], '2');
    });

    test('整包 JSON 解不出来抛带接口名的 StateError', () async {
      final transport = MockClient(
        (_) async => http.Response('{bad json', 200),
      );
      addTearDown(transport.close);
      await expectLater(
        _client(transport).catalog('all', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('TG影视库列表'),
          ),
        ),
      );
    });
  });

  group('detail 详情解析', () {
    test('episode_no 排序、name 为空回退第N集、简介多键容错', () async {
      final transport = _jsonClient({
        '/api/shows/9': {
          'id': 9,
          'name': '测试剧',
          'cover_path': '/api/covers/9',
          'description': '剧情简介',
          'episodes': [
            {'id': 11, 'episode_no': 2, 'name': ''},
            {'id': 12, 'episode_no': 1, 'name': '首播'},
            {'id': '', 'episode_no': 3, 'name': '缺 id 跳过'},
          ],
        },
      });
      addTearDown(transport.close);
      final detail = await _client(transport).detail('9');
      expect(detail.title, '测试剧');
      expect(detail.cover, 'http://127.0.0.1:5278/api/covers/9');
      expect(detail.synopsis, '剧情简介');
      expect(detail.episodes.length, 2);
      expect(detail.episodes[0].videoId, '12');
      expect(detail.episodes[0].title, '首播');
      expect(detail.episodes[0].seriesId, '9');
      expect(detail.episodes[1].videoId, '11');
      expect(detail.episodes[1].title, '第2集');
    });

    test('episodeNo 驼峰键与无 episode_no 时按位置编号', () {
      final episodes = TgdramaContentClient.parseEpisodes([
        {'id': 'e1', 'episodeNo': 3},
        {'id': 'e2'},
      ], 's1');
      expect(episodes[0].videoId, 'e2');
      expect(episodes[0].title, '第2集');
      expect(episodes[1].videoId, 'e1');
      expect(episodes[1].title, '第3集');
    });

    test('没有分集抛“该剧未返回分集”', () async {
      final transport = _jsonClient({
        '/api/shows/9': {'id': 9, 'name': '空剧', 'total': 10},
      });
      addTearDown(transport.close);
      await expectLater(
        _client(transport).detail('9'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            '该剧未返回分集',
          ),
        ),
      );
    });
  });

  group('playSource 与 search', () {
    test('playSource 直接拼 HLS 直链', () async {
      final service = _FakeService();
      final transport = MockClient(
        (_) async => throw StateError('不应调任何接口'),
      );
      addTearDown(transport.close);
      final source = await _client(
        transport,
        service: service,
      ).playSource(const DramaSiteEpisode(videoId: '77', title: '第1集'));
      expect(
        source.url,
        'http://127.0.0.1:5278/api/episodes/77/hls/index.m3u8',
      );
      expect(service.calls, 1);
    });

    test('search 调对 q 参数、列表与 catalog 共用解析', () async {
      var query = '';
      final transport = _jsonClient({
        '/api/search': {
          'list': [
            {'id': 's1', 'name': '搜到的剧', 'cover_path': '/c/1'},
          ],
          'total': 1,
        },
      }, onRequest: (request) => query = request.url.queryParameters['q'] ?? '');
      addTearDown(transport.close);
      final items = await _client(transport).search('测试剧');
      expect(query, '测试剧');
      expect(items.length, 1);
      expect(items.first.id, 's1');
      expect(items.first.cover, 'http://127.0.0.1:5278/c/1');
    });
  });

  group('服务未启动', () {
    test('ensureRunning 回 false 就抛带 lastError 的 StateError', () async {
      final service = _FakeService(running: false, error: '本地服务未拉起');
      final transport = _jsonClient({
        '/api/shows': {'list': [], 'total': 0},
      });
      addTearDown(transport.close);
      final client = _client(transport, service: service);
      await expectLater(
        client.catalog('all', 1),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'TG影视库本地服务未启动：本地服务未拉起，请先到设置里登录 Telegram',
          ),
        ),
      );
      await expectLater(
        client.detail('9'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        client.search('x'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('站点注册', () {
    test('tgdrama 登记在 dramaSites、走新客户端、不进核心站表', () {
      expect(
        dramaSites.any((s) => s.id == 'tgdrama' && s.name == 'TG影视库'),
        isTrue,
      );
      expect(dramaSiteContentClient('tgdrama'), isA<TgdramaContentClient>());
      expect(coreVideoSiteIds.contains('tgdrama'), isFalse);
    });

    test('影视区切站表里有 tgdrama', () {
      expect(videoZoneSites().any((s) => s.id == 'tgdrama'), isTrue);
    });
  });
}
