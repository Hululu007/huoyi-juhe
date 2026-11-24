import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 跟进批预览图：用户导入站进影视/午夜切换器后的样子（测试渲染出 PNG）。
///
/// 条目按真实分区拼：内置区只有午夜 jar 站 2 个（核心影视站
/// hgdj/hgdj58/hgdjv 是短剧站，仍不在视频组）；用户导入的影视站
/// 1 个进导入区·视频组。假站名，只验版式与分区。
/// 各单跑（整文件批量跑会卡在已知的 toImage 收尾挂起）。

const _followupEntries = <SiteGridEntry>[
  (
    id: 'b-mid-1',
    name: '午夜站一',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.midnight,
  ),
  (
    id: 'b-mid-2',
    name: '午夜站二',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.midnight,
  ),
  (
    id: 'i-video',
    name: '导入影视站',
    zone: SiteGridZone.import,
    group: SiteGridGroup.video,
  ),
];

/// 改前对照：只有内置午夜站，导入区是空的、视频组一个站都没有
/// （上一批交卷时的样子）。
const _beforeEntries = <SiteGridEntry>[
  (
    id: 'b-mid-1',
    name: '午夜站一',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.midnight,
  ),
  (
    id: 'b-mid-2',
    name: '午夜站二',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.midnight,
  ),
];

Future<void> _capture(
  WidgetTester tester,
  ValueKey<String> boundaryKey,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> _pumpPreviewHost(
  WidgetTester tester,
  List<SiteGridEntry> entries, {
  SiteGridZone initialZone = SiteGridZone.builtin,
  String? selectedId,
}) async {
  await loadPreviewFonts(tester);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey<String>('site-picker-preview'),
      child: MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansCJK',
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          backgroundColor: const Color(0xFF0F0F14),
          body: Center(
            child: Builder(
              builder: (buttonContext) => TextButton(
                onPressed: () async {
                  await showSiteGridDialog(
                    context: buttonContext,
                    sites: entries,
                    selectedId: selectedId,
                    initialZone: initialZone,
                    onDeleteSite: (_) async => true,
                  );
                },
                child: const Text('打开切换站点'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('打开切换站点'));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('site-grid-dialog')), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('预览（跟进）：导入区有用户导入站·视频组 1', (tester) async {
    await _pumpPreviewHost(
      tester,
      _followupEntries,
      initialZone: SiteGridZone.import,
      selectedId: 'i-video',
    );
    expect(find.text('导入区（1）'), findsOneWidget);
    expect(find.text('视频 1'), findsOneWidget);
    expect(find.text('导入影视站'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_followup_import_filled',
    );
  });

  testWidgets('预览（跟进）：视频组改前——导入区空、视频组无站', (tester) async {
    await _pumpPreviewHost(
      tester,
      _beforeEntries,
      initialZone: SiteGridZone.import,
    );
    expect(find.text('导入区（0）'), findsOneWidget);
    expect(find.text('导入区还没有站，去「站源管理」导入一个'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_followup_video_group_before',
    );
  });

  testWidgets('预览（跟进）：长按删导入站确认', (tester) async {
    await _pumpPreviewHost(
      tester,
      _followupEntries,
      initialZone: SiteGridZone.import,
    );
    await tester.longPress(find.text('导入影视站'));
    await tester.pumpAndSettle();
    expect(find.text('删除导入站'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_followup_delete_confirm',
    );
  });

  testWidgets('预览（跟进）：内置区仍只有午夜组、视频组不在此区', (tester) async {
    await _pumpPreviewHost(
      tester,
      _followupEntries,
      selectedId: 'b-mid-1',
    );
    expect(find.text('内置区（2）'), findsOneWidget);
    expect(find.text('午夜 2'), findsOneWidget);
    expect(find.textContaining('视频'), findsNothing);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_followup_builtin_midnight_only',
    );
  });
}
