import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class JarBridgeFailure implements Exception {
  JarBridgeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class JarSiteSpec {
  const JarSiteSpec({
    required this.siteId,
    required this.configId,
    required this.name,
    required this.className,
    required this.jarUrl,
    required this.jarMd5,
    this.ext = '',
  });

  final String siteId;
  final String configId;
  final String name;
  final String className;
  final String jarUrl;
  final String jarMd5;
  final String ext;

  Map<String, dynamic> toJson() => {
    'siteId': siteId,
    'configId': configId,
    'name': name,
    'className': className,
    'jarUrl': jarUrl,
    'jarMd5': jarMd5,
    'ext': ext,
  };

  factory JarSiteSpec.fromJson(Map<String, dynamic> json) => JarSiteSpec(
    siteId: json['siteId'] as String? ?? '',
    configId: json['configId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    className: json['className'] as String? ?? '',
    jarUrl: json['jarUrl'] as String? ?? '',
    jarMd5: json['jarMd5'] as String? ?? '',
    ext: json['ext'] as String? ?? '',
  );

  static String classNameForApi(String api) {
    final simple = api.startsWith('csp_') ? api.substring(4) : api;
    return 'com.github.catvod.spider.$simple';
  }

  static String siteIdFor(String configId, String key) =>
      'jar:$configId:$key';
}

class JarClassInfo {
  const JarClassInfo({
    required this.className,
    required this.instantiable,
    this.reason = '',
  });

  final String className;
  final bool instantiable;
  final String reason;

  String get simpleName => className.split('.').last;

  factory JarClassInfo.fromJson(Map<String, dynamic> json) => JarClassInfo(
    className: json['className'] as String? ?? '',
    instantiable: json['instantiable'] == true,
    reason: json['reason'] as String? ?? '',
  );
}

class JarBridge {
  JarBridge._();

  static const _channel = MethodChannel('juhe/jarbridge');
  static final Map<String, String> _jarPaths = {};

  /// 同一 configId 正在跑的解包任务：并发的 callJson 共用同一份在途
  /// 任务，不各调一次原生 ensureJar（见 ensureJarPath 的说明）。
  static final Map<String, Future<String>> _ensureInFlight = {};

  static bool get supported => debugForceSupported ?? Platform.isAndroid;

  /// 仅供测试：flutter test 跑在宿主 Linux 上时 Platform.isAndroid 为
  /// false，用它强制打开 jar 桥调用路径（通道本身由测试 mock）。
  /// 生产代码绝不设置。
  @visibleForTesting
  static bool? debugForceSupported;

  static Future<String> ensureJarPath({
    required String configId,
    required String url,
    String md5 = '',
  }) async {
    // 缓存的路径先验文件还在：覆盖安装后 jarbridge 目标文件一旦没了
    // （旧版并发解包竞态会把目标删空），旧缓存会让原生 loaderFor 的
    // sealForLoad 直接报“jar 文件不存在，无法加载”，且重试也不好
    // （同进程内一直走缓存）。文件不在就丢缓存、重解一次。
    final cached = _jarPaths[configId];
    if (cached != null) {
      try {
        if (await File(cached).exists()) return cached;
      } catch (_) {}
      _jarPaths.remove(configId);
    }
    // 同一 configId 的并发解包共用同一份在途任务：否则 3 站并发加载
    // 会各调一次原生 ensureJar、抢同一个 .part 临时文件和同一个目标
    // 文件（首页影视区一窗 3 站 Future.wait；原生侧也有同 configId
    // 锁，这里是 Dart 侧的第二道，避免重复调通道与重复读盘）。
    // 只让一份真正跑，其余等它；跑完那份把路径写进缓存，后到的直接复用。
    final inFlight = _ensureInFlight[configId];
    if (inFlight != null) return inFlight;
    final future = _ensureJarPathUncached(
      configId: configId,
      url: url,
      md5: md5,
    );
    _ensureInFlight[configId] = future;
    try {
      return await future;
    } finally {
      _ensureInFlight.remove(configId);
    }
  }

  static Future<String> _ensureJarPathUncached({
    required String configId,
    required String url,
    String md5 = '',
  }) async {
    if (!supported) {
      throw JarBridgeFailure('jar 桥仅支持 Android，当前平台无法下载与加载远程 jar');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'ensureJar',
        {'configId': configId, 'url': url, 'md5': md5},
      );
      final jarPath = result?['path'] as String? ?? '';
      if (jarPath.isEmpty) {
        throw JarBridgeFailure('jar 下载失败：桥未返回本地路径');
      }
      _jarPaths[configId] = jarPath;
      return jarPath;
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 桥调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  /// 启动时校验内置 jar 是否已落盘：不存在或指纹对不上就重解一次。
  /// 尽力而为：任何失败都不抛、不挡启动（点站时还会再解一次）。
  /// 覆盖安装后指纹变了，先在启动时把 jar 落盘，避免用户第一次点站
  /// 才解包、还撞上并发（见 ensureJarPath 的说明）。
  static Future<void> verifyBuiltinJar({
    required String assetPath,
    required String configId,
    required String md5,
  }) async {
    try {
      final local = await resolveBuiltinJarAsset(
        assetPath: assetPath,
        configId: configId,
        md5: md5,
      );
      await ensureJarPath(configId: configId, url: local, md5: md5);
    } catch (_) {}
  }

  /// 内置 jar 站的 asset 落盘：asset 不是文件路径，原生桥接只能吃本地路径，
  /// 这里把 asset 拷到应用目录的 `builtin_jars/<configId>.jar`；已存在且 MD5
  /// 对得上时复用，对不上重拷自愈。原生侧 ensureJar 还会再验一次 MD5。
  static Future<String> resolveBuiltinJarAsset({
    required String assetPath,
    required String configId,
    required String md5,
    Future<ByteData> Function(String assetPath)? assetLoader,
  }) async {
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/builtin_jars');
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}/$configId.jar');
    final expected = md5.trim().toLowerCase();
    if (await target.exists()) {
      if (expected.isEmpty) return target.path;
      try {
        final current = md5Hex(await target.readAsBytes());
        if (current == expected) return target.path;
      } catch (_) {}
    }
    final loader = assetLoader ?? rootBundle.load;
    final bytes = await loader(assetPath);
    await target.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    return target.path;
  }

  static String md5Hex(List<int> bytes) => md5.convert(bytes).toString();

  /// jar 蜘蛛本地代理：调原生 jarProxy（静态 proxy(Map) 方法），回包与
  /// py host 的 proxy 动作同形 {status, mime, bodyBase64}。
  static Future<Map<String, dynamic>> jarProxy(
    JarSiteSpec spec,
    Map<String, String> param,
  ) async {
    final jarPath = await _ensureJar(spec);
    try {
      return await _invokeJarProxy(spec, jarPath, param);
    } on JarBridgeFailure catch (failure) {
      // 与 callJson 同款 stale 重试：目标文件在解包与代理调用之间没了
      // 就清缓存、重解一次、再调一次；只重试一次。
      if (!failure.message.contains('jar 文件不存在')) rethrow;
      _jarPaths.remove(spec.configId);
      final freshPath = await _ensureJar(spec);
      return await _invokeJarProxy(spec, freshPath, param);
    }
  }

  static Future<Map<String, dynamic>> _invokeJarProxy(
    JarSiteSpec spec,
    String jarPath,
    Map<String, String> param,
  ) async {
    if (!supported) {
      throw JarBridgeFailure('jar 桥仅支持 Android，当前平台无法调用本地代理');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'jarProxy',
        {
          'siteId': spec.siteId,
          'configId': spec.configId,
          'jarPath': jarPath,
          'className': spec.className,
          'ext': spec.ext,
          'param': param,
        },
      );
      return result == null ? const {} : Map<String, dynamic>.from(result);
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 本地代理调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<List<JarClassInfo>> enumerate(String jarPath) async {
    if (!supported) {
      throw JarBridgeFailure('jar 桥仅支持 Android，当前平台无法枚举 jar 内的 Spider 类');
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'enumerate',
        {'jarPath': jarPath},
      );
      return [
        for (final row in result?['classes'] as List? ?? const [])
          if (row is Map) JarClassInfo.fromJson(Map<String, dynamic>.from(row)),
      ];
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 枚举失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<void> release(String siteId) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('release', {'siteId': siteId});
    } catch (_) {}
  }

  /// 把系统出口代理交给 jar 侧：原生 JarBridge 经反射调 ZakaCfg.setProxy，
  /// 之后所有 jar 站的 ZakaHttp 请求都走该代理；传空串清掉回直连。
  /// 与核心出口代理同款接线（见 SystemProxyService.applyEgressProxy）。
  /// 尽力而为：桥未就绪或原生侧失败时返回 false，不抛错，不挡启动。
  static Future<bool> setJarProxy(String url) async {
    if (!supported) return false;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'setJarProxy',
        {'url': url},
      );
      return result != null;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> callJson(
    JarSiteSpec spec,
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final jarPath = await _ensureJar(spec);
    try {
      return await _invokeCall(spec, jarPath, method, args);
    } on JarBridgeFailure catch (failure) {
      if (failure.message.contains('未找到站点类')) {
        final recovered = await _retryWithFreshJar(spec, method, args);
        if (recovered != null) return recovered;
        rethrow;
      }
      if (failure.message.contains('jar 文件不存在')) {
        // 目标文件在解包与加载之间没了（旧版竞态残留、或外部清理）：
        // 清掉缓存路径、重解一次、再调一次；重解仍失败时原错上抛。
        // 只重试一次，避免把真正的站方错误也循环重调。
        _jarPaths.remove(spec.configId);
        final freshPath = await _ensureJar(spec);
        return await _invokeCall(spec, freshPath, method, args);
      }
      rethrow;
    }
  }

  static Future<String> _ensureJar(JarSiteSpec spec) => ensureJarPath(
    configId: spec.configId,
    url: spec.jarUrl,
    md5: spec.jarMd5,
  );

  static Future<Map<String, dynamic>> _invokeCall(
    JarSiteSpec spec,
    String jarPath,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('call', {
        'siteId': spec.siteId,
        'configId': spec.configId,
        'jarPath': jarPath,
        'className': spec.className,
        'ext': spec.ext,
        'method': method,
        'args': args,
      });
      final text = result?['text'] as String? ?? '';
      if (text.trim().isEmpty) return const {};
      try {
        final decoded = jsonDecode(text);
        return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
      } catch (_) {
        throw JarBridgeFailure('jar 站点「${spec.name}」的 $method 返回了无法解析的内容');
      }
    } on PlatformException catch (error) {
      throw JarBridgeFailure(error.message ?? 'jar 桥调用失败');
    } on MissingPluginException {
      throw JarBridgeFailure('jar 桥未就绪：当前安装包未包含 jar 桥通道');
    }
  }

  static Future<Map<String, dynamic>?> _retryWithFreshJar(
    JarSiteSpec spec,
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      _jarPaths.remove(spec.configId);
      String? fallbackPath;
      if (spec.jarMd5.isNotEmpty) {
        final directory = await getApplicationSupportDirectory();
        final imported = File(
          '${directory.path}/imported_jars/${spec.jarMd5}.jar',
        );
        if (await imported.exists()) fallbackPath = imported.path;
      }
      fallbackPath ??= await _ensureJar(spec);
      final recovered = await _invokeCall(spec, fallbackPath, method, args);
      if (spec.jarMd5.isNotEmpty && fallbackPath.isNotEmpty) {
        try {
          await ensureJarPath(
            configId: spec.configId,
            url: fallbackPath,
            md5: spec.jarMd5,
          );
        } catch (_) {}
      }
      return recovered;
    } catch (_) {
      return null;
    }
  }
}
