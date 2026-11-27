import 'dart:async';
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

  testWidgets('市场网格：手机宽三列，点卡上安装真装上并登记成站', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // 本用例的仓库带按地址分流的假下载：索引地址回订阅、包地址回包。
    final marketStore = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _MarketHttpClient(),
    );
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
                  initialZone: SiteGridZone.plugin,
                  enablePluginZone: true,
                  pluginStore: marketStore,
                  onDeleteSite: deleteSiteGridEntry,
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
    // 等市场卡片（真异步下载 + 解析）出现。
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.alpha')),
    );
    // 三列：前三张卡同一行、横坐标递增；第四张换行回第一列。
    final tops = <double>[];
    final lefts = <double>[];
    for (final id in ['alpha', 'beta', 'gamma', 'delta']) {
      final rect = tester.getRect(
        find.byKey(ValueKey('plugin-market-row-com.idj.ext.$id')),
      );
      tops.add(rect.top);
      lefts.add(rect.left);
    }
    expect(tops[0], tops[1]);
    expect(tops[1], tops[2]);
    expect(lefts[0] < lefts[1] && lefts[1] < lefts[2], isTrue);
    expect(tops[3] > tops[0], isTrue);
    expect(lefts[3], lefts[0]);
    // 点第一张卡的安装按钮：走完下载 → 校验 → probe → 写盘 → 登记。
    await tester.tap(
      find.byKey(const ValueKey('plugin-install-com.idj.ext.alpha')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_alpha')),
    );
    expect(
      find.byKey(const ValueKey('site-grid-row-idj_alpha')),
      findsOneWidget,
    );
    // 文件 IO 必须走 runAsync 真异步（FakeAsync 里直接 await 会永挂）。
    final installed = await tester.runAsync(
      () => marketStore.listInstalled(),
    );
    expect(installed!.map((p) => p.entry.pluginId), [
      'com.idj.ext.alpha',
    ]);
    // 卡片状态翻成已安装（市场区段重拉后）。
    await pumpUntilFound(tester, find.text('已安装'));
    expect(find.text('已安装'), findsOneWidget);
  });

  testWidgets('市场安装失败：界面提示是中文人话、不带英文异常原文', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    // probe 假实现抛一串典型英文异常（模拟原生桥回的 JS 报错，
    // StateError 自带「Bad state:」前缀）：走完下载 → 校验 → probe
    // 失败后，界面只许看到中文提示，不许看到异常原文任何片段。
    final failingStore = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {
        throw StateError('JS 执行失败：ReferenceError: foo is not defined');
      },
      uriValidator: (_) async {},
      httpFactory: () => _MarketHttpClient(),
    );
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
                  initialZone: SiteGridZone.plugin,
                  enablePluginZone: true,
                  pluginStore: failingStore,
                  onDeleteSite: deleteSiteGridEntry,
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
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.alpha')),
    );
    await tester.tap(
      find.byKey(const ValueKey('plugin-install-com.idj.ext.alpha')),
    );
    await pumpUntilFound(tester, find.byType(SnackBar));
    final snackText = tester
        .widget<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        )
        .data!;
    expect(snackText, contains('试加载失败'));
    expect(snackText, contains('请稍后重试'));
    for (final fragment in [
      'Bad state',
      'JS 执行失败',
      'ReferenceError',
      'is not defined',
      'foo',
    ]) {
      expect(
        snackText,
        isNot(contains(fragment)),
        reason: '界面文案不许带异常原文片段：$fragment',
      );
    }
    // 失败不留半成品：没装上。
    final installed = await tester.runAsync(
      () => failingStore.listInstalled(),
    );
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

/// 市场网格用例的假下载：索引地址回四条订阅、包地址按文件名回包，
/// 其余一律 404。只在本文件内用，不碰真网络。
class _MarketHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final path = url.path;
    if (path.endsWith('index.json')) {
      return _MarketRequest(
        _MarketResponse(200, utf8.encode(_marketSubscriptionJson)),
      );
    }
    if (path.endsWith('.idjplugin')) {
      final segment = path.split('/').last.replaceAll('.idjplugin', '');
      return _MarketRequest(
        _MarketResponse(200, utf8.encode(_marketBundleJson(segment))),
      );
    }
    return _MarketRequest(_MarketResponse(404, const []));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _marketSubscriptionJson = '''
{"name":"测试源","plugins":[
 {"id":"com.idj.ext.alpha","name":"插件alpha","version":"1.0.0","type":"video","adult":false,"description":"甲","manifest":"alpha/alpha.idjplugin"},
 {"id":"com.idj.ext.beta","name":"插件beta","version":"1.0.0","type":"video","adult":false,"description":"乙","manifest":"beta/beta.idjplugin"},
 {"id":"com.idj.ext.gamma","name":"插件gamma","version":"1.0.0","type":"video","adult":false,"description":"丙","manifest":"gamma/gamma.idjplugin"},
 {"id":"com.idj.ext.delta","name":"插件delta","version":"1.0.0","type":"video","adult":false,"description":"丁","manifest":"delta/delta.idjplugin"}
],"cms":[]}
''';

String _marketBundleJson(String segment) => jsonEncode({
  'manifest': {
    'schema': 1,
    'id': 'com.idj.ext.$segment',
    'name': '插件$segment',
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

class _MarketHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _MarketRequest implements HttpClientRequest {
  _MarketRequest(this._response);

  final _MarketResponse _response;

  @override
  final HttpHeaders headers = _MarketHeaders();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _MarketResponse extends Stream<List<int>> implements HttpClientResponse {
  _MarketResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  HttpHeaders get headers => _MarketHeaders();

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
