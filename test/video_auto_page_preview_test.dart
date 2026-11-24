import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';

/// 视频列表滑到底自动加载下一页预览图：测试渲染出 PNG，不构建整包。
///
/// 第一张：首屏第一页；第二张：往上滑到底后第二页自动拼上、
/// 底脚「没有更多了」。取数用假客户端，不发真请求。
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
  testWidgets('预览：视频列表滑到底自动加载下一页', (tester) async {
    await loadPreviewFonts(tester);
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
          key: const ValueKey<String>('video-auto-page-preview'),
          child: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: CustomScrollView(
              slivers: [
                DramaSiteGrid(
                  siteId: 'test-site',
                  categoryId: 'c1',
                  gridWidth: 358,
                  client: _FakeGridClient(),
                  showFilterBar: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('片一-1'), findsOneWidget);

    await _capture(
      tester,
      const ValueKey<String>('video-auto-page-preview'),
      'video_auto_page_1',
    );

    // 往上滑到底，第二页自动拼上。
    await tester.scrollUntilVisible(find.text('片二-1'), 300);
    await tester.pumpAndSettle();
    expect(find.text('片二-1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('没有更多了'), 300);
    await tester.pumpAndSettle();

    await _capture(
      tester,
      const ValueKey<String>('video-auto-page-preview'),
      'video_auto_page_2',
    );
  });
}

class _FakeGridClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('c1', '电影')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page == 1) {
      return DramaSiteCatalogPage(
        items: [
          for (var i = 1; i <= 12; i++)
            DramaSiteItem(id: '一-$i', title: '片一-$i', cover: ''),
        ],
        hasMore: true,
      );
    }
    return DramaSiteCatalogPage(
      items: [
        for (var i = 1; i <= 12; i++)
          DramaSiteItem(id: '二-$i', title: '片二-$i', cover: ''),
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
