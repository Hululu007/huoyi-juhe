import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  static bool get supported => Platform.isAndroid;

  static Future<String> ensureJarPath({
    required String configId,
    required String url,
    String md5 = '',
  }) async {
    final cached = _jarPaths[configId];
    if (cached != null) return cached;
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
      if (!failure.message.contains('未找到站点类')) rethrow;
      final recovered = await _retryWithFreshJar(spec, method, args);
      if (recovered != null) return recovered;
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
