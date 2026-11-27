import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 选站弹窗插件区测试（2026-11-27 新布局：插件区只留显示）：
/// 三区渲染（区签带插件区）、切到插件区能看到已装插件站卡、点卡
/// 能选中返回；市场区段不在弹窗里、无插件添加按钮、长按插件卡
/// 不弹卸载（市场与管理全套在「我的 → 插件管理」页，见
/// plugin_manage_page_test.dart）。插件仓库用临时目录 + 内存
/// prefs + 假 probe，不碰真网络。文件 IO 是真异步：按本树口径
/// 用 runAsync 真时间轮询等待。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;
  late IdjPluginStore store;
  String? dialogResult;

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
    dialogResult = null;
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
              onPressed: () async {
                dialogResult = await showSiteGridDialog(
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
                );
              },
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

  testWidgets('三区：区签有插件区；无添加按钮、无市场区段', (tester) async {
    await openDialog(tester);
    expect(
      find.byKey(const ValueKey('site-grid-zone-builtin')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('site-grid-zone-import')), findsOneWidget);
    expect(find.byKey(const ValueKey('site-grid-zone-plugin')), findsOneWidget);
    expect(find.text('插件区（0）'), findsOneWidget);
    // 管理职能已搬走：没有插件添加「+」、没有添加面板入口。
    expect(find.byKey(const ValueKey('site-grid-add')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-add-local')), findsNothing);
    expect(find.byKey(const ValueKey('plugin-add-remote')), findsNothing);
  });

  testWidgets('切到插件区：已装插件成站卡，市场区段不在', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_demo')),
    );
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsOneWidget);
    expect(find.text('演示插件'), findsWidgets);
    // 弹窗里没有市场：区段、标题、市场卡都不出现。
    expect(find.byKey(const ValueKey('plugin-market-section')), findsNothing);
    expect(find.text('插件市场'), findsNothing);
    expect(
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.demo')),
      findsNothing,
    );
  });

  testWidgets('点插件站卡能选中：弹窗返回该站 id', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    final row = find.byKey(const ValueKey('site-grid-row-idj_demo'));
    await pumpUntilFound(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('site-grid-dialog')), findsNothing);
    expect(dialogResult, 'idj_demo');
  });

  testWidgets('长按插件站卡不弹卸载、插件仍在', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await openDialog(tester, initialZone: SiteGridZone.plugin);
    final row = find.byKey(const ValueKey('site-grid-row-idj_demo'));
    await pumpUntilFound(tester, row);
    await tester.longPress(row);
    // 给可能的异步卸载流留出跑完的时间窗：确认框始终不许出现。
    // （卡上没挂长按处理：长按抬手至多按点按处理选中该站、关弹窗，
    // 绝不许走卸载。）
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.byKey(const ValueKey('plugin-uninstall-confirm')),
        findsNothing,
      );
    }
    final installed = await tester.runAsync(() => store.listInstalled());
    expect(installed, hasLength(1));
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

  testWidgets('不启用插件区时仍是两区（旧行为不变）', (tester) async {
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
