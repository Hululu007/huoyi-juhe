import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/adult_novels_page.dart';
import 'package:fqapp/services/source_registry.dart';

void main() {
  testWidgets('无门禁：聚合页直接显示空态，不取数也不锁', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AdultNovelsPage()),
    );
    // 核心取数走真实网络（本机无核心在跑）：先用真实时间等取数落空
    // （后端启动超时 15 秒 + 单站超时 15 秒，20 秒足够），再泵一帧刷新。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 20));
    });
    await tester.pump();
    expect(find.text('暂无成人小说'), findsOneWidget);
    expect(find.text('核心站与已导入的成人源暂无内容'), findsOneWidget);
    expect(find.text('午夜区未开启'), findsNothing);
  });

  testWidgets('入口：不再设门，直接出现', (tester) async {
    const sliver = MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [AdultNovelsEntrySliver()],
        ),
      ),
    );
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adult-novels-entry')), findsOneWidget);
  });

  testWidgets('漫画入口：标题与键各是自己的', (tester) async {
    const sliver = MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [AdultNovelsEntrySliver(type: ContentType.comic)],
        ),
      ),
    );
    await tester.pumpWidget(sliver);
    await tester.pumpAndSettle();
    expect(find.text('成人漫画'), findsOneWidget);
    expect(find.byKey(const Key('adult-entry-comic')), findsOneWidget);
  });
}
