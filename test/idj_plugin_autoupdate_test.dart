import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';

/// 插件自动更新 + 已卸载四态记录测试（用户 2026-11-27 令）：
/// - 首装手动、之后订阅索引出新版时静默自动装（走完整安装链）；
/// - 无新版不下载、未装不自动装、失败保旧版、损坏跳过；
/// - 卸载留持久化记录（id + 卸载时版本）：市场隐藏判定、装回
///   清记录、再卸载按新版本重记、重启（新仓库实例）不复活。
/// 网络与 probe 全用假实现，不碰真出口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;

  // 假远程：订阅版本号、包版本号、包失败模式都可中途切换。
  var remoteVersion = '2.0.0';
  var bundleVersion = '2.0.0';
  var bundleTampered = false;
  var bundleMissing = false;
  var bundleRequests = 0;

  Future<void> fakeProbe({
    required String pluginId,
    required String script,
    required Map<String, dynamic> manifest,
  }) async {}

  IdjPluginStore makeStore() => IdjPluginStore(
    preferences: prefs,
    rootDir: rootDir,
    supportDir: supportDir,
    probe: fakeProbe,
    httpFactory: () => _FakeHttpClient((url) {
      if (url.toString().endsWith('demo.idjplugin')) {
        bundleRequests++;
        if (bundleMissing) return _FakeResponse(404, const []);
        return _FakeResponse(
          200,
          utf8.encode(
            _bundleText(
              version: bundleVersion,
              integrity: bundleTampered ? 'sha256-bogus' : null,
            ),
          ),
        );
      }
      return _FakeResponse(404, const []);
    }),
    uriValidator: (_) async {},
  );

  IdjSubscription subscription() => IdjPluginStore.parseSubscriptionJson({
    'name': '测试源',
    'plugins': [
      {
        'id': 'com.idj.ext.demo',
        'name': '演示插件',
        'version': remoteVersion,
        'type': 'video',
        'adult': false,
        'manifest': 'demo/demo.idjplugin',
      },
    ],
  }, Uri.parse('https://example.com/sub.json'));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = await Directory.systemTemp.createTemp('idj_au_root');
    supportDir = await Directory.systemTemp.createTemp('idj_au_support');
    remoteVersion = '2.0.0';
    bundleVersion = '2.0.0';
    bundleTampered = false;
    bundleMissing = false;
    bundleRequests = 0;
  });

  tearDown(() async {
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  group('自动更新（订阅索引路线）', () {
    test('已装 v1、订阅出 v2：静默装上，索引与包都到 v2', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, ['com.idj.ext.demo']);
      expect(bundleRequests, 1);
      final installed = await store.listInstalled();
      expect(installed, hasLength(1));
      expect(installed.single.entry.version, '2.0.0');
      expect(installed.single.damaged, isFalse);
      final bundle = await store.readBundle('com.idj.ext.demo');
      expect(bundle!.manifest.version, '2.0.0');
    });

    test('订阅版本与已装相同：不下载、不装', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      remoteVersion = '1.0.0';
      bundleVersion = '1.0.0';
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      expect(bundleRequests, 0);
      final installed = await store.listInstalled();
      expect(installed.single.entry.version, '1.0.0');
    });

    test('订阅版本更低：不动', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      remoteVersion = '0.9.0';
      bundleVersion = '0.9.0';
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      expect(bundleRequests, 0);
    });

    test('从未装过的插件：订阅有新版也不自动装（首装永远手动）', () async {
      final store = makeStore();
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      expect(bundleRequests, 0);
      expect(await store.listInstalled(), isEmpty);
    });

    test('更新包 integrity 不符：拒装、保留 v1 完好可用', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      bundleTampered = true;
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      final installed = await store.listInstalled();
      expect(installed, hasLength(1));
      expect(installed.single.entry.version, '1.0.0');
      expect(installed.single.damaged, isFalse);
    });

    test('更新包下载 404：保留 v1 完好可用', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      bundleMissing = true;
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      final installed = await store.listInstalled();
      expect(installed.single.entry.version, '1.0.0');
      expect(installed.single.damaged, isFalse);
    });

    test('成人插件已装：照常自动更新（门禁只管显示、不拦更新）', () async {
      final store = makeStore();
      await store.installBundleText(
        _bundleText(version: '1.0.0', adult: true),
      );
      // 订阅条目与包都标成人，版本升到 2.0.0。
      final adultSub = IdjPluginStore.parseSubscriptionJson({
        'name': '测试源',
        'plugins': [
          {
            'id': 'com.idj.ext.demo',
            'name': '演示插件',
            'version': '2.0.0',
            'type': 'video',
            'adult': true,
            'manifest': 'demo/demo.idjplugin',
          },
        ],
      }, Uri.parse('https://example.com/sub.json'));
      // 包侧 adult 由 _bundleText 默认 false：换成成人包夹具。
      final store2 = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe: fakeProbe,
        httpFactory: () => _FakeHttpClient(
          (url) => url.toString().endsWith('demo.idjplugin')
              ? _FakeResponse(
                  200,
                  utf8.encode(_bundleText(version: '2.0.0', adult: true)),
                )
              : _FakeResponse(404, const []),
        ),
        uriValidator: (_) async {},
      );
      final updated = await store2.autoUpdateFromSubscriptions([adultSub]);
      expect(updated, ['com.idj.ext.demo']);
      final installed = await store2.listInstalled();
      expect(installed.single.entry.version, '2.0.0');
      expect(installed.single.entry.adult, isTrue);
    });

    test('包文件损坏的已装条目：自动更新跳过、不冒充修复', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      final dir = Directory(
        '${rootDir.path}/com.idj.ext.demo',
      );
      await dir.delete(recursive: true);
      final before = await store.listInstalled();
      expect(before.single.damaged, isTrue);
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      expect(bundleRequests, 0);
      final after = await store.listInstalled();
      expect(after, hasLength(1));
      expect(after.single.entry.version, '1.0.0');
    });
  });

  group('已卸载记录（市场四态）', () {
    test('卸载留记录：id + 卸载时版本；新实例（重启）仍在、已装不复活', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      await store.uninstall('com.idj.ext.demo');
      expect(await store.readUninstalledVersions(), {
        'com.idj.ext.demo': '1.0.0',
      });
      expect(await store.listInstalled(), isEmpty);
      // 模拟重启：同 prefs、同目录的新仓库实例。
      final rebooted = makeStore();
      expect(await rebooted.readUninstalledVersions(), {
        'com.idj.ext.demo': '1.0.0',
      });
      expect(await rebooted.listInstalled(), isEmpty);
      expect(await rebooted.readIndex(), isEmpty);
    });

    test('隐藏判定：远程 ≤ 记录版本隐藏、更高重新出现、无记录不隐藏', () {
      expect(
        IdjPluginStore.marketEntryHiddenAfterUninstall(
          remoteVersion: '1.0.0',
          uninstalledVersion: '1.0.0',
        ),
        isTrue,
      );
      expect(
        IdjPluginStore.marketEntryHiddenAfterUninstall(
          remoteVersion: '0.9.0',
          uninstalledVersion: '1.0.0',
        ),
        isTrue,
      );
      expect(
        IdjPluginStore.marketEntryHiddenAfterUninstall(
          remoteVersion: '1.0.1',
          uninstalledVersion: '1.0.0',
        ),
        isFalse,
      );
      expect(
        IdjPluginStore.marketEntryHiddenAfterUninstall(
          remoteVersion: '1.0.0',
          uninstalledVersion: null,
        ),
        isFalse,
      );
    });

    test('装回清记录；再卸载按新版本重新记', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      await store.uninstall('com.idj.ext.demo');
      expect(await store.readUninstalledVersions(), {
        'com.idj.ext.demo': '1.0.0',
      });
      await store.installBundleText(_bundleText(version: '2.0.0'));
      expect(await store.readUninstalledVersions(), isEmpty);
      await store.uninstall('com.idj.ext.demo');
      expect(await store.readUninstalledVersions(), {
        'com.idj.ext.demo': '2.0.0',
      });
    });

    test('已卸载的插件不被自动更新装回（不在已装索引里）', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText(version: '1.0.0'));
      await store.uninstall('com.idj.ext.demo');
      remoteVersion = '3.0.0';
      bundleVersion = '3.0.0';
      final updated = await store.autoUpdateFromSubscriptions([
        subscription(),
      ]);
      expect(updated, isEmpty);
      expect(bundleRequests, 0);
      expect(await store.listInstalled(), isEmpty);
    });
  });
}

// ---------- 测试夹具 ----------

String _script() =>
    'export default { home(){}, category(){}, search(){}, '
    'detail(){}, play(){} };';

String _bundleText({String version = '1.0.0', bool adult = false, Object? integrity}) {
  return jsonEncode({
    'manifest': {
      'schema': 1,
      'id': 'com.idj.ext.demo',
      'name': '演示插件',
      'version': version,
      'entry': 'main.js',
      'type': 'video',
      'adult': adult,
      'capabilities': ['home', 'category', 'search', 'detail', 'play'],
      'permissions': {
        'http': ['example.com'],
        'media': ['example.com'],
        'cloudflare': false,
        'storage': false,
        'login': false,
      },
      'integrity': ?integrity,
    },
    'files': {'main.js': _script()},
  });
}

// ---------- 假 HTTP（与 idj_plugin_store_test 同款） ----------

class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = [value.toString()];
  }

  @override
  String? value(String name) => _values[name.toLowerCase()]?.firstOrNull;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this._response);

  final _FakeResponse _response;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _response;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._body);

  @override
  final int statusCode;
  final List<int> _body;

  @override
  HttpHeaders get headers => _FakeHeaders();

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

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._handler);

  final _FakeResponse Function(Uri url) _handler;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeRequest(_handler(url));

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
