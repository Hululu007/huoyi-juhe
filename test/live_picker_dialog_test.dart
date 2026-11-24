import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/source_picker_sheet.dart';

/// 公共弹窗独立测试：不经过 LivePage（编译图小），只验弹窗本体——
/// 28 个内置源全进弹窗、有导入源时分平台源 / 导入源两组、点 tile
/// 回源 id。页面级选源出频道由 live_picker_whoslib_test 覆盖。
void main() {
  Finder pickerTiles() => find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key as ValueKey<String>).value.startsWith('site-picker-row-'),
  );

  /// 把弹窗列表往下拖，直到 [finder] 出现（ListView 懒加载，
  /// 下方的组不滚进去不会建出来）。
  Future<void> scrollPickerIntoView(
    WidgetTester tester,
    Finder finder,
  ) async {
    for (var i = 0; i < 20; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.drag(
        find.byKey(const ValueKey('site-picker-list')),
        const Offset(0, -300),
      );
      await tester.pump();
    }
  }

  /// 打开弹窗，返回弹窗关闭时回传的源 id（点 tile 才完成）。
  Future<Future<String?>> openPicker(
    WidgetTester tester, {
    bool withImported = false,
  }) async {
    final picked = Completer<String?>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  picked.complete(
                    await showSitePickerDialog(
                      context,
                      sectionName: '直播',
                      currentId: 'whos_lib',
                      groups: [
                        SourcePickerGroup(
                          title: withImported ? '平台源' : '',
                          entries: [
                            for (final source in LiveSources.builtin)
                              SourcePickerEntry(
                                id: source.id,
                                name: source.name,
                              ),
                          ],
                        ),
                        if (withImported)
                          const SourcePickerGroup(
                            title: '导入源',
                            entries: [
                              SourcePickerEntry(
                                id: 'imported',
                                name: '导入的频道',
                              ),
                            ],
                          ),
                      ],
                    ),
                  );
                },
                child: const Text('开弹窗'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开弹窗'));
    await tester.pumpAndSettle();
    expect(find.text('切换直播源'), findsOneWidget);
    return picked.future;
  }

  testWidgets('弹窗列出全部 28 个内置源，首项内置片库', (tester) async {
    await openPicker(tester);
    expect(pickerTiles(), findsNWidgets(28));
    expect(find.text('内置片库'), findsOneWidget);
    expect(find.text('日本有码'), findsOneWidget);
    expect(find.text('欧美大屌'), findsOneWidget);
    expect(find.text('哔哩哔哩'), findsOneWidget);
    expect(find.text('平台源'), findsNothing);
  });

  testWidgets('有导入源时分平台源 / 导入源两组，点 tile 回 id', (tester) async {
    final future = await openPicker(tester, withImported: true);
    expect(find.text('平台源 28'), findsOneWidget);
    // 导入组在列表下方：ListView 懒加载，滚到 tile 建出来为止。
    await scrollPickerIntoView(
      tester,
      find.byKey(const ValueKey('site-picker-row-imported')),
    );
    await tester.pumpAndSettle();
    expect(find.text('导入源 1'), findsOneWidget);
    expect(pickerTiles(), findsNWidgets(29));
    await tester.ensureVisible(
      find.byKey(const ValueKey('site-picker-row-m3u_oumei')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('site-picker-row-m3u_oumei')),
    );
    await tester.pumpAndSettle();
    expect(await future, 'm3u_oumei');
  });

  testWidgets('搜索过滤：输“日本”只剩两条有码源', (tester) async {
    await openPicker(tester);
    await tester.enterText(
      find.byKey(const ValueKey('site-picker-search')),
      '日本',
    );
    await tester.pumpAndSettle();
    expect(find.text('日本有码'), findsOneWidget);
    expect(find.text('日本有码 2'), findsOneWidget);
    expect(find.text('欧美大屌'), findsNothing);
  });
}
