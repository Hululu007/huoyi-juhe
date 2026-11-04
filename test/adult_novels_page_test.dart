import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/services/midnight_gate.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    MidnightGate.activated.value = false;
  });

  testWidgets('门禁未开：聚合页只显示锁定页，不取数', (tester) async {
    MidnightGate.activated.value = false;
    await tester.pumpWidget(const MaterialApp(home: AdultNovelsPage()));
    await tester.pumpAndSettle();
    expect(find.text('午夜区未开启'), findsOneWidget);
    expect(find.text('暂无成人小说'), findsNothing);
  });

  testWidgets('门禁已开、无成人源：小说 tab 显示空态与导入提示', (tester) async {
    MidnightGate.activated.value = true;
    await tester.pumpWidget(const MaterialApp(home: AdultNovelsPage()));
    await tester.pumpAndSettle();
    expect(find.text('暂无成人小说'), findsOneWidget);
    expect(find.text('可在设置 → 书源里导入成人源'), findsOneWidget);
  });

  testWidgets('入口：门禁未开不露，门禁已开出现', (tester) async {
    const sliver = MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [AdultNovelsEntrySliver()],
        ),
      ),
    );
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-novels-entry')), findsNothing);

    // 同一棵树重 pump 不重跑 initState：先 dispose 再重建；门禁单例已加载
    // 后 ensureLoaded 不重读偏好，这里直接改开关值测显隐逻辑。
    await tester.pumpWidget(const SizedBox.shrink());
    MidnightGate.activated.value = true;
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-novels-entry')), findsOneWidget);
  });
}
