import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/category_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/unified_video_categories.dart';
import 'package:fqapp/services/video_category_tags.dart';

/// 分类页统一模式测试（魔蚁风频道分类页）：影视频道默认全部站点，
/// 顶部「频道分类」+ 筛选行，左栏是本站真实内容分类（统一分类 +
/// 可浏览标签），右侧 2 列大卡是该分类下各站 catalog 的真作品；
/// 模式切换、页内搜索过滤左栏、筛选行排序/完结过滤、类型下拉。
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

  testWidgets('影视频道默认魔蚁风：大标题+左栏真实分类+作品卡', (tester) async {
    await pump(tester);

    expect(find.text('频道分类'), findsOneWidget);
    // 模式切换行：全部站点选中、本站未选。
    expect(find.byKey(const ValueKey('unified_mode_all')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('unified_mode_single')),
      findsOneWidget,
    );
    // 筛选行四项都在。
    expect(find.byKey(const ValueKey('moyi_type_filter')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_filter_hot')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_filter_latest')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('moyi_filter_finished')),
      findsOneWidget,
    );
    // 左栏：热门/全部 + 本站真实分类 + 可浏览标签（不是只三组）。
    expect(find.byKey(const ValueKey('moyi_left_热门')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_全部')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_中热丙')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_冷门乙')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_可看标签')), findsOneWidget);
    // 旧 chip 布局已不在：没有分组头与 chip。
    expect(find.text('热门分类'), findsNothing);
    expect(find.text('主题'), findsNothing);
    // 默认选中「热门」：热门甲首站的作品出了，角标按备注真实信号挂。
    expect(find.text('a 站作品 /cat/1'), findsOneWidget);
    expect(find.text('a 站作品二 /cat/1'), findsOneWidget);
    expect(find.text('HD'), findsOneWidget);
    expect(find.text('NEW'), findsOneWidget);
  });

  testWidgets('模式切换：本站左栏与作品，来回切回统一', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('unified_mode_single')));
    await tester.pumpAndSettle();

    // 单站模式：左栏是本站分类 + 主题，没有统一分类。
    expect(find.byKey(const ValueKey('moyi_left_本站热')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_本站主题')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsNothing);
    // 本站作品按名找客户端 categories() 的 id 取 catalog。
    expect(find.text('a 站作品 cat1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('unified_mode_all')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsOneWidget);
    expect(find.text('a 站作品 /cat/1'), findsOneWidget);
    expect(find.text('a 站作品 cat1'), findsNothing);
  });

  testWidgets('页内搜索过滤左栏分类，关闭后恢复', (tester) async {
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
    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_中热丙')), findsNothing);
    expect(find.byKey(const ValueKey('moyi_left_冷门乙')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('unified_category_search_close')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('unified_category_search')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('moyi_left_中热丙')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_冷门乙')), findsOneWidget);
  });

  testWidgets('点左栏分类换作品', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('moyi_left_中热丙')));
    await tester.pumpAndSettle();

    // 中热丙在 a、b 两站：两站作品都出现，热门甲的作品没了。
    expect(find.text('a 站作品 /cat/3'), findsOneWidget);
    expect(find.text('b 站作品 /cat/3'), findsOneWidget);
    expect(find.text('a 站作品 /cat/1'), findsNothing);
  });

  testWidgets('点左栏标签出该标签作品', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('moyi_left_可看标签')));
    await tester.pumpAndSettle();

    expect(find.text('a 站作品 /tag/x'), findsOneWidget);
    expect(find.text('a 站作品 /cat/1'), findsNothing);
  });

  testWidgets('筛选行：最新按备注日期排前，完结只留完结', (tester) async {
    await pump(tester);

    // 默认热门：v1（更新至12集 高清）在左列、v2（带日期）在右列。
    Offset left(String text) => tester.getTopLeft(find.text(text));
    expect(left('a 站作品 /cat/1').dx < left('a 站作品二 /cat/1').dx, isTrue);

    await tester.tap(find.byKey(const ValueKey('moyi_filter_latest')));
    await tester.pumpAndSettle();

    // 最新：带日期的 v2 排到左列、v1 换到右列。
    expect(left('a 站作品二 /cat/1').dx < left('a 站作品 /cat/1').dx, isTrue);

    await tester.tap(find.byKey(const ValueKey('moyi_filter_finished')));
    await tester.pumpAndSettle();

    // 完结：只留备注写着完结的 v2，v1 没了。
    expect(find.text('a 站作品二 /cat/1'), findsOneWidget);
    expect(find.text('a 站作品 /cat/1'), findsNothing);
  });

  testWidgets('类型下拉：选标签只留标签，选分类只留分类', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('moyi_type_filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moyi_type_tag')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('moyi_left_可看标签')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsNothing);
    expect(find.byKey(const ValueKey('moyi_left_中热丙')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('moyi_type_filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moyi_type_cat')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_可看标签')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('moyi_type_filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('moyi_type_all')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('moyi_left_热门甲')), findsOneWidget);
    expect(find.byKey(const ValueKey('moyi_left_可看标签')), findsOneWidget);
  });
}

class _FakeClient extends DramaSiteContentClient {
  _FakeClient(this.siteId);

  final String siteId;

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('cat1', '本站热'),
    DramaSiteCategory('cat2', '本站主题'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (categoryId == '/cat/1') {
      return DramaSiteCatalogPage(
        items: const [
          DramaSiteItem(
            id: 'v1',
            title: 'a 站作品 /cat/1',
            cover: '',
            remark: '更新至12集 高清',
          ),
          DramaSiteItem(
            id: 'v2',
            title: 'a 站作品二 /cat/1',
            cover: '',
            remark: '2026-11-09 完结',
          ),
        ],
        hasMore: false,
      );
    }
    return DramaSiteCatalogPage(
      items: [
        DramaSiteItem(
          id: 'v1',
          title: '$siteId 站作品 $categoryId',
          cover: '',
          remark: '更新至12集',
        ),
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
