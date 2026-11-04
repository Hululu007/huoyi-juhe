import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'engine_site_content.dart';
import 'jar_bridge.dart';
import 'local_db_site_content.dart';
import 'm3u_export_db.dart';
import 'site_identity.dart';
import 'zakatv_builtin.dart';
import 'js_bridge.dart';
import 'py_bridge.dart';
import 'legado_content.dart';
import 'tvbox_config.dart';
import 'xbpq_content.dart';

enum SourceKind {
  builtinDrama,
  customMaccms,
  remoteJson,
  pyImport,
  jsImport,
  jarImport,
  xbpqImport,
  legadoImport,
}

extension SourceKindLabel on SourceKind {
  String get label => switch (this) {
    SourceKind.builtinDrama => '内置短剧',
    SourceKind.customMaccms => '自定义 MacCMS',
    SourceKind.remoteJson => '远程 JSON 配置',
    SourceKind.pyImport => 'Python 导入',
    SourceKind.jsImport => 'JS 导入',
    SourceKind.jarImport => 'Jar 导入',
    SourceKind.xbpqImport => 'XBPQ 规则',
    SourceKind.legadoImport => '阅读书源',
  };
}

enum ContentType { video, novel, comic, audio, mixed }

extension ContentTypeLabel on ContentType {
  String get label => switch (this) {
    ContentType.video => '影视',
    ContentType.novel => '小说',
    ContentType.comic => '漫画',
    ContentType.audio => '听书',
    ContentType.mixed => '综合',
  };

  String get key => switch (this) {
    ContentType.video => 'video',
    ContentType.novel => 'novel',
    ContentType.comic => 'comic',
    ContentType.audio => 'audio',
    ContentType.mixed => 'mixed',
  };

  static ContentType fromKey(String? key) => switch (key) {
    'video' => ContentType.video,
    'novel' => ContentType.novel,
    'comic' => ContentType.comic,
    'audio' => ContentType.audio,
    _ => ContentType.mixed,
  };
}

extension SourceEntryContentType on SourceEntry {
  ContentType get contentType =>
      ContentTypeLabel.fromKey(extra['contentType'] as String?);
}

ContentType contentTypeForLegadoSource(LegadoSource source) {
  switch (source.sourceType) {
    case 4:
      return ContentType.video;
    case 1:
      return ContentType.audio;
    case 2:
      return ContentType.comic;
    default:
      return ContentType.novel;
  }
}

/// py 蜘蛛内容自动分类：只看源码里的取流标记，显式选型优先。
/// 调用方只在 contentType == mixed（未指定）时用它：
/// novel:// 独占 → 小说；pics:// 独占 → 漫画；纯音频标记 → 听书；
/// 带视频标记、多种标记混用、无标记 → null（保持 mixed）。
/// 混站（视频+小说同蜘蛛、视频地址走接口无字面量）可能误判为小说，
/// 此时用站源管理的改类型手动纠正一次即可（显式选型不再被覆盖）。
ContentType? detectPyContentType(String source) {
  final lower = source.toLowerCase();
  final hasNovel = source.contains('novel://');
  final hasPics = source.contains('pics://');
  final hasVideo = lower.contains('.m3u8') ||
      lower.contains('.mp4') ||
      lower.contains('.flv') ||
      lower.contains('.mkv') ||
      lower.contains('.avi') ||
      lower.contains('.mov');
  final hasAudio = lower.contains('.mp3') ||
      lower.contains('.m4a') ||
      lower.contains('.aac') ||
      lower.contains('.flac') ||
      lower.contains('.ogg') ||
      lower.contains('.wav') ||
      lower.contains('audio_url') ||
      lower.contains('audiourl') ||
      lower.contains('audio/mpeg');
  if (hasNovel && !hasPics && !hasVideo && !hasAudio) {
    return ContentType.novel;
  }
  if (hasPics && !hasNovel && !hasVideo && !hasAudio) {
    return ContentType.comic;
  }
  if (hasAudio && !hasNovel && !hasPics && !hasVideo) {
    return ContentType.audio;
  }
  return null;
}

/// 书源导入输入的判定：阅读（Legado）导入框同款三态——JSON 对象/数组
/// 直接导入，http(s) 链接走远程拉取，其他内容不认（不硬猜、不发请求）。
enum BookSourceImportKind { remote, json, invalid }

BookSourceImportKind classifyBookSourceInput(String input) {
  final text = input.trim();
  if (text.isEmpty) return BookSourceImportKind.invalid;
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return BookSourceImportKind.remote;
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    return BookSourceImportKind.json;
  }
  return BookSourceImportKind.invalid;
}

/// 书源与影视源的分界（只看内容类型，不看导入方式）：小说 / 漫画 / 听书
/// 是书源，影视与未分类（综合）是影视源。站源管理按此分两组列出，不再
/// 混在一个「自定义」里；py 小说源归书源、Legado 视频源归影视源。
bool isBookSourceEntry(SourceEntry entry) =>
    entry.contentType == ContentType.novel ||
    entry.contentType == ContentType.comic ||
    entry.contentType == ContentType.audio;

class SourceEntry {
  const SourceEntry({
    required this.id,
    required this.name,
    required this.kind,
    this.address = '',
    this.detail = '',
    this.enabled = true,
    this.extra = const {},
  });

  final String id;
  final String name;
  final SourceKind kind;
  final String address;
  final String detail;
  final bool enabled;
  final Map<String, dynamic> extra;

  SourceEntry copyWith({bool? enabled, String? name, String? detail}) =>
      SourceEntry(
        id: id,
        name: name ?? this.name,
        kind: kind,
        address: address,
        detail: detail ?? this.detail,
        enabled: enabled ?? this.enabled,
        extra: extra,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'address': address,
    'detail': detail,
    'enabled': enabled,
    'extra': extra,
  };

  static SourceEntry? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    final kindName = json['kind'] as String? ?? '';
    SourceKind? kind;
    for (final candidate in SourceKind.values) {
      if (candidate.name == kindName) kind = candidate;
    }
    if (kind == null || kind == SourceKind.builtinDrama) return null;
    final extra = json['extra'];
    return SourceEntry(
      id: id,
      name: name,
      kind: kind,
      address: json['address'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      enabled: json['enabled'] != false,
      extra: extra is Map ? Map<String, dynamic>.from(extra) : const {},
    );
  }
}

List<String> parseRemoteJsonSiteNames(dynamic decoded) {
  final names = <String>[];
  List<dynamic>? rows;
  if (decoded is Map<String, dynamic>) {
    final sites = decoded['sites'];
    if (sites is List) rows = sites;
  } else if (decoded is List) {
    rows = decoded;
  }
  if (rows == null) return names;
  for (final entry in rows) {
    if (entry is! Map<String, dynamic>) continue;
    final name = (entry['name'] as String? ?? '').trim();
    if (name.isNotEmpty) names.add(name);
  }
  return names;
}

/// 午夜 jar 内置站：jar 内置批的视频站（含 YouTube）。
/// 这批归属午夜区，不进正常区列表（首页条带、搜索、短剧药丸）；
/// 午夜页单独列它们。音频听书站不是视频站，不在此列。
bool isMidnightJarBuiltin(SourceEntry entry) {
  if (entry.kind != SourceKind.jarImport) return false;
  if (entry.extra['builtin'] != true) return false;
  final type = entry.contentType;
  return type == ContentType.video || type == ContentType.mixed;
}

class SourceRegistry {
  SourceRegistry._();

  static final SourceRegistry instance = SourceRegistry._();

  static const _customKey = 'juhe_custom_sources';
  static const _disabledKey = 'juhe_disabled_builtin_sites';
  static const _deletedBuiltinKey = 'juhe_deleted_builtin_jar';

  List<SourceEntry> _custom = const [];
  Set<String> _disabledBuiltin = {};
  Set<String> _deletedBuiltin = {};
  bool _loaded = false;

  List<SourceEntry> get custom => List.unmodifiable(_custom);

  Future<void> load() async {
    if (_loaded) return;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_customKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _custom = [
            for (final entry in decoded)
              if (entry is Map<String, dynamic>)
                SourceEntry.fromJson(entry),
          ].whereType<SourceEntry>().toList();
        }
      }
      final disabledRaw = preferences.getString(_disabledKey);
      if (disabledRaw != null && disabledRaw.isNotEmpty) {
        final decoded = jsonDecode(disabledRaw);
        if (decoded is List) {
          _disabledBuiltin = {
            for (final entry in decoded)
              if (entry is String) entry,
          };
        }
      }
      final deletedRaw = preferences.getString(_deletedBuiltinKey);
      if (deletedRaw != null && deletedRaw.isNotEmpty) {
        final decoded = jsonDecode(deletedRaw);
        if (decoded is List) {
          _deletedBuiltin = {
            for (final entry in decoded)
              if (entry is String) entry,
          };
        }
      }
    } catch (_) {}
    _loaded = true;
    _registerCustomSites();
    await _autoClassifyMixedPy();
  }

  /// 存量 mixed py 站的一次性自动分类：读已导入文件跑检测，
  /// 命中小说/漫画/听书就改类型并持久化；未命中也打标记，
  /// 避免每次启动重复读文件。文件读不到时不动、不打标记，
  /// 下次启动再试。整体 fail-soft，绝不打断 load。
  Future<void> _autoClassifyMixedPy() async {
    try {
      var touched = false;
      var typeChanged = false;
      final next = <SourceEntry>[];
      for (final entry in _custom) {
        if (entry.kind != SourceKind.pyImport ||
            entry.contentType != ContentType.mixed ||
            entry.extra['typeDetected'] == true) {
          next.add(entry);
          continue;
        }
        final path = entry.extra['path'];
        String? text;
        if (path is String && path.isNotEmpty) {
          try {
            text = await File(path).readAsString();
          } catch (_) {}
        }
        if (text == null) {
          next.add(entry);
          continue;
        }
        final detected = detectPyContentType(text);
        final extra = Map<String, dynamic>.from(entry.extra)
          ..['typeDetected'] = true;
        if (detected != null) {
          extra['contentType'] = detected.key;
          typeChanged = true;
        }
        touched = true;
        next.add(
          SourceEntry(
            id: entry.id,
            name: entry.name,
            kind: entry.kind,
            address: entry.address,
            detail: entry.detail,
            enabled: entry.enabled,
            extra: extra,
          ),
        );
      }
      if (!touched) return;
      _custom = next;
      if (typeChanged) _registerCustomSites();
      await _persist();
    } catch (_) {}
  }

  /// 把 ZakaTV jar 内置站补进登记表，幂等：已有的不动（开关状态保留），
  /// 用户删过的（墓碑）不再复活。jar 文件本身不进登记表，播放时由
  /// clientFor 按 asset 标记现取现拷。
  Future<void> ensureBuiltinJarSites() async {
    await load();
    final existing = {for (final entry in _custom) entry.id};
    var added = false;
    void addBuiltin(
      ZakatvBuiltinSite site,
      String jarId,
      String jarAsset,
      String jarMd5, {
      bool youtubeConfig = false,
    }) {
      final id = JarSiteSpec.siteIdFor(jarId, site.key);
      if (existing.contains(id) || _deletedBuiltin.contains(id)) return;
      existing.add(id);
      _custom = [
        ..._custom,
        SourceEntry(
          id: id,
          name: site.name,
          kind: SourceKind.jarImport,
          address: jarAsset,
          detail: 'ZakaTV jar 内置 · ${site.className}',
          extra: {
            'configId': jarId,
            'className': site.className,
            'jarUrl': 'asset:$jarAsset',
            'md5': jarMd5,
            'ext': site.ext,
            'contentType': site.contentTypeKey,
            'builtin': true,
            if (youtubeConfig) 'youtubeConfig': true,
          },
        ),
      ];
      added = true;
    }

    for (final site in zakatvBuiltinSites) {
      addBuiltin(site, zakatvJarId, zakatvJarAsset, zakatvJarMd5);
    }
    addBuiltin(
      youtubeBuiltinSite,
      youtubeJarId,
      youtubeJarAsset,
      youtubeJarMd5,
      youtubeConfig: true,
    );
    if (!added) return;
    _registerCustomSites();
    await _persist();
  }

  void _registerCustomSites() {
    registerExtraDramaSites([
      for (final entry in _custom)
        if (entry.kind == SourceKind.customMaccms ||
            entry.kind == SourceKind.pyImport ||
            entry.kind == SourceKind.jarImport ||
            entry.kind == SourceKind.jsImport ||
            entry.kind == SourceKind.xbpqImport ||
            entry.kind == SourceKind.legadoImport)
          DramaSite(entry.id, entry.name, [
            const DramaSiteCategory('all', '全部'),
          ]),
    ]);
  }

  Future<void> _persist() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _customKey,
        jsonEncode([for (final entry in _custom) entry.toJson()]),
      );
      await preferences.setString(
        _disabledKey,
        jsonEncode(_disabledBuiltin.toList()),
      );
      await preferences.setString(
        _deletedBuiltinKey,
        jsonEncode(_deletedBuiltin.toList()),
      );
    } catch (_) {}
  }

  bool isBuiltinEnabled(String siteId) => !_disabledBuiltin.contains(siteId);

  Future<void> setBuiltinEnabled(String siteId, bool enabled) async {
    await load();
    if (enabled) {
      _disabledBuiltin.remove(siteId);
    } else {
      _disabledBuiltin.add(siteId);
    }
    await _persist();
  }

  List<DramaSite> visibleDramaSites({Set<ContentType>? types}) {
    final sites = <DramaSite>[];
    for (final site in dramaSites) {
      if (isBuiltinEnabled(site.id)) sites.add(site);
    }
    for (final entry in _custom) {
      if (!entry.enabled) continue;
      if (isMidnightJarBuiltin(entry)) continue;
      if (types != null && !types.contains(entry.contentType)) continue;
      if (entry.kind != SourceKind.customMaccms &&
          entry.kind != SourceKind.pyImport &&
          entry.kind != SourceKind.jarImport &&
          entry.kind != SourceKind.jsImport &&
          entry.kind != SourceKind.xbpqImport &&
          entry.kind != SourceKind.legadoImport) {
        continue;
      }
      sites.add(
        DramaSite(entry.id, entry.name, [
          const DramaSiteCategory('all', '全部'),
        ]),
      );
    }
    return sites;
  }

  List<SourceEntry> builtinEntries() => [
    for (final site in dramaSites)
      SourceEntry(
        id: site.id,
        name: site.name,
        kind: SourceKind.builtinDrama,
        enabled: isBuiltinEnabled(site.id),
      ),
  ];

  SourceEntry? customById(String id) {
    for (final entry in _custom) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  static String customIdForUrl(String url) {
    var hash = 0;
    for (final code in url.codeUnits) {
      hash = ((hash << 5) - hash + code) & 0x7fffffff;
    }
    return 'custom_$hash';
  }

  static String _sanitizeFileBase(String raw) {
    final cleaned = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? 'site' : cleaned;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<SourceEntry> addCustomMaccms(
    String name,
    String baseUrl, {
    ContentType contentType = ContentType.mixed,
  }) async {
    await load();
    final trimmed = baseUrl.trim();
    if (!trimmed.toLowerCase().startsWith('http')) {
      throw StateError('MacCMS 地址需要以 http 开头');
    }
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    final entry = SourceEntry(
      id: customIdForUrl(normalized),
      name: name.trim().isEmpty ? normalized : name.trim(),
      kind: SourceKind.customMaccms,
      address: normalized,
      extra: {'contentType': contentType.key},
    );
    _custom = [
      for (final existing in _custom)
        if (existing.id != entry.id) existing,
      entry,
    ];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<SourceEntry> addRemoteJson(String name, String url) async {
    await load();
    final trimmed = url.trim();
    if (!trimmed.toLowerCase().startsWith('http')) {
      throw StateError('远程 JSON 地址需要以 http 开头');
    }
    final response = await http
        .get(Uri.parse(trimmed))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('远程 JSON 拉取失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    final parsed = parseTvboxConfig(decoded);
    if (parsed.sites.isEmpty) {
      throw StateError('远程配置里没有可展开的站点');
    }
    final configId = customIdForUrl(trimmed);
    final skipped = [...parsed.skipped];
    _custom = [
      for (final existing in _custom)
        if (existing.extra['remoteConfigId'] != configId &&
            existing.id != configId)
          existing,
    ];
    final usedIds = <String>{};
    String childId(String slug) {
      var id = '${configId}_$slug';
      var suffix = 2;
      while (usedIds.contains(id)) {
        id = '${configId}_${slug}_$suffix';
        suffix++;
      }
      usedIds.add(id);
      return id;
    }

    final children = <SourceEntry>[];
    for (final site in parsed.sites) {
      switch (site.kind) {
        case TvboxSiteKind.xbpq:
          try {
            var ruleText = site.ext.trim();
            if (ruleText.toLowerCase().startsWith('http')) {
              final ruleResponse = await http
                  .get(Uri.parse(ruleText))
                  .timeout(const Duration(seconds: 20));
              if (ruleResponse.statusCode != 200) {
                throw StateError('HTTP ${ruleResponse.statusCode}');
              }
              ruleText = utf8.decode(
                ruleResponse.bodyBytes,
                allowMalformed: true,
              );
            }
            final decoded = jsonDecode(ruleText);
            if (decoded is! Map<String, dynamic>) {
              throw StateError('规则不是 JSON 对象');
            }
            final rule = XbpqRule(decoded);
            if (rule.base.isEmpty && rule.cateUrl.isEmpty) {
              throw StateError('规则缺少主页地址与分类地址');
            }
            final id = childId(site.key);
            final directory = await getApplicationSupportDirectory();
            final dir = Directory('${directory.path}/imported_xbpq');
            if (!await dir.exists()) await dir.create(recursive: true);
            final file = File('${dir.path}/$id.json');
            await file.writeAsString(ruleText);
            children.add(
              SourceEntry(
                id: id,
                name: site.name,
                kind: SourceKind.xbpqImport,
                address: '$id.json',
                detail: '来自远程配置',
                extra: {
                  'path': file.path,
                  'remoteConfigId': configId,
                  'contentType': 'video',
                },
              ),
            );
          } catch (error) {
            skipped.add('${site.name}：XBPQ 规则无效（$error），已跳过');
          }
        case TvboxSiteKind.jar:
          children.add(
            SourceEntry(
              id: childId(site.key),
              name: site.name,
              kind: SourceKind.jarImport,
              address: site.jarUrl,
              detail: '来自远程配置',
              extra: {
                'configId': configId,
                'className': site.className,
                'jarUrl': site.jarUrl,
                'md5': site.md5,
                'ext': site.ext,
                'remoteConfigId': configId,
                'contentType': 'video',
              },
            ),
          );
        case TvboxSiteKind.api:
          children.add(
            SourceEntry(
              id: childId(site.key),
              name: site.name,
              kind: SourceKind.customMaccms,
              address: site.apiUrl,
              detail: '来自远程配置 · 接口地址已转站首页抓取',
              extra: {'remoteConfigId': configId, 'contentType': 'video'},
            ),
          );
        case TvboxSiteKind.py:
          try {
            final pyResponse = await http
                .get(Uri.parse(site.apiUrl))
                .timeout(const Duration(seconds: 20));
            if (pyResponse.statusCode != 200) {
              throw StateError('HTTP ${pyResponse.statusCode}');
            }
            final id = childId(site.key);
            final directory = await getApplicationSupportDirectory();
            final dir = Directory('${directory.path}/imported_py');
            if (!await dir.exists()) await dir.create(recursive: true);
            final file = File('${dir.path}/$id.py');
            await file.writeAsString(pyResponse.body);
            children.add(
              SourceEntry(
                id: id,
                name: site.name,
                kind: SourceKind.pyImport,
                address: site.apiUrl,
                detail: '来自远程配置',
                extra: {
                  'path': file.path,
                  'ext': site.ext,
                  'remoteConfigId': configId,
                  'contentType': 'video',
                },
              ),
            );
          } catch (error) {
            skipped.add('${site.name}：py 下载失败（$error），已跳过');
          }
      }
    }
    if (children.isEmpty) {
      throw StateError('远程配置的站点全部展开失败');
    }
    final entry = SourceEntry(
      id: configId,
      name: name.trim().isEmpty ? trimmed : name.trim(),
      kind: SourceKind.remoteJson,
      address: trimmed,
      detail: '已展开 ${children.length} 个站'
          '${skipped.isEmpty ? '' : '，跳过 ${skipped.length} 个'}',
    );
    _custom = [..._custom, entry, ...children];
    await _persist();
    return entry;
  }

  Future<SourceEntry> addJsImport(
    String name,
    String source, {
    ContentType contentType = ContentType.mixed,
  }) async {
    await load();
    final text = source.trim();
    if (text.isEmpty) {
      throw StateError('蜘蛛源码不能为空');
    }
    final id = 'import_${DateTime.now().millisecondsSinceEpoch}';
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/imported_js');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/$id.js');
    await file.writeAsString(text);
    var detail = 'JS 蜘蛛 · 已导入';
    final status = await JsBridge.status();
    if (!status.available) {
      detail = 'JS 蜘蛛 · 已导入，当前安装包无 JS 桥，暂不可播放';
    }
    final entry = SourceEntry(
      id: id,
      name: name.trim().isEmpty ? '$id.js' : name.trim(),
      kind: SourceKind.jsImport,
      address: '$id.js',
      detail: detail,
      extra: {'path': file.path, 'contentType': contentType.key},
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<SourceEntry> addPyImport(
    String name,
    String source, {
    ContentType contentType = ContentType.mixed,
    String? fileBaseName,
    bool oneClick = false,
    String? downloadPath,
  }) async {
    await load();
    final text = source.trim();
    if (text.isEmpty) {
      throw StateError('蜘蛛源码不能为空');
    }
    final id = 'import_${DateTime.now().millisecondsSinceEpoch}';
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/imported_py');
    if (!await dir.exists()) await dir.create(recursive: true);
    var base = _sanitizeFileBase(fileBaseName ?? id);
    var fileName = '$base.py';
    var counter = 2;
    while (await File('${dir.path}/$fileName').exists()) {
      fileName = '${base}_$counter.py';
      counter++;
    }
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(text);
    final effectiveType = contentType == ContentType.mixed
        ? (detectPyContentType(text) ?? contentType)
        : contentType;
    var detail = 'Python 蜘蛛 · 已导入';
    final validation = await PyBridge.validate(text);
    if (validation == null) {
      detail = 'Python 蜘蛛 · 已导入，当前安装包无 Python 桥，暂不可播放';
    } else if (!validation.ok) {
      detail = 'Python 蜘蛛 · 校验未通过：${validation.error}';
    }
    final entry = SourceEntry(
      id: id,
      name: name.trim().isEmpty ? fileName : name.trim(),
      kind: SourceKind.pyImport,
      address: fileName,
      detail: detail,
      extra: {
        'path': file.path,
        'ext': '',
        'contentType': effectiveType.key,
        if (contentType == ContentType.mixed) 'typeDetected': true,
        if (oneClick) 'oneClick': true,
        'downloadPath': ?downloadPath,
      },
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  /// 换域名重生成用的就地更新：只改 py 站，不新建站。
  /// 先校验源码再覆写原文件：校验不过时原文件与登记一字不动；
  /// 校验过（或当前包无桥时）才覆写 extra['path'] 指向的文件，
  /// 并把新下载路径、模板代号、新域名记进 extra。
  /// 站号（entry.id）不变，故本地库里该站的新旧数据天然共用
  /// 同一个站身份（py 站按登记编号归一），不重复建站。
  Future<SourceEntry> updatePyImportContent({
    required String id,
    required String source,
    String? downloadPath,
    String? templateCode,
    String? siteOrigin,
  }) async {
    await load();
    final index = _custom.indexWhere((entry) => entry.id == id);
    if (index < 0) {
      throw StateError('找不到要更新的站点');
    }
    final old = _custom[index];
    if (old.kind != SourceKind.pyImport) {
      throw StateError('只有 py 站能就地更新');
    }
    final text = source.trim();
    if (text.isEmpty) {
      throw StateError('蜘蛛源码不能为空');
    }
    final path = old.extra['path'];
    if (path is! String || path.isEmpty) {
      throw StateError('该站没有已导入的 py 文件路径，无法就地更新');
    }
    var detail = 'Python 蜘蛛 · 已导入';
    final validation = await PyBridge.validate(text);
    if (validation == null) {
      detail = 'Python 蜘蛛 · 已导入，当前安装包无 Python 桥，暂不可播放';
    } else if (!validation.ok) {
      throw StateError('新源码校验未通过：${validation.error}，旧站未动');
    }
    await File(path).writeAsString(text);
    final extra = Map<String, Object?>.from(old.extra);
    final wasAuto = old.extra['typeDetected'] == true;
    if (old.contentType == ContentType.mixed || wasAuto) {
      final detected = detectPyContentType(text);
      if (detected != null) {
        extra['contentType'] = detected.key;
      }
      extra['typeDetected'] = true;
    }
    if (downloadPath != null) {
      extra['downloadPath'] = downloadPath;
    }
    if (templateCode != null) {
      extra['templateCode'] = templateCode;
    }
    if (siteOrigin != null) {
      extra['siteOrigin'] = siteOrigin;
    }
    final updated = SourceEntry(
      id: old.id,
      name: old.name,
      kind: old.kind,
      address: old.address,
      detail: detail,
      extra: extra,
    );
    _custom = [
      for (var i = 0; i < _custom.length; i++)
        if (i == index) updated else _custom[i],
    ];
    _registerCustomSites();
    await _persist();
    return updated;
  }

  Future<SourceEntry> addJarImport(
    String name,
    String jarUrl,
    String className,
    String md5,
    String ext, {
    ContentType contentType = ContentType.mixed,
  }) async {
    await load();
    final url = jarUrl.trim();
    if (!url.toLowerCase().startsWith('http')) {
      throw StateError('jar 地址需要以 http 开头');
    }
    if (!JarBridge.supported) {
      throw StateError('jar 桥仅支持 Android，当前平台无法导入 jar 站点');
    }
    final configId = customIdForUrl(url);
    var resolvedClass = className.trim();
    if (resolvedClass.isEmpty) {
      final jarPath = await JarBridge.ensureJarPath(
        configId: configId,
        url: url,
        md5: md5.trim(),
      );
      final classes = await JarBridge.enumerate(jarPath);
      JarClassInfo? first;
      for (final candidate in classes) {
        if (candidate.instantiable) {
          first = candidate;
          break;
        }
      }
      if (first == null) {
        throw StateError('jar 里没有可实例化的 Spider 类，请手动填类名');
      }
      resolvedClass = first.className;
    }
    final id = 'import_${DateTime.now().millisecondsSinceEpoch}';
    final entry = SourceEntry(
      id: id,
      name: name.trim().isEmpty ? resolvedClass.split('.').last : name.trim(),
      kind: SourceKind.jarImport,
      address: url,
      detail: 'Jar 蜘蛛 · $resolvedClass',
      extra: {
        'configId': configId,
        'className': resolvedClass,
        'jarUrl': url,
        'md5': md5.trim(),
        'ext': ext.trim(),
        'contentType': contentType.key,
      },
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<SourceEntry> addXbpqImport(
    String name,
    String ruleJson, {
    ContentType contentType = ContentType.mixed,
  }) async {
    await load();
    final text = ruleJson.trim();
    if (text.isEmpty) {
      throw StateError('XBPQ 规则 JSON 不能为空');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('XBPQ 规则必须是单个 JSON 对象');
    }
    final rule = XbpqRule(decoded);
    if (rule.base.isEmpty && rule.cateUrl.isEmpty) {
      throw StateError('XBPQ 规则缺少主页地址与分类地址，无法使用');
    }
    final id = 'import_${DateTime.now().millisecondsSinceEpoch}';
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/imported_xbpq');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/$id.json');
    await file.writeAsString(text);
    final entry = SourceEntry(
      id: id,
      name: name.trim().isEmpty ? '$id.json' : name.trim(),
      kind: SourceKind.xbpqImport,
      address: '$id.json',
      detail: 'XBPQ 规则 · 已导入',
      extra: {'path': file.path, 'contentType': contentType.key},
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<List<SourceEntry>> addLegadoImport(
    String jsonText, {
    ContentType contentType = ContentType.mixed,
  }) async {
    await load();
    final decoded = jsonDecode(jsonText.trim());
    final raws = <Map<String, dynamic>>[];
    if (decoded is Map<String, dynamic>) {
      raws.add(decoded);
    } else if (decoded is List) {
      for (final item in decoded) {
        if (item is Map<String, dynamic>) raws.add(item);
      }
    } else {
      throw StateError('阅读书源 JSON 必须是对象或对象数组');
    }
    final entries = <SourceEntry>[];
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/imported_legado');
    if (!await dir.exists()) await dir.create(recursive: true);
    for (final raw in raws) {
      final source = LegadoSource(raw);
      if (source.name.isEmpty || source.url.isEmpty) continue;
      final type = contentType == ContentType.mixed
          ? contentTypeForLegadoSource(source)
          : contentType;
      final id = 'import_${DateTime.now().millisecondsSinceEpoch}_${entries.length}';
      final file = File('${dir.path}/$id.json');
      await file.writeAsString(jsonEncode(raw));
      entries.add(
        SourceEntry(
          id: id,
          name: source.name,
          kind: SourceKind.legadoImport,
          address: source.url,
          detail: '阅读书源 · 已导入',
          extra: {
            'path': file.path,
            'contentType': type.key,
            'hasExplore': source.exploreUrl.trim().isNotEmpty,
          },
        ),
      );
    }
    if (entries.isEmpty) {
      throw StateError('没有可用的书源：每条须含书源名与书源地址');
    }
    _custom = [..._custom, ...entries];
    _registerCustomSites();
    await _persist();
    return entries;
  }

  Future<List<SourceEntry>> addLegadoRemote(String url) async {
    final trimmed = url.trim();
    if (!trimmed.toLowerCase().startsWith('http')) {
      throw StateError('远程书源地址需要以 http 开头');
    }
    final response = await http
        .get(Uri.parse(trimmed))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return addLegadoImport(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  Future<void> removeCustom(String id) async {
    await load();
    final removed = customById(id);
    _custom = [
      for (final entry in _custom)
        if (entry.id != id && entry.extra['remoteConfigId'] != id) entry,
    ];
    if (removed?.extra['builtin'] == true) {
      // 内置 jar 站删后记墓碑，下次补齐不再复活；下载文件夹原文件不在此处处理。
      _deletedBuiltin.add(id);
    }
    _registerCustomSites();
    await _persist();
    if (removed?.kind == SourceKind.pyImport) {
      final path = removed?.extra['path'] as String? ?? '';
      if (path.isNotEmpty) {
        await PyBridge.dispose(path);
        await _deleteQuietly(path);
      }
    }
    if (removed?.kind == SourceKind.jarImport) {
      unawaited(JarBridge.release(id));
    }
  }

  Future<void> setCustomEnabled(String id, bool enabled) async {
    await load();
    _custom = [
      for (final entry in _custom)
        if (entry.id == id) entry.copyWith(enabled: enabled) else entry,
    ];
    await _persist();
  }

  Future<void> setCustomContentType(String id, ContentType type) async {
    await load();
    _custom = [
      for (final entry in _custom)
        if (entry.id == id)
          SourceEntry(
            id: entry.id,
            name: entry.name,
            kind: entry.kind,
            address: entry.address,
            detail: entry.detail,
            enabled: entry.enabled,
            extra: {...entry.extra, 'contentType': type.key}
              ..remove('typeDetected'),
          )
        else
          entry,
    ];
    await _persist();
  }

  Future<DramaSiteContentClient?> clientFor(String siteId) async {
    if (siteId.startsWith('localdb:')) {
      // 本地库入口按归一键读库：同一站点的多入口（内置、采集、
      // 书源）读同一批记录；localdb: 后已是归一键时直接透传
      // （搜索分组就是按记录的归一键建组的）。
      final raw = siteId.substring('localdb:'.length);
      await load();
      final custom = customById(raw);
      return LocalDbContentClient(
        dbSiteId: canonicalSiteKey(
          siteId: raw,
          address: custom?.address ?? '',
          addressIsSiteAddress: custom != null &&
              addressIsSiteAddressForKind(custom.kind.name),
        ),
        dbSink: HiveM3uExportDb.instance,
      );
    }
    await load();
    final custom = customById(siteId);
    if (custom != null) {
      if (!custom.enabled) return null;
      if (custom.kind == SourceKind.customMaccms) {
        return MaccmsContentClient(siteId, custom.address);
      }
      if (custom.kind == SourceKind.pyImport) {
        final path = custom.extra['path'] as String? ?? '';
        if (path.isEmpty) return null;
        return PySiteContentClient(path, ext: custom.extra['ext'] as String? ?? '');
      }
      if (custom.kind == SourceKind.jsImport) {
        final path = custom.extra['path'] as String? ?? '';
        if (path.isEmpty) return null;
        final file = File(path);
        if (!await file.exists()) return null;
        return JsSiteContentClient(await file.readAsString());
      }
      if (custom.kind == SourceKind.legadoImport) {
        final path = custom.extra['path'] as String? ?? '';
        if (path.isEmpty) return null;
        final file = File(path);
        if (!await file.exists()) return null;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) return null;
        return LegadoContentClient(siteId, LegadoSource(decoded));
      }
      if (custom.kind == SourceKind.xbpqImport) {
        final path = custom.extra['path'] as String? ?? '';
        if (path.isEmpty) return null;
        final file = File(path);
        if (!await file.exists()) return null;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) return null;
        return XbpqContentClient(siteId, decoded);
      }
      if (custom.kind == SourceKind.jarImport) {
        final className = custom.extra['className'] as String? ?? '';
        var jarUrl = custom.extra['jarUrl'] as String? ?? '';
        final configId = custom.extra['configId'] as String? ?? '';
        if (className.isEmpty || jarUrl.isEmpty || configId.isEmpty) {
          return null;
        }
        if (jarUrl.startsWith('asset:')) {
          // 内置 jar 站：asset 不是文件路径，播放时现拷到应用目录再走本地路径。
          jarUrl = await JarBridge.resolveBuiltinJarAsset(
            assetPath: jarUrl.substring('asset:'.length),
            configId: configId,
            md5: custom.extra['md5'] as String? ?? '',
          );
        }
        var ext = custom.extra['ext'] as String? ?? '';
        if (custom.extra['youtubeConfig'] == true) {
          // YouTube 站的 ext 是 84KB 的 youtube3.json，使用时现取，不进登记表。
          try {
            ext = await rootBundle.loadString(youtubeConfigAsset);
          } catch (_) {}
        }
        return JarSiteContentClient(
          JarSiteSpec(
            siteId: custom.id,
            configId: configId,
            name: custom.name,
            className: className,
            jarUrl: jarUrl,
            jarMd5: custom.extra['md5'] as String? ?? '',
            ext: ext,
          ),
        );
      }
      return null;
    }
    if (!isBuiltinEnabled(siteId)) return null;
    return dramaSiteContentClient(siteId);
  }

  Future<String?> checkSite(String siteId) async {
    final client = await clientFor(siteId);
    if (client == null) return '该站源当前不可用';
    try {
      final categories = await client.categories().timeout(
        const Duration(seconds: 20),
      );
      final categoryId = categories.isEmpty ? 'all' : categories.first.id;
      final page = await client
          .catalog(categoryId, 1)
          .timeout(const Duration(seconds: 20));
      if (page.items.isEmpty) return '分类或列表为空';
      return null;
    } catch (e) {
      return e.toString();
    }
  }
}
