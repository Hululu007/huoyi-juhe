import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/bottom_nav_manage_page.dart';
import 'package:fqapp/services/bottom_nav_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<BottomNavPrefs> seededPrefs(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = BottomNavPrefs();
    await prefs.load();
    return prefs;
  }

  Widget harness(BottomNavPrefs prefs) {
    return MaterialApp(
      home: BottomNavManagePage(prefs: prefs, actressUnlocked: false),
    );
  }

  testWidgets('两区列表正确，演员库行有未解锁标注', (tester) async {
    final prefs = await seededPrefs(<String, Object>{
      kBottomNavHiddenKey: ['live'],
    });
    await tester.pumpWidget(harness(prefs));
    await tester.pump();

    expect(find.text('当前显示'), findsOneWidget);
    expect(find.text('已隐藏'), findsOneWidget);
    expect(find.text('未解锁 · 到元婴期开放'), findsOneWidget);
    // 直播只在已隐藏区出现一次，其余页签在当前显示区。
    expect(find.text('直播'), findsOneWidget);
    expect(find.text('演员库'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('隐藏'), findsNWidgets(6));
  });

  testWidgets('点恢复后页签回可见区', (tester) async {
    // 放大视口让已隐藏区整行落在屏内（默认 800x600 时恢复钮在视口外 1px）。
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final prefs = await seededPrefs(<String, Object>{
      kBottomNavHiddenKey: ['live'],
    });
    await tester.pumpWidget(harness(prefs));
    await tester.pump();

    await tester.tap(find.text('恢复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(prefs.visibleIds, contains('live'));
    expect(prefs.state.hidden, isEmpty);
    expect(find.text('恢复'), findsNothing);
    expect(find.text('暂无隐藏的页签'), findsOneWidget);
  });

  testWidgets('只剩 1 个可见时点隐藏弹提示且状态不变', (tester) async {
    final prefs = await seededPrefs(<String, Object>{
      kBottomNavHiddenKey: [
        'game',
        'drama',
        'actress',
        'live',
        'library',
        'mine',
      ],
    });
    await tester.pumpWidget(harness(prefs));
    await tester.pump();
    expect(prefs.visibleIds, ['home']);

    await tester.tap(find.text('隐藏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('至少保留一个页签'), findsOneWidget);
    expect(prefs.visibleIds, ['home']);
    expect(prefs.state.hidden, hasLength(6));
  });

  testWidgets('恢复默认布局后回默认顺序且隐藏清空', (tester) async {
    final prefs = await seededPrefs(<String, Object>{
      kBottomNavOrderKey: ['mine', 'home', 'game', 'drama', 'actress', 'live', 'library'],
      kBottomNavHiddenKey: ['live', 'game'],
    });
    await tester.pumpWidget(harness(prefs));
    await tester.pump();
    expect(prefs.visibleIds.first, 'mine');

    await tester.scrollUntilVisible(find.text('恢复默认布局'), 200);
    await tester.tap(find.text('恢复默认布局'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('恢复默认'), findsOneWidget);

    await tester.tap(find.text('恢复默认'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(prefs.state.order, kBottomNavDefaultOrder);
    expect(prefs.state.hidden, isEmpty);
    expect(prefs.visibleIds, kBottomNavDefaultOrder);
  });
}
