// 演员库原生页预览截图：一测一张，输出三张 PNG 到
// ~/workspace/xiuxian_actress_native_ui_20261126/。
// 数据是假库 + 假仓储（封面预埋一张合成图进图片缓存，不走真网）。
// 跑法：单独跑本文件、--no-pub，不要与功能测试混链。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_adapter_models.dart';
import 'package:fqapp/actress/actress_adapter_repository.dart';
import 'package:fqapp/actress/actress_adapter_store.dart';
import 'package:fqapp/actress/actress_library_db.dart';
import 'package:fqapp/actress/actress_library_native_page.dart';

import 'actress_fixtures.dart';
import 'preview_test_support.dart';

const _previewDir = '/home/hatch/workspace/xiuxian_actress_native_ui_20261126';
const _coverUrl = 'https://v.hersav.me/images/av/preview-sample.jpg';

class _FakeDb {
  final tables = {
    'videos',
    'video_play_urls',
    'video_actress',
    'actresses',
    'video_tag',
    'video_ranking',
    'index_categories',
  };

  Map<String, Object?> _videoRow(String id, String title) => {
    'vodId': id,
    'title': title,
    'pic': _coverUrl,
    'play': 'https://v.hersav.me/h/h.m3u8',
    'playAlt': '',
    'date': '2024-01-01',
    'typeName': '成人影片',
    'actress': '演员甲',
  };

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?>? args,
  ]) async {
    if (sql.contains('sqlite_master')) {
      return [for (final t in tables) {'name': t}];
    }
    if (sql.contains('FROM video_ranking')) {
      return [_videoRow('rank-001', '排行榜作品')];
    }
    if (sql.contains('category_name AS name')) {
      return [
        {'name': '中文字幕', 'cnt': 3631},
      ];
    }
    if (sql.contains('FROM actresses a')) {
      return [
        {'name': '演员甲', 'avatar': '', 'cnt': 42},
      ];
    }
    if (sql.contains('FROM videos v')) {
      return [
        _videoRow('ssis-001', 'SSIS-001 预览作品一'),
        _videoRow('mida-002', 'MIDA-002 预览作品二'),
        _videoRow('ipx-003', 'IPX-003 预览作品三'),
        _videoRow('sone-004', 'SONE-004 预览作品四'),
        _videoRow('miaa-005', 'MIAA-005 预览作品五'),
        _videoRow('juq-006', 'JUQ-006 预览作品六'),
      ];
    }
    return [];
  }
}

class _FakeRepository extends AppRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory('all', '全部'), CatalogCategory('new', '最新')];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
    Map<String, String> filters = const {},
  }) async {
    return CatalogPage([
      for (var i = 1; i <= 6; i++)
        Drama(
          id: '$source-$i',
          source: source,
          title: '$source 在线作品 $i',
          cover: _coverUrl,
          tags: ['CODE-$i'],
        ),
    ], page: page);
  }

  @override
  Future<CatalogPage> searchAcross(List<String> sources, String query) async =>
      CatalogPage(const []);

  @override
  Future<void> searchAcrossProgressive(
    List<String> sources,
    String query, {
    required void Function(String source, List<Drama> items) onSite,
    bool Function()? shouldStop,
  }) async {
    for (final source in sources) {
      onSite(source, [
        Drama(
          id: '$source-s1',
          source: source,
          title: '搜索结果-$source',
          cover: _coverUrl,
        ),
      ]);
    }
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) async => drama.cover;

  @override
  Future<DramaDetail> detail(Drama drama) async => DramaDetail(drama, [
    Episode({'id': 'https://example.test/a.m3u8', 'title': '正片'}, 1),
  ]);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
    int route = 0,
    bool adBlock = true,
  }) async => const PlaybackPlan(url: 'https://example.test/a.m3u8');
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 25; i++) {
      try {
        await Future.delayed(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 100));
      } catch (_) {}
    }
  });
}

Future<void> _savePng(WidgetTester tester, String name) async {
  final boundary = tester
      .element(find.byType(RepaintBoundary).first)
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  Directory(_previewDir).createSync(recursive: true);
  File('$_previewDir/$name').writeAsBytesSync(bytes);
}

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore();
  });
  tearDown(() => store.dispose());

  Future<void> pumpPage(WidgetTester tester) async {
    await loadPreviewFonts(tester);
    // 封面预埋：合成图按封面 URL 塞进图片缓存，离线也能画出海报。
    // 生成 PNG 是真异步引擎操作，必须在 runAsync 里做（假时钟区里
    // 直接 await 永远等不到回包，测试会挂死）。
    final png = await tester.runAsync(
      () => fakeComicPagePng(const Color(0xFF5B3A8E)),
    );
    final sample = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png!);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
    PaintingBinding.instance.imageCache.putIfAbsent(
      NetworkImage(_coverUrl),
      () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: sample!))),
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = _FakeDb();
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          home: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'NotoSansCJK'),
            child: ActressLibraryNativePage(
              repository: _FakeRepository(),
              store: store,
              fallback: ActressLibraryDbFallback(
                pathResolver: () async => '/fake/女优库.db',
                opener: (path) async => db.query,
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('preview native list', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('native-work-ssis-001')), findsOneWidget);
    await _savePng(tester, 'preview_list.png');
  });

  testWidgets('preview native search', (tester) async {
    await pumpPage(tester);
    await tester.enterText(
      find.byKey(const ValueKey('native-search-field')),
      'SSIS',
    );
    await tester.tap(find.byKey(const ValueKey('native-search-button')));
    await _settle(tester);
    expect(find.text('女优库 · 6条'), findsOneWidget);
    await _savePng(tester, 'preview_search.png');
  });

  testWidgets('preview native sources whos', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('native-source-whos')));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('native-work-whos-whos-1')),
      findsOneWidget,
    );
    await _savePng(tester, 'preview_sources.png');
  });
}
