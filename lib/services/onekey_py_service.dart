import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'py_bridge.dart';
import 'source_registry.dart';

/// 一键写PY生成结果。
class OneKeyPyResult {
  const OneKeyPyResult({
    required this.ok,
    this.siteName = '',
    this.mode = '',
    this.templateId = '',
    this.api = '',
    this.entryId = '',
    this.message = '',
  });

  final bool ok;
  final String siteName;
  final String mode;
  final String templateId;
  final String api;
  final String entryId;
  final String message;
}

/// 一键写PY：设置里输网址，自动探测并生成 py，自动导进站源管理。
///
/// 生成走 Python 工具（assets/py_tools/yijianxiepy.py）：
/// Dart 侧只做域名精确匹配（模板库 asset），探测与模板填充全在
/// Python 里（复用工具的三路探测 + 新加的 TVBox/MacCMS/WordPress 探测）。
/// 同名站已存在时就地更新，不重复建站。
class OneKeyPyService {
  OneKeyPyService._();

  static final OneKeyPyService instance = OneKeyPyService._();

  static const _toolAsset = 'assets/py_tools/yijianxiepy.py';
  static const _templatesAsset = 'assets/onekey_templates.json';
  static const _toolDirName = 'onekey_tool';
  static const _toolFileName = 'yijianxiepy.py';

  Map<String, String> _domainTemplates = {};
  bool _templatesLoaded = false;

  /// 模板库域名精确匹配：输入网址的 host 对上已知站，返回模板 id。
  Future<String?> matchDomainTemplate(String url) async {
    await _ensureTemplates();
    final host = _hostOf(url);
    if (host == null) return null;
    return _domainTemplates[host] ??
        _domainTemplates[host.replaceFirst('www.', '')] ??
        _domainTemplates['www.$host'];
  }

  /// 模板库 probe 是 "GET https://host/..." 形式的探测描述，不是裸 URL。
  /// 直接 Uri.parse 拿不到 host（"GET " 前缀使 scheme 非法），建表永远是
  /// 空表、域名匹配永远命中不了；先用正则抠出 URL 再取 host。
  static String? _hostOfProbe(String probe) {
    final match = RegExp(r'https?://([^/:?#\s]+)').firstMatch(probe);
    final host = match?.group(1)?.toLowerCase();
    if (host == null || host.isEmpty) return null;
    return host;
  }

  Future<void> _ensureTemplates() async {
    if (_templatesLoaded) return;
    _templatesLoaded = true;
    try {
      final raw = await rootBundle.loadString(_templatesAsset);
      final decoded = jsonDecode(raw);
      final items = decoded is List
          ? decoded
          : (decoded is Map
                ? decoded['templates'] as List? ?? const []
                : const []);
      final map = <String, String>{};
      for (final item in items) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        final detection = item['detection'];
        final probes = detection is Map
            ? detection['probe'] as List? ?? const []
            : const [];
        for (final probe in probes) {
          final host = _hostOfProbe('$probe');
          if (host == null || host.contains('{')) continue;
          map.putIfAbsent(host, () => id);
        }
      }
      _domainTemplates = map;
    } catch (_) {
      _domainTemplates = {};
    }
  }

  static String? _hostOf(String url) {
    try {
      final uri = Uri.parse(url.trim());
      final host = uri.host;
      return host.isEmpty ? null : host.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  /// 工具 py 落盘到应用支持目录（不注册成站，只供本页调 PyBridge 用）。
  /// 新版 asset 换了内容也要同步覆写：只在文件不存在时才写，
  /// 手机上会永远跑旧版工具，新版修了探测/模板也落不下去。
  Future<String> _ensureToolPath() async {
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/$_toolDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/$_toolFileName');
    try {
      final text = await rootBundle.loadString(_toolAsset);
      if (!await file.exists() || await file.readAsString() != text) {
        await file.writeAsString(text);
      }
    } catch (_) {
      // 刷新失败时沿用旧文件，不挡生成；文件根本不存在才往外抛。
      if (!await file.exists()) rethrow;
    }
    return file.path;
  }

  /// 生成并自动导入：返回结果（含已导入的站 id）。
  Future<OneKeyPyResult> generate(String url, {String name = ''}) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return const OneKeyPyResult(ok: false, message: '请先输入网站地址');
    }
    final hint = await matchDomainTemplate(trimmed);
    late final Map<String, dynamic> data;
    try {
      final toolPath = await _ensureToolPath();
      final payload = jsonEncode({
        'url': trimmed,
        'name': name.trim(),
        'hint': hint ?? '',
      });
      data = await PyBridge.call(toolPath, {
        'action': 'action',
        'name': 'onekey_generate $payload',
      });
    } on StateError catch (error) {
      return OneKeyPyResult(ok: false, message: error.message);
    } catch (error) {
      return OneKeyPyResult(ok: false, message: '生成失败：$error');
    }
    if (data['ok'] != true) {
      return OneKeyPyResult(
        ok: false,
        message: '${data['msg'] ?? data['error'] ?? '生成失败'}',
      );
    }
    final source = '${data['source'] ?? ''}';
    if (source.trim().isEmpty) {
      return const OneKeyPyResult(ok: false, message: '生成的 py 源码为空');
    }
    final siteName = '${data['name'] ?? ''}'.trim();
    final mode = '${data['mode'] ?? ''}';
    final templateId = '${data['template_id'] ?? ''}';
    final api = '${data['api'] ?? ''}';
    final registry = SourceRegistry.instance;
    await registry.load();
    final existing = registry.custom.where((entry) {
      return entry.kind == SourceKind.pyImport &&
          entry.name.trim() == siteName &&
          siteName.isNotEmpty;
    }).toList();
    try {
      if (existing.isNotEmpty) {
        final entry = await registry.updatePyImportContent(
          id: existing.first.id,
          source: source,
          templateCode: templateId.isEmpty ? null : templateId,
        );
        return OneKeyPyResult(
          ok: true,
          siteName: entry.name,
          mode: mode,
          templateId: templateId,
          api: api,
          entryId: entry.id,
          message: '已更新同名站',
        );
      }
      final entry = await registry.addPyImport(
        siteName.isEmpty ? '一键生成' : siteName,
        source,
        oneClick: true,
      );
      return OneKeyPyResult(
        ok: true,
        siteName: entry.name,
        mode: mode,
        templateId: templateId,
        api: api,
        entryId: entry.id,
        message: '已生成并导入',
      );
    } on StateError catch (error) {
      return OneKeyPyResult(ok: false, message: error.message);
    }
  }
}
