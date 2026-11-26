import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/idj_runtime.dart';

/// 插件运行时测试：脚本组装（垫片/域名/改写/驱动）、契约转换
/// （home/条目/详情/取流的口径与上限）、内容客户端经假评估器
/// 走分类→列表→详情→取流、storage 信封往返、错误码映射。
/// 评估器是假实现，不碰真 QuickJS 桥（真桥全链由 Node 验证台
/// 用生产垫片原文跑真包验证）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory supportDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    rootDir = await Directory.systemTemp.createTemp('idj_rt_root');
    supportDir = await Directory.systemTemp.createTemp('idj_rt_support');
  });

  tearDown(() async {
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  IdjPluginManifest manifest({bool storage = false}) =>
      IdjPluginManifest.fromJson({
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
          'storage': storage,
          'login': false,
        },
      });

  group('脚本组装', () {
    test('垫片、域名、存储、改写与驱动都在同一份脚本里', () {
      final script = buildIdjDriverScript(
        pluginScript: 'export default { home() {} };',
        manifest: manifest(storage: true),
        op: 'home',
        args: const {},
        storage: const {'token': 'abc'},
      );
      expect(script, contains('var __idjNative'));
      expect(script, contains('var host = {'));
      expect(script, contains('"example.com"'));
      expect(script, contains('"token":"abc"'));
      expect(script, contains('var __idj_plugin ='));
      // 插件脚本自己的 export default 已被改写（驱动里的报错文案
      // 含同名字样，不在此列）。
      expect(script, isNot(contains('export default {')));
      expect(script, contains("__idj_plugin['home']"));
      // 白名单与禁发头在垫片里。
      expect(script, contains('__idjHostAllowed'));
      expect(script, contains("'cookie': 1"));
    });
  });

  group('契约转换', () {
    test('home：分类前置「全部」，条目取 poster/subtitle', () {
      final home = parseIdjHome({
        'categories': [
          {'id': 'movie', 'title': '电影'},
        ],
        'items': [
          {
            'id': 'v1',
            'title': '片一',
            'poster': 'https://img.example.com/1.jpg',
            'subtitle': 'HD',
          },
        ],
      });
      expect(home.categories.first.id, '');
      expect(home.categories.first.name, '全部');
      expect(home.categories[1].name, '电影');
      expect(home.items.single.cover, 'https://img.example.com/1.jpg');
      expect(home.items.single.remark, 'HD');
    });

    test('详情：线路/分集转宿主选集，videoId 带线路键', () {
      final detail = parseIdjDetail({
        'id': 's1',
        'title': '剧一',
        'description': '简介',
        'year': '2026',
        'lines': [
          {
            'name': '线路A',
            'episodes': [
              {'id': 'e1', 'title': '第1集'},
              {'id': 'e2', 'title': '第2集'},
            ],
          },
        ],
      }, 's1');
      expect(detail.episodes, hasLength(2));
      expect(detail.episodes.first.videoId, '线路A\u0001e1');
      expect(detail.extra['year'], '2026');
      expect(detail.synopsis, '简介');
    });

    test('取流：跳过不合规地址取第一条合规流，headers 透传', () {
      final source = parseIdjPlay({
        'streams': [
          {'url': 'http://insecure.example.com/a.m3u8'},
          {'url': 'https://127.0.0.1/a.m3u8'},
          {
            'url': 'https://cdn.example.com/a.m3u8',
            'headers': {'Referer': 'https://example.com/'},
          },
        ],
      });
      expect(source.url, 'https://cdn.example.com/a.m3u8');
      expect(source.headers['Referer'], 'https://example.com/');
    });

    test('取流：空 streams 与 DRM 都如实报错', () {
      expect(
        () => parseIdjPlay({'streams': []}),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('没有返回可播放地址'),
          ),
        ),
      );
      expect(
        () => parseIdjPlay({
          'streams': [
            {
              'url': 'https://cdn.example.com/a.m3u8',
              'drm': {'type': 'widevine'},
            },
          ],
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('DRM'),
          ),
        ),
      );
    });
  });

  group('内容客户端（假评估器全链）', () {
    Future<IdjSiteContentClient> makeClient({
      required Map<String, dynamic> Function(String op) results,
      List<String>? seenOps,
      bool storage = false,
    }) async {
      final store = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe: ({required pluginId, required script, required manifest}) async {},
        uriValidator: (_) async {},
      );
      final bundleText = jsonEncode({
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
            'storage': storage,
            'login': false,
          },
        },
        'files': {'main.js': 'export default {};'},
      });
      await store.installBundleText(bundleText);
      final runtime = IdjRuntime(
        store: store,
        evalFn: (script, timeoutMs) async {
          final op = ['home', 'category', 'detail', 'play', 'search']
              .firstWhere(
                (name) => script.contains("__idj_plugin['$name']"),
                orElse: () => '',
              );
          seenOps?.add(op);
          return jsonEncode({
            'ok': true,
            'result': results(op),
            'storage': {'seen_$op': true},
          });
        },
      );
      return IdjSiteContentClient(
        pluginId: 'com.idj.ext.demo',
        store: store,
        runtime: runtime,
      );
    }

    test('分类→列表→详情→取流全链映射', () async {
      final seenOps = <String>[];
      final client = await makeClient(
        seenOps: seenOps,
        results: (op) => switch (op) {
          'home' => {
            'categories': [
              {'id': 'movie', 'title': '电影'},
            ],
            'items': [
              {'id': 'v1', 'title': '首页片'},
            ],
          },
          'category' => {
            'items': [
              {'id': 'v2', 'title': '分类片', 'poster': 'https://i/2.jpg'},
            ],
          },
          'detail' => {
            'id': 'v2',
            'title': '分类片',
            'lines': [
              {
                'name': '主线',
                'episodes': [
                  {'id': 'e1', 'title': '第1集'},
                ],
              },
            ],
          },
          'play' => {
            'streams': [
              {'url': 'https://cdn.example.com/v2.m3u8'},
            ],
          },
          _ => <String, dynamic>{},
        },
      );
      final categories = await client.categories();
      expect(categories.map((c) => c.name), ['全部', '电影']);
      final page = await client.catalog('movie', 1);
      expect(page.items.single.title, '分类片');
      final detail = await client.detail('v2');
      expect(detail.episodes.single.title, '第1集');
      final source = await client.playSource(detail.episodes.single);
      expect(source.url, 'https://cdn.example.com/v2.m3u8');
      expect(seenOps, ['home', 'category', 'detail', 'play']);
    });

    test('storage 信封：调用后落盘，下次调用带回', () async {
      final capturedStorage = <Map<String, dynamic>>[];
      final store = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe: ({required pluginId, required script, required manifest}) async {},
        uriValidator: (_) async {},
      );
      await store.installBundleText(
        jsonEncode({
          'manifest': {
            'schema': 1,
            'id': 'com.idj.ext.demo',
            'name': '演示插件',
            'version': '1.0.0',
            'entry': 'main.js',
            'type': 'video',
            'adult': false,
            'capabilities': ['home', 'detail', 'play'],
            'permissions': {
              'http': ['example.com'],
              'media': ['example.com'],
              'cloudflare': false,
              'storage': true,
              'login': false,
            },
          },
          'files': {'main.js': 'export default {};'},
        }),
      );
      final runtime = IdjRuntime(
        store: store,
        evalFn: (script, timeoutMs) async {
          final match = RegExp(r'var __idjStorage = (\{[^;]*\});')
              .firstMatch(script);
          capturedStorage.add(
            Map<String, dynamic>.from(
              jsonDecode(match!.group(1)!) as Map,
            ),
          );
          return jsonEncode({
            'ok': true,
            'result': {'categories': [], 'items': []},
            'storage': {'counter': 7},
          });
        },
      );
      final client = IdjSiteContentClient(
        pluginId: 'com.idj.ext.demo',
        store: store,
        runtime: runtime,
      );
      await client.categories();
      await client.categories();
      expect(capturedStorage.first, isEmpty);
      expect(capturedStorage.last, {'counter': 7});
    });

    test('错误信封映射成带码异常、客户端转 StateError', () async {
      final store = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        probe: ({required pluginId, required script, required manifest}) async {},
        uriValidator: (_) async {},
      );
      await store.installBundleText(
        jsonEncode({
          'manifest': {
            'schema': 1,
            'id': 'com.idj.ext.demo',
            'name': '演示插件',
            'version': '1.0.0',
            'entry': 'main.js',
            'type': 'video',
            'adult': false,
            'capabilities': ['home', 'detail', 'play'],
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
      );
      final runtime = IdjRuntime(
        store: store,
        evalFn: (script, timeoutMs) async => jsonEncode({
          'ok': false,
          'code': 'E_DOMAIN',
          'message': '域名不在插件白名单内：evil.example.com',
        }),
      );
      final client = IdjSiteContentClient(
        pluginId: 'com.idj.ext.demo',
        store: store,
        runtime: runtime,
      );
      await expectLater(
        client.categories(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('白名单'),
          ),
        ),
      );
    });
  });

  group('probe 平台缺口', () {
    test('默认评估器在非安卓环境如实报引擎不可用', () async {
      final store = IdjPluginStore(
        preferences: prefs,
        rootDir: rootDir,
        supportDir: supportDir,
        uriValidator: (_) async {},
      );
      final runtime = IdjRuntime(store: store);
      await expectLater(
        runtime.probe(
          pluginId: 'com.idj.ext.demo',
          script: 'export default {};',
          manifest: const {},
        ),
        throwsA(
          isA<IdjPluginFailure>().having(
            (e) => e.message,
            'message',
            contains('暂不支持插件引擎'),
          ),
        ),
      );
    });
  });
}
