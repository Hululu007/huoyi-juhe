import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/editable_bottom_nav_bar.dart';

void main() {
  const tabs3 = <BottomNavTabDef>[
    BottomNavTabDef(id: 'game', icon: Icons.sports_esports, label: '游戏'),
    BottomNavTabDef(id: 'home', icon: Icons.home, label: '首页'),
    BottomNavTabDef(id: 'mine', icon: Icons.person, label: '我的'),
  ];

  Widget harness({
    required bool editing,
    required List<String> calls,
    List<BottomNavTabDef> tabs = tabs3,
    String? selectedId = 'home',
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: EditableBottomNavBar(
            tabs: tabs,
            selectedId: selectedId,
            editing: editing,
            selectedColor: Colors.blue,
            unselectedColor: Colors.grey,
            indicatorColor: Colors.blue.withValues(alpha: 0.2),
            onSelect: (id) => calls.add('select:$id'),
            onEnterEdit: () => calls.add('enterEdit'),
            onHide: (id) => calls.add('hide:$id'),
            onMove: (id, target) => calls.add('move:$id:$target'),
          ),
        ),
      ),
    );
  }

  testWidgets('普通态点按回调对应 id', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(harness(editing: false, calls: calls));
    await tester.tap(find.byKey(const Key('bottom-nav-tab-mine')));
    await tester.pump();
    expect(calls, ['select:mine']);
  });

  testWidgets('普通态长按回调 onEnterEdit', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(harness(editing: false, calls: calls));
    await tester.longPress(find.byKey(const Key('bottom-nav-tab-home')));
    await tester.pump();
    expect(calls, ['enterEdit']);
  });

  testWidgets('编辑态：角标出现，点角标回调 onHide，点页签本体不切换页', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(harness(editing: true, calls: calls));
    expect(find.byKey(const Key('bottom-nav-hide-game')), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav-hide-home')), findsOneWidget);
    expect(find.byKey(const Key('bottom-nav-hide-mine')), findsOneWidget);

    await tester.tap(find.byKey(const Key('bottom-nav-hide-home')));
    await tester.pump();
    expect(calls, ['hide:home']);

    calls.clear();
    await tester.tap(find.byKey(const Key('bottom-nav-tab-game')));
    await tester.pump();
    expect(calls, isEmpty);
  });

  testWidgets('可见页签等分整行（3 个时也成立）', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(harness(editing: false, calls: calls));
    final widths = <double>[
      for (final id in ['game', 'home', 'mine'])
        tester.getSize(find.byKey(Key('bottom-nav-tab-$id'))).width,
    ];
    expect(widths[0], closeTo(widths[1], 1.0));
    expect(widths[1], closeTo(widths[2], 1.0));
    // 3 个页签时每个约占整行三分之一（窗口宽 800）。
    expect(widths[0], closeTo(800 / 3, 2.0));
  });

  testWidgets('选中 id 不在可见列表时无选中态也不崩', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      harness(editing: false, calls: calls, selectedId: 'actress'),
    );
    expect(find.byKey(const Key('bottom-nav-tab-home')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
