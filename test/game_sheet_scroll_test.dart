import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/game_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/game_service.dart';

/// 游戏弹窗滚动回归：竖滑只滚内容，不伸缩弹窗、不关弹窗。
///
/// 背景：原来 `_openSheet` 用 DraggableScrollableSheet
/// （initial 0.72 / min 0.4 / max 0.92）包 SingleChildScrollView，
/// 竖滑先被弹窗伸缩吃掉，内容要等弹窗撑到顶才开始滚；滑到底还把
/// 弹窗收掉、看着像页面被刷新。现在是普通 SingleChildScrollView
/// （高度按内容走、上限 0.92 屏），下滑关闭禁掉（enableDrag:
/// false），关弹窗走标题栏 ×、点弹窗外面或返回键。
Future<void> _pumpGamePage(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GamePage(
          active: false,
          onExit: () {},
          onOpenFilmTab: () {},
          onOpenDramaTab: () {},
          onSwitchToVideo: () {},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _openSheet(WidgetTester tester, String diamondLabel) async {
  await tester.tap(find.text(diamondLabel));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 500));
}

/// 弹窗里外层滚动的位置（SingleChildScrollView 自带，未外挂
/// controller）。从弹窗标题向上找祖先 Scrollable，避免命中内层
/// GridView 自带的 Scrollable。
ScrollPosition _sheetPosition(WidgetTester tester, Finder insideSheet) {
  final scrollable = find.ancestor(
    of: insideSheet,
    matching: find.byType(Scrollable),
  );
  final state = tester.state<ScrollableState>(scrollable);
  return state.position;
}

Future<void> _tearDownPage(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: SizedBox())),
  );
  await tester.pump(const Duration(seconds: 3));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await GameService.instance.resetForTest();
    await GameService.instance.ensureInitialized();
  });

  tearDown(() async {
    await GameService.instance.resetForTest();
    await CultivationService.instance.resetForTest();
  });

  group('游戏弹窗滚动', () {
    testWidgets('任务弹窗：上滑滚内容，下滑到顶不关弹窗，点 × 关闭',
        (tester) async {
      await _pumpGamePage(tester);
      await _openSheet(tester, '任务');
      expect(find.text('任务 · 主线推图'), findsOneWidget);

      final scrollable = find.byType(SingleChildScrollView);
      expect(scrollable, findsOneWidget);
      expect(
        _sheetPosition(tester, find.text('任务 · 主线推图')).maxScrollExtent,
        greaterThan(0),
      );

      // 上滑：内容要跟着滚满拖动的距离（原来先被弹窗伸缩吃掉）。
      await tester.timedDrag(
        scrollable,
        const Offset(0, -400),
        const Duration(milliseconds: 300),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        _sheetPosition(tester, find.text('任务 · 主线推图')).pixels,
        greaterThan(300),
      );

      // 滑回顶部，再往下猛滑：弹窗不该被收掉或关掉。
      await tester.timedDrag(
        scrollable,
        const Offset(0, 800),
        const Duration(milliseconds: 300),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(_sheetPosition(tester, find.text('任务 · 主线推图')).pixels, 0);
      await tester.fling(scrollable, const Offset(0, 500), 800);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('任务 · 主线推图'), findsOneWidget);

      // 标题栏 × 关弹窗。
      await tester.tap(find.byIcon(LucideIcons.x));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('任务 · 主线推图'), findsNothing);

      await _tearDownPage(tester);
    });

    testWidgets('爬塔弹窗：30 层能一直上滑滚到底', (tester) async {
      await _pumpGamePage(tester);
      await _openSheet(tester, '爬塔');
      expect(find.textContaining('试炼塔'), findsOneWidget);

      final scrollable = find.byType(SingleChildScrollView);
      expect(scrollable, findsOneWidget);

      // 多次上滑：offset 一直涨，且能滚到接近底部。
      var lastOffset =
          _sheetPosition(tester, find.textContaining('试炼塔')).pixels;
      for (var i = 0; i < 5; i++) {
        await tester.timedDrag(
          scrollable,
          const Offset(0, -500),
          const Duration(milliseconds: 300),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          _sheetPosition(tester, find.textContaining('试炼塔')).pixels,
          greaterThanOrEqualTo(lastOffset),
        );
        lastOffset =
            _sheetPosition(tester, find.textContaining('试炼塔')).pixels;
      }
      expect(lastOffset, greaterThan(0));
      expect(
        _sheetPosition(tester, find.textContaining('试炼塔'))
                .maxScrollExtent -
            lastOffset,
        lessThan(500),
      );

      await _tearDownPage(tester);
    });

    testWidgets('功能菜单：内容短，弹窗按内容收窄、不撑满屏', (tester) async {
      await _pumpGamePage(tester);
      await _openSheet(tester, '功能');
      expect(find.text('商城'), findsOneWidget);

      final scrollable = find.byType(SingleChildScrollView);
      expect(scrollable, findsOneWidget);
      // 9 个功能格约 300 多 px 高，弹窗不应撑到 0.92 屏（776px）。
      expect(tester.getSize(scrollable).height, lessThan(600));
      expect(
        _sheetPosition(
          tester,
          find.descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.text('功能'),
          ),
        ).maxScrollExtent,
        0,
      );

      await _tearDownPage(tester);
    });
  });
}
