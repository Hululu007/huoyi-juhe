import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/desktop_app_frame.dart';

void main() {
  testWidgets('frame title is 火蚁聚合; global search hides on the drama tab', (
    tester,
  ) async {
    desktopTab.value = 0;
    addTearDown(() => desktopTab.value = 0);
    await tester.pumpWidget(
      const MaterialApp(
        home: DesktopAppFrame(child: SizedBox.expand()),
      ),
    );
    await tester.pump();

    expect(find.text('火蚁聚合'), findsOneWidget);
    expect(find.text('番茄小铺'), findsNothing);
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);

    // 短剧分区自带搜索入口：壳层全局搜索隐藏，只留一处搜索。
    // 短剧是 desktopTab 下标 2（0 首页、1 阅读/书架、2 短剧）。
    desktopTab.value = 2;
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsNothing);
    expect(find.text('火蚁聚合'), findsOneWidget);

    // 切回其它分区，全局搜索恢复。
    desktopTab.value = 0;
    await tester.pump();
    expect(find.byKey(const Key('desktop-search')), findsOneWidget);
  });
}
