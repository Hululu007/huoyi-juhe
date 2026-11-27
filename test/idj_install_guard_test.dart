import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';

/// 安装链失败注入：probe 普通异常 / probe IdjPluginFailure /
/// 引擎未接线 / 包文本损坏 / 下载步失败，逐个断言——抛出的都是
/// 中文 IdjPluginFailure、索引不写该插件、root 下无 .staging 残留。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = await Directory.systemTemp.createTemp('idj_guard_root');
    supportDir = await Directory.systemTemp.createTemp('idj_guard_support');
    IdjPluginStore.probeHandler = null;
  });

  tearDown(() async {
    IdjPluginStore.probeHandler = null;
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  IdjPluginStore makeStore({
    IdjProbeFn? probe,
    HttpClient Function()? httpFactory,
  }) => IdjPluginStore(
    preferences: prefs,
    rootDir: rootDir,
    supportDir: supportDir,
    probe: probe,
    httpFactory: httpFactory,
    uriValidator: (_) async {},
  );

  Future<void> expectNoResidue(IdjPluginStore store) async {
    final index = await store.readIndex();
    expect(index.containsKey('com.idj.ext.demo'), isFalse);
    expect(index, isEmpty);
    final entries = await rootDir.list(recursive: true).toList();
    expect(
      entries.where((e) => e.path.contains('.staging')),
      isEmpty,
      reason: 'root 下不应留 .staging 残留：$entries',
    );
  }

  Matcher chineseFailure([String? containsText]) => throwsA(
    isA<IdjPluginFailure>().having(
      (e) => e.message,
      'message',
      allOf([
        // 中文文案：至少含一段中文字符，且不带英文异常原文痕迹。
        contains(RegExp(r'[一-鿿]')),
        if (containsText != null) contains(containsText),
        isNot(contains('Bad state')),
        isNot(contains('StateError')),
      ]),
    ),
  );

  group('安装链失败注入', () {
    test('probe 抛普通异常：收成中文 IdjPluginFailure、不写索引不留 staging', () async {
      final store = makeStore(
        probe:
            ({required pluginId, required script, required manifest}) async =>
                throw StateError('boom english probe error'),
      );
      await expectLater(
        store.installBundleText(_bundleText()),
        chineseFailure('试加载失败'),
      );
      await expectNoResidue(store);
    });

    test('probe 抛 IdjPluginFailure：原样透传、不写索引不留 staging', () async {
      final store = makeStore(
        probe:
            ({required pluginId, required script, required manifest}) async =>
                throw IdjPluginFailure('试加载失败：插件缺少 manifest 声明的能力函数：play'),
      );
      await expectLater(
        store.installBundleText(_bundleText()),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            '试加载失败：插件缺少 manifest 声明的能力函数：play',
          ),
        ),
      );
      await expectNoResidue(store);
    });

    test('引擎未接线（probeHandler 为 null）：中文报错、不写索引不留 staging', () async {
      // 不传构造 probe、静态 probeHandler 在 setUp 已置 null。
      final store = makeStore();
      await expectLater(
        store.installBundleText(_bundleText()),
        chineseFailure('试加载失败'),
      );
      await expectNoResidue(store);
    });

    test('包文本损坏：中文报错、不写索引不留 staging', () async {
      final store = makeStore(
        probe:
            ({required pluginId, required script, required manifest}) async {},
      );
      await expectLater(
        store.installBundleText('not json at all'),
        chineseFailure(),
      );
      await expectLater(store.installBundleText('{"a":1}'), chineseFailure());
      await expectNoResidue(store);
    });

    test('下载步失败（订阅安装 404）：中文报错、不写索引不留 staging', () async {
      final store = makeStore(
        probe:
            ({required pluginId, required script, required manifest}) async {},
        httpFactory: () =>
            _FakeHttpClient((url) => _FakeResponse(404, const [])),
      );
      await expectLater(
        store.installFromSubscriptionPlugin(
          IdjSubscriptionPlugin(
            id: 'com.idj.ext.demo',
            name: '演示插件',
            version: '1.0.0',
            type: 'video',
            adult: false,
            description: '',
            manifestUrl: 'https://example.com/demo/demo.idjplugin',
          ),
        ),
        chineseFailure('下载失败'),
      );
      await expectNoResidue(store);
    });

    test('下载步底层英文异常（订阅安装）：收成中文、不写索引不留 staging', () async {
      final store = makeStore(
        probe:
            ({required pluginId, required script, required manifest}) async {},
        httpFactory: () => _FakeHttpClient((url) {
          throw const SocketException('Failed host lookup: example.com');
        }),
      );
      await expectLater(
        store.installFromSubscriptionPlugin(
          IdjSubscriptionPlugin(
            id: 'com.idj.ext.demo',
            name: '演示插件',
            version: '1.0.0',
            type: 'video',
            adult: false,
            description: '',
            manifestUrl: 'https://example.com/demo/demo.idjplugin',
          ),
        ),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('下载失败'),
              isNot(contains('SocketException')),
              isNot(contains('Failed host lookup')),
            ]),
          ),
        ),
      );
      await expectNoResidue(store);
    });
  });
}

// ---------- 测试夹具（与 idj_plugin_store_test 同款最小包） ----------

String _bundleText() {
  const script =
      'export default { home(){}, category(){}, search(){}, '
      'detail(){}, play(){} };';
  return jsonEncode({
    'manifest': {
      'schema': 1,
      'id': 'com.idj.ext.demo',
      'name': '演示插件',
      'version': '1.0.0',
      'entry': 'main.js',
      'type': 'video',
      'adult': false,
      'capabilities': ['home', 'category', 'search', 'detail', 'play'],
      'permissions': {
        'http': ['example.com'],
        'media': ['example.com'],
        'cloudflare': false,
        'storage': false,
        'login': false,
      },
    },
    'files': {'main.js': script},
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
