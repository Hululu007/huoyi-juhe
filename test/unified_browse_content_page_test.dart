import 'dart:async';

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
    expect(find.text('站4作品甲'), findsNothing);
    expect(find.text('站5作品甲'), findsNothing);
    // 还剩 2 站，加载更多按钮显示余数：把视口拉高到装得下
    // 首批 + 按钮再断言——滚到底会触发自动加载，不能先滚。
    await tester.binding.setSurfaceSize(const Size(400, 1300));
    await tester.pumpAndSettle();
    expect(find.textContaining('还剩 2 站'), findsOneWidget);
  });

  testWidgets('滑到底自动取下一批站点，不用点按钮', (tester) async {
    await pump(tester, entries(6), itemsBySite: twoItemsPerSite(6));

    expect(find.text('站4作品甲'), findsNothing);
    // 往上滑到底，第二批自动取来，不点「加载更多站点」按钮。
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

  // ---- 加载速度批（与频道分类页同款慢病同修）----

  Future<void> pumpCustom(
    WidgetTester tester,
    List<UnifiedCategorySite> entries,
    DramaSiteContentClient? Function(String siteId) clientFor, {
    Size size = const Size(400, 1600),
  }) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(
      MaterialApp(
        home: UnifiedBrowseContentPage(
          title: '测试分类',
          entries: entries,
          clientForSite: clientFor,
        ),
      ),
    );
  }

  Map<String, List<DramaSiteItem>> oneItemPerSite(int count) => {
    for (var i = 0; i < count; i++)
      'site_$i': [DramaSiteItem(id: 'v$i', title: '站$i作品', cover: '')],
  };

  testWidgets('逐站出结果：快站先上屏，不等同批慢站', (tester) async {
    final control = _ClientControl();
    final items = oneItemPerSite(4);
    await pumpCustom(
      tester,
      entries(4),
      (siteId) => _ScriptedClient(
        items[siteId]!,
        control: control,
        delay: siteId == 'site_1'
            ? const Duration(seconds: 3)
            : Duration.zero,
      ),
    );
    await tester.pump();
    await tester.pump();

    // 慢站（3 秒）还没回，同批快站作品已经上屏（旧实现 Future.wait
    // 等整批 settle，这里只有转圈）。
    expect(find.text('站0作品'), findsOneWidget);
    expect(find.text('站2作品'), findsOneWidget);
    expect(find.text('站1作品'), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(find.text('站1作品'), findsOneWidget);
    // 后到的慢站按入口序插回中间，不排到最后。
    final y0 = tester.getTopLeft(find.text('站0作品')).dy;
    final y1 = tester.getTopLeft(find.text('站1作品')).dy;
    final y2 = tester.getTopLeft(find.text('站2作品')).dy;
    expect(y0 < y1 && y1 < y2, isTrue);
  });

  testWidgets('部分站没响应：内容先出，计数不等全批 settle', (tester) async {
    final control = _ClientControl();
    final items = oneItemPerSite(4);
    await pumpCustom(
      tester,
      entries(4),
      (siteId) => _ScriptedClient(
        items[siteId]!,
        control: control,
        fails: siteId == 'site_1',
        delay: siteId == 'site_2'
            ? const Duration(seconds: 3)
            : Duration.zero,
      ),
    );
    await tester.pump();
    await tester.pump();

    // 慢站还没回：快站内容已出，失败站的计数已经更新（旧实现要
    // 等整批 settle 才一起记账，屏上只有转圈）。
    expect(find.text('站0作品'), findsOneWidget);
    expect(find.text('站2作品'), findsNothing);
    expect(find.text('1 个站取不到，已跳过'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('站2作品'), findsOneWidget);
  });

  testWidgets('站正常返回空页不算没响应', (tester) async {
    final control = _ClientControl();
    final items = oneItemPerSite(4);
    await pumpCustom(
      tester,
      entries(4),
      (siteId) => _ScriptedClient(
        siteId == 'site_0' ? const [] : items[siteId]!,
        control: control,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('站1作品'), findsOneWidget);
    // 空页是正常响应，不进没响应计数、不出页脚提示（旧实现把
    // 空页与取不到混为一谈，会虚报 1 个站取不到）。
    expect(find.textContaining('个站取不到'), findsNothing);
  });

  testWidgets('看过的汇总页再进：缓存先出，后台刷新', (tester) async {
    final control = _ClientControl();
    final items = twoItemsPerSite(4);
    // 同一个注入对象两次进页：缓存键相同（生产路径无注入，
    // 键是标题+站签名，效果一致）。
    DramaSiteContentClient? clientFor(String siteId) =>
        _ScriptedClient(items[siteId] ?? const [], control: control);

    await pumpCustom(tester, entries(4), clientFor);
    await tester.pumpAndSettle();
    expect(find.text('站0作品甲'), findsOneWidget);
    final callsAfterFirst = control.calls;
    expect(callsAfterFirst, 4);

    await tester.pumpWidget(const SizedBox.shrink());

    // 第二次进页时把刷新挂住：缓存内容应立刻在屏、无转圈。
    control.gate = Completer<void>();
    await pumpCustom(tester, entries(4), clientFor);
    await tester.pump();
    expect(find.text('站0作品甲'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    control.gate!.complete();
    control.gate = null;
    await tester.pump();
    await tester.pump();
    // 后台刷新确实又逐站取过一轮，内容不变。
    expect(control.calls, greaterThan(callsAfterFirst));
    expect(find.text('站0作品甲'), findsOneWidget);
  });
}

/// 可控时序的假客户端共用控制器：计数 catalog 调用、可挂闸。
class _ClientControl {
  Completer<void>? gate;
  int calls = 0;
}

/// 可控时序的假客户端（加载速度批用）：可延迟、可失败、可挂闸，
/// 取数行为经 [_ClientControl] 在测试中途切换。
class _ScriptedClient extends DramaSiteContentClient {
  _ScriptedClient(
    this.items, {
    required this.control,
    this.delay = Duration.zero,
    this.fails = false,
  });

  final List<DramaSiteItem> items;
  final _ClientControl control;
  final Duration delay;
  final bool fails;

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    control.calls++;
    final gate = control.gate;
    if (gate != null) await gate.future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
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
