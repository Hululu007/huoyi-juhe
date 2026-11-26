import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/idj_runtime.dart';
import 'package:fqapp/services/site_health_tracking_client.dart';
import 'package:fqapp/services/source_registry.dart';

/// 插件登记对账验收：装包后 SourceRegistry.syncIdjPluginSites 把
/// 插件登记成站（_custom 行 + 短剧站表），clientFor 能按站 key 取
/// 到 IdjSiteContentClient；卸载后对账摘站。path_provider 通道挂
/// 假处理器指到临时目录，不碰真机目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late Directory supportDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    docsDir = Directory.systemTemp.createTempSync('idj_reg_docs');
    supportDir = Directory.systemTemp.createTempSync('idj_reg_support');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            switch (call.method) {
              case 'getApplicationDocumentsDirectory':
                return docsDir.path;
              case 'getApplicationSupportDirectory':
                return supportDir.path;
              case 'getTemporaryDirectory':
                return docsDir.path;
              default:
                return null;
            }
          },
        );
    IdjPluginStore.probeHandler =
        ({
          required String pluginId,
          required String script,
          required Map<String, dynamic> manifest,
        }) async {};
    IdjPluginStore.siteKeyTaken = null;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    IdjPluginStore.probeHandler = null;
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
    if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
  });

  test('装包 → 登记成站 → 取到客户端 → 卸载摘站', () async {
    final registry = SourceRegistry.instance;
    final store = registry.idjStore;
    await store.installBundleText(_bundleText());

    await registry.syncIdjPluginSites();
    final entry = registry.customById('idj_demo');
    expect(entry, isNotNull);
    expect(entry!.kind, SourceKind.idjPlugin);
    expect(entry.extra['pluginId'], 'com.idj.ext.demo');
    expect(entry.contentType, ContentType.video);
    // 登记进了短剧/影视共用的站表（点开走全链的入口）。
    expect(allDramaSites.any((site) => site.id == 'idj_demo'), isTrue);
    // 按站 key 能取到插件内容客户端（外层包了全站同款的健康追踪
    // 装饰器，内层是插件客户端本体）。
    final client = await registry.clientFor('idj_demo');
    expect(client, isA<SiteHealthTrackingClient>());
    expect(
      (client! as SiteHealthTrackingClient).inner,
      isA<IdjSiteContentClient>(),
    );

    // 停用即摘站（行消失），包还在。
    await store.setEnabled('com.idj.ext.demo', false);
    await registry.syncIdjPluginSites();
    expect(registry.customById('idj_demo'), isNull);
    expect(await store.listInstalled(), hasLength(1));

    // 重新启用回来；卸载后对账摘干净。
    await store.setEnabled('com.idj.ext.demo', true);
    await registry.syncIdjPluginSites();
    expect(registry.customById('idj_demo'), isNotNull);
    await store.uninstall('com.idj.ext.demo');
    await registry.syncIdjPluginSites();
    expect(registry.customById('idj_demo'), isNull);
    expect(allDramaSites.any((site) => site.id == 'idj_demo'), isFalse);
  });

  test('comic / live 插件装得上但不登记成站（未接内容链）', () async {
    final registry = SourceRegistry.instance;
    await registry.idjStore.installBundleText(_bundleText(type: 'live'));
    await registry.syncIdjPluginSites();
    expect(registry.customById('idj_demo'), isNull);
    expect(await registry.idjStore.listInstalled(), hasLength(1));
    await registry.idjStore.uninstall('com.idj.ext.demo');
    await registry.syncIdjPluginSites();
  });
}

String _bundleText({String type = 'video'}) => jsonEncode({
  'manifest': {
    'schema': 1,
    'id': 'com.idj.ext.demo',
    'name': '演示插件',
    'version': '1.0.0',
    'entry': 'main.js',
    'type': type,
    'adult': false,
    'capabilities': type == 'live'
        ? ['home', 'play']
        : ['home', 'category', 'detail', 'play'],
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
