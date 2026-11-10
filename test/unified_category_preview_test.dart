import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/pages/unified_browse_content_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';

/// 统一分类浏览页预览图：测试渲染出 PNG，不构建整包。
///
/// 统一页用真实资产数据（`assets/unified_video_categories.json`，127 站、
/// 1600 去重名、86 热门）渲染，样子即用户手机上将看到的样子；
/// 内容汇总页用假客户端（不发真请求）。
///
/// 真实资产在测试里不走 rootBundle（测试的资产包是构建时快照，
/// 新加的资产读不到会一直转圈）：测试直接读资产文件解析后注入，
/// 渲染的数据与线上完全一致。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
Future<void> _loadCjkFonts() async {
  final regularBytes = File(
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  ).readAsBytesSync();
  final boldBytes = File(
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ).readAsBytesSync();
  final loader = FontLoader('NotoSansCJK')
    ..addFont(Future.value(ByteData.view(regularBytes.buffer)));
  await loader.load();
  final boldLoader = FontLoader('NotoSansCJK')
    ..addFont(Future.value(ByteData.view(boldBytes.buffer)));
  await boldLoader.load();
  final iconBytes = File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytesSync();
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

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
      final file = File('previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets('预览：统一分类浏览页（真实资产）', (tester) async {
    await _loadCjkFonts();
    SharedPreferences.setMockInitialValues({});

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    // 真实资产文件直接解析后注入（不走 rootBundle，见文件头注释）。
    final realData = parseUnifiedVideoCategories(
      File('assets/unified_video_categories.json').readAsStringSync(),
    );
    expect(realData.allNames.length, 1600);
    expect(realData.hotNames.length, 86);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansCJK',
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('unified-category-preview'),
          child: CategoryPage(
            videoSiteId: 'a',
            openVideoTab: true,
            videoLoader: _fakeSingle,
            unifiedLoader: () async => realData,
            unifiedClientForSite: (_) => _FakePreviewClient(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('频道分类'), findsOneWidget);
    expect(find.text('中文字幕'), findsWidgets);
    expect(find.byKey(const ValueKey('unified_mode_all')), findsOneWidget);
    expect(find.text('预览作品一'), findsWidgets);
    expect(tester.takeException(), isNull);

    await _capture(
      tester,
      const ValueKey<String>('unified-category-preview'),
      'unified_category_page',
    );
  });

  testWidgets('预览：统一分类内容汇总', (tester) async {
    await _loadCjkFonts();
    SharedPreferences.setMockInitialValues({});

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansCJK',
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('unified-content-preview'),
          child: UnifiedBrowseContentPage(
            title: '中文字幕',
            entries: const [
              UnifiedCategorySite(siteId: 'a', path: '/cat/1'),
              UnifiedCategorySite(siteId: 'b', path: '/cat/1'),
              UnifiedCategorySite(siteId: 'c', path: '/cat/1'),
              UnifiedCategorySite(siteId: 'd', path: '/cat/1'),
            ],
            clientForSite: (_) => _FakePreviewClient(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('中文字幕'), findsOneWidget);
    expect(find.text('预览作品一'), findsWidgets);
    expect(tester.takeException(), isNull);

    await _capture(
      tester,
      const ValueKey<String>('unified-content-preview'),
      'unified_category_content',
    );
  });
}

Future<VideoCategoryData> _fakeSingle(String siteId) async =>
    const VideoCategoryData(
      siteId: 'a',
      siteName: '测试站',
      hotTags: ['本站热'],
      themes: [],
      roles: [],
      plots: [],
    );

class _FakePreviewClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return DramaSiteCatalogPage(
      items: const [
        DramaSiteItem(id: 'v1', title: '预览作品一', cover: ''),
        DramaSiteItem(id: 'v2', title: '预览作品二', cover: ''),
        DramaSiteItem(id: 'v3', title: '预览作品三', cover: ''),
        DramaSiteItem(id: 'v4', title: '预览作品四', cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}
