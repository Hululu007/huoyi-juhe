import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';

/// 视频列表滑到底自动加载下一页（2026-11-24 用户令）。
///
/// 覆盖：滑到底自动取下一页（不点按钮）、失败显示重试且点后继续、
/// 翻页去重、到底停住不再请求、切分类重置回第一页。
void main() {
  Future<void> pumpGrid(
    WidgetTester tester,
    _FakeGridClient client, {
    String categoryId = 'c1',
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 600);
    addTearDown(tester.view.reset);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DramaSiteGrid(
                siteId: 'test-site',
                categoryId: categoryId,
                gridWidth: 358,
                client: client,
                showFilterBar: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<DramaSiteItem> pageItems(String prefix, int count, {int start = 1}) => [
    for (var i = 0; i < count; i++)
      DramaSiteItem(id: '$prefix-${start + i}', title: '片$prefix-${start + i}', cover: ''),
  ];

  _FakeGridClient twoPageClient({Map<int, int> failCounts = const {}}) {
    return _FakeGridClient(
      pagesByCategory: {
        'c1': {
          1: (pageItems('一', 12), true),
          2: (pageItems('二', 12), false),
        },
        'c2': {
          1: (pageItems('甲', 12), true),
          2: (pageItems('乙', 12), false),
        },
      },
      failCounts: failCounts,
    );
  }

  testWidgets('滑到底自动加载下一页，不用点加载更多', (tester) async {
    final client = twoPageClient();
    await pumpGrid(tester, client);

    expect(find.text('片一-1'), findsOneWidget);
    expect(find.text('片二-1'), findsNothing);

    // 往上滑到底：第二页自动拼上来，全程没点按钮。
    await tester.scrollUntilVisible(find.text('片二-1'), 300);
    await tester.pumpAndSettle();
    expect(find.text('片二-1'), findsOneWidget);
    expect(find.text('片二-12'), findsOneWidget);
    // 第二页只请求一次：预取那次；滑到底直接拼预取结果，不再发请求。
    expect(
      client.catalogCalls.where((call) => call.$2 == 2).length,
      1,
    );
  });

  testWidgets('加载下一页失败显示重试，点重试后继续', (tester) async {
    // 第二页前两次请求都失败：预取一次、滑到底取一次；点重试第三次才通。
    final client = twoPageClient(failCounts: {2: 2});
    await pumpGrid(tester, client);

    await tester.scrollUntilVisible(find.text('加载失败，点我重试'), 300);
    await tester.pumpAndSettle();
    expect(find.text('加载失败，点我重试'), findsOneWidget);
    expect(find.text('片二-1'), findsNothing);

    await tester.tap(find.text('加载失败，点我重试'));
    await tester.pumpAndSettle();
    expect(find.text('片二-1'), findsOneWidget);
    // 已加载的卡片还在，列表没被失败冲掉：滚回顶部再看
    // （底部停留时首条已被 sliver 懒加载卸载）。
    await tester.scrollUntilVisible(find.text('片一-1'), -300);
    expect(find.text('片一-1'), findsOneWidget);
  });

  testWidgets('翻页去重：第二页里重复的视频只出一次', (tester) async {
    final client = _FakeGridClient(
      pagesByCategory: {
        'c1': {
          1: (pageItems('一', 12), true),
          // 第二页第一条与第一页第一条是同一部（同 id）。
          2: (
            [
              const DramaSiteItem(id: '一-1', title: '片一-1', cover: ''),
              ...pageItems('二', 11),
            ],
            false,
          ),
        },
      },
    );
    await pumpGrid(tester, client);

    await tester.scrollUntilVisible(find.text('片二-1'), 300);
    await tester.pumpAndSettle();
    // 重复的那条是第二页首条：如果没去重，它会出现在这里；
    // 第一页首条已滚出视口被卸载，不影响这个断言。
    expect(find.text('片一-1'), findsNothing);
    // 滚回顶部，原来的那条还在，只有一张。
    await tester.scrollUntilVisible(find.text('片一-1'), -300);
    expect(find.text('片一-1'), findsOneWidget);
  });

  testWidgets('到底显示没有更多了，不再请求下一页', (tester) async {
    final client = twoPageClient();
    await pumpGrid(tester, client);

    await tester.scrollUntilVisible(find.text('片二-1'), 300);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('没有更多了'), 300);
    expect(find.text('没有更多了'), findsOneWidget);
    expect(
      client.catalogCalls.where((call) => call.$2 == 3),
      isEmpty,
    );
  });

  testWidgets('切分类重置回第一页', (tester) async {
    final client = twoPageClient();
    await pumpGrid(tester, client, categoryId: 'c1');
    expect(find.text('片一-1'), findsOneWidget);

    final callsBeforeSwitch = client.catalogCalls.length;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DramaSiteGrid(
                siteId: 'test-site',
                categoryId: 'c2',
                gridWidth: 358,
                client: client,
                showFilterBar: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('片甲-1'), findsOneWidget);
    expect(find.text('片一-1'), findsNothing);

    final callsAfterSwitch = client.catalogCalls.sublist(callsBeforeSwitch);
    expect(callsAfterSwitch, contains(('c2', 1)));
    // 切分类后滑到底，取的是新分类的第二页，不是旧分类的。
    await tester.scrollUntilVisible(find.text('片乙-1'), 300);
    await tester.pumpAndSettle();
    expect(find.text('片乙-1'), findsOneWidget);
    expect(
      client.catalogCalls.sublist(callsBeforeSwitch),
      isNot(contains(('c1', 2))),
    );
  });
}

class _FakeGridClient extends DramaSiteContentClient {
  _FakeGridClient({required this.pagesByCategory, this.failCounts = const {}});

  /// categoryId -> page -> (items, hasMore)
  final Map<String, Map<int, (List<DramaSiteItem>, bool)>> pagesByCategory;

  /// page -> 该页先失败几次再成功（预取也算一次请求）。
  final Map<int, int> failCounts;

  final List<(String, int)> catalogCalls = [];
  final Map<int, int> _failuresLeft = {};

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('c1', '分类一'),
    DramaSiteCategory('c2', '分类二'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    catalogCalls.add((categoryId, page));
    final left = _failuresLeft.putIfAbsent(page, () => failCounts[page] ?? 0);
    if (left > 0) {
      _failuresLeft[page] = left - 1;
      throw StateError('page $page down');
    }
    final entry = pagesByCategory[categoryId]?[page];
    if (entry == null) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    return DramaSiteCatalogPage(items: entry.$1, hasMore: entry.$2);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      const DramaSiteDetail(id: '', title: '', cover: '', episodes: []);

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      const DramaPlaySource(url: '');
}
