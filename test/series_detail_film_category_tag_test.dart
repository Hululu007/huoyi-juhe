import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 影视区毛玻璃详情区顶部分类标签（站原字段 category + tags）：
/// 标题正下方横排小标签，有回调时可点（点后把标签名交给回调，
/// 生产上是 openFilmCategoryTag：匹配本站分类进浏览页，匹配不到
/// 退站源搜索）；没回调时只展示；没数据时整行不占位。
/// 短剧分支不走这里（短剧头项标签保持原样不动）。
void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-film-tag-test-',
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
    FilmSiteDetail? siteDetail,
    void Function(String)? onFilmCategoryTap,
  }) async {
    final list = [chapterAt(0), chapterAt(1)];
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
            siteDetailLoader: (_) async =>
                siteDetail ??
                const FilmSiteDetail(
                  synopsis: '这是一段影视简介。',
                  extra: {'play_from': 'MissAV'},
                  stills: [],
                ),
            commentLoader: (_) async => const PlayletCommentPage(),
            onFilmCategoryTap: onFilmCategoryTap,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  testWidgets('影视区：分类/标签出可点 chip，点后回调带标签名', (tester) async {
    String? tapped;
    await pumpFilmDetail(
      tester,
      siteDetail: const FilmSiteDetail(
        synopsis: '这是一段影视简介。',
        extra: {'category': '动作，剧情', 'tags': '喜剧，动作'},
        stills: [],
      ),
      onFilmCategoryTap: (tag) => tapped = tag,
    );
    // category + tags 拆开去重：动作 / 剧情 / 喜剧（动作只出一颗）。
    expect(find.byKey(const ValueKey('film-detail-categories')), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('剧情'), findsOneWidget);
    expect(find.text('喜剧'), findsOneWidget);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('film-detail-category-动作')),
    );
    await tester.tap(find.byKey(const ValueKey('film-detail-category-动作')));
    await tester.pump();
    expect(tapped, '动作');
    await tester.tap(find.byKey(const ValueKey('film-detail-category-喜剧')));
    await tester.pump();
    expect(tapped, '喜剧');
  });

  testWidgets('影视区：没传回调时标签只展示、不可点', (tester) async {
    await pumpFilmDetail(
      tester,
      siteDetail: const FilmSiteDetail(
        synopsis: '这是一段影视简介。',
        extra: {'category': '动作', 'tags': '喜剧'},
        stills: [],
      ),
    );
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('喜剧'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('film-detail-category-动作')),
      findsNothing,
    );
    // 点展示态标签不做事、不闪退。
    await scrollToWidget(tester, find.text('动作'));
    await tester.tap(find.text('动作'));
    await tester.pump();
    expect(find.text('动作'), findsOneWidget);
  });

  testWidgets('影视区：无分类无标签时整行不占位', (tester) async {
    await pumpFilmDetail(
      tester,
      siteDetail: const FilmSiteDetail(synopsis: '简介', extra: {}, stills: []),
    );
    expect(find.byKey(const ValueKey('film-detail-categories')), findsNothing);
    expect(find.byKey(const ValueKey('film-detail-title')), findsOneWidget);
  });
}
