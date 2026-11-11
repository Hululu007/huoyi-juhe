import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fqapp/models/rank.dart';
import 'package:fqapp/pages/hongguo_discovery_page.dart';
import 'package:fqapp/pages/hongguo_rank_page.dart';
import 'package:fqapp/pages/rank_page.dart';
import 'package:fqapp/services/drama_site_content.dart';

const _homeBody =
    '<html><script>window._ROUTER_DATA = {"loaderData":{"category_page":{'
    '"recommendList":[{"video_data":{"series_id_str":"101","series_title":"推荐剧一","series_cover":"https://example.test/c1.jpg","episode_right_text":"全80集"}},'
    '{"video_data":{"series_id_str":"102","series_title":"推荐剧二","series_cover":"https://example.test/c2.jpg","episode_right_text":"全60集"}}],'
    '"selectorList":[{"items":[{"selector_item_id":"xuanhuan","show_name":"玄幻"},{"selector_item_id":"dushi","show_name":"都市"}]}],'
    '"pagination":{"totalPages":3}}}};</script></html>';

const _categoryBody =
    '<html><script>window._ROUTER_DATA = {"loaderData":{"category_page":{'
    '"recommendList":[{"video_data":{"series_id_str":"201","series_title":"真人剧一","series_cover":"https://example.test/c3.jpg","episode_right_text":"全100集"}}],'
    '"selectorList":[{"items":[{"selector_item_id":"xuanhuan","show_name":"玄幻"}]}],'
    '"pagination":{"totalPages":1}}}};</script></html>';

const _rankBody =
    '<html><script>window._ROUTER_DATA = {"loaderData":{"rank_hot-drama/page":{'
    '"isSuccess":true,"updatedText":"每小时更新","pagination":{"totalPages":1,"pageNum":1},'
    '"rankList":['
    '{"seriesId":"301","title":"榜一剧","cover":"https://example.test/r1.jpg","description":"简介","heatText":"9320万热度","rank":1,"scoreText":"9.5分","favoriteText":"100万收藏","likeText":"50万点赞","episodeCount":80,"tags":["玄幻","重生"]},'
    '{"seriesId":"302","title":"榜二剧","cover":"https://example.test/r2.jpg","description":"简介","heatText":"5000万热度","rank":2,"episodeCount":60,"tags":["都市"]},'
    '{"seriesId":"303","title":"榜三剧","cover":"https://example.test/r3.jpg","description":"简介","heatText":"100万热度","rank":3,"episodeCount":12,"tags":["玄幻"]}'
    ']}}};</script></html>';

String _fixedSuggestBody() =>
    '{"suggest_list":[{"name":"玄幻重生剧"},{"name":"","display_words":["都市赘婿"]},{"name":"玄幻重生剧"}]}';

http.Client _mockClient() {
  http.Response ok(String body) => http.Response.bytes(
    utf8.encode(body),
    200,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );
  return MockClient((request) async {
    final url = request.url;
    if (url.path == '/category' && url.queryParameters['tab'] == '1') {
      return ok(_homeBody);
    }
    if (url.path == '/category/real-drama' ||
        url.path.startsWith('/category/real-drama/')) {
      return ok(_categoryBody);
    }
    if (url.path == '/category/comic-drama' ||
        url.path.startsWith('/category/comic-drama/')) {
      return ok(_categoryBody);
    }
    if (url.path == '/rank/hot-drama') {
      return ok(_rankBody);
    }
    if (url.path == '/rank/hot-comic-drama') {
      return ok(
        _rankBody.replaceAll('rank_hot-drama/page', 'rank_hot-comic-drama/page'),
      );
    }
    if (url.path == '/incent_resource/suggestion') {
      return ok(_fixedSuggestBody());
    }
    return http.Response('not found', 404);
  });
}

void main() {
  test('红果题材解析：selectorList 的 id 与名成题材，非法 id 丢掉', () {
    final topics = HongguoContentClient.parseTopics(_homeBody);
    expect(topics.map((t) => t.id).toList(), ['xuanhuan', 'dushi']);
    expect(topics.map((t) => t.label).toList(), ['玄幻', '都市']);
    expect(
      HongguoContentClient.parseTopics(
        '<html><script>window._ROUTER_DATA = {"loaderData":{"category_page":{'
        '"selectorList":[{"items":[{"selector_item_id":"BAD ID!","show_name":"坏"},{"selector_item_id":"ok","show_name":"好"}]}]}}};</script></html>',
      ).map((t) => t.id).toList(),
      ['ok'],
    );
  });

  test('红果联想词解析：name 为空取 display_words 首项，去重、上限 8', () {
    expect(
      HongguoContentClient.parseSuggestions(_fixedSuggestBody()),
      ['玄幻重生剧', '都市赘婿'],
    );
    expect(HongguoContentClient.parseSuggestions('not json'), isEmpty);
    expect(HongguoContentClient.parseSuggestions('{"other":[]}'), isEmpty);
  });

  test('红果榜单解析：rankList 成名次与热度，分页异常与缺节报错', () {
    final data = HongguoContentClient.parseRank(_rankBody, 'hot-drama', 1);
    expect(data.entries.length, 3);
    expect(data.entries.first.rank, 1);
    expect(data.entries.first.heat, '9320万热度');
    expect(data.entries.first.metrics, '9.5分 · 100万收藏 · 50万点赞');
    expect(data.entries.first.item.remark, '全80集');
    expect(data.entries.first.tags, ['玄幻', '重生']);
    expect(data.updatedText, '每小时更新');
    expect(data.hasMore, isFalse);
    expect(data.topics, ['玄幻', '都市', '重生']);
    expect(
      data.filtered('玄幻').map((e) => e.item.id).toList(),
      ['301', '303'],
    );
    expect(
      () => HongguoContentClient.parseRank(_rankBody, 'hot-drama', 2),
      throwsStateError,
    );
    expect(
      () => HongguoContentClient.parseRank('<html></html>', 'hot-drama', 1),
      throwsStateError,
    );
  });

  test('红果「全部」走首页推荐流，不再默默取真人剧', () async {
    var requested = '';
    final client = HongguoContentClient(
      MockClient((request) async {
        requested = request.url.toString();
        return http.Response.bytes(
          utf8.encode(_homeBody),
          200,
          headers: {'content-type': 'text/html; charset=utf-8'},
        );
      }),
    );
    final page = await client.catalog('all', 1);
    expect(requested, contains('/category?tab=1&sort_type=1'));
    expect(page.items.map((i) => i.title).toList(), ['推荐剧一', '推荐剧二']);
    expect(page.topics.map((t) => t.label).toList(), ['玄幻', '都市']);
    expect(HongguoContentClient.routeForCategory('all'), 'real-drama');
  });

  test('红果题材拉取：非法题材 id 直接报错，不发请求', () async {
    final client = HongguoContentClient(_mockClient());
    await expectLater(
      client.discover('real-drama', 'BAD ID!', 1),
      throwsStateError,
    );
    final page = await client.discover('real-drama', 'xuanhuan', 1);
    expect(page.items.map((i) => i.title).toList(), ['真人剧一']);
  });

  test('红果联想词请求：匿名接口取回服务端候选词', () async {
    final client = HongguoContentClient(_mockClient());
    expect(
      await client.searchSuggestions('玄幻'),
      ['玄幻重生剧', '都市赘婿'],
    );
    expect(await client.searchSuggestions('  '), isEmpty);
  });

  testWidgets('红果发现页：分类 + 题材 chips，卡片带试播钮', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoDiscoveryPage(client: HongguoContentClient(_mockClient())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('红果发现'), findsOneWidget);
    expect(find.text('推荐剧一'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.byKey(const ValueKey('hongguo_trial_101')), findsOneWidget);
    await tester.tap(find.text('真人剧'));
    await tester.pumpAndSettle();
    expect(find.text('真人剧一'), findsOneWidget);
  });

  testWidgets('红果榜：四榜切换，题材筛保留原名次', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: HongguoRankPage(client: HongguoContentClient(_mockClient())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('综合热播榜'), findsOneWidget);
    expect(find.text('榜一剧'), findsOneWidget);
    expect(find.text('9320万热度 · 9.5分 · 100万收藏 · 50万点赞 · 全80集'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('hongguo_rank_topics')),
        matching: find.text('都市'),
      ),
    );
    await tester.pump();
    expect(find.text('榜一剧'), findsNothing);
    expect(find.text('榜二剧'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('hongguo_rank_topics')),
        matching: find.text('全部题材'),
      ),
    );
    await tester.pump();
    expect(find.text('榜一剧'), findsOneWidget);
  });

  testWidgets('排行榜页有红果榜入口，点后进红果榜', (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    const catalog = RankCatalog(
      rankId: '7098235271900037133',
      tabs: [RankTab(name: '巅峰榜', algo: 200)],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RankPage(
          catalogLoader: () async => catalog,
          pageLoader: ({
            required rankId,
            required algo,
            required categoryId,
            required offset,
            required startAt,
          }) async => const RankBoard(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rank_hongguo_boards')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rank_hongguo_boards')));
    await tester.pumpAndSettle();
    expect(find.text('综合热播榜'), findsOneWidget);
  });
}
