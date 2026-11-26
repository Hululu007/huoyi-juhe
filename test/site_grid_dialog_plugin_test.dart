import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 选站弹窗插件区测试：三区渲染（区签带插件区）、切到插件区能看到
/// 已装插件站与插件市场、右上角「+」打开添加面板、长按插件站走
/// 卸载确认并真的卸掉。插件仓库用临时目录 + 内存 prefs + 假
/// probe，不碰真网络（订阅拉取失败只显示错误行，不拦弹窗）。
/// 文件 IO 是真异步：按本树口径用 runAsync 真时间轮询等待。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;
  late IdjPluginStore store;

  String bundleText({String name = '演示插件', bool adult = false}) =>
      jsonEncode({
        'manifest': {
          'schema': 1,
          'id': 'com.idj.ext.demo',
          'name': name,
          'version': '1.0.0',
          'entry': 'main.js',
          'type': 'video',
          'adult': adult,
          'capabilities': ['home', 'category', 'detail', 'play'],
          'permissions': {
            'http': ['example.com'],
            'media': ['example.com'],
            'cloudflare': false,
            'storage': false,
            'login': false,
          },
        },
        'files': {'main.js': 'export default {};'},
      });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = Directory.systemTemp.createTempSync('idj_ui_root');
    supportDir = Directory.systemTemp.createTempSync('idj_ui_support');
    store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
    );
  });

  tearDown(() {
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Widget host({SiteGridZone initialZone = SiteGridZone.builtin}) {
    return MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonContext) => TextButton(
              onPressed: () => showSiteGridDialog(
                context: buttonContext,
                sites: const [
                  (
                    id: 'b-video',
                    name: '内置影视',
                    zone: SiteGridZone.builtin,
                    group: SiteGridGroup.video,
                  ),
                ],
                initialZone: initialZone,
                enablePluginZone: true,
                pluginStore: store,
                onDeleteSite: deleteSiteGridEntry,
              ),
              child: const Text('打开切换站点'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openDialog(
    WidgetTester tester, {
    SiteGridZone initialZone = SiteGridZone.builtin,
  }) async {
    await tester.pumpWidget(host(initialZone: initialZone));
    await tester.tap(find.text('打开切换站点'));
    await tester.pumpAndSettle();
  }

  /// 真异步轮询：等 finder 出现（插件区条目靠文件 IO 对账后才进表）。
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 30; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 30; i++) {
      if (finder.evaluate().isEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('三区：区签有插件区，标题行有 + 号', (tester) async {
    await openDialog(tester);
    expect(
      find.byKey(const ValueKey('site-grid-zone-builtin')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('site-grid-zone-import')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-grid-zone-plugin')), findsOneWidget);
    expect(find.text('插件区（0）'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-grid-add')), findsOneWidget);
  });

  testWidgets('切到插件区：已装插件成站、市场区段出现', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_demo')),
    );
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsOneWidget);
    expect(find.text('演示插件'), findsWidgets);
    // 市场区段在站网格下方，滚到底才构建。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('plugin-market-section')),
      findsOneWidget,
    );
    expect(find.text('插件市场'), findsOneWidget);
  });

  testWidgets('成人插件未解锁时插件区不露', (tester) async {
    await tester.runAsync(
      () => store.installBundleText(bundleText(name: '成人插件', adult: true)),
    );
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    // 等对账跑完（站卡判定跑完一轮后，未解锁的成人插件仍不出现）。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsNothing);
    expect(find.text('成人插件'), findsNothing);
  });

  testWidgets('+ 号打开添加面板：本地包与远程源两项', (tester) async {
    await openDialog(tester);
    await tester.tap(find.byKey(const ValueKey('site-grid-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-add-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-add-remote')), findsOneWidget);
    expect(find.text('添加本地插件包'), findsOneWidget);
    expect(find.text('添加远程插件源'), findsOneWidget);
  });

  testWidgets('长按插件站 → 卸载确认 → 真卸载', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    final row = find.byKey(const ValueKey('site-grid-row-idj_demo'));
    await pumpUntilFound(tester, row);
    await tester.longPress(row);
    // 卸载流先查插件仓库（真文件 IO），FakeAsync 下轮询等确认框。
    final confirm = find.byKey(const ValueKey('plugin-uninstall-confirm'));
    await pumpUntilFound(tester, confirm);
    expect(confirm, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-ok')));
    await pumpUntilGone(tester, row);
    final installed = await tester.runAsync(() => store.listInstalled());
    expect(installed, isEmpty);
  });

  testWidgets('不启用插件区时仍是两区、无 + 号（旧行为不变）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (buttonContext) => TextButton(
                onPressed: () => showSiteGridDialog(
                  context: buttonContext,
                  sites: const [
                    (
                      id: 'b-video',
                      name: '内置影视',
                      zone: SiteGridZone.builtin,
                      group: SiteGridGroup.video,
                    ),
                  ],
                ),
                child: const Text('打开切换站点'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开切换站点'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-grid-zone-plugin')), findsNothing);
    expect(find.byKey(const ValueKey('site-grid-add')), findsNothing);
  });
}
