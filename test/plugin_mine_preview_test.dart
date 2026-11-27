import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';
import 'package:fqapp/pages/plugin_manage_page.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/mine/mine_entries.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 新布局预览图（2026-11-27：插件搬进「我的」、选站弹窗插件区只
/// 留显示）：①「我的」入口列表能看到「插件管理」行；②插件管理页
/// （市场 + 已装列表）；③选站弹窗插件区（只有站卡、无市场）。
/// 数据全是假实现（临时目录仓库 + 假订阅下载），不碰真网络；
/// 单独跑，不与普通测试混链。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late IdjPluginStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    rootDir = Directory.systemTemp.createTempSync('idj_mine_prev_root');
    supportDir = Directory.systemTemp.createTempSync('idj_mine_prev_support');
    store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _PreviewHttpClient(),
    );
  });

  tearDown(() {
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('plugin-mine-preview')),
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

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('预览①：我的页入口列表有插件管理行', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-mine-preview'),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: const Scaffold(
            backgroundColor: Color(0xFF0F0F14),
            body: SafeArea(child: MineEntries()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('插件管理'), findsOneWidget);
    expect(find.text('数据库导入'), findsOneWidget);
    await capture(tester, 'plugin_mine_entries');
  });

  testWidgets('预览②：插件管理页（市场 + 已装列表）', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await store.installBundleText(_bundleText(id: 'com.idj.ext.demo', name: '橙果短剧'));
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.aiguo', name: '爱果短剧'),
      );
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-mine-preview'),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: PluginManagePage(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 等市场卡与已装行都落定再截，画面不留「正在加载」。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.huangguo')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-installed-row-com.idj.ext.aiguo')),
    );
    expect(find.text('插件市场'), findsOneWidget);
    expect(find.text('已安装插件'), findsOneWidget);
    await capture(tester, 'plugin_manage_page');
  });

  testWidgets('预览③：选站弹窗插件区只有站卡、无市场', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await store.installBundleText(_bundleText(id: 'com.idj.ext.demo', name: '橙果短剧'));
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.aiguo', name: '爱果短剧'),
      );
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.huangguo', name: '黄果短剧'),
      );
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-mine-preview'),
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
                    initialZone: SiteGridZone.plugin,
                    enablePluginZone: true,
                    pluginStore: store,
                    onDeleteSite: deleteSiteGridEntry,
                  ),
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
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_huangguo')),
    );
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsOneWidget);
    expect(find.text('插件区（3）'), findsOneWidget);
    // 只留显示：没有市场区段、没有添加按钮。
    expect(find.byKey(const ValueKey('plugin-market-section')), findsNothing);
    expect(find.byKey(const ValueKey('site-grid-add')), findsNothing);
    await capture(tester, 'plugin_zone_display_only');
  });
}

String _bundleText({required String id, required String name}) =>
    jsonEncode({
      'manifest': {
        'schema': 1,
        'id': id,
        'name': name,
        'version': '1.0.0',
        'entry': 'main.js',
        'type': 'video',
        'adult': false,
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

/// 预览专用假下载：任何地址都回同一份小订阅（3 条插件）。
class _PreviewHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _PreviewRequest(_PreviewResponse(200, utf8.encode(_subscriptionJson)));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _subscriptionJson = '''
{"name":"预览源","plugins":[
 {"id":"com.idj.ext.demo","name":"橙果短剧","version":"1.0.0","type":"video","adult":false,"description":"橙果原创短剧","manifest":"demo/demo.idjplugin"},
 {"id":"com.idj.ext.aiguo","name":"爱果短剧","version":"1.0.1","type":"video","adult":false,"description":"爱果短剧全集","manifest":"aiguo/aiguo.idjplugin"},
 {"id":"com.idj.ext.huangguo","name":"黄果短剧","version":"1.0.0","type":"shortdrama","adult":false,"description":"黄果短剧与漫剧","manifest":"huangguo/huangguo.idjplugin"}
],"cms":[]}
''';

class _PreviewHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _PreviewRequest implements HttpClientRequest {
  _PreviewRequest(this._response);

  final _PreviewResponse _response;

  @override
  final HttpHeaders headers = _PreviewHeaders();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _PreviewResponse extends Stream<List<int>> implements HttpClientResponse {
  _PreviewResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  HttpHeaders get headers => _PreviewHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable([_body]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
