@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_hero.dart';

import 'preview_test_support.dart';

/// 工人 A（胶囊缩小 + 去顶栏放大镜）的预览图：只渲改动，不碰生产逻辑。
///
/// ① home_capsule_row.png：真的 HomePage，切到「影视」tab，站的四个
/// 分类（中文字幕 / 最近更新 / 新作上市 / 无码流出）走真的
/// _filmCategoryStrip（36 高、12 号字、横向内边距 10）。
/// ② home_topbar_with_search.png：真的 HomeHero，顶栏右端是搜索/刷新
/// 两个圆钮（分类钮需 onCategory，未传不占位），点放大镜进搜索。
/// 2026-11-24 用户最新令（21:04）恢复右上角放大镜圆钮，取代 20:27
/// 「放大镜去掉」的旧令；搜索行已整行删除，搜索框胶囊不再存在。
///
/// 输出目录固定：~/workspace/xiuxian_category_ui_20261124/preview/。
/// 字体走共享支撑（runAsync 里做真 IO）；没字体时跳过，不拖垮环境。
/// 单独跑本文件，加 timeout，PNG 落地后即可杀掉。
Directory _outDir() {
  final home = Platform.environment['HOME'];
  final path = home == null || home.isEmpty
      ? 'previews'
      : '$home/workspace/xiuxian_category_ui_20261124/preview';
  return Directory(path);
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
      final file = File('${_outDir().path}/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      // ignore: avoid_print
      print('XIUXIAN_PREVIEW wrote ${file.path}');
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets('preview: film tab capsule strip (shrunk)', (tester) async {
    const regular =
        '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc';
    const bold = '/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc';
    if (!File(regular).existsSync() || !File(bold).existsSync()) {
      markTestSkipped('本机没有 NotoSerifCJK 字体，跳过预览图渲染');
      return;
    }
    await loadPreviewFonts(tester, serif: true, lucide: true);

    // 影视站带四个真实分类（extra['extractedCategories']），与用户
    // 截图那排同名；没有真实客户端，网格报「该站源当前不可用」，不触网。
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        {
          'id': 'seed_previewfilm',
          'name': '预览影视',
          'kind': 'pyImport',
          'address': 'previewfilm.py',
          'detail': '预览',
          'enabled': true,
          'extra': {
            'builtin': true,
            'contentType': 'video',
            'extractedCategories': [
              {'id': 'zh', 'name': '中文字幕'},
              {'id': 'new', 'name': '最近更新'},
              {'id': 'latest', 'name': '新作上市'},
              {'id': 'uncensored', 'name': '无码流出'},
            ],
          },
        },
      ]),
      'video_zone_site_id': 'seed_previewfilm',
    });

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith(
            () => HomeNotifier(
              usesLocalTabs: true,
              homepageLoader:
                  ({
                    int tabType = 2,
                    int offset = 0,
                    String? sessionId,
                  }) async => HomepagePage(
                    items: const [],
                    nextOffset: null,
                    sessionId: null,
                  ),
              searchLoader: (query, {int page = 1}) async => const [],
            ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSerifCJK',
            brightness: Brightness.dark,
          ),
          home: RepaintBoundary(
            key: const ValueKey('preview-capsule-row'),
            child: const HomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final filmTab = find.byKey(const ValueKey('home_category_3'));
    await tester.ensureVisible(filmTab);
    await tester.pumpAndSettle();
    await tester.tap(filmTab);
    await tester.pumpAndSettle();

    // 四个分类胶囊都在：第一项默认选中（_refreshFilmCategories 取
    // 第一个真实分类），其余未选中。
    for (final label in ['中文字幕', '最近更新', '新作上市', '无码流出']) {
      expect(find.text(label), findsWidgets);
    }
    expect(tester.takeException(), isNull);
    // toImage 要求边界已画完：补一帧再截，否则报 !debugNeedsPaint。
    await tester.pump();
    await _capture(tester, const ValueKey('preview-capsule-row'), 'home_capsule_row');
  });

  testWidgets('preview: top bar with brand search button', (
    tester,
  ) async {
    const regular =
        '/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc';
    const bold = '/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc';
    if (!File(regular).existsSync() || !File(bold).existsSync()) {
      markTestSkipped('本机没有 NotoSerifCJK 字体，跳过预览图渲染');
      return;
    }
    await loadPreviewFonts(tester, serif: true, lucide: true);

    var searched = false;
    await tester.binding.setSurfaceSize(const Size(390, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSerifCJK',
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF1E1D38),
          body: RepaintBoundary(
            key: const ValueKey('preview-topbar'),
            child: HomeHero(
              onSearch: () => searched = true,
              onRefresh: () {},
              brandSubtitle: '预览影视',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(HomeHero.brandName), findsOneWidget);
    expect(find.byKey(const Key('home_brand_search')), findsOneWidget);
    expect(find.byKey(const Key('home_brand_refresh')), findsOneWidget);
    await tester.tap(find.byKey(const Key('home_brand_search')));
    expect(searched, isTrue);
    expect(tester.takeException(), isNull);
    // toImage 要求边界已画完：补一帧再截，否则报 !debugNeedsPaint。
    await tester.pump();
    await _capture(tester, const ValueKey('preview-topbar'), 'home_topbar_with_search');
  });
}
