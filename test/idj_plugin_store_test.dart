import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';

/// 插件仓库测试：manifest 校验 / 域名归一化 / integrity / 安装链
/// （probe、写盘、索引、站 key）/ 卸载 / 启停 / 看门狗 / 订阅 /
/// 输入解释器 / 权限差异。网络与 probe 全用假实现，不碰真出口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;
  var probeCalls = 0;
  var probeShouldFail = false;

  Future<void> fakeProbe({
    required String pluginId,
    required String script,
    required Map<String, dynamic> manifest,
  }) async {
    probeCalls++;
    if (probeShouldFail) {
      throw IdjPluginFailure('试加载失败：插件缺少 manifest 声明的能力函数：play');
    }
  }

  IdjPluginStore makeStore({HttpClient Function()? httpFactory}) =>
      IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe: fakeProbe,
        httpFactory: httpFactory,
        uriValidator: (_) async {},
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = await Directory.systemTemp.createTemp('idj_root');
    supportDir = await Directory.systemTemp.createTemp('idj_support');
    probeCalls = 0;
    probeShouldFail = false;
  });

  tearDown(() async {
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  group('manifest 校验', () {
    test('合法 manifest 零问题', () {
      final manifest = IdjPluginManifest.fromJson(_manifestJson());
      expect(manifest.problems(), isEmpty);
    });

    test('域名清单先归一化再验：协议头/端口/路径剥掉后合法', () {
      final manifest = IdjPluginManifest.fromJson(
        _manifestJson(
          http: ['https://EXAMPLE.com:8443/api', 'http://*.Sub.Example.COM/x'],
        ),
      );
      expect(manifest.httpDomains, ['example.com', '*.sub.example.com']);
      expect(manifest.problems(), isEmpty);
    });

    test('IP 字面量域名被拒', () {
      final manifest = IdjPluginManifest.fromJson(
        _manifestJson(http: ['127.0.0.1']),
      );
      expect(manifest.problems().join(), contains('域名不合法'));
    });

    test('坏 id / 坏版本 / 缺能力逐条报', () {
      final manifest = IdjPluginManifest.fromJson(
        _manifestJson(
          id: 'Bad ID',
          version: '1.0',
          capabilities: ['home'],
        ),
      );
      final problems = manifest.problems().join('；');
      expect(problems, contains('反向域名'));
      expect(problems, contains('三段版本号'));
      expect(problems, contains('缺少 detail 能力'));
      expect(problems, contains('缺少 play 能力'));
    });

    test('minAppVersion 高于宿主规格被拒', () {
      final manifest = IdjPluginManifest.fromJson(
        _manifestJson(minAppVersion: '9.9.9'),
      );
      expect(manifest.problems().join(), contains('高于本机支持'));
    });
  });

  group('包解析与 integrity', () {
    test('扁平 integrity 对齐放行、篡改脚本被拒', () {
      final script = _script();
      final good = _bundleText(script: script, integrity: _hashOf(script));
      expect(IdjPluginStore.parseBundleText(good).manifest.id,
          'com.idj.ext.demo');
      final bad = _bundleText(
        script: '$script // tampered',
        integrity: _hashOf(script),
      );
      expect(
        () => IdjPluginStore.parseBundleText(bad),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            contains('完整性校验失败'),
          ),
        ),
      );
    });

    test('对象形态 integrity（files[entry]）同样核对', () {
      final script = _script();
      final text = _bundleText(
        script: script,
        integrity: {
          'files': {'main.js': 'sha256-${_hashOf(script)}'},
        },
      );
      expect(IdjPluginStore.parseBundleText(text).fileHash, _hashOf(script));
    });

    test('真包 fixture（橙果短剧）解析与 integrity 全过', () {
      final text = File('test/fixtures/idj_chengguo.idjplugin')
          .readAsStringSync();
      final bundle = IdjPluginStore.parseBundleText(text);
      expect(bundle.manifest.id, 'com.idj.ext.chengguo');
      expect(bundle.manifest.type, 'video');
      expect(bundle.manifest.capabilities,
          containsAll(['home', 'category', 'detail', 'play']));
    });

    test('缺 manifest / 缺脚本的文本被拒', () {
      expect(
        () => IdjPluginStore.parseBundleText('{"a":1}'),
        throwsA(isA<IdjPluginFailure>()),
      );
      expect(
        () => IdjPluginStore.parseBundleText('not json'),
        throwsA(isA<IdjPluginFailure>()),
      );
    });
  });

  group('安装 / 卸载 / 启停', () {
    test('安装全链：probe 被调、包落盘、索引登记、站 key 生成', () async {
      final store = makeStore();
      final installed = await store.installBundleText(_bundleText());
      expect(probeCalls, 1);
      expect(installed.entry.siteKey, 'idj_demo');
      expect(installed.entry.enabled, isTrue);
      final listed = await store.listInstalled();
      expect(listed, hasLength(1));
      expect(listed.single.damaged, isFalse);
      final bundle = await store.readBundle('com.idj.ext.demo');
      expect(bundle, isNotNull);
      expect(bundle!.manifest.name, '演示插件');
    });

    test('probe 失败不装：索引与磁盘都不留半成品', () async {
      probeShouldFail = true;
      final store = makeStore();
      await expectLater(
        store.installBundleText(_bundleText()),
        throwsA(isA<IdjPluginFailure>()),
      );
      expect(await store.listInstalled(), isEmpty);
      final dirs = await rootDir.list().toList();
      expect(dirs.where((e) => e.path.contains('staging')), isEmpty);
      expect(dirs.where((e) => e.path.contains('com.idj')), isEmpty);
    });

    test('同末段不同 id 的站 key 加后缀', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      final second = await store.installBundleText(
        _bundleText(id: 'org.other.demo'),
      );
      expect(second.entry.siteKey, 'idj_demo_2');
    });

    test('覆盖安装保留停用状态', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      await store.setEnabled('com.idj.ext.demo', false);
      final updated = await store.installBundleText(
        _bundleText(version: '1.0.1'),
      );
      expect(updated.entry.enabled, isFalse);
      expect(updated.entry.version, '1.0.1');
    });

    test('卸载删包删索引；卸未装的报错', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      await store.uninstall('com.idj.ext.demo');
      expect(await store.listInstalled(), isEmpty);
      await expectLater(
        store.uninstall('com.idj.ext.demo'),
        throwsA(isA<IdjPluginFailure>()),
      );
    });

    test('包文件被删后列表标损坏、启用被拒', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      await store.setEnabled('com.idj.ext.demo', false);
      final dir = Directory(
        '${rootDir.path}/com.idj.ext.demo',
      );
      await dir.delete(recursive: true);
      final listed = await store.listInstalled();
      expect(listed.single.damaged, isTrue);
      expect(listed.single.damageReason, contains('缺失'));
      await expectLater(
        store.setEnabled('com.idj.ext.demo', true),
        throwsA(isA<IdjPluginFailure>()),
      );
    });
  });

  group('看门狗', () {
    test('连续 3 次非瞬时失败自动停用，成功清零', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      await store.recordFailure('com.idj.ext.demo', code: 'E_PLUGIN');
      await store.recordFailure('com.idj.ext.demo', code: 'E_PLUGIN');
      var index = await store.readIndex();
      expect(index['com.idj.ext.demo']!.enabled, isTrue);
      expect(index['com.idj.ext.demo']!.failures, 2);
      await store.recordSuccess('com.idj.ext.demo');
      index = await store.readIndex();
      expect(index['com.idj.ext.demo']!.failures, 0);
      await store.recordFailure('com.idj.ext.demo', code: 'E_PLUGIN');
      await store.recordFailure('com.idj.ext.demo', code: 'E_PLUGIN');
      await store.recordFailure('com.idj.ext.demo', code: 'E_PLUGIN');
      index = await store.readIndex();
      expect(index['com.idj.ext.demo']!.enabled, isFalse);
    });

    test('网络类瞬时错误不计数', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      for (var i = 0; i < 5; i++) {
        await store.recordFailure('com.idj.ext.demo', code: 'E_NET');
      }
      final index = await store.readIndex();
      expect(index['com.idj.ext.demo']!.failures, 0);
      expect(index['com.idj.ext.demo']!.enabled, isTrue);
    });
  });

  group('订阅与解释器', () {
    test('真索引 fixture 解析：相对包路径按订阅地址解析', () {
      final raw = File('test/fixtures/idj_subscription_index.json')
          .readAsStringSync();
      final subscription = IdjPluginStore.parseSubscriptionJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
        Uri.parse('https://example.com/plugins/index.json'),
      );
      expect(subscription.plugins.length, greaterThanOrEqualTo(20));
      final chengguo = subscription.plugins
          .firstWhere((p) => p.id == 'com.idj.ext.chengguo');
      expect(
        chengguo.manifestUrl,
        'https://example.com/plugins/chengguo/chengguo.idjplugin',
      );
    });

    test('添加订阅先拉成功才保存；失败不保存', () async {
      final routes = <String, _FakeResponse Function()>{
        'https://example.com/sub.json': () => _FakeResponse(
          200,
          utf8.encode(jsonEncode({
            'name': '测试源',
            'plugins': [
              {
                'id': 'com.idj.ext.demo',
                'name': '演示插件',
                'version': '1.0.0',
                'type': 'video',
                'adult': false,
                'manifest': 'demo/demo.idjplugin',
              },
            ],
          })),
        ),
      };
      final store = makeStore(
        httpFactory: () => _FakeHttpClient(
          (url) => routes[url.toString()]?.call() ??
              _FakeResponse(404, const []),
        ),
      );
      final subscription =
          await store.addSubscription('https://example.com/sub.json');
      expect(subscription.name, '测试源');
      expect(subscription.plugins, hasLength(1));
      await expectLater(
        store.addSubscription('https://example.com/missing.json'),
        throwsA(isA<IdjPluginFailure>()),
      );
      final saved = prefs.getStringList(idjSubscriptionsPrefsKey);
      expect(saved, ['https://example.com/sub.json']);
    });

    test('内置订阅不可删；删用户订阅不卸已装插件', () async {
      final store = makeStore();
      await store.installBundleText(_bundleText());
      await store.removeSubscription(idjBuiltInSubscriptionUrl);
      // 内置地址删除是空操作（不抛、不影响已装）。
      expect(await store.listInstalled(), hasLength(1));
    });

    test('从订阅条目安装：下载包文本走安装链', () async {
      final bundle = _bundleText();
      final store = makeStore(
        httpFactory: () => _FakeHttpClient(
          (url) => url.toString().endsWith('demo.idjplugin')
              ? _FakeResponse(200, utf8.encode(bundle))
              : _FakeResponse(404, const []),
        ),
      );
      final installed = await store.installFromSubscriptionPlugin(
        IdjSubscriptionPlugin(
          id: 'com.idj.ext.demo',
          name: '演示插件',
          version: '1.0.0',
          type: 'video',
          adult: false,
          description: '',
          manifestUrl: 'https://example.com/demo/demo.idjplugin',
        ),
      );
      expect(installed.entry.siteKey, 'idj_demo');
    });

    test('interpret 分流：包 / 订阅 / M3U / TVBox', () async {
      final store = makeStore();
      final bundleResult = await store.interpret(_bundleText());
      expect(bundleResult.kind, IdjInterpretKind.bundle);
      final m3uResult = await store.interpret('#EXTM3U\n#EXTINF:-1,央视');
      expect(m3uResult.kind, IdjInterpretKind.m3u);
      final tvboxResult = await store.interpret('{"sites": [], "spider": "x"}');
      expect(tvboxResult.kind, IdjInterpretKind.tvbox);
      final subResult = await store.interpret('{"name":"源","plugins":[]}');
      expect(subResult.kind, IdjInterpretKind.subscription);
      final junkResult = await store.interpret('hello');
      expect(junkResult.kind, IdjInterpretKind.unsupported);
    });
  });

  group('权限差异', () {
    test('新增域名与开 CF 被算出', () {
      final oldManifest = IdjPluginManifest.fromJson(_manifestJson());
      final newManifest = IdjPluginManifest.fromJson(
        _manifestJson(
          http: ['example.com', 'new.example.com'],
          cloudflare: true,
        ),
      );
      final diff = IdjPluginStore.permissionDiff(oldManifest, newManifest);
      expect(diff.addedDomains, ['new.example.com']);
      expect(diff.cloudflareEnabled, isTrue);
      expect(diff.hasExpansion, isTrue);
      expect(diff.describe().join(), contains('新版本多申请了 1 个域名'));
    });
  });

  group('错误文案中文化（界面口径）', () {
    test('probe 底层英文异常不外露：转中文人话、原文不进 message', () async {
      final store = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe:
            ({
              required pluginId,
              required script,
              required manifest,
            }) async {
              // 模拟原生桥回的典型英文异常串（StateError 自带前缀）。
              throw StateError(
                'JS 执行失败：ReferenceError: foo is not defined',
              );
            },
        uriValidator: (_) async {},
      );
      final bundle = IdjPluginStore.parseBundleText(_bundleText());
      await expectLater(
        store.probeBundle(bundle),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('试加载失败'),
              contains('请稍后重试'),
              isNot(contains('Bad state')),
              isNot(contains('JS 执行失败')),
              isNot(contains('ReferenceError')),
              isNot(contains('foo')),
            ]),
          ),
        ),
      );
    });

    test('下载底层英文异常不外露：转中文人话', () async {
      final store = makeStore(
        httpFactory: () => _FakeHttpClient((url) {
          throw const SocketException('Failed host lookup: example.com');
        }),
      );
      await expectLater(
        store.downloadText(
          Uri.parse('https://example.com/sub.json'),
          maxBytes: 1024,
        ),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('下载失败'),
              contains('请检查网络后重试'),
              isNot(contains('SocketException')),
              isNot(contains('Failed host lookup')),
            ]),
          ),
        ),
      );
    });
  });
}

// ---------- 测试夹具 ----------

String _script() =>
    'export default { home(){}, category(){}, search(){}, '
    'detail(){}, play(){} };';

String _hashOf(String script) => IdjPluginBundle.hashScript(script);

Map<String, dynamic> _manifestJson({
  String id = 'com.idj.ext.demo',
  String version = '1.0.0',
  String type = 'video',
  bool adult = false,
  List<String> capabilities = const [
    'home',
    'category',
    'search',
    'detail',
    'play',
  ],
  List<String> http = const ['example.com'],
  bool cloudflare = false,
  String minAppVersion = '',
}) => {
  'schema': 1,
  'id': id,
  'name': '演示插件',
  'version': version,
  'entry': 'main.js',
  'type': type,
  'adult': adult,
  'capabilities': capabilities,
  'minAppVersion': minAppVersion,
  'permissions': {
    'http': http,
    'media': http,
    'cloudflare': cloudflare,
    'storage': false,
    'login': false,
  },
};

String _bundleText({
  String id = 'com.idj.ext.demo',
  String version = '1.0.0',
  String? script,
  Object? integrity,
}) {
  final entryScript = script ?? _script();
  return jsonEncode({
    'manifest': {
      ..._manifestJson(id: id, version: version),
      'integrity': ?integrity,
    },
    'files': {'main.js': entryScript},
  });
}

// ---------- 假 HTTP ----------

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
