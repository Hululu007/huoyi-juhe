import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'preview_test_support.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/local_media_proxy.dart';
import 'package:fqapp/services/local_proxy_preferences.dart';

/// 本地代理服务页预览图：测试渲染出 PNG，不构建整包。
///
/// 服务在 runAsync 里真起（真定时器，不卡 FakeAsync 的 pumpAndSettle），
/// 截图里状态是「运行中 · 端口 9978」与本机地址，即用户手机上将看到的样子。
/// 测完在 runAsync 里停服务，不留定时器。
Future<void> _loadCjkFonts(WidgetTester tester) async {
  // 字体走共享支撑拿可移植路径（见 preview_test_support.dart）：
  // 此前写死的 /home/hatch/flutter/... 与 pub-cache 绝对路径在 CI 机上
  // 不存在，一跑就报 PathNotFoundException。
  await loadPreviewFonts(tester, lucide: true, monospace: true);
}


void main() {
  testWidgets('预览：设置 → 服务 → 本地代理（运行中）', (tester) async {
    await _loadCjkFonts(tester);
    SharedPreferences.setMockInitialValues({});
    LocalProxyPreferences.instance.resetForTest();
    await LocalProxyPreferences.instance.load();

    // 真起服务（真异步区，HttpServer 的 idleTimeout 定时器是真定时器）。
    await tester.runAsync(() => LocalMediaProxy.instance.start());
    expect(LocalMediaProxy.instance.isRunning, isTrue);
    addTearDown(
      () => tester.runAsync(() => LocalMediaProxy.instance.stop()),
    );

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(430, 1200);
    addTearDown(tester.view.reset);

    // AppTheme 不带 fontFamily：这里按它的配色重建一份，字体换成已载入
    // 的 NotoSansCJK，否则测试环境默认字体没有中文会出方框。
    final baseTheme = AppTheme.createTheme(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'NotoSansCJK',
          brightness: baseTheme.brightness,
          colorScheme: baseTheme.colorScheme,
          scaffoldBackgroundColor: baseTheme.scaffoldBackgroundColor,
          canvasColor: baseTheme.canvasColor,
          // 顶栏标题样式没写 fontFamily，测试里会落到默认字体出黑块：
          // 这里补上思源黑体。
          appBarTheme: baseTheme.appBarTheme.copyWith(
            titleTextStyle: baseTheme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: 'NotoSansCJK',
            ),
          ),
          useMaterial3: baseTheme.useMaterial3,
        ),
        home: RepaintBoundary(
          key: const ValueKey<String>('local-proxy-preview'),
          child: const ApiServicePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地代理'), findsOneWidget);
    expect(find.text('本地代理开关'), findsOneWidget);
    // 运行中时状态行是组合文本「运行中 · 端口 <port>」。
    expect(
      find.text('运行中 · 端口 ${LocalMediaProxy.instance.port}'),
      findsOneWidget,
    );
    expect(find.text('自测'), findsNWidgets(2));
    expect(tester.takeException(), isNull);

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('local-proxy-preview')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('previews/local_proxy_service.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

    await tester.runAsync(() => LocalMediaProxy.instance.stop());
  });
}
