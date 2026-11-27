import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/plugin_manage_page.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/mine/mine_entries.dart';

/// 插件管理页测试（2026-11-27 新布局：市场与管理搬进「我的」）：
/// - 「我的」入口列表里有「插件管理」行、点得进管理页；
/// - 管理页有市场区段 + 已装列表 + 添加入口（「+」打开添加面板）；
/// - 已装行：启停开关走仓库 setEnabled、行尾按钮卸载走确认框真卸；
/// - 损坏的已装插件标损坏；成人插件门禁未开时已装行不显示；
/// - 市场安装失败时界面提示是中文人话、不带英文异常原文。
/// 仓库用临时目录 + 内存 prefs + 假 probe + 假下载，不碰真网络；
/// 文件 IO 是真异步，按本树口径 runAsync 真时间轮询等待。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;
  late IdjPluginStore store;

  String bundleText({
    String id = 'com.idj.ext.demo',
    String name = '演示插件',
    bool adult = false,
  }) => jsonEncode({
    'manifest': {
      'schema': 1,
      'id': id,
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
    rootDir = Directory.systemTemp.createTempSync('idj_mp_root');
    supportDir = Directory.systemTemp.createTempSync('idj_mp_support');
    store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _ManageHttpClient(),
    );
  });

  tearDown(() {
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget pageHost() => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: PluginManagePage(store: store),
  );

  testWidgets('「我的」入口：插件管理行可见可点、进管理页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const Scaffold(body: MineEntries()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数据库导入'), findsOneWidget);
    expect(find.text('插件管理'), findsOneWidget);
    await tester.tap(find.text('插件管理'));
    await tester.pumpAndSettle();
    // 管理页标题出现（默认仓库在测试环境拉不到订阅也不拦进页）。
    expect(find.text('插件管理'), findsWidgets);
    expect(find.byKey(const ValueKey('plugin-manage-add')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plugin-market-section')),
      findsOneWidget,
    );
  });

  testWidgets('管理页结构：市场 + 已装列表 + 添加入口打开面板', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(pageHost());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-market-section')), findsOneWidget);
    expect(find.text('插件市场'), findsOneWidget);
    expect(find.text('已安装插件'), findsOneWidget);
    final row = find.byKey(
      const ValueKey('plugin-installed-row-com.idj.ext.demo'),
    );
    await pumpUntilFound(tester, row);
    expect(row, findsOneWidget);
    expect(find.text('演示插件'), findsWidgets);
    expect(find.text('v1.0.0 · 视频'), findsOneWidget);
    // 添加入口：点「+」打开添加面板（本地包 / 远程源两项）。
    await tester.tap(find.byKey(const ValueKey('plugin-manage-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plugin-add-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-add-remote')), findsOneWidget);
    expect(find.text('添加本地插件包'), findsOneWidget);
    expect(find.text('添加远程插件源'), findsOneWidget);
  });

  testWidgets('已装行启停：开关走仓库、关掉后插件区条目口径同步', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(pageHost());
    final toggle = find.byKey(
      const ValueKey('plugin-installed-toggle-com.idj.ext.demo'),
    );
    // 等开关界面值翻到目标值：页内启停后重读已装列表含真文件 IO，
    // 靠 runAsync 真时间轮询推进（本树既有口径）。
    Future<void> pumpUntilSwitch(bool value) async {
      for (var i = 0; i < 40; i++) {
        if (toggle.evaluate().isNotEmpty &&
            tester.widget<Switch>(toggle).value == value) {
          return;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await pumpUntilFound(tester, toggle);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await pumpUntilSwitch(false);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    var installed = await tester.runAsync(() => store.listInstalled());
    expect(installed!.single.entry.enabled, isFalse);
    // 再打开恢复启用。
    await tester.tap(toggle);
    await pumpUntilSwitch(true);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    installed = await tester.runAsync(() => store.listInstalled());
    expect(installed!.single.entry.enabled, isTrue);
  });

  testWidgets('已装行卸载：行尾按钮 → 确认框 → 真卸载', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(pageHost());
    final row = find.byKey(
      const ValueKey('plugin-installed-row-com.idj.ext.demo'),
    );
    await pumpUntilFound(tester, row);
    await tester.tap(
      find.byKey(
        const ValueKey('plugin-installed-uninstall-com.idj.ext.demo'),
      ),
    );
    final confirm = find.byKey(const ValueKey('plugin-uninstall-confirm'));
    await pumpUntilFound(tester, confirm);
    expect(confirm, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-ok')));
    await pumpUntilGone(tester, row);
    expect(row, findsNothing);
    final installed = await tester.runAsync(() => store.listInstalled());
    expect(installed, isEmpty);
  });

  testWidgets('损坏的已装插件在列表里标损坏与原因', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    // 删掉包文件制造损坏（索引还在、包没了 → 仓库判「包文件缺失」）。
    await tester.runAsync(() async {
      for (final entity in rootDir.listSync(recursive: true)) {
        if (entity is File) entity.deleteSync();
      }
    });
    await tester.pumpWidget(pageHost());
    await pumpUntilFound(tester, find.textContaining('已损坏'));
    expect(find.textContaining('已损坏'), findsOneWidget);
    expect(find.textContaining('包文件缺失'), findsOneWidget);
  });

  testWidgets('成人插件未解锁时已装行不显示', (tester) async {
    await tester.runAsync(
      () => store.installBundleText(
        bundleText(id: 'com.idj.ext.adult', name: '成人插件', adult: true),
      ),
    );
    await tester.pumpWidget(pageHost());
    await tester.pumpAndSettle();
    // 等已装列表加载完（空态文案出现说明加载已落定）。
    await pumpUntilFound(tester, find.textContaining('还没有安装插件'));
    expect(
      find.byKey(const ValueKey('plugin-installed-row-com.idj.ext.adult')),
      findsNothing,
    );
    expect(find.text('成人插件'), findsNothing);
  });

  testWidgets('市场安装失败：界面提示是中文人话、不带英文异常原文', (tester) async {
    final failingStore = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {
        throw StateError('JS 执行失败：ReferenceError: foo is not defined');
      },
      uriValidator: (_) async {},
      httpFactory: () => _ManageHttpClient(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: PluginManagePage(store: failingStore),
      ),
    );
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
    final installed = await tester.runAsync(
      () => failingStore.listInstalled(),
    );
    expect(installed, isEmpty);
  });
}

/// 管理页用例的假下载：索引地址回一条订阅、包地址回包，其余 404。
class _ManageHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final path = url.path;
    if (path.endsWith('index.json')) {
      return _ManageRequest(
        _ManageResponse(200, utf8.encode(_subscriptionJson)),
      );
    }
    if (path.endsWith('.idjplugin')) {
      return _ManageRequest(
        _ManageResponse(200, utf8.encode(_alphaBundleJson)),
      );
    }
    return _ManageRequest(_ManageResponse(404, const []));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _subscriptionJson = '''
{"name":"测试源","plugins":[
 {"id":"com.idj.ext.alpha","name":"插件alpha","version":"1.0.0","type":"video","adult":false,"description":"甲","manifest":"alpha/alpha.idjplugin"}
],"cms":[]}
''';

final _alphaBundleJson = jsonEncode({
  'manifest': {
    'schema': 1,
    'id': 'com.idj.ext.alpha',
    'name': '插件alpha',
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

class _ManageHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ManageRequest implements HttpClientRequest {
  _ManageRequest(this._response);

  final _ManageResponse _response;

  @override
  final HttpHeaders headers = _ManageHeaders();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _ManageResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _ManageResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  HttpHeaders get headers => _ManageHeaders();

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
