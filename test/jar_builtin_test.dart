import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 站点库批（2026-11-27）：jar 站登记表已移出包、进站点库
  // （seg_site_stations 的 jarImport 行），本文件原先查包内登记表
  // 与 ensureBuiltinJarSites 补齐 lifecycle 的用例改查随包名单；
  // 注册对账/幂等/关站不复活的 lifecycle 覆盖已移
  // test/site_library_registry_test.dart（syncSqlSites 对账组）。
  test('jar 登记在站点库名单里：248 行、键唯一、排除站 6 个仍在账', () {
    final raw = File('assets/site_library/roster.json').readAsStringSync();
    final stations =
        (jsonDecode(raw) as Map<String, dynamic>)['stations'] as List;
    final jarRows = stations
        .where((s) => (s as Map<String, dynamic>)['kind'] == 'jarImport')
        .toList();
    expect(jarRows.length, 248);
    for (final row in jarRows) {
      final s = row as Map<String, dynamic>;
      expect(s['siteId'], startsWith('jar:'), reason: '${s['id']}');
      expect((s['name'] as String).isNotEmpty, isTrue, reason: '${s['id']}');
    }
    // 排除站清单仍留在包里（历史账，恢复须用户另行下令）。
    expect(zakatvExcludedSites.length, 6);
    expect(
      zakatvExcludedSites.map((site) => site.key).toSet(),
      {'zakahzai', 'zakahzai747', 'ZakaXme', 'zakajavbus', 'zaka520av', 'zakaaoxx69'},
    );
    for (final site in zakatvExcludedSites) {
      expect(site.reason.isNotEmpty, isTrue, reason: site.key);
    }
    expect(youtubeSpiderClass, 'com.github.catvod.spider.YouTube');
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
    final oneBytes = await File(oneJarAsset).readAsBytes();
    expect(JarBridge.md5Hex(oneBytes), oneJarMd5);
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
