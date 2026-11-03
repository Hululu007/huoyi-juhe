import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class JsRuntimeStatus {
  const JsRuntimeStatus({required this.available, this.detail = ''});

  final bool available;
  final String detail;
}

String buildJsDriverScript({
  required String script,
  required String operation,
  String tid = '',
  int page = 1,
  String query = '',
  String vodId = '',
  String flag = '',
  String playId = '',
}) {
  const fnNames = {
    'home': 'homeContent',
    'category': 'categoryContent',
    'detail': 'detailContent',
    'search': 'searchContent',
    'player': 'playerContent',
  };
  final fnName = fnNames[operation];
  if (fnName == null) throw StateError('不支持的 JS 蜘蛛操作：$operation');
  String call;
  switch (operation) {
    case 'home':
      call = 'fn()';
      break;
    case 'category':
      call = 'fn(${jsonEncode(tid)}, $page, false, {})';
      break;
    case 'detail':
      call = 'fn([${jsonEncode(vodId)}])';
      break;
    case 'search':
      call = 'fn(${jsonEncode(query)}, false, $page)';
      break;
    case 'player':
      call = 'fn(${jsonEncode(flag)}, ${jsonEncode(playId)}, [])';
      break;
    default:
      call = 'fn()';
  }
  return '''
$script
;(function(){
  function findFn(name){
    if (typeof globalThis[name] === 'function') return globalThis[name];
    for (var i = 0; i < 2; i++) {
      var holder = globalThis[i === 0 ? 'rule' : 'spider'];
      if (holder && typeof holder[name] === 'function') return holder[name];
    }
    if (typeof Spider === 'function') {
      try {
        var inst = new Spider();
        if (inst && typeof inst[name] === 'function') return inst[name];
      } catch (e) {}
    }
    return null;
  }
  var target = '$fnName';
  var fn = findFn(target);
  var alts = {
    'homeContent': ['home', 'homeVod'],
    'categoryContent': ['category'],
    'detailContent': ['detail'],
    'searchContent': ['search'],
    'playerContent': ['play', 'player']
  }[target] || [];
  for (var i = 0; i < alts.length && !fn; i++) fn = findFn(alts[i]);
  if (!fn) throw new Error('JS spider does not provide ' + target);
  return $call;
})();
''';
}

Map<String, dynamic> parseJsEvalResult(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('JS 引擎返回格式错误');
  }
  if (decoded['ok'] != true) {
    throw StateError('JS 蜘蛛执行失败：${decoded['error'] ?? '未知错误'}');
  }
  final result = decoded['result'];
  if (result is String) {
    final trimmed = result.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final parsed = jsonDecode(trimmed);
      if (parsed is List) return {'list': parsed};
      if (parsed is Map<String, dynamic>) return parsed;
      throw StateError('JS 蜘蛛返回了无法解析的文本结果');
    }
    throw StateError('JS 蜘蛛返回了纯文本而非结果对象');
  }
  if (result is List) return {'list': result};
  if (result is Map<String, dynamic>) return result;
  if (result == null) return <String, dynamic>{};
  throw StateError('JS 蜘蛛返回了不支持的结果形状');
}

class JsBridge {
  JsBridge._();

  static const _channel = MethodChannel('juhe/quickjs');
  static JsRuntimeStatus? _statusCache;

  static Future<JsRuntimeStatus> status({bool force = false}) async {
    if (!force && _statusCache != null) return _statusCache!;
    final status = await _probe();
    if (status.available) _statusCache = status;
    return status;
  }

  static Future<JsRuntimeStatus> _probe() async {
    if (!Platform.isAndroid) {
      return const JsRuntimeStatus(
        available: false,
        detail: 'JS 桥仅支持 Android',
      );
    }
    try {
      final raw = await _channel.invokeMethod<String>('status');
      final decoded = jsonDecode(raw ?? '{}') as Map<String, dynamic>;
      if (decoded['available'] == true) {
        return const JsRuntimeStatus(available: true);
      }
      return const JsRuntimeStatus(available: false, detail: '桥未报告可用');
    } on MissingPluginException {
      return const JsRuntimeStatus(available: false, detail: '安装包未集成 JS 桥');
    } on PlatformException catch (error) {
      return JsRuntimeStatus(
        available: false,
        detail: error.message ?? '桥启动失败',
      );
    } catch (error) {
      return JsRuntimeStatus(available: false, detail: error.toString());
    }
  }

  static Future<void> ensureReady() async {
    final status = await JsBridge.status();
    if (!status.available) {
      throw StateError(
        'JS 运行时未就绪：当前安装包未包含 QuickJS 桥。${status.detail}',
      );
    }
  }

  static Future<Map<String, dynamic>> run({
    required String script,
    required String operation,
    String tid = '',
    int page = 1,
    String query = '',
    String vodId = '',
    String flag = '',
    String playId = '',
    int timeoutMs = 30000,
  }) async {
    await ensureReady();
    final driver = buildJsDriverScript(
      script: script,
      operation: operation,
      tid: tid,
      page: page,
      query: query,
      vodId: vodId,
      flag: flag,
      playId: playId,
    );
    try {
      final raw = await _channel.invokeMethod<String>('eval', {
        'script': driver,
        'timeoutMs': timeoutMs,
      }).timeout(Duration(seconds: timeoutMs ~/ 1000 + 10));
      return parseJsEvalResult(raw ?? '{}');
    } on PlatformException catch (error) {
      throw StateError('JS 蜘蛛执行失败：${error.message ?? error.code}');
    }
  }
}
