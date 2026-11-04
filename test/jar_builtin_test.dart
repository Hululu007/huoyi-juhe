import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/zakatv_builtin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置表：146 站 + 4 排除站，键唯一、类名与类型齐全', () {
    expect(zakatvBuiltinSites.length, 146);
    expect(zakatvExcludedSites.length, 4);
    final keys = zakatvBuiltinSites.map((site) => site.key).toList();
    expect(keys.toSet().length, keys.length);
    for (final site in zakatvBuiltinSites) {
      expect(
        site.className.startsWith('com.github.catvod.spider.'),
        isTrue,
        reason: site.key,
      );
      expect(site.name.isNotEmpty, isTrue, reason: site.key);
    }
    expect(
      zakatvExcludedSites.map((site) => site.key).toSet(),
      {'zakahzai', 'zakahzai747', 'ZakaXme', 'zakajavbus'},
    );
    for (final site in zakatvExcludedSites) {
      expect(site.reason.isNotEmpty, isTrue, reason: site.key);
    }
    expect(
      zakatvBuiltinSites
          .where((site) => site.contentTypeKey == 'audio')
          .map((site) => site.key),
      ['go_tingshu'],
    );
    // 成人标记分两种：🔞 开头的 93 站进午夜门禁；徽章前缀（🆕/👑等）+ 🔞
    // 的 29 站与原树行为一致（门禁只认 🔞 开头），此处只锁定数量不改规则。
    // 全量 150 站含 🔞 的是 126，4 个被排除站全含 🔞，故现役是 122。
    expect(
      zakatvBuiltinSites.where((site) => site.name.startsWith('🔞')).length,
      93,
    );
    expect(
      zakatvBuiltinSites.where((site) => site.name.contains('🔞')).length,
      122,
    );
    expect(youtubeBuiltinSite.className, youtubeSpiderClass);
    expect(youtubeBuiltinSite.key, 'youtube');
  });

  test('补齐 lifecycle：补 147 站、幂等、开关保留、删后墓碑不再复活', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = SourceRegistry.instance;
    await registry.ensureBuiltinJarSites();
    final first = registry.custom
        .where((entry) => entry.extra['builtin'] == true)
        .toList();
    expect(first.length, 147);
    expect(
      first.where((entry) => entry.kind == SourceKind.jarImport).length,
      147,
    );
    final youtube = first.firstWhere(
      (entry) => entry.id == 'jar:youtube:youtube',
    );
    expect(youtube.extra['youtubeConfig'], true);
    expect(youtube.extra['configId'], 'youtube');
    final sample = first.firstWhere(
      (entry) => entry.id == 'jar:zakatv:ZakaMjv011',
    );
    expect(sample.name, '🔞mjv011');
    expect(sample.extra['className'], 'com.github.catvod.spider.ZakaMjv011Amns2');
    expect(sample.extra['configId'], 'zakatv');
    expect(sample.extra['md5'], zakatvJarMd5);
    expect(
      (sample.extra['jarUrl'] as String).startsWith('asset:'),
      isTrue,
    );

    await registry.ensureBuiltinJarSites();
    expect(
      registry.custom.where((entry) => entry.extra['builtin'] == true).length,
      147,
    );

    await registry.setCustomEnabled(sample.id, false);
    await registry.ensureBuiltinJarSites();
    final kept = registry.custom.firstWhere((entry) => entry.id == sample.id);
    expect(kept.enabled, isFalse);

    await registry.removeCustom(sample.id);
    await registry.ensureBuiltinJarSites();
    expect(
      registry.custom.any((entry) => entry.id == sample.id),
      isFalse,
    );
    expect(
      registry.custom.where((entry) => entry.extra['builtin'] == true).length,
      146,
    );
    // 内置 jar 视频站现归午夜页，不再进 visibleDramaSites；此处改验一个
    // 内置短剧站仍可见，意图不变：删一站不影响其他站的可见性。
    expect(
      registry.visibleDramaSites().any(
        (site) => site.id == 'original',
      ),
      isTrue,
    );
  });

  test('asset 落盘：缺失写、MD5 对上复用、对不上重拷自愈', () async {
    final temp = await Directory.systemTemp.createTemp('jar_builtin_test');
    addTearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return temp.path;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    var loads = 0;
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    Future<ByteData> loader(String asset) async {
      loads++;
      return ByteData.view(bytes.buffer);
    }

    final path = await JarBridge.resolveBuiltinJarAsset(
      assetPath: 'assets/jars/zakatv.jar',
      configId: 'zakatv',
      md5: JarBridge.md5Hex(bytes),
      assetLoader: loader,
    );
    expect(loads, 1);
    expect(await File(path).readAsBytes(), bytes);

    final reused = await JarBridge.resolveBuiltinJarAsset(
      assetPath: 'assets/jars/zakatv.jar',
      configId: 'zakatv',
      md5: JarBridge.md5Hex(bytes),
      assetLoader: loader,
    );
    expect(reused, path);
    expect(loads, 1);

    await File(path).writeAsBytes([9, 9, 9]);
    final healed = await JarBridge.resolveBuiltinJarAsset(
      assetPath: 'assets/jars/zakatv.jar',
      configId: 'zakatv',
      md5: JarBridge.md5Hex(bytes),
      assetLoader: loader,
    );
    expect(healed, path);
    expect(loads, 2);
    expect(await File(path).readAsBytes(), bytes);
  });
}
