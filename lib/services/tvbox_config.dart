import 'dart:convert';

import 'jar_bridge.dart';

enum TvboxSiteKind { jar, api, py }

class TvboxSiteSpec {
  const TvboxSiteSpec({
    required this.key,
    required this.name,
    required this.kind,
    this.className = '',
    this.jarUrl = '',
    this.md5 = '',
    this.ext = '',
    this.apiUrl = '',
  });

  final String key;
  final String name;
  final TvboxSiteKind kind;
  final String className;
  final String jarUrl;
  final String md5;
  final String ext;
  final String apiUrl;
}

class TvboxConfigParse {
  const TvboxConfigParse({required this.sites, required this.skipped});

  final List<TvboxSiteSpec> sites;
  final List<String> skipped;
}

({String url, String md5}) parseSpiderRef(String raw) {
  var url = '';
  var md5 = '';
  final md5Pattern = RegExp(r'^[0-9a-fA-F]{32}$');
  for (final part in raw.split(';')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    if (md5Pattern.hasMatch(trimmed)) {
      md5 = trimmed.toLowerCase();
    } else if (url.isEmpty) {
      url = trimmed;
    }
  }
  return (url: url, md5: md5);
}

String homepageOfApi(String api) {
  final marker = api.indexOf('api.php');
  if (marker > 0) {
    final base = api.substring(0, marker);
    return base.endsWith('/') ? base : '$base/';
  }
  return api;
}

String _extString(dynamic ext) {
  if (ext is String) return ext;
  if (ext is Map) return jsonEncode(ext);
  return '';
}

String _slug(String key, int index) {
  final slug = key
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return slug.isEmpty ? 'site_$index' : slug;
}

TvboxConfigParse parseTvboxConfig(dynamic decoded) {
  final sites = <TvboxSiteSpec>[];
  final skipped = <String>[];
  List<dynamic>? rows;
  var configSpider = (url: '', md5: '');
  if (decoded is Map<String, dynamic>) {
    final spider = decoded['spider'];
    if (spider is String && spider.trim().isNotEmpty) {
      configSpider = parseSpiderRef(spider);
    }
    final raw = decoded['sites'];
    if (raw is List) rows = raw;
  } else if (decoded is List) {
    rows = decoded;
  }
  if (rows == null) return const TvboxConfigParse(sites: [], skipped: []);
  for (var i = 0; i < rows.length; i++) {
    final entry = rows[i];
    if (entry is! Map<String, dynamic>) continue;
    final key = (entry['key'] as String? ?? '').trim();
    final name = (entry['name'] as String? ?? '').trim();
    final api = (entry['api'] as String? ?? '').trim();
    final display = name.isEmpty ? key : name;
    if (api.isEmpty) {
      skipped.add('$display：缺少 api，已跳过');
      continue;
    }
    final ext = _extString(entry['ext']);
    if (api == 'csp_XBPQ') {
      skipped.add('$display：XBPQ 规则站暂不支持，已跳过');
      continue;
    }
    if (api.startsWith('csp_')) {
      final ref = entry['jar'] != null
          ? parseSpiderRef(entry['jar'].toString())
          : configSpider;
      if (ref.url.isEmpty) {
        skipped.add('$display：jar 站但配置未提供 spider jar 地址，已跳过');
        continue;
      }
      sites.add(
        TvboxSiteSpec(
          key: _slug(key.isEmpty ? name : key, i),
          name: display,
          kind: TvboxSiteKind.jar,
          className: JarSiteSpec.classNameForApi(api),
          jarUrl: ref.url,
          md5: ref.md5,
          ext: ext,
          apiUrl: api,
        ),
      );
      continue;
    }
    final apiPath = api.split('?').first.split('#').first;
    if (apiPath.toLowerCase().endsWith('.py')) {
      sites.add(
        TvboxSiteSpec(
          key: _slug(key.isEmpty ? name : key, i),
          name: display,
          kind: TvboxSiteKind.py,
          ext: ext,
          apiUrl: api,
        ),
      );
      continue;
    }
    if (api.startsWith('http://') || api.startsWith('https://')) {
      sites.add(
        TvboxSiteSpec(
          key: _slug(key.isEmpty ? name : key, i),
          name: display,
          kind: TvboxSiteKind.api,
          ext: ext,
          apiUrl: homepageOfApi(api),
        ),
      );
      continue;
    }
    skipped.add('$display：api 格式无法识别，已跳过');
  }
  return TvboxConfigParse(sites: sites, skipped: skipped);
}
