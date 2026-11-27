import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'preview_test_support.dart';
import 'package:fqapp/models/reading_stats.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/widgets/mine/mine_entries.dart';
import 'package:fqapp/widgets/mine/mine_plugin_section.dart';
import 'package:fqapp/widgets/mine/mine_summary.dart';
import 'package:fqapp/widgets/site_grid_dialog.dart';

/// 内嵌折叠布局预览图（2026-11-27 20:16 令：插件管理搬到「我的」
/// 页今日阅读原位置、市场与已装原地折叠展开不跳页）：
/// ①区段折叠态（市场与已装各只露三排）；②区段展开态（两段全
/// 展开）；③今日阅读挪位后的样子（挪到入口列表正上方、入口列
/// 表里不再有插件管理行）；④选站弹窗插件区（只有站卡、无市场，
/// 既有口径不变）。
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
    rootDir = Directory.systemTemp.createTempSync('idj_in_prev_root');
    supportDir = Directory.systemTemp.createTempSync('idj_in_prev_support');
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
      find.byKey(const ValueKey<String>('plugin-inline-preview')),
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
    // 12 个插件的已装列表链在假时钟区要接力几十次真 IO，轮询
    // 次数给足（预览④只装 3 个时自然提前命中返回）。
    for (var i = 0; i < 150; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> installTwelve(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < _names.length; i++) {
        await store.installBundleText(
          _bundleText(id: 'com.idj.ext.m$i', name: _names[i]),
        );
      }
    });
  }

  Widget sectionPreviewHost() => MaterialApp(
    theme: ThemeData(fontFamily: 'NotoSansCJK', brightness: Brightness.dark),
    home: Scaffold(
      backgroundColor: const Color(0xFF0F0F14),
      body: SingleChildScrollView(
        child: RepaintBoundary(
          key: const ValueKey<String>('plugin-inline-preview'),
          child: MinePluginSection(store: store),
        ),
      ),
    ),
  );

  testWidgets('预览①：插件管理区段折叠态（市场与已装各三排）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await installTwelve(tester);
    await tester.pumpWidget(sectionPreviewHost());
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.m8')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-installed-row-com.idj.ext.m0')),
    );
    // 折叠态：市场第 10 张起不建；已装按名字排序后只建前 9 张
    // （数总数，不依赖具体哪几张）。
    expect(
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.m9')),
      findsNothing,
    );
    var installedBuilt = 0;
    for (var i = 0; i < 12; i++) {
      installedBuilt += find
          .byKey(ValueKey('plugin-installed-row-com.idj.ext.m$i'))
          .evaluate()
          .length;
    }
    expect(installedBuilt, 9);
    expect(find.text('插件管理'), findsOneWidget);
    await capture(tester, 'plugin_inline_collapsed');
  });

  testWidgets('预览②：插件管理区段展开态（两段全展开）', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await installTwelve(tester);
    await tester.pumpWidget(sectionPreviewHost());
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.m8')),
    );
    final marketToggle = find.byKey(const ValueKey('plugin-market-expand'));
    await tester.ensureVisible(marketToggle);
    await tester.pumpAndSettle();
    await tester.tap(marketToggle);
    await tester.pumpAndSettle();
    final installedToggle = find.byKey(
      const ValueKey('plugin-installed-expand'),
    );
    await tester.ensureVisible(installedToggle);
    await tester.pumpAndSettle();
    await tester.tap(installedToggle);
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('plugin-installed-row-com.idj.ext.m11')),
    );
    expect(
      find.byKey(const ValueKey('plugin-market-row-com.idj.ext.m11')),
      findsOneWidget,
    );
    await capture(tester, 'plugin_inline_expanded');
  });

  testWidgets('预览③：今日阅读挪到入口列表正上方、无插件管理行', (tester) async {
    await loadPreviewFonts(tester, lucide: true);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-inline-preview'),
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: 'NotoSansCJK',
            brightness: Brightness.dark,
          ),
          home: Scaffold(
            backgroundColor: const Color(0xFF0F0F14),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MineSummary(
                    stats: ReadingStats.empty,
                    today: DateUtils.dateOnly(DateTime.now()),
                  ),
                  const MineEntries(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('今日阅读'), findsOneWidget);
    expect(find.text('数据库导入'), findsOneWidget);
    // 入口列表里不再有插件管理行（不能再点行跳页）。
    expect(find.text('插件管理'), findsNothing);
    await capture(tester, 'plugin_inline_today_moved');
  });

  testWidgets('预览④：选站弹窗插件区只有站卡、无市场', (tester) async {
    await loadPreviewFonts(tester);
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.demo', name: '橙果短剧'),
      );
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.aiguo', name: '爱果短剧'),
      );
      await store.installBundleText(
        _bundleText(id: 'com.idj.ext.huangguo', name: '黄果短剧'),
      );
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey<String>('plugin-inline-preview'),
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

const _names = [
  '橙果短剧',
  '爱果短剧',
  '黄果短剧',
  '青果视频',
  '红果影视',
  '蓝果短剧',
  '紫果漫剧',
  '金果视频',
  '银果短剧',
  '星果影视',
  '月果漫剧',
  '云果视频',
];

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

/// 预览专用假下载：任何地址都回同一份 12 条插件的订阅。
class _PreviewHttpClient implements HttpClient {
  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _PreviewRequest(_PreviewResponse(200, utf8.encode(_subscriptionJson())));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

String _subscriptionJson() => jsonEncode({
  'name': '官方插件源',
  'plugins': [
    for (var i = 0; i < _names.length; i++)
      {
        'id': 'com.idj.ext.m$i',
        'name': _names[i],
        'version': '1.0.0',
        'type': 'video',
        'adult': false,
        'description': '预览条目 $i',
        'manifest': 'm$i/m$i.idjplugin',
      },
  ],
  'cms': [],
});

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
