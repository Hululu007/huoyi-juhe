import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/site_browse_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HierarchicalClient implements DramaSiteContentClient {
  @override
  Future<List<DramaSiteCategory>> categories() async {
    return const [
      DramaSiteCategory('m', '电影'),
      DramaSiteCategory('a', '动作', parentId: 'm', path: '电影/动作'),
      DramaSiteCategory('c', '喜剧', parentId: 'm', path: '电影/喜剧'),
      DramaSiteCategory('j', '剧集'),
      DramaSiteCategory('g', '国产', parentId: 'j', path: '剧集/国产'),
    ];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    const byCategory = {
      'm': ['电影片'],
      'a': ['动作片'],
      'c': ['喜剧片'],
      'j': ['剧集片'],
      'g': ['国产片'],
    };
    final titles = byCategory[categoryId] ?? const <String>[];
    return DramaSiteCatalogPage(
      items: [
        for (final title in titles)
          DramaSiteItem(id: title, title: title, cover: ''),
      ],
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    throw UnimplementedError();
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    throw UnimplementedError();
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async => const [];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('多级分类纯函数：顶级、子级、路径、层级判定', () {
    const cats = [
      DramaSiteCategory('m', '电影'),
      DramaSiteCategory('a', '动作', parentId: 'm', path: '电影/动作'),
      DramaSiteCategory('c', '喜剧', parentId: 'm', path: '电影/喜剧'),
      DramaSiteCategory('j', '剧集'),
      DramaSiteCategory('orphan', '孤儿', parentId: 'gone'),
    ];
    expect(browseHasHierarchy(cats), isTrue);
    expect(
      browseRoots(cats).map((c) => c.id),
      ['m', 'j', 'orphan'],
    );
    expect(
      browseChildren(cats, 'm').map((c) => c.id),
      ['a', 'c'],
    );
    expect(browsePath(cats, 'c'), ['m', 'c']);
    expect(browsePath(cats, 'missing'), isEmpty);
    expect(
      browseHasHierarchy(const [
        DramaSiteCategory('1', '电影'),
        DramaSiteCategory('2', '剧集'),
      ]),
      isFalse,
    );
  });

  Future<void> pumpUntilText(WidgetTester tester, String text) async {
    for (var i = 0; i < 30; i++) {
      if (find.text(text).evaluate().isNotEmpty) return;
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail('未出现 $text');
  }

  testWidgets('多级分类下钻：顶级行与子行分开，点叶子才切网格', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SiteBrowsePage(
          siteId: 'test_site',
          siteName: '测试站',
          client: _HierarchicalClient(),
          dbSink: MemoryM3uExportDb(),
        ),
      ),
    );
    // 初次打开默认选中第一个顶级：顶级行与它的子行都出现，网格是顶级内容。
    await pumpUntilText(tester, '电影片');
    expect(find.text('电影'), findsOneWidget);
    expect(find.text('剧集'), findsOneWidget);
    expect(find.text('动作'), findsOneWidget);
    expect(find.text('喜剧'), findsOneWidget);
    expect(find.text('国产'), findsNothing);
    // 点叶子：网格切到该叶子。
    await tester.tap(find.text('喜剧'));
    await pumpUntilText(tester, '喜剧片');
    // 点另一个顶级：子行换成它的孩子，网格先切到顶级本身。
    await tester.tap(find.text('剧集'));
    await pumpUntilText(tester, '剧集片');
    expect(find.text('国产'), findsOneWidget);
    expect(find.text('动作'), findsNothing);
    await tester.tap(find.text('国产'));
    await pumpUntilText(tester, '国产片');
  });
}
