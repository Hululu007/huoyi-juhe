import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 切换站点弹窗（两区版）预览图：测试渲染出 PNG，不构建整包。
/// 对照魔蚁那 4 张（内置区 / 导入区 / 卸载确认 / 短剧区）。
///
/// 测试环境默认字体没有中文会出方框，这里先把系统里的
/// Noto Sans CJK SC 载进来当主题字体，字才能正常显示。

const _filmEntries = <SiteGridEntry>[
  (
    id: 'b-video-1',
    name: '内置影视一',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.video,
  ),
  (
    id: 'b-video-2',
    name: '内置影视二',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.video,
  ),
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
  (
    id: 'i-mid',
    name: '导入午夜站',
    zone: SiteGridZone.import,
    group: SiteGridGroup.midnight,
  ),
];

const _shortDramaEntries = <SiteGridEntry>[
  (
    id: 'b-drama-1',
    name: '红果短剧',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'b-drama-2',
    name: '番茄短剧',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'b-drama-3',
    name: '黄果短剧',
    zone: SiteGridZone.builtin,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'i-drama-1',
    name: '导入短剧一',
    zone: SiteGridZone.import,
    group: SiteGridGroup.shortDrama,
  ),
  (
    id: 'i-drama-2',
    name: '导入短剧二',
    zone: SiteGridZone.import,
    group: SiteGridGroup.shortDrama,
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
  testWidgets('预览：切换站点弹窗·内置区', (tester) async {
    await _pumpPreviewHost(
      tester,
      _filmEntries,
      selectedId: 'b-video-1',
    );
    expect(find.text('内置区（4）'), findsOneWidget);
    expect(find.text('视频 2'), findsOneWidget);
    expect(find.text('午夜 2'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_zone_builtin',
    );
  });

  testWidgets('预览：切换站点弹窗·导入区', (tester) async {
    await _pumpPreviewHost(
      tester,
      _filmEntries,
      initialZone: SiteGridZone.import,
    );
    expect(find.text('导入区（2）'), findsOneWidget);
    expect(find.text('导入影视站'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_zone_import',
    );
  });

  testWidgets('预览：切换站点弹窗·删除导入站确认', (tester) async {
    await _pumpPreviewHost(
      tester,
      _filmEntries,
      initialZone: SiteGridZone.import,
    );
    await tester.longPress(find.text('导入影视站'));
    await tester.pumpAndSettle();
    expect(find.text('删除导入站'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_uninstall_confirm',
    );
  });

  testWidgets('预览：切换站点弹窗·短剧区', (tester) async {
    await _pumpPreviewHost(
      tester,
      _shortDramaEntries,
      selectedId: 'b-drama-1',
    );
    expect(find.text('内置区（3）'), findsOneWidget);
    expect(find.text('短剧 3'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('site-picker-preview'),
      'site_picker_zone_short_drama',
    );
  });
}
