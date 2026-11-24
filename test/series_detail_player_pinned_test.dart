import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 影视区详情页：内联播放器固定在顶部（2026-11-24 用户令）。
///
/// 以前播放器是滚动区里的第一个 sliver，上下滑详情内容时播放器跟着
/// 滑走；现在播放器提到滚动区外、固定在顶部，只有下面的详情内容
/// （魔蚁详情 / 剧照 / 推荐）可以上下滑。短剧分支没有内联播放器，
/// 不动；女优库详情页也没有内联播放器（点播走整页播放器），不动。
void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-player-pinned-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  Future<void> pumpFilmDetail(WidgetTester tester) async {
    final chapters = <Chapter>[for (var i = 0; i < 8; i++) chapterAt(i)];
    await tester.pumpWidget(
      hostPage(
        KeyedSubtree(
          key: UniqueKey(),
          child: SeriesDetailPage(
            seriesId: 'film-1',
            historyStore: MemoryReaderStore(),
            title: '抽象三国第一季',
            cover: '',
            episodes: chapters,
            seriesLoader: (_) async => seriesDetailFixture(
              episodeCount: chapters.length,
              episodeLabel: '共${chapters.length}集',
            ),
            siteDetailLoader: (_) async => const FilmSiteDetail(
              synopsis:
                  '东汉末年分三国，烽火连天不休。刘备、关羽、张飞桃园结义，'
                  '立志匡扶汉室；曹操挟天子以令诸侯，孙权坐断东南。'
                  '这是一段用搞笑口吻重讲的三国故事。',
              extra: {'play_from': 'MissAV'},
              stills: [],
            ),
            commentLoader: (_) async => const PlayletCommentPage(),
            // 取流注入抛错：只测滚动/固定行为，不走真联网（与现有影视区
            // 测试同一做法；取流失败后播放器给重试入口，不静默黑屏）。
            contentLoader: (_, _) async =>
                throw Exception('test-no-stream'),
            relatedLoader: (_) async => const [
              DramaSiteItem(id: 'rel-1', title: '推荐一', cover: ''),
              DramaSiteItem(id: 'rel-2', title: '推荐二', cover: ''),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  /// 往下拖内容（详情区往上滚），等惯性滚动落地。
  Future<void> scrollContentDown(WidgetTester tester, double dy) async {
    await tester.drag(
      find.byKey(const ValueKey('series-detail-content')),
      Offset(0, dy),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('影视区：上下滑详情内容，顶部内联播放器位置不动', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await pumpFilmDetail(tester);

    final player = find.byKey(const ValueKey('film-inline-player'));
    expect(player, findsOneWidget);
    // 播放器不在滚动区里（结构断言：固定在滚动区外）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('series-detail-content')),
        matching: player,
      ),
      findsNothing,
    );
    final topBefore = tester.getTopLeft(player);
    final titleBefore = tester.getTopLeft(
      find.byKey(const ValueKey('film-detail-title')),
    );

    await scrollContentDown(tester, -500);

    // 播放器顶部位置一动不动，详情标题确实往上滚走了。
    expect(tester.getTopLeft(player), topBefore);
    final titleAfter = tester.getTopLeft(
      find.byKey(const ValueKey('film-detail-title')),
    );
    expect(titleAfter.dy, lessThan(titleBefore.dy));
    // 选集、简介这些内容仍在页里、能点（滚动没有把它们弄丢）。
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影视区横屏：播放器限高不溢出，上下滑仍固定', (tester) async {
    // 默认测试面 800x600 就是横屏。
    await pumpFilmDetail(tester);

    final player = find.byKey(const ValueKey('film-inline-player'));
    expect(player, findsOneWidget);
    // 横屏 16:9 全宽会超出可用高（800*9/16=450，留给滚动区只剩 150），
    // 限高到屏高的 62%（372），下面的滚动区仍有空间。
    expect(tester.getSize(player).height, lessThanOrEqualTo(600 * 0.62 + 1));
    final topBefore = tester.getTopLeft(player);

    await scrollContentDown(tester, -400);

    expect(tester.getTopLeft(player), topBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets('影视区：选集点按后详情滚回顶部，播放器仍在顶', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await pumpFilmDetail(tester);

    // 先把内容滚下去，再点一集（取流注入为空会失败，但滚动行为照常）。
    await scrollContentDown(tester, -500);
    await tester.tap(find.byKey(const ValueKey('series-episode-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // 播放器还在顶部；详情内容仍在页里、没丢。
    final playerTop = tester.getTopLeft(
      find.byKey(const ValueKey('film-inline-player')),
    );
    expect(playerTop.dy, lessThanOrEqualTo(1));
    expect(find.text('选集'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
