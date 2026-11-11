import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/services/api_client.dart';

/// 官方短剧 feed 是两段接口：`bookapi/bookmall/tab` 只给出这个 tab 的 cell
/// （`cell_id_str`）和 session，卡片本体由 `bookapi/bookmall/cell/change` 返回
/// （`com/dragon/read/shortvideo/common/c.java`）。这里钉住调用形状。
///
/// 2026-11-08 新链路：视频 tab 先走 Rust 核心的 plan→cell/change 合并路由
/// `/recommend/fanqie-feed`（见 `ApiClient.homepagePage` 开头注释），拿到
/// 就直接用，不再走 tab/v 老路；拿不到才落回老路（第一段 homepage +
/// 第二段 series-feed）。所以首屏/翻页的调用形状断言钉的是新链路，
/// 老路只在“新链路失败回退”的用例里断言。
///
/// 看剧(8)/漫剧(24) 走两段老路；推荐(16) 有意只走第一段（它的卡是服务端模板卡，
/// 第二段只会把它变成更多空卡）。
void main() {
  late List<String> calls;
  var feedWorks = true;

  /// 第二段的卡片形状照真实响应：卡片在 `data.cell_view.cell_data[]`，每张卡自带
  /// `video_data[]`。推荐频道的模板卡（`show_type=407`）用 `series_*` 字段，且数字型
  /// `series_id` 已被上游截断成 double，精确值只在 `series_id_str`。
  String feedBody(int offset) => jsonEncode({
    'code': 0,
    'data': {
      'next_offset': offset + 5,
      'session_id': 'flow-$offset',
      'cell_view': {
        'cell_name': '猜你喜欢',
        'cell_data': [
          {
            'video_data': [
              {
                'series_id': 7669730394324880000,
                'series_id_str': '7669730394324880409',
                'series_title': '悍妻替嫁，从前说',
                'series_cover': 'https://example.invalid/tpl.jpg',
                'video_detail': {'content_type': 1004},
              },
            ],
          },
          {
            'video_data': [
              {
                'series_id': '222',
                'video_detail': {'content_type': 1004},
              },
            ],
          },
        ],
      },
    },
  });

  /// 第一段的 tab 条目。`withCard` 时它自己带一张卡，用来验证退回路径。
  String tabBody({bool withCard = false}) => jsonEncode({
    'code': 0,
    'data': {
      'tab_item': [
        {
          'tab_type': 8,
          'session_id': 'tab-session',
          if (withCard) 'next_offset': 3,
          if (withCard)
            'cell_data': [
              {
                'video_data': [
                  {
                    'series_id': 333,
                    'video_detail': {'content_type': 1004},
                  },
                ],
              },
            ],
        },
      ],
      // 上游把数字型 cell_id 写成 double，只有 cell_id_str 是精确值。
      'cell_id_str': '7294257141911650341',
    },
  });

  ApiClient buildClient({bool withCard = false}) {
    calls = <String>[];
    feedWorks = true;
    return ApiClient(
      baseUrl: 'http://backend.invalid',
      client: MockClient((request) async {
        calls.add(request.url.toString());
        if (request.url.path.endsWith('/recommend/homepage')) {
          return http.Response.bytes(
            utf8.encode(tabBody(withCard: withCard)),
            200,
          );
        }
        if (!feedWorks) {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 101116})),
            200,
          );
        }
        final offset =
            int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
        return http.Response.bytes(utf8.encode(feedBody(offset)), 200);
      }),
    );
  }

  test('推荐/看剧先取 cell 再取卡片，模板卡的标题封面与精确 id 都拿到', () async {
    final page = await buildClient().homepagePage(tabType: 16, offset: 0);

    // 模板卡（show_type=407）：标题/封面走 series_*，id 取未截断的 series_id_str。
    final first = page.items.first;
    expect(first.id, '7669730394324880409');
    expect(first.seriesId, '7669730394324880409');
    expect(first.title, '悍妻替嫁，从前说');
    expect(first.cover, 'https://example.invalid/tpl.jpg');
    expect(page.items.map((item) => item.id), [
      '7669730394324880409',
      '222',
    ]);
    expect(page.nextOffset, 5);
    expect(page.sessionId, 'flow-0');
    // 新链路：推荐 tab 一次 fanqie-feed 直接拿到模板卡，不再走老路两段。
    expect(calls, hasLength(1));
    expect(calls.single, contains('/recommend/fanqie-feed'));
    expect(calls.single, contains('tab_type=16'));
    expect(calls.single, contains('offset=0'));
  });

  test('翻页只打第二段，用 GetMore 带上游标和 session', () async {
    final client = buildClient();
    await client.homepagePage(tabType: 8, offset: 0);
    calls.clear();

    await client.homepagePage(tabType: 8, offset: 5, sessionId: 'flow-0');

    // 新链路：翻页仍只打一次 fanqie-feed，带上 offset 与 session。
    expect(calls, hasLength(1));
    expect(calls.single, contains('/recommend/fanqie-feed'));
    expect(calls.single, contains('offset=5'));
    expect(calls.single, contains('session_id=flow-0'));
  });
  test('首屏第二段失败时退回第一段，不抛异常', () async {
    final client = buildClient(withCard: true);
    // 第二段开始失败，模拟老后端没有这个端点（404）或上游 101116。
    feedWorks = false;

    final page = await client.homepagePage(tabType: 8, offset: 0);

    // 新链路先试 fanqie-feed（失败），再落回老路两段：homepage + series-feed。
    expect(calls, hasLength(3));
    expect(calls.first, contains('/recommend/fanqie-feed'));
    expect(calls[1], contains('/recommend/homepage'));
    expect(calls.last, contains('/recommend/series-feed'));
    expect(page.items.map((item) => item.id), ['333']);
    expect(page.sessionId, 'tab-session');
  });

  test('翻页时第二段失败会退回第一段，而不是抛错中断', () async {
    final client = buildClient(withCard: true);
    await client.homepagePage(tabType: 8, offset: 0);

    // 第二段开始失败，模拟上游 101116。
    feedWorks = false;
    calls.clear();

    final page = await client.homepagePage(
      tabType: 8,
      offset: 5,
      sessionId: 'flow-0',
    );

    // 新链路先试 fanqie-feed（失败），再落回老路两段：homepage + series-feed。
    expect(calls.first, contains('/recommend/fanqie-feed'));
    expect(calls, hasLength(3));
    expect(calls[1], contains('/recommend/homepage'));
    expect(calls.last, contains('/recommend/series-feed'));
    // 退回后仍拿到第一段那张卡，调用方不会因为异常而停止翻页。
    expect(page.items.map((item) => item.id), ['333']);
    // 第一段的游标（3）没有前进超过请求的 offset（5），客户端按既有规则丢弃它——
    // 这正是老路径的行为，不是这次改动引入的。
    expect(page.nextOffset, isNull);
  });

  test('非视频 tab 只打第一段', () async {
    await buildClient().homepagePage(tabType: 2, offset: 0);

    expect(calls, hasLength(1));
    expect(calls.single, contains('/recommend/homepage'));
  });

  test('上游没给短剧 tab 时不拿别的 tab 的书 cell 换视频流，如实抛错', () async {
    // 2026-11-07 真站形状：只回推荐/男生/女生三个书 tab，第一段的
    // 第一个 cell_id_str 是推荐区书 cell；拿它去换视频流只会回 0 条。
    final client = ApiClient(
      baseUrl: 'http://backend.invalid',
      client: MockClient((request) async {
        calls.add(request.url.toString());
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'code': 0,
              'data': {
                'tab_item': [
                  {
                    'tab_type': 2,
                    'title': '推荐',
                    'session_id': 'book-session',
                    'cell_data': [
                      {'cell_id_str': '7156181637888212999', 'show_type': 390},
                    ],
                  },
                  {'tab_type': 1, 'title': '男生'},
                  {'tab_type': 0, 'title': '女生'},
                ],
              },
            }),
          ),
          200,
        );
      }),
    );
    calls = <String>[];

    await expectLater(
      client.homepagePage(tabType: 8, offset: 0),
      throwsA(isA<ApiException>()),
    );
    // 新链路先试 fanqie-feed，再走第一段 homepage；拿不到短剧 tab 就如实抛错。
    // 第二段 series-feed 一次都没打：书 cell 没进视频流；也不回空白页假装没内容。
    expect(calls, hasLength(2));
    expect(calls.first, contains('/recommend/fanqie-feed'));
    expect(calls.last, contains('/recommend/homepage'));
    expect(
      calls.where((call) => call.contains('/recommend/series-feed')),
      isEmpty,
    );
  });

  test('所要 tab 自己的 cell 可用（无 data 顶层 cell 时）', () async {
    final client = ApiClient(
      baseUrl: 'http://backend.invalid',
      client: MockClient((request) async {
        calls.add(request.url.toString());
        if (request.url.path.endsWith('/recommend/fanqie-feed')) {
          // 新链路这一次拿不到，老路才跑起来：所要 tab 自己的 cell 归属
          // 是老路第二段的断言目标，不是新链路的。
          return http.Response.bytes(
            utf8.encode(jsonEncode({'code': 101116})),
            200,
          );
        }
        if (request.url.path.endsWith('/recommend/homepage')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 0,
                'data': {
                  'tab_item': [
                    {
                      'tab_type': 8,
                      'session_id': 'tab-session',
                      'cell_data': [
                        {'cell_id_str': '7294257141911650341'},
                      ],
                    },
                  ],
                },
              }),
            ),
            200,
          );
        }
        final offset =
            int.tryParse(request.url.queryParameters['offset'] ?? '0') ?? 0;
        return http.Response.bytes(utf8.encode(feedBody(offset)), 200);
      }),
    );
    calls = <String>[];

    final page = await client.homepagePage(tabType: 8, offset: 0);

    expect(
      calls.where((call) => call.contains('/recommend/series-feed')),
      hasLength(1),
    );
    expect(
      calls
          .firstWhere((call) => call.contains('/recommend/series-feed')),
      contains('cell_id=7294257141911650341'),
    );
    expect(page.items.map((item) => item.id), [
      '7669730394324880409',
      '222',
    ]);
  });
}
