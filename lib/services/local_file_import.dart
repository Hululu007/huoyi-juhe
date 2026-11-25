import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'file_text_picker.dart';
import 'source_registry.dart';

/// 本地文件批量导入：统一入口的服务层（站源管理页“批量导入本地文件”
/// 按钮背后）。一次多选 py/json/html/js，逐个按扩展名 + 内容嗅探
/// 分流到注册表现成的解析器，单个失败不中断整批，最后汇总一次。
///
/// 分区文案与影视区切换弹窗的口径一致（video_page.dart 的
/// videoPagePlayableSites：video/mixed 的 py/jar/js/xbpq/自定义站
/// 与有探索地址的书源进影视区；小说/漫画/听书进阅读区）。这里按
/// 同一组判定复述，不直接引页面文件，避免服务层反向依赖页面；
/// 单测里用 videoPagePlayableSites 对同一批条目做一致性校验，
/// 判定漂移会被测试抓住。
String zoneLabelForEntry(SourceEntry entry) {
  final videoKind =
      entry.kind == SourceKind.customMaccms ||
      entry.kind == SourceKind.pyImport ||
      entry.kind == SourceKind.jarImport ||
      entry.kind == SourceKind.jsImport ||
      entry.kind == SourceKind.xbpqImport ||
      (entry.kind == SourceKind.legadoImport &&
          entry.extra['hasExplore'] == true);
  if (videoKind &&
      entry.enabled &&
      (entry.contentType == ContentType.video ||
          entry.contentType == ContentType.mixed)) {
    return '影视区';
  }
  if (isBookSourceEntry(entry)) return '${entry.contentType.label}区';
  // 本地网页、TVBox 配置父条目等：不进任何区，只在站源管理里可见。
  return '站源管理可见';
}

/// 刚导进视频站后，影视区切换弹窗下一次打开时一次性切到导入区，
/// 让用户直接看到新站（读一次即清掉，不影响以后的默认区）。
/// 标记写在 SharedPreferences 里：站源管理页与影视页不在同一栈，
/// 靠内存变量传不过去。
const _openImportZoneOnceKey = 'juhe_site_grid_open_import_zone_once';

Future<void> markSiteGridOpenImportZoneOnce() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_openImportZoneOnceKey, true);
  } catch (_) {}
}

Future<bool> consumeSiteGridOpenImportZoneOnce() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getBool(_openImportZoneOnceKey) ?? false;
    if (value) await preferences.remove(_openImportZoneOnceKey);
    return value;
  } catch (_) {
    return false;
  }
}

/// 单个导入结果的文案：一个站写“站名（分区）”，多个站逗号连起来，
/// 超过 5 个只列前 5 个、后面写“等共 N 个站”。
String describeImportedEntries(List<SourceEntry> entries) {
  if (entries.isEmpty) return '已导入';
  const shownMax = 5;
  final shown = entries.take(shownMax).map(
    (e) => '${e.name}（${zoneLabelForEntry(e)}）',
  );
  final tail = entries.length > shownMax
      ? '等共 ${entries.length} 个站'
      : '';
  return '已导入 ${entries.length} 个站：${[...shown, if (tail.isNotEmpty) tail].join('、')}';
}

/// JSON 内容嗅探出的种类：三种 JSON 长得不一样，不能只按扩展名分流。
enum LocalJsonKind { legado, tvbox, xbpq }

/// 按内容嗅探 JSON 种类：Legado 书源认 bookSourceUrl/bookSourceName；
/// TVBox 配置认 sites 数组（或直接是带 api/key 的站点数组）；
/// XBPQ 规则认 base/cateUrl/主页url/分类url/数组等规则字段。
/// 认不出返回 null，调用方按“无法识别”报错，不硬猜。
LocalJsonKind? sniffJsonKind(dynamic decoded) {
  bool hasAnyKey(Map map, List<String> keys) {
    for (final key in keys) {
      if (map.containsKey(key)) return true;
    }
    return false;
  }

  if (decoded is Map) {
    if (hasAnyKey(decoded, ['bookSourceUrl', 'bookSourceName'])) {
      return LocalJsonKind.legado;
    }
    if (decoded['sites'] is List) return LocalJsonKind.tvbox;
    if (hasAnyKey(decoded, [
      'base',
      'host',
      'homeUrl',
      '主页url',
      'cateUrl',
      '分类url',
      'classUrl',
      '数组',
      'listNode',
      'cateNode',
      '搜索url',
      'searchUrl',
      '线路数组',
      'lineNode',
    ])) {
      return LocalJsonKind.xbpq;
    }
    return null;
  }
  if (decoded is List) {
    var sawLegado = false;
    var sawTvbox = false;
    for (final item in decoded) {
      if (item is! Map) continue;
      if (hasAnyKey(item, ['bookSourceUrl', 'bookSourceName'])) {
        sawLegado = true;
      }
      if (hasAnyKey(item, ['api', 'key'])) sawTvbox = true;
    }
    if (sawLegado) return LocalJsonKind.legado;
    if (sawTvbox) return LocalJsonKind.tvbox;
    return null;
  }
  return null;
}

/// 本地文件分流到的解析器。
enum LocalImportKind { py, js, jsonLegado, jsonTvbox, jsonXbpq, html }

/// 扩展名 + 内容嗅探分流：.py 走 py 蜘蛛；.js 走 js 蜘蛛；.json 按
/// 内容嗅探三种 JSON；.html/.htm 走本地网页；扩展名不在表里或没有
/// 扩展名时按内容嗅探（{ 或 [ 开头走 JSON，含 class Spider 走 py，
/// 含 <html 走 html）。都认不出抛 StateError，写清文件名与原因，
/// 不硬猜、不静默跳过。
LocalImportKind classifyLocalImportFile(String name, String text) {
  final lowerName = name.toLowerCase();
  final ext = lowerName.contains('.')
      ? lowerName.split('.').last
      : '';
  final trimmed = text.trimLeft();
  if (ext == 'py') return LocalImportKind.py;
  if (ext == 'js') return LocalImportKind.js;
  if (ext == 'html' || ext == 'htm') return LocalImportKind.html;
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw StateError('$name：不是有效的 JSON');
    }
    return switch (sniffJsonKind(decoded)) {
      LocalJsonKind.legado => LocalImportKind.jsonLegado,
      LocalJsonKind.tvbox => LocalImportKind.jsonTvbox,
      LocalJsonKind.xbpq => LocalImportKind.jsonXbpq,
      null => throw StateError(
        '$name：JSON 内容无法识别（不是书源、TVBox 配置或 XBPQ 规则）',
      ),
    };
  }
  if (text.contains('class Spider') || text.contains('def homeContent')) {
    return LocalImportKind.py;
  }
  if (text.contains('function homeContent')) return LocalImportKind.js;
  if (trimmed.toLowerCase().contains('<html')) {
    return LocalImportKind.html;
  }
  throw StateError('$name：无法识别的文件类型（只认 .py / .js / .json / .html，内容也对不上）');
}

/// 单个文件的导入结果：成功时列出导进来的站（站名 + 分区），
/// 失败时 error 写清原因。
class LocalImportFileResult {
  const LocalImportFileResult({
    required this.fileName,
    required this.ok,
    this.sites = const [],
    this.error = '',
  });

  final String fileName;
  final bool ok;

  /// 成功时导进来的站：站名 + 分区。
  final List<({String name, String zone})> sites;
  final String error;
}

/// 一批的导入结果：成功几个、失败几个、失败的是哪几个文件与原因、
/// 每个站分到哪个区；成功与失败都写清，不留“没反应”。
class LocalImportBatchResult {
  const LocalImportBatchResult({required this.results});

  final List<LocalImportFileResult> results;

  int get successCount => results.where((r) => r.ok).length;

  int get failureCount => results.where((r) => !r.ok).length;

  bool get hasVideoZoneSite =>
      results.any((r) => r.sites.any((s) => s.zone == '影视区'));

  /// 汇总行：首行成功/失败数，后面每文件一行。
  List<String> get summaryLines {
    final lines = <String>[
      failureCount == 0
          ? '全部导入成功，共 $successCount 个文件'
          : '成功 $successCount 个，失败 $failureCount 个',
    ];
    for (final result in results) {
      if (result.ok) {
        final sites = result.sites
            .map((s) => '${s.name}（${s.zone}）')
            .join('、');
        lines.add('成功：${result.fileName} → $sites');
      } else {
        lines.add('失败：${result.fileName}（${result.error}）');
      }
    }
    return lines;
  }

  String get summaryText => summaryLines.join('\n');
}

/// 本地文件批量导入服务：单例，背后是 SourceRegistry.instance。
class LocalFileImportService {
  LocalFileImportService._();

  static final LocalFileImportService instance = LocalFileImportService._();

  /// 批量导入已选到的文件：每个文件各自 try/catch，单个失败不中断
  /// 整批、继续导后面的；最后返回汇总结果（调用方弹一次）。
  /// 读不到字节的文件（error 已记）也照常进汇总，不掀整批。
  /// 这一批里有视频区新站时，写一次“下次打开切换弹窗切导入区”
  /// 标记，让用户导完直接看到新站。
  Future<LocalImportBatchResult> importPickedFiles(
    List<PickedTextFile> files,
  ) async {
    final results = <LocalImportFileResult>[];
    for (final file in files) {
      try {
        if (file.bytes == null) {
          throw StateError(file.error ?? '读取文件失败');
        }
        final text = decodePickedText(file.bytes!);
        final kind = classifyLocalImportFile(file.name, text);
        final base = _fileBase(file.name);
        final entries = await _importOne(kind, base, file.name, text);
        results.add(
          LocalImportFileResult(
            fileName: file.name,
            ok: true,
            sites: [
              for (final entry in entries)
                (name: entry.name, zone: zoneLabelForEntry(entry)),
            ],
          ),
        );
      } catch (e) {
        results.add(
          LocalImportFileResult(
            fileName: file.name,
            ok: false,
            error: e.toString(),
          ),
        );
      }
    }
    final batch = LocalImportBatchResult(results: results);
    if (batch.hasVideoZoneSite) {
      await markSiteGridOpenImportZoneOnce();
    }
    return batch;
  }

  Future<List<SourceEntry>> _importOne(
    LocalImportKind kind,
    String base,
    String fileName,
    String text,
  ) async {
    final registry = SourceRegistry.instance;
    switch (kind) {
      case LocalImportKind.py:
        return [
          await registry.addPyImport(base, text, fileBaseName: base),
        ];
      case LocalImportKind.js:
        return [await registry.addJsImport(base, text)];
      case LocalImportKind.jsonLegado:
        return await registry.addLegadoImport(text);
      case LocalImportKind.jsonTvbox:
        final parent = await registry.addLocalTvboxConfig(
          text,
          fileName: fileName,
        );
        // 父条目是配置容器，子站才是可播的站：汇总里父子都列出来，
        // 子站按登记表里 remoteConfigId == 父条目 id 找回。
        final children = [
          for (final entry in registry.custom)
            if (entry.extra['remoteConfigId'] == parent.id) entry,
        ];
        return [parent, ...children];
      case LocalImportKind.jsonXbpq:
        return [await registry.addXbpqImport(base, text)];
      case LocalImportKind.html:
        return [
          await registry.addHtmlImport(base, text, fileBaseName: base),
        ];
    }
  }

  /// 文件名去目录、去扩展名：'a/b/c.py' → 'c'，作默认站名与
  /// 落盘文件名前缀。
  String _fileBase(String name) {
    final base = name.split('/').last.split('\\').last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}
