@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/onekey_py_page.dart';
import 'package:fqapp/pages/source_management_page.dart';

/// 站源管理页 + 一键写PY页换肤预览图：第 27 轮背景全换漏掉的两处。
///
/// 做法：泵真实页面本体（SourceManagementPage / OneKeyPyPage），
/// 站源管理页用假数据种子（1 个 Python 小说站 + 1 个 JS 站 +
/// 1 个 MacCMS 站，见 SharedPreferences 的 juhe_custom_sources；
/// 内置短剧组走真实 dramaSites，第一站番茄短剧自带“检测”按钮），
/// 一键写PY页直接泵真实页。字体先载 NotoSerifCJK + MaterialIcons +
/// Lucide，否则中文与图标全是方框。
///
/// 主题用深色 + 金种子（与 AppTheme 深色档同款金主色 #D4AF37），
/// 所以图里“生成并导入”金按钮与开关金色与真机一致。
/// 两张 PNG 出到 ~/workspace/moyi_style_preview/（source_management /
/// onekey_py）。
final String _outDir = previewOutDir().path;

Future<void> _loadFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester, serif: true, lucide: true);
}


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
      final file = File('$_outDir/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

ThemeData _previewTheme() => ThemeData(
  fontFamily: 'NotoSerifCJK',
  brightness: Brightness.dark,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFFD4AF37),
    brightness: Brightness.dark,
  ),
);

void main() {
  testWidgets('预览：站源管理页换肤（深紫蓝渐变底 + 深紫卡行 + 金开关）', (
    tester,
  ) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        {
          'id': 'p1',
          'name': '我的 Python 小说站',
          'kind': 'pyImport',
          'enabled': true,
          'extra': {'contentType': 'novel'},
        },
        {
          'id': 'j1',
          'name': '我的 JS 站',
          'kind': 'jsImport',
          'enabled': false,
          'extra': {'contentType': 'video'},
        },
        {
          'id': 'm1',
          'name': '我的 MacCMS 站',
          'kind': 'customMaccms',
          'enabled': true,
          'address': 'https://example.com',
          'extra': {'contentType': 'video'},
        },
      ]),
    });
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: _previewTheme(),
        home: RepaintBoundary(
          key: const ValueKey<String>('moyi-source-management'),
          child: const SourceManagementPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('站源管理'), findsOneWidget);
    expect(find.text('内置短剧'), findsOneWidget);
    // 第一站番茄短剧（id original）自带“检测”按钮与开关。
    expect(find.text('番茄短剧'), findsOneWidget);
    expect(find.text('检测'), findsWidgets);
    expect(find.text('已启用'), findsWidgets);
    expect(find.byType(Switch), findsWidgets);
    // 滚到假数据组，确认自定义行也在深底卡片里。
    await tester.scrollUntilVisible(find.text('我的 Python 小说站'), 500);
    expect(find.text('我的 Python 小说站'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('我的 MacCMS 站'), 500);
    expect(find.text('我的 MacCMS 站'), findsOneWidget);
    // 截图取首屏（内置短剧组 + 检测 + 金开关）：往回滚到顶，
    // scrollUntilVisible 用负步长往上滚（滚到 AppBar 标题没用，
    // 它一直可见、不会触发回滚）。
    await tester.scrollUntilVisible(find.text('内置短剧'), -500);
    await tester.pump();
    expect(find.text('番茄短剧'), findsOneWidget);
    await _capture(
      tester,
      const ValueKey<String>('moyi-source-management'),
      'source_management',
    );
  });

  testWidgets('预览：一键写PY页换肤（深紫蓝渐变底 + 深紫输入框 + 金按钮）', (
    tester,
  ) async {
    await _loadFonts(tester);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: _previewTheme(),
        home: RepaintBoundary(
          key: const ValueKey<String>('moyi-onekey-py'),
          child: const OneKeyPyPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('一键写PY'), findsOneWidget);
    expect(find.text('网站地址'), findsOneWidget);
    expect(find.text('站名（可选，不填按域名自动取）'), findsOneWidget);
    expect(find.text('生成并导入'), findsOneWidget);
    expect(find.textContaining('说明：先按域名匹配已知站模板'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    await _capture(
      tester,
      const ValueKey<String>('moyi-onekey-py'),
      'onekey_py',
    );
  });
}
