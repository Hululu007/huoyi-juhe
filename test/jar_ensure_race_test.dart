import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/jar_bridge.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

/// jar 解包竞态回归测试（18 轮报障：覆盖安装后全部 jar 站报
/// “jar 文件不存在，无法加载：.../files/jarbridge/zakatv.jar”）。
///
/// 根因链（代码实证，另见 /tmp/jar_race_sim.py 的并发模拟，
/// 原算法 13/60 次跑完后目标文件不存在、随后用缓存路径调 loaderFor
/// 全部报同一错；修复版 0/60）：
/// ① 原生 ensureJar 无锁，3 站并发加载抢同一个 .part 临时文件和
/// 同一个目标文件；② JarFilePrep.replaceTarget 先删目标再放新文件，
/// 删与放之间有空窗、删后放失败就把目标删空；③ Dart 侧缓存路径不
/// 复验文件还在，同进程内一直走缓存、重试也不好。
/// 本文件只测 Dart 侧三道防线（原生侧的锁与原子替换随下轮构建编译验）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 本文件全程 mock 通道，强制打开 jar 桥调用路径（宿主是 Linux）。
  JarBridge.debugForceSupported = true;

  const channel = MethodChannel('juhe/jarbridge');
  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<Directory> tempDir(String tag) async {
    final dir = await Directory.systemTemp.createTemp('jar_race_$tag');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    return dir;
  }

  test('覆盖安装场景：缓存路径的文件没了，下次调用重走原生解包', () async {
    final dir = await tempDir('cache');
    final target = File('${dir.path}/zakatv.jar');
    var ensureCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ensureJar') {
        ensureCalls++;
        // 原生侧把文件落盘（写 3 字节假 jar，只验路径与调用次数）。
        await target.writeAsBytes([1, 2, 3]);
        return <String, dynamic>{'path': target.path, 'md5': 'abc'};
      }
      throw PlatformException(code: 'unimplemented');
    });

    final first = await JarBridge.ensureJarPath(
      configId: 'race-cache',
      url: '/fake/zakatv.jar',
      md5: 'abc',
    );
    expect(first, target.path);
    expect(ensureCalls, 1);

    // 模拟覆盖安装后文件没了（旧版竞态把目标删空）：删掉缓存路径的文件。
    await target.delete();
    final second = await JarBridge.ensureJarPath(
      configId: 'race-cache',
      url: '/fake/zakatv.jar',
      md5: 'abc',
    );
    expect(second, target.path);
    expect(
      ensureCalls,
      2,
      reason: '缓存路径文件不在时必须重调原生解包，不能直接返回旧缓存',
    );
  });

  test('并发解包：同一 configId 的 3 路调用只调一次原生', () async {
    var ensureCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ensureJar') {
        ensureCalls++;
        // 故意拖 100ms，让 3 路调用撞在同一个在途任务上。
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return <String, dynamic>{
          'path': '/fake/jarbridge/zakatv.jar',
          'md5': 'abc',
        };
      }
      throw PlatformException(code: 'unimplemented');
    });

    final results = await Future.wait([
      JarBridge.ensureJarPath(
        configId: 'race-dedup',
        url: '/fake/zakatv.jar',
        md5: 'abc',
      ),
      JarBridge.ensureJarPath(
        configId: 'race-dedup',
        url: '/fake/zakatv.jar',
        md5: 'abc',
      ),
      JarBridge.ensureJarPath(
        configId: 'race-dedup',
        url: '/fake/zakatv.jar',
        md5: 'abc',
      ),
    ]);
    expect(results.toSet().length, 1);
    expect(results.first, '/fake/jarbridge/zakatv.jar');
    expect(
      ensureCalls,
      1,
      reason: '3 路并发解包必须共用同一份在途任务，只调一次原生',
    );
  });

  test('点站时报 jar 文件不存在：清缓存、重解一次、再调一次', () async {
    final dir = await tempDir('retry');
    final target = File('${dir.path}/zakatv.jar');
    var ensureCalls = 0;
    var callCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ensureJar') {
        ensureCalls++;
        await target.writeAsBytes([1, 2, 3]);
        return <String, dynamic>{'path': target.path, 'md5': 'abc'};
      }
      if (call.method == 'call') {
        callCalls++;
        if (callCalls == 1) {
          // 第一次调蜘蛛时目标文件刚好没了（竞态残留）：原生报 phone 同款错。
          throw PlatformException(
            code: 'jar_error',
            message: 'jar 文件不存在，无法加载：${target.path}',
          );
        }
        return <String, dynamic>{'text': '{"list":[]}'};
      }
      throw PlatformException(code: 'unimplemented');
    });

    const spec = JarSiteSpec(
      siteId: 'jar:zakatv:ZakaTg',
      configId: 'race-retry',
      name: 'tg频道',
      className: 'com.github.catvod.spider.ZakaTgAmns',
      jarUrl: '/fake/zakatv.jar',
      jarMd5: 'abc',
    );
    final result = await JarBridge.callJson(spec, 'homeContent', {
      'filter': true,
    });
    expect(result['list'], isEmpty);
    expect(ensureCalls, 2, reason: 'stale 报错后必须重解一次再调');
    expect(callCalls, 2);
  });

  test('verifyBuiltinJar：走一遍 asset 落盘 + 原生解包，失败不抛', () async {
    final dir = await tempDir('verify');
    const provider = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(provider, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return dir.path;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(provider, null));

    var ensureCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ensureJar') {
        ensureCalls++;
        return <String, dynamic>{
          'path': '${dir.path}/jarbridge/zakatv.jar',
          'md5': zakatvJarMd5,
        };
      }
      throw PlatformException(code: 'unimplemented');
    });

    await JarBridge.verifyBuiltinJar(
      assetPath: zakatvJarAsset,
      configId: 'race-verify',
      md5: zakatvJarMd5,
    );
    expect(ensureCalls, 1);
    // asset 真拷过去了（8.6MB 真 jar，MD5 对得上声明）。
    final copied = File('${dir.path}/builtin_jars/race-verify.jar');
    expect(await copied.exists(), isTrue);
    expect(JarBridge.md5Hex(await copied.readAsBytes()), zakatvJarMd5);
  });
}
