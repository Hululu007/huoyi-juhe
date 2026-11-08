
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/api_service_page.dart';
import 'package:fqapp/services/app_theme.dart';
import 'package:fqapp/services/local_media_proxy.dart';
import 'package:fqapp/services/local_proxy_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LocalProxyPreferences.instance.resetForTest();
  });

  tearDown(() async {
    await LocalMediaProxy.instance.stop();
    LocalMediaProxy.instance.debugResetForTest();
    LocalProxyPreferences.instance.resetForTest();
  });

  testWidgets('服务页本地代理卡片：开关、端口、状态、地址都在', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地代理'), findsOneWidget);
    expect(find.text('本地代理开关'), findsOneWidget);
    // 服务没起：状态「已停止」、地址行「已关闭」。
    expect(find.text('已停止'), findsWidgets);
    expect(find.text('已关闭'), findsOneWidget);
    // 自测按钮有两个（后端服务一个、本地代理一个）。
    expect(find.text('自测'), findsNWidgets(2));
  });

  testWidgets('服务页本地代理开关：关掉弹确认，确认后开关关、偏好落盘', (tester) async {
    // 注意：widget 测试里不起真服务——HttpServer.bind 会建一个 2 分钟
    // 周期定时器（idleTimeout），FakeAsync 下它永不结束，pumpAndSettle
    // 会一直等；服务的起停由纯测试（local_proxy_service_test.dart）
    // 覆盖。这里只测开关 UI：偏好默认开、服务没起，开关是开着的。
    await LocalProxyPreferences.instance.load();
    expect(LocalProxyPreferences.instance.enabled.value, isTrue);

    await tester.binding.setSurfaceSize(const Size(430, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(Brightness.light),
        home: const ApiServicePage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地代理开关'), findsOneWidget);
    await tester.tap(find.text('本地代理开关'));
    await tester.pumpAndSettle();
    expect(find.text('关闭本地代理'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    expect(LocalProxyPreferences.instance.enabled.value, isFalse);
    expect(LocalMediaProxy.instance.isRunning, isFalse);
    expect(find.text('已停止'), findsWidgets);
    expect(find.text('已关闭'), findsOneWidget);
  });
}
