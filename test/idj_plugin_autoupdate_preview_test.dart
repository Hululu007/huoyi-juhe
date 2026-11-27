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

/// 插件自动更新 + 长按卸载预览图（用户 2026-11-27 令）：
/// 一张改后市场（已装插件自动更新到 v2 后只剩版本号 + 已安装、
/// 无任何更新字样），一张市场卡长按弹出的卸载确认框。
/// 数据全是假实现（临时目录仓库 + 可切换版本假下载），不碰真
/// 网络；单独跑，不与普通测试混链。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late IdjPluginStore store;
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
    final prefs = await SharedPreferences.getInstance();
    rootDir = Directory.systemTemp.createTempSync('idj_au_prev_root');
    supportDir = Directory.systemTemp.createTempSync('idj_au_prev_support');
    remoteVersion = '1.0.0';
    store = IdjPluginStore(
      preferences: prefs,
      rootDir: rootDir,
      supportDir: supportDir,
      probe: ({required pluginId, required script, required manifest}) async {},
      uriValidator: (_) async {},
      httpFactory: () => _PreviewHttpClient(() => remoteVersion),
    );
  });

  tearDown(() {
    if (rootDir.existsSync()) rootDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey<String>('plugin-autoupdate-preview')),
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

  Future<void> pumpHost(WidgetTester tester) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-autoupdate-preview'),
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
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
  }

  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 90; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  final marketCard = find.byKey(
    const ValueKey('plugin-market-row-com.idj.ext.alpha'),
  );

  testWidgets('预览：改后市场（自动更新到 v2、无更新字样）', (tester) async {
    remoteVersion = '2.0.0';
    await tester.runAsync(() => store.installBundleText(bundleText('1.0.0')));
    await pumpHost(tester);
    await pumpUntilFound(tester, marketCard);
    // 等卡面版本落定 v2.0.0（自动更新装完 + 可见实例刷新）。
    await pumpUntilFound(tester, find.text('v2.0.0'));
    expect(find.text('v2.0.0'), findsOneWidget);
    expect(find.text('更新'), findsNothing);
    // 再滚一程让市场卡整张入镜再截（卡是加载后才长出来的，
    // pumpHost 里那一滚不够）。
    await tester.drag(find.byType(ListView), const Offset(0, -350));
    await tester.pumpAndSettle();
    await capture(tester, 'plugin_autoupdate_market');
  });

  testWidgets('预览：市场卡长按卸载确认框', (tester) async {
    remoteVersion = '1.0.0';
    await tester.runAsync(() => store.installBundleText(bundleText('1.0.0')));
    await pumpHost(tester);
    await pumpUntilFound(tester, marketCard);
    // 等卡渲染到已装态再长按（未装态的卡不挂长按手势）。
    await pumpUntilFound(tester, find.text('已安装'));
    // 先滚上去等站行落定（弹窗对账会让区段重挂载，等它稳了再
    // 长按，避免手势打在已被替换的旧卡上——界面测试同款口径）。
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('site-grid-row-idj_alpha')),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, marketCard);
    await tester.longPress(marketCard);
    final confirm = find.byKey(const ValueKey('plugin-uninstall-confirm'));
    await pumpUntilFound(tester, confirm);
    expect(confirm, findsOneWidget);
    // 等确认框入场动画落定再截，不然截到的是透明首帧。
    await tester.pumpAndSettle();
    await capture(tester, 'plugin_autoupdate_uninstall_confirm');
  });
}

/// 可切换版本的假下载：订阅与包版本都读当前值；订阅带三条，
/// 画面接近真实市场（一条已装、两条未装）。
class _PreviewHttpClient implements HttpClient {
  _PreviewHttpClient(this._version);

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
            '{"name":"预览源","plugins":['
            '{"id":"com.idj.ext.alpha","name":"插件alpha","version":"$v","type":"video","adult":false,"description":"甲","manifest":"alpha/alpha.idjplugin"},'
            '{"id":"com.idj.ext.beta","name":"插件beta","version":"1.0.0","type":"video","adult":false,"description":"乙","manifest":"beta/beta.idjplugin"},'
            '{"id":"com.idj.ext.gamma","name":"插件gamma","version":"1.0.0","type":"shortdrama","adult":false,"description":"丙","manifest":"gamma/gamma.idjplugin"}'
            '],"cms":[]}',
          ),
        ),
      );
    }
    if (path.endsWith('.idjplugin')) {
      final segment = path.split('/').last.replaceAll('.idjplugin', '');
      final v = segment == 'alpha' ? _version() : '1.0.0';
      return _Req(
        _Res(
          200,
          utf8.encode(
            jsonEncode({
              'manifest': {
                'schema': 1,
                'id': 'com.idj.ext.$segment',
                'name': '插件$segment',
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
