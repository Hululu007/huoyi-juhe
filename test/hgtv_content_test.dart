import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/hgtv_content.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _jsonResponse(Object decoded) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(decoded)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> _landpageBody(
  List<Map<String, dynamic>> rows, {
  bool hasMore = false,
}) {
  return {
    'code': '0',
    'data': {'video_data': rows, 'has_more': hasMore},
  };
}

Map<String, dynamic> _row(
  String id,
  String title, {
  String remark = '',
}) {
  return {
    'series_id_str': id,
    'series_title': title,
    'series_cover': 'https://pic.test/$id.jpg',
    'episode_right_text': remark,
  };
}

String _hexUpper(List<int> bytes) {
  const chars = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(chars[(b >> 4) & 15]);
    out.write(chars[b & 15]);
  }
  return out.toString();
}

void main() {
  test('分类固定 5 个', () async {
    final client = HgtvContentClient(MockClient((_) async => _jsonResponse({})));
    final categories = await client.categories();
    expect(
      categories.map((c) => c.id).toList(),
      ['home', 'real', 'comic', 'ai', 'latest'],
    );
    expect(
      categories.map((c) => c.name).toList(),
      ['首页推荐', '真人剧', '漫剧', 'AI剧', '最新上架'],
    );
  });

  test('目录第 1 页合并 App 第 1+2 页并去重，签名头齐全', () async {
    final bodies = <Map<String, dynamic>>[];
    final rawBodies = <List<int>>[];
    final queries = <Map<String, String>>[];
    final headerSets = <Map<String, String>>[];
    final client = HgtvContentClient(
      MockClient((request) async {
        rawBodies.add(request.bodyBytes);
        bodies.add(
          jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>,
        );
        queries.add(request.url.queryParameters);
        headerSets.add(request.headers);
        final offset = bodies.last['offset'] as int;
        if (offset == 0) {
          return _jsonResponse(
            _landpageBody([_row('1', '剧一'), _row('2', '剧二')]),
          );
        }
        return _jsonResponse(
          _landpageBody(
            [_row('2', '剧二'), _row('3', '剧三')],
            hasMore: true,
          ),
        );
      }),
      Random(42),
    );
    final page = await client.catalog('real', 1);
    expect(page.items.map((i) => i.id).toList(), ['1', '2', '3']);
    expect(page.items.first.title, '剧一');
    expect(page.hasMore, isTrue);
    expect(bodies.length, 2);
    expect(bodies[0]['offset'], 0);
    expect(bodies[0]['limit'], 20);
    expect(bodies[0]['req_type'], 'default');
    expect(bodies[0]['need_selector_panel'], isTrue);
    expect(bodies[1]['offset'], 20);
    expect(bodies[1]['limit'], 100);
    expect(bodies[1]['req_type'], 'only_content');
    expect(bodies[1]['need_selector_panel'], isFalse);
    expect(bodies[0]['select_items'], {
      'genre': ['short_play'],
      'sort': ['hot_score'],
    });
    for (var i = 0; i < 2; i++) {
      final query = queries[i];
      expect(query['aid'], '8662');
      expect(RegExp(r'^\d{19}$').hasMatch(query['device_id'] ?? ''), isTrue);
      expect(RegExp(r'^\d{19}$').hasMatch(query['iid'] ?? ''), isTrue);
      expect(RegExp(r'^\d+$').hasMatch(query['_rticket'] ?? ''), isTrue);
      final headers = headerSets[i];
      expect(headers['X-Khronos'], isNotNull);
      expect(headers['X-Gorgon'], isNotNull);
      expect(headers['X-SS-Req-Ticket'], isNotNull);
      expect(headers['X-Argus'], isNotNull);
      expect(headers['X-Ladon'], isNotNull);
      expect(headers['X-Helios'], isNotNull);
      expect(headers['X-Medusa'], isNotNull);
      expect(headers['X-SS-STUB'], _hexUpper(md5.convert(rawBodies[i]).bytes));
    }
    expect(queries[0]['device_id'], queries[1]['device_id']);
  });

  test('目录第 2 页只取 App 第 3 页', () async {
    Map<String, dynamic>? seenBody;
    final client = HgtvContentClient(
      MockClient((request) async {
        seenBody =
            jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
        return _jsonResponse(_landpageBody([_row('9', '剧九')]));
      }),
    );
    final page = await client.catalog('latest', 2);
    expect(seenBody?['offset'], 120);
    expect(seenBody?['limit'], 100);
    expect(page.items.map((i) => i.id).toList(), ['9']);
    expect(page.hasMore, isFalse);
  });

  test('无效分类不发请求直接报错', () async {
    var called = false;
    final client = HgtvContentClient(
      MockClient((_) async {
        called = true;
        return _jsonResponse({});
      }),
    );
    await expectLater(client.catalog('zzz', 1), throwsStateError);
    expect(called, isFalse);
  });

  test('详情 App 路按 vid_index 排序出集', () async {
    final client = HgtvContentClient(
      MockClient((request) async {
        return _jsonResponse({
          'code': '',
          'data': {
            'video_data': {
              'series_id_str': '123',
              'series_title': '测试剧',
              'series_cover': 'https://pic.test/123.jpg',
              'episode_cnt': '3',
              'video_list': [
                {'vid': '333', 'vid_index': '3'},
                {'vid': '111', 'vid_index': '1'},
                {'vid': '222', 'vid_index': '2'},
              ],
            },
          },
        });
      }),
    );
    final detail = await client.detail('123');
    expect(detail.title, '测试剧');
    expect(detail.episodes.map((e) => e.videoId).toList(), ['111', '222', '333']);
    expect(
      detail.episodes.map((e) => e.title).toList(),
      ['第1集', '第2集', '第3集'],
    );
  });

  test('详情 App 集数不全时走网页兜底', () async {
    final client = HgtvContentClient(
      MockClient((request) async {
        if (request.url.host.contains('fqnovel')) {
          return _jsonResponse({
            'data': {
              'video_data': {
                'series_id_str': '123',
                'series_title': 'App 剧',
                'series_cover': 'https://pic.test/123.jpg',
                'episode_cnt': '5',
                'video_list': [
                  {'vid': '111', 'vid_index': '1'},
                  {'vid': '222', 'vid_index': '2'},
                ],
              },
            },
          });
        }
        const html =
            '<html><body><script>window._ROUTER_DATA = '
            '{"loaderData":{"detail_page":{"seriesDetail":'
            '{"series_title":"Web Drama","series_cover":"https://pic.test/web.jpg",'
            '"vid_list":["901","902"]}}}}'
            '</script></body></html>';
        return http.Response(html, 200);
      }),
    );
    final detail = await client.detail('123');
    expect(detail.title, 'Web Drama');
    expect(detail.episodes.map((e) => e.videoId).toList(), ['901', '902']);
  });

  test('详情 App 与网页都失败时抛 App 原错', () async {
    final client = HgtvContentClient(
      MockClient((request) async {
        if (request.url.host.contains('fqnovel')) {
          return http.Response('server error', 500);
        }
        return http.Response('not found', 404);
      }),
    );
    await expectLater(
      client.detail('123'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('500'),
        ),
      ),
    );
  });

  test('搜索解析与去重', () async {
    final client = HgtvContentClient(
      MockClient((request) async {
        expect(request.url.path, '/api/search/result');
        expect(request.url.queryParameters['aid'], '8662');
        expect(request.url.queryParameters['page'], '1');
        return _jsonResponse({
          'searchList': [
            _row('1', '搜剧A'),
            _row('1', '搜剧A'),
            {
              'video_data': {
                'series_id': '2',
                'series_title': '搜剧B',
                'series_cover': 'https://pic.test/2.jpg',
              },
            },
          ],
        });
      }),
    );
    final items = await client.search('  搜剧  ');
    expect(items.map((i) => i.id).toList(), ['1', '2']);
    expect(items[1].title, '搜剧B');
    await expectLater(client.search('   '), throwsStateError);
  });

  test('播放走网页播放页地址加 360p 兜底由红果客户端承担', () async {
    final client = HgtvContentClient(
      MockClient((request) async {
        if (request.url.path.contains('/player/')) {
          const html =
              '<html><body><script>window._ROUTER_DATA = '
              '{"loaderData":{"player_page":{"vid":"111","series_id":"123",'
              '"video_player_info":{"main_url":"https://cdn.test/a.m3u8",'
              '"backup_url":"https://cdn.test/b.m3u8"}}}}'
              '</script></body></html>';
          return http.Response(html, 200);
        }
        return http.Response('not found', 404);
      }),
    );
    final source = await client.playSource(
      const DramaSiteEpisode(videoId: '111', title: '第1集', seriesId: '123'),
    );
    expect(source.url, 'https://cdn.test/a.m3u8');
    expect(source.variants.map((v) => v.url).toList(), ['https://cdn.test/b.m3u8']);
    final fallback = await client.playSource(
      const DramaSiteEpisode(videoId: '999', title: '第1集'),
    );
    expect(fallback.url, 'https://hongguoduanju.com/video/public/999/360p.mp4');
  });

  test('注册表 hgtv 返回 HGTV 客户端', () {
    expect(dramaSiteContentClient('hgtv'), isA<HgtvContentClient>());
  });
}
