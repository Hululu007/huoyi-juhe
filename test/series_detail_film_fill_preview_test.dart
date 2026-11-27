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
import 'package:fqapp/models/series_detail.dart';
import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/film_detail_fill.dart';
import 'package:fqapp/services/shelf_store.dart';

import 'support/fakes.dart';
import 'support/series_detail_fixtures.dart';

/// 片库详情页自动补预览图（与普通测试分开跑）：三张 PNG 出到
/// ~/workspace/xiuxian_film_detail_fill_20261127/previews/：
/// film_jav_before.png（无 fill，只有站详情）、film_jav_after.png
/// （假 fill 补满：信息卡 + 缎带 + 合并演员 + 剧照）、
/// film_normal_after.png（普通影视：同站同名搜索回填后）。
/// 封面 / 剧照是假地址、截图里是占位色块，只证版式。
const _outDir =
    '/home/hatch/workspace/xiuxian_film_detail_fill_20261127/previews';

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$_outDir/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'series-detail-film-fill-preview-test-',
    );
    Hive.init(directory.path);
    await ShelfStore.instance.init();
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

  Future<void> pumpPreview(
    WidgetTester tester, {
    required String boundary,
    required String seriesId,
    required String title,
    required FilmSiteDetail Function(String id) siteDetail,
    Future<FilmDetailFill> Function(String code, Object? meta)? filmFillLoader,
    Future<List<DramaSiteItem>> Function(String query)? siteSearchLoader,
  }) async {
    final list = [chapterAt(0), chapterAt(1)];
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'NotoSansCJK',
          ),
          home: RepaintBoundary(
            key: ValueKey<String>(boundary),
            child: SeriesDetailPage(
              seriesId: seriesId,
              historyStore: MemoryReaderStore(),
              title: title,
              cover: '',
              episodes: list,
              seriesLoader: (_) async => SeriesDetail(
                seriesId: seriesId,
                title: title,
                episodeCount: list.length,
                episodeLabel: '共${list.length}集',
                status: 1,
              ),
              siteDetailLoader: (id) async => siteDetail(id),
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
    });
    // 番号索引是真异步加载，多等一会让补全链落定。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
  }

  testWidgets('预览：JAV 补全前（无 fill）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    await pumpPreview(
      tester,
      boundary: 'film-jav-before-preview',
      seriesId: 'ZZTEST-001',
      title: '某番号片',
      siteDetail: (_) => const FilmSiteDetail(
        synopsis: '本站自带简介，补全前只有这一段。',
        extra: {'play_from': '线路甲', 'actor': '站内演员'},
        stills: ['https://example.com/own-still.jpg'],
      ),
      // 无 fill：假加载器全空回（等同各路都没查到时的页面形态，
      // 但本站自带简介/演员/剧照照常显示）。
      filmFillLoader: (code, meta) async => const FilmDetailFill(),
    );
    expect(find.text('站内演员'), findsOneWidget);
    expect(find.byKey(const ValueKey('film-info-card')), findsNothing);
    await _capture(
      tester,
      const ValueKey<String>('film-jav-before-preview'),
      'film_jav_before.png',
    );
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('预览：JAV 补全后（假 fill 补满）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    await pumpPreview(
      tester,
      boundary: 'film-jav-after-preview',
      seriesId: 'ZZTEST-001',
      title: '某番号片',
      siteDetail: (_) => const FilmSiteDetail(
        synopsis: '',
        extra: {'play_from': '线路甲'},
        stills: ['https://example.com/own-still.jpg'],
      ),
      filmFillLoader: (code, meta) async => const FilmDetailFill(
        code: 'ZZTEST-001',
        synopsis: '补全回来的完整简介：这部片的剧情与看点都在这一段里。',
        cast: [
          FilmFillCast(name: '补全演员甲'),
          FilmFillCast(name: '补全演员乙'),
        ],
        director: '某导演',
        maker: '某制作商',
        series: '某系列',
        releaseDate: '2024-05-06',
        durationText: '120 分钟',
        score: '8.5',
        scoreCount: 321,
        originTitle: 'Original Title ZZ',
        stills: [
          'https://example.com/fill-still-1.jpg',
          'https://example.com/fill-still-2.jpg',
        ],
      ),
    );
    expect(find.byKey(const ValueKey('film-info-card')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('film-info-score-ribbon')),
      findsOneWidget,
    );
    expect(find.text('全部 3 >'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('film-jav-after-preview'),
      'film_jav_after.png',
    );
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('预览：普通影视搜索回填后', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 1600);
    addTearDown(tester.view.reset);
    await pumpPreview(
      tester,
      boundary: 'film-normal-after-preview',
      seriesId: 'film_normal_1',
      title: '山村故事',
      siteDetail: (id) => id == 'film_normal_2'
          ? const FilmSiteDetail(
              synopsis: '同站同名条目回填的简介：山村里发生的暖心故事。',
              extra: {'actor': '回填演员甲,回填演员乙', 'category': '剧情'},
              stills: [
                'https://example.com/search-still-1.jpg',
                'https://example.com/search-still-2.jpg',
              ],
            )
          : const FilmSiteDetail(
              synopsis: '',
              extra: {'play_from': '线路甲'},
              stills: [],
            ),
      siteSearchLoader: (query) async => const [
        DramaSiteItem(
          id: 'film_normal_2',
          title: '山村故事',
          cover: 'https://example.com/search-cover.jpg',
        ),
      ],
    );
    expect(find.text('回填演员甲'), findsOneWidget);
    expect(find.text('全部 2 >'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('film-normal-after-preview'),
      'film_normal_after.png',
    );
    await tester.pump(const Duration(seconds: 11));
  });
}
