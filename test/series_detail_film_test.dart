import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 影视区新版式（照火蚁TV播放详情页）：顶部是内联播放器（点海报直接播），
/// 下面是毛玻璃详情区（标题 / 集数 / 站源 / 加入追剧 / 选集 / 简介）。
/// 短剧分支一字不动，这里只断言影视区分支。
void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-film-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  Future<void> pumpFilmDetail(
    WidgetTester tester, {
    List<Chapter>? episodes,
    Future<Map<String, dynamic>> Function(String, String)? contentLoader,
  }) async {
    final list = episodes ?? [chapterAt(0), chapterAt(1)];
    await tester.pumpWidget(
      hostPage(
        KeyedSubtree(
          key: UniqueKey(),
          child: SeriesDetailPage(
            seriesId: 'film-1',
            historyStore: MemoryReaderStore(),
            title: '抽象三国第一季',
            cover: '',
            episodes: list,
            seriesLoader: (_) async => seriesDetailFixture(
              episodeCount: list.length,
              episodeLabel: '共${list.length}集',
            ),
            siteDetailLoader: (_) async => const FilmSiteDetail(
              synopsis: '这是一段影视简介。',
              extra: {'play_from': 'MissAV'},
              stills: [],
            ),
            commentLoader: (_) async => const PlayletCommentPage(),
            contentLoader: contentLoader,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('影视区：顶部是内联播放器，下面是毛玻璃详情区', (tester) async {
    await pumpFilmDetail(tester);
    // 顶部内联播放器（16:9 黑色区，点海报直接播）。
    expect(find.byKey(const ValueKey('film-inline-player')), findsOneWidget);
    expect(find.byKey(const ValueKey('film-inline-play')), findsOneWidget);
    // 毛玻璃详情：标题 / 集数 / 站源 / 加入追剧。
    expect(find.byKey(const ValueKey('film-detail-title')), findsOneWidget);
    expect(find.text('抽象三国第一季'), findsOneWidget);
    expect(find.text('共 2 集 · 当前第 1 集'), findsOneWidget);
    expect(find.text('站源： MissAV'), findsOneWidget);
    expect(find.byKey(const ValueKey('film-detail-follow')), findsOneWidget);
    expect(find.text('加入追剧'), findsOneWidget);
  });

  testWidgets('影视区：旧版式元素全部消失', (tester) async {
    await pumpFilmDetail(tester);
    // 顶栏（只有返回）与底部金色大播放钮都不再出现——返回在播放器顶栏里。
    expect(find.byKey(const ValueKey('series-detail-topbar')), findsNothing);
    expect(
      find.byKey(const ValueKey('series-detail-bottom-play-button')),
      findsNothing,
    );
    // 旧「播放线路」区与旧头部播放钮也不再出现（线路折进「站源」行）。
    expect(find.text('播放线路'), findsNothing);
    expect(find.text('立即播放'), findsNothing);
    expect(find.byKey(const ValueKey('series-detail-play-button')), findsNothing);
  });

  testWidgets('影视区：选集点按走注入的取流，不走番茄接口', (tester) async {
    final loaded = <String>[];
    await pumpFilmDetail(
      tester,
      contentLoader: (itemId, tab) async {
        loaded.add(itemId);
        throw Exception('test-no-stream');
      },
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-episode-1')),
    );
    await tester.tap(find.byKey(const ValueKey('series-episode-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // 注入的取流被调到，且拿到的是第 2 集的 itemId。
    expect(loaded, ['ep-1']);
    // 取流失败后内联播放器给重试入口，不静默黑屏。
    expect(find.byKey(const ValueKey('film-inline-retry')), findsOneWidget);
  });
}
