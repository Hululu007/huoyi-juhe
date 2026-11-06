import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/pages/unified_browse_content_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';

/// 分类页统一模式测试：影视频道默认全部站点（热门分类/全部两组），
/// 模式切换、页内搜索过滤 chip、点 chip 进多站内容汇总。
/// 数据与取数全是注入的假数据，不联网、不读真实资产。
void main() {
  UnifiedVideoCategories fakeUnified() => parseUnifiedVideoCategories('''
{
  "version": 1,
  "site_count": 5,
  "total_site_count": 5,
  "sites_without_categories": [],
  "categories": {
    "热门甲": [
      {"siteId": "a", "path": "/cat/1"},
      {"siteId": "b", "path": "/cat/1"},
      {"siteId": "c", "path": "/cat/1"},
      {"siteId": "d", "path": "/cat/1"},
      {"siteId": "e", "path": "/cat/1"}
    ],
    "中热丙": [
      {"siteId": "a", "path": "/cat/3"},
      {"siteId": "b", "path": "/cat/3"}
    ],
    "冷门乙": [{"siteId": "a", "path": "/cat/2"}]
  },
  "tags": {
    "可看标签": [{"siteId": "a", "url": "/tag/x", "browsable": true}]
  }
}
''');

  const fakeSingle = VideoCategoryData(
    siteId: 'a',
    siteName: '测试站',
    hotTags: ['本站热'],
    themes: ['本站主题'],
    roles: [],
    plots: [],
  );

  DramaSiteContentClient fakeClient(String siteId) => _FakeClient(siteId);

  Future<void> pump(
    WidgetTester tester, {
    UnifiedVideoCategories? unified,
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: CategoryPage(
          videoSiteId: 'a',
          openVideoTab: true,
          videoLoader: (_) async => fakeSingle,
          unifiedLoader: () async => unified ?? fakeUnified(),
          unifiedClientForSite: fakeClient,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('影视频道默认统一模式：热门分类与全部两组', (tester) async {
    await pump(tester);

    // 模式切换行：全部站点选中、本站未选。
    expect(find.byKey(const ValueKey('unified_mode_all')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('unified_mode_single')),
      findsOneWidget,
    );
    // 左栏两组：热门分类/全部（没有小说那四组）。
    expect(find.text('热门分类'), findsWidgets);
    expect(find.text('全部'), findsWidgets);
    expect(find.text('主题'), findsNothing);
    // 热门组只有热门甲（>=5 站），全部组三名全有。
    expect(find.text('热门甲'), findsNWidgets(2));
    expect(find.text('中热丙'), findsOneWidget);
    expect(find.text('冷门乙'), findsOneWidget);
    // 热门 chip 带火苗。
    expect(
      find.descendant(
        of: find
            .byKey(const ValueKey('category_tile_unified_cat_热门甲'))
            .first,
        matching: find.byType(Icon),
      ),
      findsOneWidget,
    );
  });

  testWidgets('模式切换：本站四组，来回切回统一', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('unified_mode_single')));
    await tester.pumpAndSettle();

    // 单站模式：老四组。
    expect(find.text('热门标签'), findsWidgets);
    expect(find.text('主题'), findsWidgets);
    expect(find.text('本站热'), findsWidgets);
    expect(find.text('本站主题'), findsWidgets);
    expect(find.text('热门分类'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('unified_mode_all')));
    await tester.pumpAndSettle();

    expect(find.text('热门分类'), findsWidgets);
    expect(find.text('热门甲'), findsNWidgets(2));
    expect(find.text('本站热'), findsNothing);
  });

  testWidgets('页内搜索过滤 chip，关闭后恢复', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('category_search')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('unified_category_search')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('unified_category_search')),
      '热门',
    );
    await tester.pumpAndSettle();

    // 只剩含「热门」的名字。
    expect(find.text('热门甲'), findsWidgets);
    expect(find.text('中热丙'), findsNothing);
    expect(find.text('冷门乙'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('unified_category_search_close')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('unified_category_search')),
      findsNothing,
    );
    expect(find.text('中热丙'), findsOneWidget);
    expect(find.text('冷门乙'), findsOneWidget);
  });

  testWidgets('点统一分类 chip 进多站内容汇总', (tester) async {
    await pump(tester);

    // 「中热丙」在 a、b 两站：点全部组里的那颗。
    await tester.tap(
      find.byKey(const ValueKey('category_tile_unified_cat_中热丙')),
    );
    await tester.pumpAndSettle();

    // 汇总页标题是分类名，两站内容都出现。
    expect(find.text('中热丙'), findsWidgets);
    expect(find.text('a 站作品'), findsOneWidget);
    expect(find.text('b 站作品'), findsOneWidget);
    expect(find.byType(UnifiedBrowseContentPage), findsOneWidget);
  });

  testWidgets('标签组出现，点标签进汇总（只收可浏览的）', (tester) async {
    await pump(tester);

    expect(find.text('标签'), findsWidgets);
    expect(find.text('可看标签'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('category_tile_unified_tag_可看标签')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UnifiedBrowseContentPage), findsOneWidget);
    expect(find.text('a 站作品'), findsOneWidget);
  });
}

class _FakeClient extends DramaSiteContentClient {
  _FakeClient(this.siteId);

  final String siteId;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return DramaSiteCatalogPage(
      items: [
        DramaSiteItem(id: 'v1', title: '$siteId 站作品', cover: ''),
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
