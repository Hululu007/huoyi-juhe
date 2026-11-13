// 改编自万象影院 lib/core/pygen/onekey_py_service.dart（用户自有项目，
// 与本树一键写PY同源的纯 Dart 版一键生成逻辑）。
// 改编处：探测取数改走本目录共用的 fetchScrapeHtml（package:http +
// 验证判定）；模板库域名匹配复用本树 OneKeyPyService.matchDomainTemplate；
// 校验改走 PyBridge.validate；注册改走 SourceRegistry.addPyImport /
// updatePyImportContent + 同名判更新（照抄 OneKeyPyService.generate
// 后半段）；PluginConfig/SourceRepository/PyImporter 引用全部去掉。
// 生成逻辑不引入中文注释；模板资产与本树 yijianxiepy.py 内嵌模板同源。
/// 网页爬取内一键生成 py：以本次爬取实际拿到的数据为依据生成 py 蜘蛛。
///
/// 依据：爬取页地址（取 origin 作基址）+ 本次实际拉取的页面 HTML（CMS
/// 结构探测，不再重新拉首页）+ 页面标题（作源名）+ 通用模式下已提取的
/// 链接地址（作结构佐证）。苹果 CMS / WordPress 两类接口探测仍需请求
/// 其各自接口地址（由基址派生，不是让用户重新输网址）。
///
/// 探测链（与原输入网址版一致）：① 域名精确匹配已知站（模板 id 作 hint
/// 置顶）→ ② CMS 特征逐个探（苹果 CMS → TVBox 接口 → MacCMS →
/// WordPress → Next.js）→ ③ 通用嗅探兜底（爬取已证明站点可达）。
/// 命中验证页时抛 [OneKeyVerificationException]（走现有验证流程，不绕
/// 过）；爬取数据不足（无页面内容）时诚实报错，不编假规则。
///
/// 生成只产出代码（[OneKeyCodeResult]），默认不注册；调用方按需经
/// [ScrapePyService.registerGenerated] 注册进站点列表，或经导出通道
/// 保存/分享 py 文件。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../services/onekey_py_service.dart';
import '../services/py_bridge.dart';
import '../services/source_registry.dart';
import 'verification_detector.dart';
import 'web_scrape_service.dart';

/// 生成失败（诚实错误，直接展示给用户）。
class OneKeyException implements Exception {
  OneKeyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 探测命中验证页：需用户走现有验证流程，本服务不绕过。
class OneKeyVerificationException extends OneKeyException {
  OneKeyVerificationException(String url)
    : super('该站点需要验证后才能访问：$url。请先在浏览器里完成验证，再回来生成。');
}

/// 生成出的 py 代码（未注册）。
class OneKeyCodeResult {
  const OneKeyCodeResult({
    required this.code,
    required this.fileName,
    required this.siteName,
    required this.base,
    required this.templateId,
    required this.mode,
    required this.api,
  });

  /// 生成的 py 蜘蛛源码全文。
  final String code;

  /// 建议文件名（如 `examplecom.py`）。
  final String fileName;

  /// 源名（页面标题净化后，或由基址推导）。
  final String siteName;

  /// 站点基址（爬取地址的 origin）。
  final String base;

  /// 命中的模板 id（`generic_html` 为通用嗅探兜底）。
  final String templateId;

  /// 探测结论模式（如 `apple cms json`）。
  final String mode;

  /// 命中的接口地址（无则为空）。
  final String api;
}

/// 注册结果（经 [ScrapePyService.registerGenerated]）。
class ScrapePyRegisterResult {
  const ScrapePyRegisterResult({
    required this.entryId,
    required this.entryName,
    required this.updated,
  });

  /// 登记条目 id（新建或被更新的同名站）。
  final String entryId;

  /// 登记条目名。
  final String entryName;

  /// true = 更新了同名旧站；false = 新注册。
  final bool updated;
}

/// 注册口子抽象：默认实现包 [SourceRegistry]，测试注入假实现隔离。
abstract class ScrapePyRegistrar {
  Future<void> load();

  /// 按名找已登记的 py 站（同名判更新用）；无则返回 null。
  Future<ScrapePyEntryRef?> findPyImportByName(String name);

  /// 新注册一个 py 站，返回登记条目引用。
  Future<ScrapePyEntryRef> addPyImport(
    String name,
    String source, {
    String? fileBaseName,
  });

  /// 就地更新一个 py 站的源码，返回登记条目引用。
  Future<ScrapePyEntryRef> updatePyImportContent({
    required String id,
    required String source,
    String? templateCode,
  });
}

/// 登记条目引用（id + 名，注册结果只用这两项）。
class ScrapePyEntryRef {
  const ScrapePyEntryRef({required this.id, required this.name});
  final String id;
  final String name;
}

/// 默认注册口子：包本树 [SourceRegistry] 单例。
class SourceRegistryScrapePyRegistrar implements ScrapePyRegistrar {
  const SourceRegistryScrapePyRegistrar();

  @override
  Future<void> load() => SourceRegistry.instance.load();

  @override
  Future<ScrapePyEntryRef?> findPyImportByName(String name) async {
    if (name.trim().isEmpty) return null;
    for (final entry in SourceRegistry.instance.custom) {
      if (entry.kind == SourceKind.pyImport && entry.name.trim() == name) {
        return ScrapePyEntryRef(id: entry.id, name: entry.name);
      }
    }
    return null;
  }

  @override
  Future<ScrapePyEntryRef> addPyImport(
    String name,
    String source, {
    String? fileBaseName,
  }) async {
    final entry = await SourceRegistry.instance.addPyImport(
      name,
      source,
      fileBaseName: fileBaseName,
      oneClick: true,
    );
    return ScrapePyEntryRef(id: entry.id, name: entry.name);
  }

  @override
  Future<ScrapePyEntryRef> updatePyImportContent({
    required String id,
    required String source,
    String? templateCode,
  }) async {
    final entry = await SourceRegistry.instance.updatePyImportContent(
      id: id,
      source: source,
      templateCode: templateCode,
    );
    return ScrapePyEntryRef(id: entry.id, name: entry.name);
  }
}

class ScrapePyService {
  ScrapePyService({
    Future<String> Function(String url)? fetch,
    Future<String> Function()? templateText,
    Future<String?> Function(String url)? matchTemplate,
    Future<PyValidation?> Function(String source)? validate,
    ScrapePyRegistrar? registrar,
  }) : _fetch = fetch ?? _defaultFetch,
       _templateText = templateText ?? _defaultTemplateText,
       _matchTemplate =
           matchTemplate ?? OneKeyPyService.instance.matchDomainTemplate,
       _validate = validate ?? PyBridge.validate,
       _registrar = registrar ?? const SourceRegistryScrapePyRegistrar();

  static const String templateAssetPath =
      'assets/py_tools/universal_spider_template.py';

  /// CMS 探测顺序（与原工具 `_generate_code` 一致）。
  static const List<String> probeOrder = <String>[
    'apple_cms_v10',
    'tvbox_api',
    'maccms_html',
    'wordpress',
    'nextjs',
  ];

  static const List<String> _applePaths = <String>[
    '/api.php/provide/vod',
    '/api.php/provide/vod/at/json',
    '/provide/vod',
    '/api/vod',
  ];

  static const List<String> _maccmsFeatures = <String>[
    '/vod/detail/',
    '/vod/play/',
    '/vod/type/',
    '/vod/search/',
    '/voddetail/',
    '/vodplay/',
    '/vodtype/',
    '/vodsearch/',
    '/index.php/vod/',
  ];

  final Future<String> Function(String url) _fetch;
  final Future<String> Function() _templateText;
  final Future<String?> Function(String url) _matchTemplate;
  final Future<PyValidation?> Function(String source) _validate;
  final ScrapePyRegistrar _registrar;

  static Future<String> _defaultFetch(String url) => fetchScrapeHtml(url);

  static Future<String> _defaultTemplateText() =>
      rootBundle.loadString(templateAssetPath);

  /// 由地址推导默认源名（与原工具 `_safe_name` 一致：host 去 www./端口，
  /// 仅留字母数字与汉字，空则“生成源”）。
  static String safeName(String site) {
    String host;
    try {
      host = Uri.parse(site).host;
      if (host.isEmpty) host = site;
    } on Object {
      host = site;
    }
    host = host.replaceAll('www.', '');
    final String name = host
        .split(':')
        .first
        .replaceAll(RegExp(r'[^0-9A-Za-z\u4e00-\u9fa5]+'), '');
    return name.isEmpty ? '生成源' : name;
  }

  /// 页面标题净化为可安全填进模板 `SITE_NAME = "..."` 的源名：去引号、
  /// 反斜杠与控制字符、空白折叠、截断；净化后为空返回空（调用方回落
  /// 到 [safeName]）。
  static String sanitizeTitle(String? title) {
    if (title == null) return '';
    final String cleaned = title
        .replaceAll(RegExp(r'["\\]'), '')
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '';
    return cleaned.length > 24 ? cleaned.substring(0, 24).trim() : cleaned;
  }

  /// Python 风格的列表字面量（供 @BASES@ 占位符）。
  static String pythonReprList(List<String> items) {
    final String inner = items.map((String s) => "'$s'").join(', ');
    return '[$inner]';
  }

  /// 由爬取数据生成 py 代码（不注册）：返回代码与探测结论；数据不足
  /// 或验证拦截时抛 [OneKeyException]。
  Future<OneKeyCodeResult> generateFromScrape({
    required String scrapeUrl,
    required String html,
    String? pageTitle,
    List<String> linkUrls = const <String>[],
    String name = '',
    void Function(String progress)? onProgress,
  }) async {
    final String base = _originOf(scrapeUrl);
    if (base.isEmpty) {
      throw OneKeyException('未能从爬取地址解析出站点基址：$scrapeUrl');
    }
    if (html.trim().isEmpty) {
      throw OneKeyException('本次爬取没有拿到页面内容，无法生成 py。请先在网页爬取里打开一个能正常显示的页面，再点生成。');
    }
    String siteName = name.trim();
    if (siteName.isEmpty) siteName = sanitizeTitle(pageTitle);
    if (siteName.isEmpty) siteName = safeName(base);

    onProgress?.call('正在匹配已知站点模板…');
    String hint = '';
    try {
      hint = await _matchTemplate(base) ?? '';
    } on Object {
      hint = '';
    }
    final List<String> order = <String>[...probeOrder];
    if (hint.isNotEmpty && order.contains(hint)) {
      order.remove(hint);
      order.insert(0, hint);
    }

    // 结构证据：本次爬取的 HTML + 已提取的链接地址（通用模式下的导航/
    // 列表链接能佐证 CMS 路径特征）。首页不再重新拉取。
    final String evidence = <String>[html, ...linkUrls].join('\n');

    String templateId = 'generic_html';
    String foundForce = 'html';
    String foundMode = 'generic html sniffing';
    String foundApi = '';

    // 命中验证页：不绕过，转为带指引的诚实错误。
    try {
      for (final String tid in order) {
        onProgress?.call('正在探测：$tid…');
        if (tid == 'apple_cms_v10') {
          final String? api = await _probeApple(base);
          if (api != null) {
            templateId = tid;
            foundForce = 'json';
            foundMode = 'apple cms json';
            foundApi = api;
            break;
          }
        } else if (tid == 'tvbox_api') {
          final String? host = await _probeTvbox(base, evidence);
          if (host != null) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'tvbox api';
            foundApi = host;
            break;
          }
        } else if (tid == 'maccms_html') {
          if (_probeMaccms(evidence)) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'maccms html';
            break;
          }
        } else if (tid == 'wordpress') {
          if (await _probeWordpress(base)) {
            templateId = tid;
            foundForce = 'html';
            foundMode = 'wordpress';
            break;
          }
        } else if (tid == 'nextjs') {
          if (evidence.contains('/_next/static') &&
              evidence.contains('/vod/play/') &&
              evidence.contains('/detail/')) {
            templateId = tid;
            foundForce = 'nextjs';
            foundMode = 'nextjs';
            break;
          }
        }
      }
    } on VerificationRequiredException catch (e) {
      throw OneKeyVerificationException(e.url);
    }
    // 未命中任一 CMS 时走通用嗅探兜底：爬取本身已证明站点可达，
    // 不再额外发请求确认。

    onProgress?.call('正在生成 py 蜘蛛…');
    final String template = await _templateText();
    final DateTime now = DateTime.now();
    final String ts =
        '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
    final String code = template
        .replaceAll('@NAME@', siteName)
        .replaceAll('@SITE@', base)
        .replaceAll('@BASES@', pythonReprList(<String>[base]))
        .replaceAll('@API@', foundApi)
        .replaceAll('@FORCE@', foundForce)
        .replaceAll('@IMGPROXY@', '')
        .replaceAll('@MODE@', foundMode)
        .replaceAll('@TS@', ts);

    await _checkValidation(code);

    return OneKeyCodeResult(
      code: code,
      fileName: '${safeName(base)}.py',
      siteName: siteName,
      base: base,
      templateId: templateId,
      mode: foundMode,
      api: foundApi,
    );
  }

  /// 把已生成的代码注册进站点列表（可选，默认不注册；同名站就地更新）。
  Future<ScrapePyRegisterResult> registerGenerated({
    required OneKeyCodeResult generated,
  }) async {
    await _checkValidation(generated.code);
    await _registrar.load();
    final ScrapePyEntryRef? existing = await _registrar.findPyImportByName(
      generated.siteName,
    );
    if (existing != null) {
      final ScrapePyEntryRef updated = await _registrar.updatePyImportContent(
        id: existing.id,
        source: generated.code,
        templateCode: generated.templateId,
      );
      return ScrapePyRegisterResult(
        entryId: updated.id,
        entryName: updated.name,
        updated: true,
      );
    }
    final String fileBase = generated.fileName.endsWith('.py')
        ? generated.fileName.substring(0, generated.fileName.length - 3)
        : generated.fileName;
    final ScrapePyEntryRef added = await _registrar.addPyImport(
      generated.siteName,
      generated.code,
      fileBaseName: fileBase,
    );
    return ScrapePyRegisterResult(
      entryId: added.id,
      entryName: added.name,
      updated: false,
    );
  }

  /// 校验生成的代码：桥不存在（返回 null）时无法校验，放行（注册口子
  /// 同样容忍无桥，只在登记详情里注明）；校验明确不过时诚实报错。
  Future<void> _checkValidation(String code) async {
    final PyValidation? validation = await _validate(code);
    if (validation != null && !validation.ok) {
      throw OneKeyException('生成的 py 未通过校验：${validation.error}');
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 取地址的 origin（scheme + host + 端口），无 host 返回空。
  static String _originOf(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) return '';
    final String scheme = uri.scheme.isEmpty ? 'https' : uri.scheme;
    final String port = uri.hasPort ? ':${uri.port}' : '';
    return '$scheme://${uri.host}$port';
  }

  Future<String?> _probeApple(String base) async {
    for (final String path in _applePaths) {
      final String url = base + path;
      final String probeUrl = '$url${url.contains('?') ? '&' : '?'}ac=list';
      try {
        final String body = await _fetch(
          probeUrl,
        ).timeout(const Duration(seconds: 8));
        final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
        if (decoded is Map<String, dynamic>) {
          final Object? list = decoded['list'];
          if (list is List && list.isNotEmpty) return url;
          if (list is Map && list.isNotEmpty) return url;
        }
      } on VerificationRequiredException {
        rethrow;
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<String?> _probeTvbox(String base, String evidence) async {
    final List<String> hosts = <String>[];
    final RegExp hostRe = RegExp(
      r'https?://([A-Za-z0-9.\-]+)(?::\d+)?/api/tvbox/',
    );
    for (final RegExpMatch m in hostRe.allMatches(evidence)) {
      final String h = m.group(1)!;
      if (!hosts.contains(h)) hosts.add(h);
    }
    final String baseHost = Uri.tryParse(base)?.host ?? '';
    if (baseHost.isNotEmpty && !hosts.contains(baseHost)) {
      hosts.add(baseHost);
    }
    for (final String host in hosts) {
      try {
        final String body = await _fetch(
          'https://$host/api/tvbox/home?nav=1',
        ).timeout(const Duration(seconds: 8));
        final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
        if (decoded is Map<String, dynamic>) {
          final Object? nav = decoded['nav'];
          final Object? list = decoded['list'];
          final Object? data = decoded['data'];
          if (_truthy(nav) || _truthy(list) || _truthy(data)) {
            return 'https://$host';
          }
        }
      } on VerificationRequiredException {
        rethrow;
      } on Object {
        continue;
      }
    }
    return null;
  }

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    if (v is String) return v.isNotEmpty;
    return true;
  }

  static bool _probeMaccms(String evidence) {
    return _maccmsFeatures.any(evidence.contains);
  }

  Future<bool> _probeWordpress(String base) async {
    try {
      final String body = await _fetch(
        '$base/wp-json/wp/v2/',
      ).timeout(const Duration(seconds: 8));
      final Object? decoded = jsonDecode(body.replaceAll('\uFEFF', ''));
      if (decoded is Map<String, dynamic>) {
        return decoded.containsKey('routes') ||
            decoded.containsKey('name') ||
            decoded.containsKey('namespaces');
      }
    } on VerificationRequiredException {
      rethrow;
    } on Object {
      return false;
    }
    return false;
  }
}
