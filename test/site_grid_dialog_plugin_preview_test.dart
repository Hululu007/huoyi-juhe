import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 选站弹窗插件区预览图：改前（两区）与改后（三区 + 插件区含已装
/// 站与市场列表）各一张。数据全是假实现（临时目录仓库 + 假订阅
/// 下载），不碰真网络；单独跑，不与普通测试混链。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late IdjPluginStore store;

  const entries = <SiteGridEntry>[
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
      id: 'i-video',
      name: '导入影视站',
      zone: SiteGridZone.import,
      group: SiteGridGroup.video,
    ),
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    rootDir = Directory.systemTemp.createTempSync('idj_prev_root');
    supportDir = Directory.systemTemp.createTempSync('idj_prev_support');
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
      find.byKey(const ValueKey<String>('plugin-picker-preview')),
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

  Future<void> pumpHost(
    WidgetTester tester, {
    required bool enablePluginZone,
    SiteGridZone initialZone = SiteGridZone.builtin,
  }) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-picker-preview'),
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
                    sites: entries,
                    initialZone: initialZone,
                    enablePluginZone: enablePluginZone,
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
    expect(find.byKey(const ValueKey('site-grid-dialog')), findsOneWidget);
  }

  testWidgets('预览：改前两区', (tester) async {
    await pumpHost(tester, enablePluginZone: false);
    expect(find.text('内置区（2）'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-grid-zone-plugin')), findsNothing);
    await capture(tester, 'site_picker_before_two_zones');
  });

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 30; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('预览：插件区·已装网格（三列站卡）', (tester) async {
    await tester.runAsync(() async {
      await store.installBundleText(_demoBundleText());
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.aiguo', name: '爱果短剧'),
      );
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.huangguo', name: '黄果短剧'),
      );
    });
    await pumpHost(
      tester,
      enablePluginZone: true,
      initialZone: SiteGridZone.plugin,
    );
    // 等插件区对账把三个已装站带进表，网格第一行正好三张卡。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_huangguo')),
    );
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('site-grid-row-idj_aiguo')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('site-grid-row-idj_huangguo')),
      findsOneWidget,
    );
    expect(find.text('插件区（3）'), findsOneWidget);
    // 市场区段也等加载完再截，画面不留「正在加载」。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.aiguo')),
    );
    await capture(tester, 'plugin_zone_installed_grid');
  });

  testWidgets('预览：插件区·市场网格（三列卡片）', (tester) async {
    await tester.runAsync(
      () => store.installBundleText(_demoBundleText()),
    );
    await pumpHost(
      tester,
      enablePluginZone: true,
      initialZone: SiteGridZone.plugin,
    );
    // 等插件区对账把已装站带进表。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_demo')),
    );
    expect(find.byKey(const ValueKey('site-grid-row-idj_demo')), findsOneWidget);
    expect(find.text('插件区（1）'), findsOneWidget);
    expect(find.byKey(const ValueKey('site-grid-add')), findsOneWidget);
    // 等市场订阅（假下载，真异步）加载出卡片，再滚一下让卡片入镜。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.aiguo')),
    );
    expect(
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.aiguo')),
      findsOneWidget,
    );
    expect(find.text('爱果短剧'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -160));
    await tester.pumpAndSettle();
    await capture(tester, 'plugin_zone_market_grid');
    await capture(tester, 'site_picker_after_plugin_zone');
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

String _demoBundleText() => jsonEncode({
  'manifest': {
    'schema': 1,
    'id': 'com.idj.ext.demo',
    'name': '橙果短剧',
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

/// 预览专用假下载：任何地址都回同一份小订阅（3 条插件：演示插件
/// 已装、一个可更新、一个未装），市场行状态齐全。
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
 {"id":"com.idj.ext.demo","name":"橙果短剧","version":"1.0.0","type":"video","adult":false,"description":"橙果原创短剧，5 条线路 + 题材标签","manifest":"demo/demo.idjplugin"},
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
