import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 插件自动更新 + 市场四态的界面测试（用户 2026-11-27 令）：
/// - 已装 v1、远程出 v2：打开插件区后后台静默装上 v2，市场卡
///   只显示版本号 + 已安装，全程无「更新」字样；
/// - 市场卡长按卸载：确认后卡片与站网格条目一起消失、留已卸载
///   记录；远程同版本时市场里不再出现，远程升版后重新出现
///   （可安装），装回后记录清除、站点恢复。
/// 仓库用临时目录 + 内存 prefs + 假 probe + 可切换版本的假
/// 下载；文件 IO 与网络都是真异步，按本树口径 runAsync 轮询。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;
  late IdjPluginStore store;

  // 假远程当前版本号：订阅条目与包内 manifest 同步切换。
  var remoteVersion = '1.0.0';

  String bundleText(String version) => jsonEncode({
    'manifest': {
      'schema': 1,
      'id': 'com.idj.ext.alpha',
      'name': '插件alpha',
      'version': version,
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = Directory.systemTemp.createTempSync('idj_au_ui_root');
    supportDir = Directory.systemTemp.createTempSync('idj_au_ui_support');
    remoteVersion = '1.0.0';
    store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _VersionedHttpClient(() => remoteVersion),
    );
  });

  tearDown(() {
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Widget host() {
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
    );
  }

  Future<void> openDialog(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.tap(find.text('打开切换站点'));
    await tester.pumpAndSettle();
    // 市场区段在站网格下方，滚一下让它构建出来（构建才触发加载
    // 与自动更新）。
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
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

  Future<void> pumpUntilGone(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40; i++) {
      if (finder.evaluate().isEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pumpUntilVersion(WidgetTester tester, String version) async {
    for (var i = 0; i < 40; i++) {
      final installed = await tester.runAsync(() => store.listInstalled());
      if (installed != null &&
          installed.isNotEmpty &&
          installed.first.entry.version == version) {
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final marketCard = find.byKey(
    const ValueKey('plugin-market-row-com.idj.ext.alpha'),
  );
  final siteRow = find.byKey(const ValueKey('site-grid-row-idj_alpha'));

  testWidgets('自动更新：已装 v1、远程 v2，开插件区后静默装上且无更新字样', (
    tester,
  ) async {
    remoteVersion = '2.0.0';
    await tester.runAsync(() => store.installBundleText(bundleText('1.0.0')));
    await openDialog(tester);
    await pumpUntilFound(tester, marketCard);
    // 后台自动更新装完 v2（真异步下载 + 写盘，轮询仓库版本）。
    await pumpUntilVersion(tester, '2.0.0');
    final installed = await tester.runAsync(() => store.listInstalled());
    expect(installed!.single.entry.version, '2.0.0');
    // 卡片状态只剩版本号 + 已安装；整个弹窗找不到「更新」二字，
    // 也没有旧版 → 新版的箭头状态行。
    expect(find.text('已安装'), findsOneWidget);
    // 区段可能因弹窗对账重挂载：装更新的实例与当前可见实例未必
    // 同一个，可见卡的文案靠其自身那轮自动更新收尾刷新，轮询等
    // 它落定（真异步 + 假时钟区续链，本树既有轮询口径）。
    await pumpUntilFound(tester, find.text('v2.0.0'));
    expect(find.text('v2.0.0'), findsWidgets);
    expect(find.text('更新'), findsNothing);
    expect(find.textContaining('→'), findsNothing);
    expect(find.textContaining('新版本'), findsNothing);
    expect(find.textContaining('可更新'), findsNothing);
  });

  testWidgets('市场卡长按卸载四态：同版隐藏、升版重现、装回清记录站点恢复', (
    tester,
  ) async {
    remoteVersion = '1.0.0';
    await tester.runAsync(() => store.installBundleText(bundleText('1.0.0')));
    await openDialog(tester);
    await pumpUntilFound(tester, marketCard);
    expect(find.text('已安装'), findsOneWidget);
    // 站网格里也有它。
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, siteRow);
    expect(siteRow, findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    // 长按市场卡 → 共用卸载确认框。
    await tester.longPress(marketCard);
    final confirm = find.byKey(const ValueKey('plugin-uninstall-confirm'));
    await pumpUntilFound(tester, confirm);
    expect(confirm, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('plugin-uninstall-ok')));
    // 卸载后：市场卡消失（同版本 → 已卸载隐藏）、站网格条目消失。
    await pumpUntilGone(tester, marketCard);
    expect(marketCard, findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(siteRow, findsNothing);
    final afterUninstall = await tester.runAsync(
      () => store.readUninstalledVersions(),
    );
    expect(afterUninstall, {'com.idj.ext.alpha': '1.0.0'});
    final installedNow = await tester.runAsync(() => store.listInstalled());
    expect(installedNow, isEmpty);
    // 远程升版：刷新市场，条目重新出现且可安装。
    remoteVersion = '2.0.0';
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plugin-market-refresh')));
    await pumpUntilFound(tester, marketCard);
    expect(marketCard, findsOneWidget);
    expect(
      find.byKey(const ValueKey('plugin-install-com.idj.ext.alpha')),
      findsOneWidget,
    );
    expect(find.text('更新'), findsNothing);
    // 装回：记录清除、站点恢复、版本为 v2。
    await tester.tap(
      find.byKey(const ValueKey('plugin-install-com.idj.ext.alpha')),
    );
    await pumpUntilVersion(tester, '2.0.0');
    final records = await tester.runAsync(
      () => store.readUninstalledVersions(),
    );
    expect(records, isEmpty);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await pumpUntilFound(tester, siteRow);
    expect(siteRow, findsOneWidget);
  });
}

/// 可切换版本的假下载：订阅 JSON 与包的版本都读 [version] 当前值。
class _VersionedHttpClient implements HttpClient {
  _VersionedHttpClient(this._version);

  final String Function() _version;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final path = url.path;
    if (path.endsWith('index.json')) {
      final v = _version();
      return _Req(
        _Res(
          200,
          utf8.encode(
            '{"name":"测试源","plugins":['
            '{"id":"com.idj.ext.alpha","name":"插件alpha","version":"$v",'
            '"type":"video","adult":false,"description":"甲",'
            '"manifest":"alpha/alpha.idjplugin"}],"cms":[]}',
          ),
        ),
      );
    }
    if (path.endsWith('.idjplugin')) {
      final v = _version();
      return _Req(
        _Res(
          200,
          utf8.encode(
            jsonEncode({
              'manifest': {
                'schema': 1,
                'id': 'com.idj.ext.alpha',
                'name': '插件alpha',
                'version': v,
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
            }),
          ),
        ),
      );
    }
    return _Req(_Res(404, const []));
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Req implements HttpClientRequest {
  _Req(this._response);

  final _Res _response;

  @override
  final HttpHeaders headers = _Headers();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _Res extends Stream<List<int>> implements HttpClientResponse {
  _Res(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  HttpHeaders get headers => _Headers();

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
