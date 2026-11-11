import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/home_film_zone.dart';

/// 推荐页全局「影视」区预览图：测试渲染出 PNG，不构建整包。
///
/// 修为 0 时视频池已空（不分档视频站也不在默认
/// SourceRegistry 里），预览改用注入的单站假数据：打开即自动取
/// 首窗推荐平铺三列视频卡，不再点站点药丸；取数用假客户端，不发真请求。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。
Future<void> _loadCjkFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester);
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
  testWidgets('预览：推荐页全局影视区', (tester) async {
    await _loadCjkFonts(tester);
    SharedPreferences.setMockInitialValues({});

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    // 注入单站假数据（修为 0 的默认视频池已空）。
    const sites = [
      (id: 'preview-site', name: '预览站', kind: 'video'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansCJK',
          brightness: Brightness.dark,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('film-zone-preview'),
          child: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: CustomScrollView(
              slivers: [
                HomeFilmZone(
                  gridWidth: 358,
                  sites: sites,
                  clientForSite: (_) => _FakePreviewClient(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 分区标题「影视」只有一个（按 header 的 key 定位，不与卡片角标混数）。
    expect(
      find.descendant(
        of: find.byKey(const Key('film-zone-header')),
        matching: find.text('影视'),
      ),
      findsOneWidget,
    );
    // 4 张影视卡的元信息行各带一个种类角标「影视」：28 轮起 film 有了自己的
    // 标签，以前回落成「小说」，所以全页共 5 处「影视」。
    expect(find.text('影视'), findsNWidgets(5));
    // 打开即自动取首窗推荐，不用点站。
    expect(find.text('预览作品一'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _capture(
      tester,
      const ValueKey<String>('film-zone-preview'),
      'home_film_zone',
    );
  });
}

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
