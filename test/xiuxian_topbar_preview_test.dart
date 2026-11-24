@Timeout(Duration(minutes: 30))
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/home_page.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/widgets/home/home_hero.dart';

import 'preview_test_support.dart';

/// 首页顶栏改版预览图（2026-11-24 用户 21:01 令 + 21:04 补充令）：
///
/// ① home_topbar_new.png：真的 HomePage，品牌行（头像 + 标题 + 当前站名
/// 小字）+ 右端搜索/刷新/分类三个圆钮，分类导航排（推荐/小说/短剧/影视/
/// 漫剧/漫画/听书）已随搜索行删除顶到品牌行下方。
/// ② home_topbar_site_picker.png：点头像弹出站点列表框（两区版弹窗本体
/// 不动，只验头像就是入口）。
///
/// 输出：~/workspace/xiuxian_home_topbar_20261124/preview/。
/// 字体走共享支撑（runAsync 里做真 IO）；没字体时跳过，不拖垮环境。
Directory _outDir() {
  final home = Platform.environment['HOME'];
  final path = home == null || home.isEmpty
      ? 'previews'
      : '$home/workspace/xiuxian_home_topbar_20261124/preview';
  return Directory(path);
}

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  // toImage 要求边界已画完：点按后补一帧再截，否则报 !debugNeedsPaint。
  await tester.pump();
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
  testWidgets('preview: new home top bar and avatar site picker', (
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

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    // 整个 MaterialApp 包进重绘边界：站点弹窗画在 Overlay 里，不包
    // 整棵树就截不到第二张图。
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('preview-topbar-full'),
        child: ProviderScope(
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
            home: const Scaffold(
              backgroundColor: Color(0xFF1E1D38),
              body: HomePage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // ① 顶栏全貌：品牌行 + 右端三个圆钮，搜索行已删。
    expect(find.text(HomeHero.brandName), findsOneWidget);
    expect(find.byKey(const Key('home_brand_avatar')), findsOneWidget);
    expect(find.byKey(const Key('home_brand_search')), findsOneWidget);
    expect(find.byKey(const Key('home_brand_refresh')), findsOneWidget);
    expect(find.byKey(const Key('home_brand_category')), findsOneWidget);
    expect(find.byKey(const Key('home_search_button')), findsNothing);
    expect(find.byKey(const Key('home_category_button')), findsNothing);
    expect(find.byKey(const Key('home_site_button')), findsNothing);
    final searchX = tester
        .getCenter(find.byKey(const Key('home_brand_search')))
        .dx;
    final refreshX = tester
        .getCenter(find.byKey(const Key('home_brand_refresh')))
        .dx;
    final categoryX = tester
        .getCenter(find.byKey(const Key('home_brand_category')))
        .dx;
    expect(searchX, lessThan(refreshX));
    expect(refreshX, lessThan(categoryX));
    // 分类导航排已顶到品牌行下方：搜索行在时它在 112 下方，现在应在 100 以内。
    expect(
      tester.getRect(find.byKey(const ValueKey('home_category_0'))).top,
      lessThan(100),
    );
    // 七个分类标签都在树里（预览图里它们是方框，见 REPORT.md 字体说明，
    // 不是丢了标签：测试器无系统字体兜底，AnimatedDefaultTextStyle
    // 把字族置空后测不到中文字形，真机走系统字体正常显示）。
    for (final label in ['推荐', '小说', '短剧', '影视', '漫剧', '漫画', '听书']) {
      expect(find.text(label), findsWidgets);
    }
    expect(tester.takeException(), isNull);
    await _capture(tester, const ValueKey('preview-topbar-full'), 'home_topbar_new');

    // ② 点头像弹出站点列表框。
    await tester.tap(find.byKey(const Key('home_brand_avatar')));
    await tester.pumpAndSettle();
    expect(find.text('切换站点'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(
      tester,
      const ValueKey('preview-topbar-full'),
      'home_topbar_site_picker',
    );
  });
}
