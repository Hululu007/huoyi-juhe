import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/unified_browse_content_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';

/// 统一浏览内容页测试：多站汇总（首批 4 站并行、按站分组）、
/// 加载更多站点、某站取不到跳过并计数。取数用假客户端，不联网。
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<UnifiedCategorySite> entries, {
    Map<String, List<DramaSiteItem>>? itemsBySite,
    Set<String>? failingSites,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedBrowseContentPage(
          title: '测试分类',
          entries: entries,
          clientForSite: (siteId) => _FakeClient(
            itemsBySite?[siteId] ?? const [],
            fails: failingSites?.contains(siteId) ?? false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<UnifiedCategorySite> entries(int count) => [
    for (var i = 0; i < count; i++)
      UnifiedCategorySite(siteId: 'site_$i', path: '/cat/$i'),
  ];

  Map<String, List<DramaSiteItem>> twoItemsPerSite(int count) => {
    for (var i = 0; i < count; i++)
      'site_$i': [
        DramaSiteItem(id: 'v${i}a', title: '站$i作品甲', cover: ''),
        DramaSiteItem(id: 'v${i}b', title: '站$i作品乙', cover: ''),
      ],
  };

  testWidgets('首批取 4 站并行，按站分组展示', (tester) async {
    await pump(tester, entries(6), itemsBySite: twoItemsPerSite(6));

    expect(find.text('测试分类'), findsOneWidget);
    // 首批 4 站的站头与作品都出现，第 5、6 站还没取。
    expect(find.text('站0作品甲'), findsOneWidget);
    // 第 4 站在首屏外，滚到可见再断言（懒加载只建可见卡）。
    await tester.scrollUntilVisible(find.text('站3作品乙'), 300);
    expect(find.text('站3作品乙'), findsOneWidget);
    expect(find.text('站4作品甲'), findsNothing);
    expect(find.text('站5作品甲'), findsNothing);
    // 还剩 2 站，加载更多按钮显示余数（按钮在列表底，滚到可见再断言）。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
      300,
    );
    expect(find.textContaining('还剩 2 站'), findsOneWidget);
  });

  testWidgets('加载更多站点取下一批', (tester) async {
    await pump(tester, entries(6), itemsBySite: twoItemsPerSite(6));

    // 按钮在列表底，先滚到可见再点。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
      300,
    );
    await tester.tap(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('站4作品甲'), 300);
    expect(find.text('站4作品甲'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('站5作品乙'), 300);
    expect(find.text('站5作品乙'), findsOneWidget);
    // 站全取完了，按钮消失。
    expect(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
      findsNothing,
    );
  });

  testWidgets('某站取不到就跳过并在页脚计数', (tester) async {
    await pump(
      tester,
      entries(5),
      itemsBySite: twoItemsPerSite(5),
      failingSites: {'site_1', 'site_3'},
    );

    // 取得到的站正常展示。
    expect(find.text('站0作品甲'), findsOneWidget);
    expect(find.text('站2作品甲'), findsOneWidget);
    expect(find.text('站4作品甲'), findsNothing);
    // 2 站失败，页脚计数；其余站不受影响。
    expect(find.text('2 个站取不到，已跳过'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
      300,
    );
    await tester.tap(
      find.byKey(const ValueKey('unified_browse_load_more_sites')),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('站4作品甲'), 300);
    expect(find.text('站4作品甲'), findsOneWidget);
  });

  testWidgets('全部站都取不到显示错误与重试', (tester) async {
    await pump(
      tester,
      entries(2),
      itemsBySite: const {},
      failingSites: {'site_0', 'site_1'},
    );

    expect(find.textContaining('都打不开'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}

class _FakeClient extends DramaSiteContentClient {
  _FakeClient(this.items, {this.fails = false});

  final List<DramaSiteItem> items;
  final bool fails;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (fails) throw StateError('site down');
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}
