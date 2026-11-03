import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'engine_site_content.dart';
import 'jar_bridge.dart';
import 'py_bridge.dart';

enum SourceKind {
  builtinDrama,
  customMaccms,
  remoteJson,
  pyImport,
  jsImport,
  jarImport,
}

extension SourceKindLabel on SourceKind {
  String get label => switch (this) {
    SourceKind.builtinDrama => '内置短剧',
    SourceKind.customMaccms => '自定义 MacCMS',
    SourceKind.remoteJson => '远程 JSON 配置',
    SourceKind.pyImport => 'Python 导入',
    SourceKind.jsImport => 'JS 导入',
    SourceKind.jarImport => 'Jar 导入',
  };
}

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

class SourceRegistry {
  SourceRegistry._();

  static final SourceRegistry instance = SourceRegistry._();

  static const _customKey = 'juhe_custom_sources';
  static const _disabledKey = 'juhe_disabled_builtin_sites';

  List<SourceEntry> _custom = const [];
  Set<String> _disabledBuiltin = {};
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
    } catch (_) {}
    _loaded = true;
    _registerCustomSites();
  }

  void _registerCustomSites() {
    registerExtraDramaSites([
      for (final entry in _custom)
        if (entry.kind == SourceKind.customMaccms ||
            entry.kind == SourceKind.pyImport ||
            entry.kind == SourceKind.jarImport)
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

  List<DramaSite> visibleDramaSites() {
    final sites = <DramaSite>[];
    for (final site in dramaSites) {
      if (isBuiltinEnabled(site.id)) sites.add(site);
    }
    for (final entry in _custom) {
      if (!entry.enabled) continue;
      if (entry.kind != SourceKind.customMaccms &&
          entry.kind != SourceKind.pyImport &&
          entry.kind != SourceKind.jarImport) {
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

  Future<SourceEntry> addCustomMaccms(String name, String baseUrl) async {
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
    final names = parseRemoteJsonSiteNames(decoded);
    if (names.isEmpty) {
      throw StateError('远程 JSON 里没有可识别的站点列表');
    }
    final entry = SourceEntry(
      id: customIdForUrl(trimmed),
      name: name.trim().isEmpty ? trimmed : name.trim(),
      kind: SourceKind.remoteJson,
      address: trimmed,
      detail: '${names.length} 个站点：${names.take(3).join('、')}'
          '${names.length > 3 ? '…' : ''}',
    );
    _custom = [
      for (final existing in _custom)
        if (existing.id != entry.id) existing,
      entry,
    ];
    await _persist();
    return entry;
  }

  Future<SourceEntry> addImportRecord(
    String name,
    String fileName,
    SourceKind kind,
  ) async {
    await load();
    if (kind != SourceKind.jsImport) {
      throw StateError('登记导入只支持 JS 类型，Python 与 Jar 走引擎导入');
    }
    final entry = SourceEntry(
      id: 'import_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? fileName : name.trim(),
      kind: kind,
      address: fileName,
      detail: '已登记，JS 执行引擎尚未接入，暂不可播放',
    );
    _custom = [..._custom, entry];
    await _persist();
    return entry;
  }

  Future<SourceEntry> addPyImport(String name, String source) async {
    await load();
    final text = source.trim();
    if (text.isEmpty) {
      throw StateError('蜘蛛源码不能为空');
    }
    final id = 'import_${DateTime.now().millisecondsSinceEpoch}';
    final directory = await getApplicationSupportDirectory();
    final dir = Directory('${directory.path}/imported_py');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/$id.py');
    await file.writeAsString(text);
    var detail = 'Python 蜘蛛 · 已导入';
    final validation = await PyBridge.validate(text);
    if (validation == null) {
      detail = 'Python 蜘蛛 · 已导入，当前安装包无 Python 桥，暂不可播放';
    } else if (!validation.ok) {
      detail = 'Python 蜘蛛 · 校验未通过：${validation.error}';
    }
    final entry = SourceEntry(
      id: id,
      name: name.trim().isEmpty ? '$id.py' : name.trim(),
      kind: SourceKind.pyImport,
      address: '$id.py',
      detail: detail,
      extra: {'path': file.path, 'ext': ''},
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<SourceEntry> addJarImport(
    String name,
    String jarUrl,
    String className,
    String md5,
    String ext,
  ) async {
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
      },
    );
    _custom = [..._custom, entry];
    _registerCustomSites();
    await _persist();
    return entry;
  }

  Future<void> removeCustom(String id) async {
    await load();
    final removed = customById(id);
    _custom = [for (final entry in _custom) if (entry.id != id) entry];
    _registerCustomSites();
    await _persist();
    if (removed?.kind == SourceKind.pyImport) {
      final path = removed?.extra['path'] as String? ?? '';
      if (path.isNotEmpty) unawaited(PyBridge.dispose(path));
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

  Future<DramaSiteContentClient?> clientFor(String siteId) async {
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
      if (custom.kind == SourceKind.jarImport) {
        final className = custom.extra['className'] as String? ?? '';
        final jarUrl = custom.extra['jarUrl'] as String? ?? '';
        final configId = custom.extra['configId'] as String? ?? '';
        if (className.isEmpty || jarUrl.isEmpty || configId.isEmpty) {
          return null;
        }
        return JarSiteContentClient(
          JarSiteSpec(
            siteId: custom.id,
            configId: configId,
            name: custom.name,
            className: className,
            jarUrl: jarUrl,
            jarMd5: custom.extra['md5'] as String? ?? '',
            ext: custom.extra['ext'] as String? ?? '',
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
