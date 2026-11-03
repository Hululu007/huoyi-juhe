import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'drama_site_content.dart';
import 'drama_sites.dart';

enum SourceKind { builtinDrama, customMaccms, remoteJson, pyImport, jsImport }

extension SourceKindLabel on SourceKind {
  String get label => switch (this) {
    SourceKind.builtinDrama => '内置短剧',
    SourceKind.customMaccms => '自定义 MacCMS',
    SourceKind.remoteJson => '远程 JSON 配置',
    SourceKind.pyImport => 'Python 导入',
    SourceKind.jsImport => 'JS 导入',
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
  });

  final String id;
  final String name;
  final SourceKind kind;
  final String address;
  final String detail;
  final bool enabled;

  SourceEntry copyWith({bool? enabled, String? name, String? detail}) =>
      SourceEntry(
        id: id,
        name: name ?? this.name,
        kind: kind,
        address: address,
        detail: detail ?? this.detail,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    'address': address,
    'detail': detail,
    'enabled': enabled,
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
    return SourceEntry(
      id: id,
      name: name,
      kind: kind,
      address: json['address'] as String? ?? '',
      detail: json['detail'] as String? ?? '',
      enabled: json['enabled'] != false,
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
        if (entry.kind == SourceKind.customMaccms)
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
      if (entry.kind != SourceKind.customMaccms || !entry.enabled) continue;
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
    if (kind != SourceKind.pyImport && kind != SourceKind.jsImport) {
      throw StateError('导入记录只支持 Python 与 JS 类型');
    }
    final entry = SourceEntry(
      id: 'import_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? fileName : name.trim(),
      kind: kind,
      address: fileName,
      detail: '已登记，执行引擎尚未接入，暂不可播放',
    );
    _custom = [..._custom, entry];
    await _persist();
    return entry;
  }

  Future<void> removeCustom(String id) async {
    await load();
    _custom = [for (final entry in _custom) if (entry.id != id) entry];
    _registerCustomSites();
    await _persist();
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
      if (custom.kind == SourceKind.customMaccms && custom.enabled) {
        return MaccmsContentClient(siteId, custom.address);
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
