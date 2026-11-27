import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/engine_site_content.dart';
import 'package:fqapp/services/film_detail_fill.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 片库详情页自动补（第③④件：页面接线 + 显示对齐 + 非 JAV 回填）。
///
/// 覆盖：vod_ 前缀真形态数据经 parseTvboxDetail 进页面后分类标签与
/// 演员显形（堵旧测试只喂短键的盲区）；假 filmFillLoader 补全后信息
/// 卡 / 评分缎带 / 剧照合并 / 原名翻译切换；补不到不编造（无评分行、
/// 无发行日期行、无缎带、无信息卡、底线说明出现）；非 JAV 同站同名
/// 搜索回填显形、搜不到留空不编造。
void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-film-fill-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
    // 封面 / 剧照走 CachedNetworkImage 时缓存库要拿临时目录。
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
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() async => ShelfStore.instance.clear());

  SeriesDetail detailFixture(String title, {String episodeLabel = '共2集'}) =>
      SeriesDetail(
        seriesId: 'series-1',
        title: title,
        episodeCount: 2,
        episodeLabel: episodeLabel,
        status: 1,
      );

  Future<void> pumpFilm(
    WidgetTester tester, {
    required String seriesId,
    required String title,
    FilmSiteDetail Function(String id)? siteDetail,
    Future<FilmDetailFill> Function(String code, Object? meta)? filmFillLoader,
    Future<List<DramaSiteItem>> Function(String query)? siteSearchLoader,
  }) async {
    final list = [chapterAt(0), chapterAt(1)];
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
            seriesLoader: (_) async => detailFixture(title),
            siteDetailLoader: (id) async =>
                siteDetail?.call(id) ??
                const FilmSiteDetail(
                  synopsis: '本站简介。',
                  extra: {'play_from': '线路甲'},
                  stills: [],
                ),
            commentLoader: (_) async => const PlayletCommentPage(),
            filmFillLoader: filmFillLoader == null
                ? null
                : (code, meta) => filmFillLoader(code, meta),
            siteSearchLoader: siteSearchLoader,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  /// 等异步补全链（番号索引加载 + 补全 / 回填）落定：轮询泵到条件
  /// 满足或次数耗尽。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ready, {
    int tries = 20,
  }) async {
    for (var i = 0; i < tries; i++) {
      if (ready()) return;
      await tester.pump(const Duration(milliseconds: 600));
    }
    await tester.pump();
  }

  /// 耗掉 CachedNetworkImage 缓存库排的 10 秒一次性清理定时器。
  Future<void> drain(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 11));

  testWidgets('vod_ 真形态：分类标签与演员在页面上出现', (tester) async {
    // 经 parseTvboxDetail 产出 DramaSiteDetail 再转 FilmSiteDetail，
    // 与生产同路（站回包只有 vod_ 前缀键，归一在解析出口做）。
    final parsed = parseTvboxDetail(<String, dynamic>{
      'list': [
        <String, dynamic>{
          'vod_id': 'vod100',
          'vod_name': '真形态影片',
          'vod_pic': '',
          'vod_content': '真形态简介内容',
          'vod_actor': '甲演员,乙演员',
          'vod_director': '某导演',
          'vod_year': '2024',
          'vod_area': '日本',
          'vod_type_name': '剧情片',
          'vod_class': '热门,新片',
          'vod_play_from': '线路甲',
          'vod_play_url':
              '第1集\$https://example.com/1.m3u8#第2集\$https://example.com/2.m3u8',
        },
      ],
    });
    await pumpFilm(
      tester,
      seriesId: 'vod100',
      title: '真形态影片',
      siteDetail: (_) => FilmSiteDetail(
        synopsis: parsed.synopsis,
        extra: parsed.extra,
        stills: parsed.stills,
      ),
    );
    await pumpUntil(tester, () => find.text('甲演员').evaluate().isNotEmpty);
    // 分类标签（vod_type_name → category、vod_class → tags）。
    expect(
      find.byKey(const ValueKey('film-detail-categories')),
      findsOneWidget,
    );
    expect(find.text('剧情片'), findsOneWidget);
    expect(find.text('热门'), findsOneWidget);
    expect(find.text('新片'), findsOneWidget);
    // 演员进行合并演员行（头区），且只出现一次（简介区已去重）。
    expect(find.byKey(const ValueKey('film-detail-cast-row')), findsOneWidget);
    expect(find.text('甲演员'), findsOneWidget);
    expect(find.text('乙演员'), findsOneWidget);
    // 导演 chip（vod_director → director）。
    expect(find.text('导演：某导演'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('番号补全：信息卡出行、剧照合并、原名可切换', (tester) async {
    String? filledCode;
    await pumpFilm(
      tester,
      seriesId: 'ZZTEST-001',
      title: '某番号片',
      siteDetail: (_) => const FilmSiteDetail(
        synopsis: '',
        extra: {'play_from': '线路甲'},
        stills: ['https://example.com/own-still.jpg'],
      ),
      filmFillLoader: (code, meta) async {
        filledCode = code;
        return const FilmDetailFill(
          code: 'ZZTEST-001',
          synopsis: '补全简介内容',
          cast: [FilmFillCast(name: '补全演员')],
          maker: '某制作商',
          series: '某系列',
          releaseDate: '2024-05-06',
          durationText: '120 分钟',
          score: '8.5',
          scoreCount: 321,
          originTitle: 'Original Title ZZ',
          stills: ['https://example.com/fill-still.jpg'],
        );
      },
    );
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey('film-info-card')).evaluate().isNotEmpty,
    );
    // 番号由 id 提出、交给补全加载器。
    expect(filledCode, 'ZZTEST-001');
    // 信息卡：番号 / 发行日期 / 时长 / 制作商 / 系列 / 评分行。
    expect(find.byKey(const ValueKey('film-info-card')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('film-info-code'))).data,
      'ZZTEST-001',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('film-info-release-date')))
          .data,
      '2024-05-06',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('film-info-maker'))).data,
      '某制作商',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('film-info-score'))).data,
      '8.5 · 共 321 人评分',
    );
    // 评分金色缎带。
    expect(
      find.byKey(const ValueKey('film-info-score-ribbon')),
      findsOneWidget,
    );
    // 补全演员进头区演员行；补全简介进简介区。
    expect(find.text('补全演员'), findsOneWidget);
    await scrollToWidget(tester, find.text('补全简介内容'));
    expect(find.text('补全简介内容'), findsOneWidget);
    // 剧照合并：本站 1 张 + 补全 1 张 → 全部 2。
    await scrollToWidget(tester, find.byKey(const ValueKey('film-stills-all')));
    expect(find.text('全部 2 >'), findsOneWidget);
    // 原名翻译切换：点 [翻译] 后大标题变原名，再点切回。
    await scrollToWidget(
      tester,
      find.byKey(const ValueKey('film-detail-title-translate')),
    );
    expect(find.text('某番号片'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('film-detail-title-translate')));
    await tester.pump();
    expect(find.text('Original Title ZZ'), findsOneWidget);
    expect(find.text('某番号片'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('film-detail-title-translate')));
    await tester.pump();
    expect(find.text('某番号片'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('补不到不编造：fill 全空时无评分/日期/缎带/信息卡，底线说明出现', (tester) async {
    await pumpFilm(
      tester,
      seriesId: 'ZZTEST-002',
      title: '查不到的片',
      siteDetail: (_) => const FilmSiteDetail(
        synopsis: '',
        extra: {'play_from': '线路甲'},
        stills: [],
      ),
      // 假补全全空（连番号都不回填）= 各路都没查到。
      filmFillLoader: (code, meta) async => const FilmDetailFill(),
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('film-detail-fill-empty-note'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('film-info-card')), findsNothing);
    expect(find.byKey(const ValueKey('film-info-score')), findsNothing);
    expect(find.byKey(const ValueKey('film-info-release-date')), findsNothing);
    expect(find.byKey(const ValueKey('film-info-score-ribbon')), findsNothing);
    expect(find.text('详细资料暂时没补到（各源都没查到这部片的资料），播放不受影响。'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('非 JAV：同站同名搜索回填简介/演员/剧照/封面', (tester) async {
    await pumpFilm(
      tester,
      seriesId: 'film_normal_1',
      title: '山村故事',
      siteDetail: (id) => id == 'film_normal_2'
          ? const FilmSiteDetail(
              synopsis: '搜索回填的简介',
              extra: {'actor': '回填演员'},
              stills: ['https://example.com/search-still.jpg'],
            )
          : const FilmSiteDetail(
              synopsis: '',
              extra: {'play_from': '线路甲'},
              stills: [],
            ),
      siteSearchLoader: (query) async => const [
        DramaSiteItem(id: 'film_normal_1', title: '山村故事', cover: ''),
        DramaSiteItem(
          id: 'film_normal_2',
          title: ' 山村故事 ',
          cover: 'https://example.com/search-cover.jpg',
        ),
        DramaSiteItem(id: 'film_normal_3', title: '别的片', cover: ''),
      ],
    );
    await pumpUntil(tester, () => find.text('回填演员').evaluate().isNotEmpty);
    // 回填演员进头区演员行。
    expect(find.byKey(const ValueKey('film-detail-cast-row')), findsOneWidget);
    expect(find.text('回填演员'), findsOneWidget);
    // 回填简介进简介区。
    await scrollToWidget(tester, find.text('搜索回填的简介'));
    expect(find.text('搜索回填的简介'), findsOneWidget);
    // 回填剧照：全部 1。
    await scrollToWidget(tester, find.byKey(const ValueKey('film-stills-all')));
    expect(find.text('全部 1 >'), findsOneWidget);
    // 页面封面为空时回落命中条目的封面（海报处）。
    final posterImage = tester.widget<CachedNetworkImage>(
      find.descendant(
        of: find.byKey(const ValueKey('film-detail-poster')),
        matching: find.byType(CachedNetworkImage),
      ),
    );
    expect(posterImage.imageUrl, 'https://example.com/search-cover.jpg');
    // 有回填资料时不出底线说明。
    expect(
      find.byKey(const ValueKey('film-detail-fill-empty-note')),
      findsNothing,
    );
    await drain(tester);
  });

  testWidgets('非 JAV：搜不到同名时留空不编造，底线说明出现', (tester) async {
    await pumpFilm(
      tester,
      seriesId: 'film_normal_9',
      title: '无名小片',
      siteDetail: (_) => const FilmSiteDetail(
        synopsis: '',
        extra: {'play_from': '线路甲'},
        stills: [],
      ),
      siteSearchLoader: (query) async => const [
        DramaSiteItem(id: 'film_other_1', title: '完全不同的片', cover: ''),
      ],
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('film-detail-fill-empty-note'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byKey(const ValueKey('film-detail-cast-row')), findsNothing);
    expect(find.byKey(const ValueKey('film-info-card')), findsNothing);
    expect(find.text('本片剧照'), findsNothing);
    expect(find.text('详细资料暂时没补到（各源都没查到这部片的资料），播放不受影响。'), findsOneWidget);
    await drain(tester);
  });
}
