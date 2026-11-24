import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'preview_test_support.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
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
    String seriesId = 'film-1',
    String title = '抽象三国第一季',
    List<Chapter>? episodes,
    Future<Map<String, dynamic>> Function(String, String)? contentLoader,
    FilmSiteDetail? siteDetail,
    Future<List<DramaSiteItem>> Function(String)? relatedLoader,
    Future<List<DramaSiteItem>> Function(String)? homeRelatedLoader,
    void Function(DramaSiteItem)? onOpenRelatedFilm,
  }) async {
    final list = episodes ?? [chapterAt(0), chapterAt(1)];
    await tester.pumpWidget(
      hostPage(
        KeyedSubtree(
          key: UniqueKey(),
          child: SeriesDetailPage(
            seriesId: seriesId,
            historyStore: MemoryReaderStore(),
            title: title,
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
            contentLoader: contentLoader,
            relatedLoader: relatedLoader,
            homeRelatedLoader: homeRelatedLoader,
            onOpenRelatedFilm: onOpenRelatedFilm,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // 推荐视频在站详情回来后才拉，再放一个泵等它回来。
    await tester.pump();
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

  testWidgets('影视区：推荐视频有数据时出小卡片网格，点卡片进详情', (tester) async {
    DramaSiteItem? opened;
    await pumpFilmDetail(
      tester,
      relatedLoader: (_) async => const [
        DramaSiteItem(id: 'rec-1', title: '推荐一', cover: ''),
        DramaSiteItem(
          id: 'rec-2',
          title: '推荐二',
          cover: '',
          remark: '共12集',
        ),
      ],
      onOpenRelatedFilm: (item) => opened = item,
    );
    // 网格是懒加载：滚到卡片本身（不是只滚到区块顶），卡片建出来
    // 且在屏内再点按，否则点按会打到折叠线下。
    await scrollToWidget(tester, find.text('推荐一'));
    await tester.pump();
    expect(find.text('推荐视频'), findsOneWidget);
    expect(find.text('推荐一'), findsOneWidget);
    expect(find.text('推荐二'), findsOneWidget);
    await tester.tap(find.text('推荐一'));
    await tester.pump();
    expect(opened?.id, 'rec-1');
  });

  testWidgets('影视区：相关推荐有数据时出小卡片网格，点卡片进详情', (tester) async {
    DramaSiteItem? opened;
    await pumpFilmDetail(
      tester,
      homeRelatedLoader: (_) async => const [
        DramaSiteItem(id: 'rel-1', title: '推荐一', cover: ''),
        DramaSiteItem(
          id: 'rel-2',
          title: '推荐二',
          cover: '',
          remark: '共12集',
        ),
      ],
      onOpenRelatedFilm: (item) => opened = item,
    );
    await scrollToWidget(tester, find.text('推荐一'));
    await tester.pump();
    expect(find.text('相关推荐'), findsOneWidget);
    expect(find.text('推荐一'), findsOneWidget);
    expect(find.text('推荐二'), findsOneWidget);
    await tester.tap(find.text('推荐一'));
    await tester.pump();
    expect(opened?.id, 'rel-1');
  });

  testWidgets('影视区：推荐视频只取 6 个，相关推荐排除推荐视频已展示的条目', (
    tester,
  ) async {
    await pumpFilmDetail(
      tester,
      relatedLoader: (_) async => [
        for (var i = 1; i <= 8; i++)
          DramaSiteItem(id: 'rec-$i', title: '同类$i', cover: ''),
      ],
      homeRelatedLoader: (_) async => const [
        // rec-1 已在推荐视频里出现，相关推荐里不再重复。
        DramaSiteItem(id: 'rec-1', title: '同类1', cover: ''),
        DramaSiteItem(id: 'home-1', title: '首页一', cover: ''),
        DramaSiteItem(id: 'home-2', title: '首页二', cover: ''),
      ],
    );
    // 网格是懒加载：滚到卡片本身再断言；滚走后离屏卡片会被回收，
    // 所以去重用卡片 key 断言（不在相关推荐网格里），不用全局文本。
    await scrollToWidget(tester, find.text('同类6'));
    await tester.pump();
    expect(find.text('推荐视频'), findsOneWidget);
    expect(find.text('同类1'), findsOneWidget);
    expect(find.text('同类6'), findsOneWidget);
    expect(find.text('同类7'), findsNothing);
    expect(find.text('同类8'), findsNothing);
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('film-related-card-home-1')),
    );
    await tester.pump();
    expect(find.text('相关推荐'), findsOneWidget);
    expect(find.text('首页一'), findsOneWidget);
    expect(find.text('首页二'), findsOneWidget);
    // rec-1 已在推荐视频里出现，相关推荐网格里没有它。
    expect(
      find.byKey(const ValueKey('film-related-card-rec-1')),
      findsNothing,
    );
  });

  testWidgets('影视区：390 宽手机推荐卡片 4 列、单卡约 82 宽', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    await pumpFilmDetail(
      tester,
      relatedLoader: (_) async => [
        for (var i = 1; i <= 6; i++)
          DramaSiteItem(id: 'rec-$i', title: '同类$i', cover: ''),
      ],
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-detail-recommended-section')),
    );
    await tester.pump();
    // 内容宽 390 - 16*2 = 358，列宽档 85 → 4 列，单卡
    // (358 - 3*10) / 4 = 82（原横排卡 120 宽）。
    final size = tester.getSize(
      find.byKey(const ValueKey('film-recommended-card-rec-1')),
    );
    expect(size.width, moreOrLessEquals(82, epsilon: 2));
    // 4 列：第一行 4 张卡的顶边在同一高度。
    final tops = <double>{};
    for (var i = 1; i <= 4; i++) {
      tops.add(
        tester
            .getTopLeft(
              find.byKey(ValueKey('film-recommended-card-rec-$i')),
            )
            .dy,
      );
    }
    expect(tops.length, 1);
  });

  testWidgets('影视区：无简介无剧照时不留空白块，相关推荐照常出', (tester) async {
    await pumpFilmDetail(
      tester,
      siteDetail: const FilmSiteDetail(synopsis: '', extra: {}, stills: []),
      homeRelatedLoader: (_) async => const [
        DramaSiteItem(id: 'rel-1', title: '推荐一', cover: ''),
      ],
    );
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('series-detail-related-section')),
    );
    await tester.pump();
    // 简介与剧照两节都不渲染（不占位），相关推荐区正常出现。
    expect(find.text('简介'), findsNothing);
    expect(find.text('本片剧照'), findsNothing);
    expect(find.text('相关推荐'), findsOneWidget);
    expect(find.text('推荐一'), findsOneWidget);
    // 推荐视频区没有数据时不画。
    expect(find.text('推荐视频'), findsNothing);
  });

  testWidgets('影视区：推荐取不到时两块都不画', (tester) async {
    await pumpFilmDetail(
      tester,
      relatedLoader: (_) async => const <DramaSiteItem>[],
      homeRelatedLoader: (_) async => const <DramaSiteItem>[],
    );
    await tester.pump();
    expect(find.text('推荐视频'), findsNothing);
    expect(find.text('相关推荐'), findsNothing);
    expect(find.text('推荐一'), findsNothing);
  });

  testWidgets('影视区：番号匹配到演员时头区出演员行', (tester) async {
    // 002HODV-21431 在内置三站元数据里，女优是霧島櫻（带头像地址）。
    await pumpFilmDetail(
      tester,
      seriesId: '002HODV-21431',
      title: '002HODV-21431',
    );
    // 内置索引是真异步加载（两个 gz 解压 + 建表），多放几个泵等它回来。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 600));
      if (find.text('霧島櫻').evaluate().isNotEmpty) break;
    }
    await tester.pump();
    expect(
      find.byKey(const ValueKey('film-detail-cast-row')),
      findsOneWidget,
    );
    expect(find.text('霧島櫻'), findsOneWidget);
  });

  testWidgets('影视区：番号匹配不到时不画演员行', (tester) async {
    await pumpFilmDetail(tester);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump();
    expect(find.byKey(const ValueKey('film-detail-cast-row')), findsNothing);
  });

  testWidgets('预览：详情页演员行 + 推荐视频 + 相关推荐', (tester) async {
    // 卡片封面是非空网络地址，CachedNetworkImage 会建缓存库、要走
    // path_provider 拿临时目录：不 mock 会报 MissingPluginException。
    // mock 后缓存库会排一个 10 秒一次性清理定时器（CacheStore
    // _scheduleCleanup，只跑一次、不重排），截图后 pump 11 秒把它
    // 耗掉再收尾，否则收尾报 timersPending。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            if (methodCall.method == 'getTemporaryDirectory' ||
                methodCall.method == 'getApplicationSupportDirectory' ||
                methodCall.method == 'getApplicationDocumentsDirectory') {
              return directory.path;
            }
            return null;
          },
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
    });

    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    // 页比较长：播放器 + 头区（含演员行）+ 选集 + 简介 + 剧照 +
    // 两块推荐网格，用高视口一次截全。
    tester.view.physicalSize = const Size(390, 2800);
    addTearDown(tester.view.reset);

    const base = 'https://example.com';
    final chapters = <Chapter>[for (var i = 0; i < 8; i++) chapterAt(i)];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansCJK',
          ),
          home: RepaintBoundary(
            key: const ValueKey<String>('detail-actors-recs-preview'),
            child: SeriesDetailPage(
              // 002HODV-21431 在内置三站元数据里，女优是霧島櫻。
              seriesId: '002HODV-21431',
              historyStore: MemoryReaderStore(),
              title: '002HODV-21431',
              cover: '$base/cover.jpg',
              episodes: chapters,
              seriesLoader: (_) async => seriesDetailFixture(
                episodeCount: chapters.length,
                episodeLabel: '共${chapters.length}集',
              ),
              siteDetailLoader: (_) async => const FilmSiteDetail(
                // actor 字段里也有霧島櫻：头区演员行已显示的人，
                // 简介区演员行不再重复。
                synopsis: '这是一段影视简介。',
                extra: {
                  'play_from': '在线播放',
                  'actor': '霧島櫻，张三',
                  'year': '2025',
                  'area': '日本',
                  'category': '成人影片',
                },
                stills: [],
              ),
              commentLoader: (_) async => const PlayletCommentPage(),
              relatedLoader: (_) async => [
                for (var i = 1; i <= 6; i++)
                  DramaSiteItem(
                    id: 'rec-$i',
                    title: '同类推荐$i',
                    cover: '$base/rec-$i.jpg',
                    remark: '共12集',
                  ),
              ],
              homeRelatedLoader: (_) async => [
                // rec-1 已在推荐视频里，相关推荐里不再重复。
                const DramaSiteItem(
                  id: 'rec-1',
                  title: '同类推荐1',
                  cover: '$base/rec-1.jpg',
                ),
                for (var i = 1; i <= 6; i++)
                  DramaSiteItem(
                    id: 'home-$i',
                    title: '首页推荐$i',
                    cover: '$base/home-$i.jpg',
                    remark: '共8集',
                  ),
              ],
            ),
          ),
        ),
      );
      try {
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 20),
        );
      } on TimeoutException {
        // 图片流未收敛不致命，继续截图；断言会校验关键元素在不在。
      }
    });
    // 内置番号索引是真异步加载（两个 gz 解压 + 建表），等真时间让它回来。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pump();

    // 演员行：霧島櫻只出现一次（头区演员行；简介区演员行已去重）。
    expect(find.text('霧島櫻'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('film-detail-cast-row')),
      findsOneWidget,
    );
    // 简介区演员行还剩张三（头区没有的人）。
    expect(find.text('张三'), findsOneWidget);
    // 两块推荐区：标题 + 小卡片（390 宽 4 列、单卡约 82 宽）。
    expect(find.text('推荐视频'), findsOneWidget);
    expect(find.text('相关推荐'), findsOneWidget);
    expect(find.text('同类推荐1'), findsOneWidget);
    expect(find.text('同类推荐6'), findsOneWidget);
    expect(find.text('首页推荐1'), findsOneWidget);
    final size = tester.getSize(
      find.byKey(const ValueKey('film-recommended-card-rec-1')),
    );
    expect(size.width, moreOrLessEquals(82, epsilon: 2));

    // 截图：封面走测试假时钟回 400，卡片上是占位色块、不是真实封面——
    // 布局与字号是真实的，见 REPORT.md。
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('detail-actors-recs-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          '/home/hatch/workspace/xiuxian_detail_actors_recs_20261124/preview/detail_actors_recs.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

    // 耗掉 CachedNetworkImage 缓存库排的 10 秒一次性清理定时器再收尾。
    await tester.pump(const Duration(seconds: 11));
  });
}
