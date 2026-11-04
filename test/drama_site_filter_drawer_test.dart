import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/xbpq_content.dart';
import 'package:fqapp/widgets/home/drama_site_filter_drawer.dart';

void main() {
  testWidgets('筛选抽屉：分组标题与选项齐全，点选/清除/完成回调正确', (tester) async {
    final picked = <String>[];
    var cleared = false;
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DramaSiteFilterDrawer(
            groups: const [
              XbpqFilterGroup('类型', [
                XbpqFilterOption('全部', ''),
                XbpqFilterOption('都市', 'city'),
              ]),
              XbpqFilterGroup('年份', [
                XbpqFilterOption('全部', ''),
                XbpqFilterOption('2024', '2024'),
              ]),
            ],
            selected: const {'类型': 'city'},
            onSelected: (groupKey, value) => picked.add('$groupKey=$value'),
            onClear: () => cleared = true,
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    expect(find.text('筛选·1'), findsOneWidget);
    expect(find.text('类型'), findsOneWidget);
    expect(find.text('年份'), findsOneWidget);
    expect(find.text('都市'), findsOneWidget);

    await tester.tap(find.text('2024'));
    expect(picked, ['年份=2024']);

    await tester.tap(find.text('清除筛选'));
    expect(cleared, isTrue);

    await tester.tap(find.text('完成'));
    expect(closed, isTrue);
  });
}
