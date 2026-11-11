import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/cultivation_titles_page.dart';
import 'package:fqapp/services/cultivation.dart';

Future<void> _pumpPage(
  WidgetTester tester,
  CultivationSnapshot snapshot,
) async {
  // 画布加高到能放下标题栏 + 14 行（14 × 72），这样所有行都在
  // 视口里，首次进页的自动滚动也不会把行滚出视口。
  await tester.binding.setSurfaceSize(const Size(400, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(home: CultivationTitlesPage(snapshot: snapshot)),
  );
  // 称号特效是循环动画，不能用 pumpAndSettle。
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('榜单共 14 行，每行有名次、称号、所需修为与境界', (tester) async {
    const snapshot = CultivationSnapshot(bonusXp: 1200, sect: '掩月宗');
    await _pumpPage(tester, snapshot);

    expect(find.text('称号排行'), findsOneWidget);
    for (var rank = 1; rank <= 14; rank++) {
      expect(
        find.byKey(ValueKey('cultivation_title_row_$rank')),
        findsOneWidget,
      );
    }
    // 无称号的行写「—」：按榜单现算（不写死行数，榜单加称号时
    // 也不用改单测）。
    final noTitleCount =
        cultivationTitleLadder().where((t) => !t.hasTitle).length;
    expect(find.text('—'), findsNWidgets(noTitleCount));
    expect(find.text('掩月宗精英'), findsOneWidget);
    expect(find.text('0 修为 · 炼气期'), findsOneWidget);
    expect(find.text('300 修为 · 筑基期'), findsOneWidget);
    expect(find.text('30000 修为 · 合体期'), findsOneWidget);
    expect(find.text('3200000 修为 · 道祖'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修为 1200 时当前行是结丹期，标「当前」', (tester) async {
    const snapshot = CultivationSnapshot(bonusXp: 1200, sect: '掩月宗');
    await _pumpPage(tester, snapshot);

    expect(find.text('当前'), findsOneWidget);
    // 当前行是第 3 行（结丹期），「当前」标记与「掩月宗精英」
    // 在同一行里。
    final row = find.byKey(const ValueKey('cultivation_title_row_3'));
    expect(find.descendant(of: row, matching: find.text('当前')),
        findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('掩月宗精英')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('修为 1200 时已达成与未达成状态分得对', (tester) async {
    const snapshot = CultivationSnapshot(bonusXp: 1200, sect: '掩月宗');
    await _pumpPage(tester, snapshot);

    // 已达成：炼气期（0）、筑基期（300）两行；结丹期（1000）是
    // 当前行，标「当前」不标「已达成」。
    expect(find.text('已达成'), findsNWidgets(2));
    // 未达成：其余 11 行。
    expect(find.text('未达成'), findsNWidgets(11));
    expect(tester.takeException(), isNull);
  });

  testWidgets('修为 0 时当前行是炼气期，没有已达成行', (tester) async {
    const snapshot = CultivationSnapshot(bonusXp: 0, sect: '黄枫谷');
    await _pumpPage(tester, snapshot);

    expect(find.text('当前'), findsOneWidget);
    expect(find.text('已达成'), findsNothing);
    expect(find.text('未达成'), findsNWidgets(13));
    final row = find.byKey(const ValueKey('cultivation_title_row_1'));
    expect(find.descendant(of: row, matching: find.text('当前')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('前三特效称号标名次：道祖第 1、大罗第 2、太乙第 3 待起名',
      (tester) async {
    const snapshot = CultivationSnapshot(bonusXp: 0, sect: '黄枫谷');
    await _pumpPage(tester, snapshot);

    // 前三行（太乙 12、大罗 13、道祖 14）都标「前三特效」。
    expect(find.text('前三特效'), findsNWidgets(3));
    // 太乙的称号是占位，标「待起名」。
    expect(find.text('待起名'), findsOneWidget);
    final taiyiRow = find.byKey(const ValueKey('cultivation_title_row_12'));
    // 前三特效称号用描边 + 渐变 + 流光三层叠字，同一称号出现 3 次。
    expect(
      find.descendant(of: taiyiRow, matching: find.text('待补充·前三称号之三')),
      findsNWidgets(3),
    );
    expect(
      find.descendant(of: taiyiRow, matching: find.text('待起名')),
      findsOneWidget,
    );
    // 道祖行（第 14 行）是第 1 名，称号唯我独尊。
    final daozuRow = find.byKey(const ValueKey('cultivation_title_row_14'));
    expect(
      find.descendant(of: daozuRow, matching: find.text('唯我独尊')),
      findsNWidgets(3),
    );
    expect(
      find.descendant(of: daozuRow, matching: find.text('1')),
      findsOneWidget,
    );
    // 大罗行（第 13 行）是第 2 名，称号超凡入化。
    final daluoRow = find.byKey(const ValueKey('cultivation_title_row_13'));
    expect(
      find.descendant(of: daluoRow, matching: find.text('超凡入化')),
      findsNWidgets(3),
    );
    expect(
      find.descendant(of: daluoRow, matching: find.text('2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
