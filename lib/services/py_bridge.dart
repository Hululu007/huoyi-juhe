import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class PyRuntimeStatus {
  const PyRuntimeStatus({
    required this.available,
    this.python = '',
    this.detail = '',
  });

  final bool available;
  final String python;
  final String detail;

  String get notReadyMessage =>
      'Python 运行时未就绪：当前安装包未包含可用的 CPython 运行时。'
      '该站已导入并可见，但需要使用带 Python 桥的安装包打开。'
      '${detail.isEmpty ? '' : '（$detail）'}';
}

class PyValidation {
  const PyValidation({
    required this.ok,
    required this.hasSpider,
    required this.missing,
    required this.error,
  });

  final bool ok;
  final bool hasSpider;
  final List<String> missing;
  final String error;

  factory PyValidation.fromJson(Map<String, dynamic> json) => PyValidation(
    ok: json['ok'] == true,
    hasSpider: json['hasSpider'] == true,
    missing: (json['missing'] as List? ?? const [])
        .map((value) => value.toString())
        .toList(),
    error: json['error'] as String? ?? '',
  );
}

class PyBridge {
  PyBridge._();

  static const _channel = MethodChannel('juhe/pybridge');
  static PyRuntimeStatus? _statusCache;

  static Future<PyRuntimeStatus> status({bool force = false}) async {
    if (!force && _statusCache != null) return _statusCache!;
    final status = await _probe();
    if (status.available) {
      _statusCache = status;
    } else {
      _statusCache = null;
    }
    return status;
  }

  static Future<PyRuntimeStatus> _probe() async {
    if (!Platform.isAndroid) {
      return const PyRuntimeStatus(
        available: false,
        detail: 'Python 桥仅支持 Android',
      );
    }
    try {
      final raw = await _channel.invokeMethod<String>('status');
      final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      if (decoded['available'] == true) {
        return PyRuntimeStatus(
          available: true,
          python: decoded['python'] as String? ?? '',
        );
      }
      return const PyRuntimeStatus(available: false, detail: '桥未报告可用');
    } on MissingPluginException {
      return const PyRuntimeStatus(available: false, detail: '安装包未集成 Python 桥');
    } on PlatformException catch (error) {
      return PyRuntimeStatus(
        available: false,
        detail: error.message ?? '桥启动失败',
      );
    } catch (error) {
      return PyRuntimeStatus(available: false, detail: error.toString());
    }
  }

  static Future<void> ensureReady() async {
    final status = await PyBridge.status();
    if (!status.available) throw StateError(status.notReadyMessage);
  }

  static Future<PyValidation?> validate(String source) async {
    final status = await PyBridge.status();
    if (!status.available) return null;
    try {
      final raw = await _channel.invokeMethod<String>('validate', {
        'source': source,
      });
      return PyValidation.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map),
      );
    } on PlatformException catch (error) {
      throw StateError('蜘蛛校验失败：${error.message ?? error.code}');
    }
  }

  static Future<Map<String, dynamic>> call(
    String path,
    Map<String, dynamic> request,
  ) async {
    final data = await callRaw(path, request);
    return data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
  }

  static Future<dynamic> callRaw(
    String path,
    Map<String, dynamic> request,
  ) async {
    await ensureReady();
    final action = request['action']?.toString() ?? '';
    try {
      final raw = await _channel
          .invokeMethod<String>('call', {
            'path': path,
            'request': jsonEncode(request),
          })
          .timeout(const Duration(seconds: 70));
      final decoded = Map<String, dynamic>.from(jsonDecode(raw ?? '{}') as Map);
      if (decoded['ok'] != true) {
        throw StateError(
          'py 蜘蛛执行失败（步骤=$path/$action）：${decoded['error'] ?? '未知错误'}',
        );
      }
      return decoded['data'];
    } on TimeoutException {
      unawaited(dispose(path));
      throw StateError(
        'py 蜘蛛执行超时（70 秒，步骤=$path/$action）：蜘蛛可能在等上游响应，请重试或换集',
      );
    } on PlatformException catch (error) {
      throw StateError(
        'py 蜘蛛执行失败（步骤=$path/$action）：${error.message ?? error.code}',
      );
    }
  }

  static Future<void> dispose(String path) async {
    try {
      await _channel.invokeMethod<String>('dispose', {'path': path});
    } catch (_) {}
  }

  static Future<void> disposeAll() async {
    try {
      await _channel.invokeMethod<String>('disposeAll');
    } catch (_) {}
  }
}
