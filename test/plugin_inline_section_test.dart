import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/mine/mine_entries.dart';
import 'package:fqapp/widgets/mine/mine_plugin_section.dart';

/// 「我的」页内嵌插件管理测试（2026-11-27 20:16 令：插件管理搬
/// 到今日阅读原位置、原地折叠展开不跳页）：
/// - 入口列表里不再有「插件管理」行（不能再点行跳页）；
/// - 区段内有市场 + 已装网格 + 添加入口（「+」打开添加面板）；
/// - 已装卡：启停开关走仓库 setEnabled、卡尾按钮卸载走确认框真卸；
/// - 损坏的已装插件标损坏；成人插件门禁未开时已装卡不显示；
/// - 市场安装失败时界面提示是中文人话、不带英文异常原文；
/// - 折叠口径：市场与已装收起时各只露三排（三列网格 9 张），点
///   「展开全部」看全、再点收回三排。
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
    rootDir = Directory.systemTemp.createTempSync('idj_in_root');
    supportDir = Directory.systemTemp.createTempSync('idj_in_support');
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


  /// 长轮询：装满 12 个插件时，已装列表一条链要在假时钟区里接力
  /// 几十次真 IO（逐个包 exists+读文件+验哈希），普通 40 轮不够，
  /// 折叠用例专用加长版（真机是真事件循环、无此问题）。
  Future<void> pumpUntilFoundLong(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 150; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget sectionHost({IdjPluginStore? useStore}) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: ListView(children: [MinePluginSection(store: useStore ?? store)]),
    ),
  );

  void usePhoneSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
  }

  testWidgets('入口列表里不再有插件管理行、区段在「我的」页内嵌', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: const Scaffold(body: MineEntries()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数据库导入'), findsOneWidget);
    // 不许再有「点插件管理跳走」的路径。
    expect(find.text('插件管理'), findsNothing);
    // 区段本体：标题、「+」、市场区段都在原地。
    await tester.pumpWidget(sectionHost());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mine-plugin-section')), findsOneWidget);
    expect(find.text('插件管理'), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-manage-add')), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-market-section')), findsOneWidget);
  });

  testWidgets('区段结构：市场 + 已装网格 + 添加入口打开面板', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(sectionHost());
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

  testWidgets('已装卡启停：开关走仓库、关掉后状态同步', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(sectionHost());
    final toggle = find.byKey(
      const ValueKey('plugin-installed-toggle-com.idj.ext.demo'),
    );
    // 等开关界面值翻到目标值：启停后重读已装列表含真文件 IO，
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

  testWidgets('已装卡卸载：卡尾按钮 → 确认框 → 真卸载', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    await tester.pumpWidget(sectionHost());
    final row = find.byKey(
      const ValueKey('plugin-installed-row-com.idj.ext.demo'),
    );
    await pumpUntilFound(tester, row);
    await tester.tap(
      find.byKey(const ValueKey('plugin-installed-uninstall-com.idj.ext.demo')),
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

  testWidgets('损坏的已装插件在卡里标损坏与原因', (tester) async {
    await tester.runAsync(() => store.installBundleText(bundleText()));
    // 删掉包文件制造损坏（索引还在、包没了 → 仓库判「包文件缺失」）。
    await tester.runAsync(() async {
      for (final entity in rootDir.listSync(recursive: true)) {
        if (entity is File) entity.deleteSync();
      }
    });
    await tester.pumpWidget(sectionHost());
    await pumpUntilFound(tester, find.textContaining('已损坏'));
    expect(find.textContaining('已损坏'), findsOneWidget);
    expect(find.textContaining('包文件缺失'), findsOneWidget);
  });

  testWidgets('成人插件未解锁时已装卡不显示', (tester) async {
    await tester.runAsync(
      () => store.installBundleText(
        bundleText(id: 'com.idj.ext.adult', name: '成人插件', adult: true),
      ),
    );
    await tester.pumpWidget(sectionHost());
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
    await tester.pumpWidget(sectionHost(useStore: failingStore));
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

  testWidgets('已装折叠：收起三排、展开看全、再收回三排', (tester) async {
    usePhoneSurface(tester);
    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        // 已装列表按名字排序（仓库既有口径）：名字零填充，排序
        // 才与序号一致，收起态前 9 张恰为 p0..p8。
        await store.installBundleText(
          bundleText(
            id: 'com.idj.ext.p$i',
            name: '插件${i.toString().padLeft(2, '0')}',
          ),
        );
      }
    });
    await tester.pumpWidget(sectionHost());
    Finder card(int i) =>
        find.byKey(ValueKey('plugin-installed-row-com.idj.ext.p$i'));
    await pumpUntilFoundLong(tester, card(8));
    // 收起态：三列三排 = 9 张，第 10 张起不建。
    for (var i = 0; i < 9; i++) {
      expect(card(i), findsOneWidget, reason: '收起态第 $i 张应在');
    }
    expect(card(9), findsNothing);
    expect(card(11), findsNothing);
    final toggle = find.byKey(const ValueKey('plugin-installed-expand'));
    expect(toggle, findsOneWidget);
    expect(find.text('展开全部'), findsWidgets);
    // 展开看全。
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      expect(card(i), findsOneWidget, reason: '展开态第 $i 张应在');
    }
    expect(find.text('收起'), findsWidgets);
    // 再收回三排。
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(card(8), findsOneWidget);
    expect(card(9), findsNothing);
  });

  testWidgets('市场折叠：收起三排、展开看全、再收回三排', (tester) async {
    usePhoneSurface(tester);
    final manyStore = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _ManyPluginsHttpClient(),
    );
    await tester.pumpWidget(sectionHost(useStore: manyStore));
    Finder card(int i) =>
        find.byKey(ValueKey('plugin-market-row-com.idj.ext.m$i'));
    await pumpUntilFoundLong(tester, card(8));
    for (var i = 0; i < 9; i++) {
      expect(card(i), findsOneWidget, reason: '收起态第 $i 张应在');
    }
    expect(card(9), findsNothing);
    expect(card(11), findsNothing);
    final toggle = find.byKey(const ValueKey('plugin-market-expand'));
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      expect(card(i), findsOneWidget, reason: '展开态第 $i 张应在');
    }
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(card(8), findsOneWidget);
    expect(card(9), findsNothing);
  });
}

/// 假下载：索引地址回一条订阅、包地址回包，其余 404。
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

/// 假下载（多插件源）：任何索引地址回 12 条插件的订阅，包地址 404
/// （折叠用例只看列表形态，不真安装）。
class _ManyPluginsHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (url.path.endsWith('index.json')) {
      return _ManageRequest(
        _ManageResponse(200, utf8.encode(_manySubscriptionJson())),
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

String _manySubscriptionJson() => jsonEncode({
  'name': '多插件源',
  'plugins': [
    for (var i = 0; i < 12; i++)
      {
        'id': 'com.idj.ext.m$i',
        'name': '市场插件$i',
        'version': '1.0.0',
        'type': 'video',
        'adult': false,
        'description': '第 $i 个',
        'manifest': 'm$i/m$i.idjplugin',
      },
  ],
  'cms': [],
});

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
