import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';

/// 影视区改造预览图：测试渲染出 PNG，不构建整包。
///
/// 影视页那张是版式复合预览：真实 DramaSiteGrid（4 列）+ 与
/// VideoPage 同款的顶栏（影视标题、右上角分类按钮）与午夜区药丸，
/// 数据走注入的假客户端——真实 VideoPage 在测试里会去拉午夜站
/// 的真实接口，出不了稳定的版式图。分类页那张是真实 CategoryPage
///（仅数据源注入，与正式的影视频道同一条渲染链）。
class _FakeClient extends DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return DramaSiteCatalogPage(
      items: [
        for (var i = 0; i < 8; i++)
          DramaSiteItem(id: 'v$i', title: '测试剧目$i', cover: ''),
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

Future<void> _loadPreviewFont(WidgetTester tester) async {
  await tester.runAsync(() async {
    final bytes = await File(
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    ).readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    // 分类页用 Lucide 图标（flutter_lucide 包内字体），测试里也要加载，
    // 否则火苗/返回/搜索图标在图里是方框。路径写死（仅测试用，
    // 与上方系统字体路径同款做法；文件不存在时跳过，不让预览失败）。
    final lucideFile = File(
      '/home/hatch/.pub-cache/hosted/pub.dev/flutter_lucide-1.59.0/lib/fonts/lucide.ttf',
    );
    if (await lucideFile.exists()) {
      final lucideBytes = await lucideFile.readAsBytes();
      final lucide = FontLoader('lucide')
        ..addFont(Future.value(ByteData.sublistView(lucideBytes)));
      await lucide.load();
    }
  });
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
      final file = File('build/validation/video-zone-20261105/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets('预览：影视页（午夜区在顶部、4 列卡片、分类与切站药丸）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await _loadPreviewFont(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('video-zone-preview-boundary'),
          child: Scaffold(
            appBar: AppBar(
              title: const Text('影视'),
              actions: [
                TextButton(
                  onPressed: () {},
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('分类'),
                ),
                IconButton(
                  icon: const Icon(Icons.video_library),
                  tooltip: '本地库',
                  onPressed: () {},
                ),
                IconButton(
                  icon: const Icon(Icons.list),
                  tooltip: '站源管理',
                  onPressed: () {},
                ),
              ],
            ),
            body: CustomScrollView(
              slivers: [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '午夜区',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.grey),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '🔞91成人短剧',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          SizedBox(width: 4),
                          Icon(Icons.arrow_drop_down, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                DramaSiteGrid(
                  siteId: 'fake_site',
                  categoryId: 'all',
                  gridWidth: 400,
                  client: _FakeClient(),
                  showFilterBar: false,
                  columns: 4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('午夜区'), findsOneWidget);
    expect(find.text('🔞91成人短剧'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey('video-zone-preview-boundary'),
      'video_page',
    );
  });

  testWidgets('预览：分类页（影视 tab、左栏、含熟女的热门标签）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _loadPreviewFont(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('category-preview-boundary'),
          child: CategoryPage(
            videoSiteId: 'seed_91crdjai',
            openVideoTab: true,
            // 统一资产默认走 rootBundle，在 widget 测试的 fake async 下
            // 读不到会挂起：这里直接给 empty，走单站模式（本站四组），
            // 本预览验的就是单站模式。
            unifiedLoader: () async => UnifiedVideoCategories.empty,
            videoLoader: (_) async => const VideoCategoryData(
              siteId: 'seed_91crdjai',
              siteName: '🔞91成人短剧',
              hotTags: ['成人短剧', '成人漫剧', '真人剧', '成人视频', '熟女'],
              themes: ['都市', '古装'],
              roles: ['姐姐'],
              plots: ['重逢'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 魔蚁布局：顶栏不再是旧「影视」tab，标题是「频道分类」。
    expect(find.text('频道分类'), findsOneWidget);
    expect(find.text('熟女'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey('category-preview-boundary'),
      'category_page',
    );
  });
}
