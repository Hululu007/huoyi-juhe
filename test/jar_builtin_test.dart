import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/zakatv_builtin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('内置表：247 站 + 6 排除站，键唯一、类名与类型齐全', () {
    expect(zakatvBuiltinSites.length, 247);
    expect(zakatvExcludedSites.length, 6);
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
      {'zakahzai', 'zakahzai747', 'ZakaXme', 'zakajavbus', 'zaka520av', 'zakaaoxx69'},
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
    // 成人标记分两种：🔞 开头的 189 站进午夜门禁；徽章前缀（🆕/👑等）+ 🔞
    // 的站与原树行为一致（门禁只认 🔞 开头），此处只锁定数量不改规则。
    // 全量 247 站含 🔞 的是 220，6 个被排除站全含 🔞。
    // 189/220 含电视直播（ZakaLiveTv，2026-11-08 改名加 🔞 进午夜区）。
    expect(
      zakatvBuiltinSites.where((site) => site.name.startsWith('🔞')).length,
      189,
    );
    expect(
      zakatvBuiltinSites.where((site) => site.name.contains('🔞')).length,
      220,
    );
    expect(youtubeBuiltinSite.className, youtubeSpiderClass);
    expect(youtubeBuiltinSite.key, 'youtube');
  });

  test('指纹一致：声明值 == 盘上 jar 实测 MD5（合 jar 完必同步）', () async {
    // 铁律：每次合 jar 完必须跑 scripts/sync_jar_fingerprint.sh 同步声明；
    // 本测试是最后一道拦网——声明与盘上 jar 对不上时直接失败，防火蚁TV
    // +40/+41 的 244 站全未注册重演。flutter test 从仓库根目录跑，
    // assets 相对路径可直接读到。
    final zakatvBytes = await File(zakatvJarAsset).readAsBytes();
    expect(JarBridge.md5Hex(zakatvBytes), zakatvJarMd5);
    final youtubeBytes = await File(youtubeJarAsset).readAsBytes();
    expect(JarBridge.md5Hex(youtubeBytes), youtubeJarMd5);
  });

  test('补齐 lifecycle：补 248 站、幂等、开关保留、删后墓碑不再复活', () async {
    SharedPreferences.setMockInitialValues({});
    final registry = SourceRegistry.instance;
    await registry.ensureBuiltinJarSites();
    final first = registry.custom
        .where((entry) => entry.extra['builtin'] == true)
        .toList();
    expect(first.length, 248);
    expect(
      first.where((entry) => entry.kind == SourceKind.jarImport).length,
      248,
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
      248,
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
      247,
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
