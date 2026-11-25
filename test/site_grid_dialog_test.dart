import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 切换站点弹窗（两区版）测试：区签切区、左右滑切区、空区提示、
/// 搜索只过滤活动区、长按删/藏接线、当前站回落纯函数。

const _entries = <SiteGridEntry>[
  (
    id: 'b-drama',
    name: '红果短剧',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'b-video',
    name: '内置影视',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.video,
  ),
  (
    id: 'b-mid',
    name: '午夜内置',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.midnight,
  ),
  (
    id: 'i-drama',
    name: '导入短剧站',
    zone: SiteGridZone.import,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'i-video',
    name: '导入影视站',
    zone: SiteGridZone.import,
    group: SiteGridGroup.video,
  ),
];

class _Host extends StatefulWidget {
  const _Host({
    this.entries = _entries,
    this.initialZone = SiteGridZone.builtin,
    this.onDeleteSite,
  });

  final List<SiteGridEntry> entries;
  final SiteGridZone initialZone;
  final Future<bool> Function(SiteGridEntry entry)? onDeleteSite;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? picked;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          // showDialog 要的 context 必须在 MaterialApp 之下：直接用
          // State 的 context 会找不到 MaterialLocalizations，
          // 用 Builder 取按钮处的内层 context。
          child: Builder(
            builder: (buttonContext) => TextButton(
              onPressed: () async {
                final result = await showSiteGridDialog(
                  context: buttonContext,
                  sites: widget.entries,
                  initialZone: widget.initialZone,
                  onDeleteSite: widget.onDeleteSite,
                );
                setState(() => picked = result);
              },
              child: const Text('打开切换站点'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('打开切换站点'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('site-grid-dialog')), findsOneWidget);
}

/// 手机尺寸视口：弹窗列表是懒加载的 ListView，默认 800x600 测试窗
/// 下第三组在可视区外建不出来；用 390x844 真机尺寸让三组一次建全。
Future<void> _pumpHost(WidgetTester tester, _Host host) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(host);
}

void main() {
  group('区签与切区', () {
    testWidgets('区签带站数，点签切区', (tester) async {
      await _pumpHost(tester, const _Host());
      await _openDialog(tester);

      expect(find.text('内置区（3）'), findsOneWidget);
      expect(find.text('导入区（2）'), findsOneWidget);
      expect(find.text('红果短剧'), findsOneWidget);
      expect(find.text('导入影视站'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('site-grid-zone-import')));
      await tester.pumpAndSettle();
      expect(find.text('红果短剧'), findsNothing);
      expect(find.text('导入影视站'), findsOneWidget);
      expect(find.text('导入短剧站'), findsOneWidget);
    });

    testWidgets('左右滑切区', (tester) async {
      await _pumpHost(tester, const _Host());
      await _openDialog(tester);

      await tester.fling(
        find.byKey(const ValueKey('site-grid-dialog')),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('导入影视站'), findsOneWidget);
      expect(find.text('红果短剧'), findsNothing);

      await tester.fling(
        find.byKey(const ValueKey('site-grid-dialog')),
        const Offset(300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('红果短剧'), findsOneWidget);
      expect(find.text('导入影视站'), findsNothing);
    });

    testWidgets('区内分组标题「名 + 空格 + 数」', (tester) async {
      await _pumpHost(tester, const _Host());
      await _openDialog(tester);

      expect(find.text('短剧 1'), findsOneWidget);
      expect(find.text('视频 1'), findsOneWidget);
      expect(find.text('午夜 1'), findsOneWidget);
    });

    testWidgets('导入区空时给去处提示', (tester) async {
      await _pumpHost(
        tester,
        const _Host(
          entries: [
            (
              id: 'b-drama',
              name: '红果短剧',
              zone: SiteGridZone.builtin,
              group: SiteGridGroup.shortDrama,
            ),
          ],
          initialZone: SiteGridZone.import,
        ),
      );
      await _openDialog(tester);

      expect(
        find.text('导入区还没有站，去「站源管理」导入一个'),
        findsOneWidget,
      );
    });
  });

  group('搜索', () {
    testWidgets('搜索只过滤活动区，不跨区拉站', (tester) async {
      await _pumpHost(tester, const _Host());
      await _openDialog(tester);

      await tester.enterText(
        find.byKey(const ValueKey('site-grid-search')),
        '导入影视站',
      );
      await tester.pumpAndSettle();
      // 内置区里没有匹配的站。站名用行 key 断言：find.text 也会命中
      // 搜索框里的输入文本（EditableText），不能用来判站名在不在。
      expect(find.text('没有匹配的站点'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('site-grid-row-i-video')),
        findsNothing,
      );

      // 切到导入区：同一查询在新区里命中，不用重输。
      await tester.tap(find.byKey(const ValueKey('site-grid-zone-import')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('site-grid-row-i-video')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('site-grid-row-i-drama')),
        findsNothing,
      );
    });
  });

  group('长按删/藏', () {
    testWidgets('长按导入站弹删除确认，确认后调回调并摘行', (tester) async {
      final deleted = <SiteGridEntry>[];
      await _pumpHost(
        tester,
        _Host(
          initialZone: SiteGridZone.import,
          onDeleteSite: (entry) async {
            deleted.add(entry);
            return true;
          },
        ),
      );
      await _openDialog(tester);

      await tester.longPress(find.text('导入影视站'));
      await tester.pumpAndSettle();
      expect(find.text('删除导入站'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('site-grid-delete-confirm-ok')),
      );
      await tester.pumpAndSettle();
      expect(deleted.map((e) => e.id), ['i-video']);
      expect(find.text('导入影视站'), findsNothing);
      expect(find.text('导入短剧站'), findsOneWidget);
      // 弹窗还开着，站数跟着变。
      expect(find.text('导入区（1）'), findsOneWidget);
    });

    testWidgets('长按内置站弹隐藏确认，确认后调回调、行摘掉站不删',
        (tester) async {
      final handled = <SiteGridEntry>[];
      await _pumpHost(
        tester,
        _Host(
          onDeleteSite: (entry) async {
            handled.add(entry);
            return true;
          },
        ),
      );
      await _openDialog(tester);

      await tester.longPress(find.text('内置影视'));
      await tester.pumpAndSettle();
      expect(find.text('隐藏内置站'), findsOneWidget);
      expect(find.text('隐藏'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('site-grid-delete-confirm-ok')),
      );
      await tester.pumpAndSettle();
      expect(handled.map((e) => e.id), ['b-video']);
      expect(handled.single.zone, SiteGridZone.builtin);
      expect(find.text('内置影视'), findsNothing);
      expect(find.text('内置区（2）'), findsOneWidget);
    });

    testWidgets('确认框点取消不调回调、不摘行', (tester) async {
      var called = false;
      await _pumpHost(
        tester,
        _Host(
          initialZone: SiteGridZone.import,
          onDeleteSite: (_) async {
            called = true;
            return true;
          },
        ),
      );
      await _openDialog(tester);

      await tester.longPress(find.text('导入影视站'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('site-grid-delete-confirm-cancel')),
      );
      await tester.pumpAndSettle();
      expect(called, isFalse);
      expect(find.text('导入影视站'), findsOneWidget);
    });

    testWidgets('点站名选中并关闭，返回站 id', (tester) async {
      await _pumpHost(tester, const _Host());
      await _openDialog(tester);

      // 站卡改版后（封面区 + 站名）单卡更高，第三组要先滚到位再点。
      await tester.ensureVisible(find.text('午夜内置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('午夜内置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('site-grid-dialog')), findsNothing);
      final state = tester.state<_HostState>(find.byType(_Host));
      expect(state.picked, 'b-mid');
    });
  });

  group('resolveCurrentSiteId', () {
    test('当前站在表里就留着', () {
      expect(
        resolveCurrentSiteId('b', ['a', 'b', 'c']),
        'b',
      );
    });

    test('当前站不在表里就回落首站', () {
      expect(
        resolveCurrentSiteId('gone', ['a', 'b']),
        'a',
      );
    });

    test('表空了回 null，调用方保留旧站', () {
      expect(resolveCurrentSiteId('gone', []), isNull);
    });

    test('当前站为空也回落首站', () {
      expect(resolveCurrentSiteId(null, ['a', 'b']), 'a');
    });
  });
}
