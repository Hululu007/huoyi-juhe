import 'dart:convert';

import 'drama_playback.dart';
import 'local_media_proxy.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'jar_bridge.dart';
import 'js_bridge.dart';
import 'py_bridge.dart';

String _text(Object? value) => '${value ?? ''}'.trim();

int _pageInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}

List<Map<String, dynamic>> _rows(Object? value) {
  if (value is! List) return const [];
  return [
    for (final row in value)
      if (row is Map) Map<String, dynamic>.from(row),
  ];
}

List<DramaSiteCategory> parseTvboxCategories(Map<String, dynamic> home) {
  final categories = <DramaSiteCategory>[];
  for (final row in _rows(home['class'])) {
    final id = _text(row['type_id']);
    final name = _text(row['type_name']);
    if (id.isEmpty || name.isEmpty) continue;
    categories.add(DramaSiteCategory(id, name));
  }
  if (categories.isEmpty) {
    return const [DramaSiteCategory('all', '全部')];
  }
  return categories;
}

List<DramaSiteItem> parseTvboxItems(Map<String, dynamic> json) {
  return [
    for (final row in _rows(json['list']))
      DramaSiteItem(
        id: _text(row['vod_id']),
        title: _text(row['vod_name']),
        cover: _text(row['vod_pic']),
        remark: _text(row['vod_remarks']),
      ),
  ].where((item) => item.id.isNotEmpty).toList();
}

DramaSiteCatalogPage parseTvboxCatalog(Map<String, dynamic> json) {
  final items = parseTvboxItems(json);
  final page = _pageInt(json['page']);
  final pageCount = _pageInt(json['pagecount']);
  final hasMore = pageCount > 0 && page > 0 && page < pageCount;
  return DramaSiteCatalogPage(items: items, hasMore: hasMore);
}

DramaSiteDetail parseTvboxDetail(Map<String, dynamic> json) {
  final rows = _rows(json['list']);
  if (rows.isEmpty) {
    throw StateError('详情为空');
  }
  final row = rows.first;
  final vodId = _text(row['vod_id']);
  final title = _text(row['vod_name']);
  final cover = _text(row['vod_pic']);
  final flags = _text(row['vod_play_from']).split('\$\$\$');
  final groups = _text(row['vod_play_url']).split('\$\$\$');
  final episodes = <DramaSiteEpisode>[];
  for (var g = 0; g < groups.length; g++) {
    final group = groups[g].trim();
    if (group.isEmpty) continue;
    final flag = g < flags.length ? flags[g].trim() : '';
    for (final part in group.split('#')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final dollar = trimmed.indexOf('\$');
      final name = dollar < 0 ? trimmed : trimmed.substring(0, dollar);
      final playId = dollar < 0 ? trimmed : trimmed.substring(dollar + 1);
      if (playId.isEmpty) continue;
      episodes.add(
        DramaSiteEpisode(
          videoId: '$flag\u0001$playId',
          title: groups.length > 1 && flag.isNotEmpty
              ? '$flag-$name'
              : name,
          seriesId: vodId,
        ),
      );
    }
  }
  return DramaSiteDetail(
    id: vodId,
    title: title,
    cover: cover,
    synopsis: _text(row['vod_content']),
    episodes: episodes,
  );
}

/// 蜘蛛本地代理回包（py host 的 proxy 动作与 jar 的 jarProxy 共用此形）：
/// {status, mime, bodyBase64, headers?}。base64 解不开时如实抛错。
LocalProxyResponse parseLocalProxyResponse(Map<String, dynamic> json) {
  final encoded = _text(json['bodyBase64']);
  List<int> body;
  try {
    body = base64Decode(encoded);
  } catch (_) {
    throw StateError('本地代理回包的 bodyBase64 解不开');
  }
  final headers = <String, String>{};
  final headerRaw = json['headers'];
  if (headerRaw is Map) {
    for (final entry in headerRaw.entries) {
      headers[entry.key.toString()] = entry.value.toString();
    }
  }
  return LocalProxyResponse(
    status: int.tryParse(_text(json['status'])) ?? 200,
    mime: _text(json['mime']),
    body: body,
    headers: headers,
  );
}

DramaPlaySource parseTvboxPlay(Map<String, dynamic> json) {
  final parse = _text(json['parse']);
  if (parse == '1') {
    throw StateError('该集需要壳解析，当前播放合同只支持直链');
  }
  final url = _text(json['url']);
  if (url.isEmpty) {
    throw StateError('该集没有可播地址');
  }
  final headers = <String, String>{};
  final headerRaw = json['header'];
  if (headerRaw is Map) {
    for (final entry in headerRaw.entries) {
      headers[entry.key.toString()] = entry.value.toString();
    }
  }
  return DramaPlaySource(url: url, headers: headers);
}

class PySiteContentClient extends DramaSiteContentClient
    implements LocalProxyCapable {
  PySiteContentClient(this.pyPath, {this.ext = ''});

  final String pyPath;
  final String ext;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> request) =>
      PyBridge.call(pyPath, {...request, 'extend': ext});

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final home = await _call({'action': 'categories'});
    return parseTvboxCategories(home);
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final json = await _call({
      'action': 'catalog',
      'category': categoryId == 'all' ? '' : categoryId,
      'page': page,
    });
    return parseTvboxCatalog(json);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final json = await _call({'action': 'detail', 'vodId': seriesId});
    return parseTvboxDetail(json);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final json = await _call({'action': 'search', 'query': query, 'page': 1});
    return parseTvboxItems(json);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final parts = episode.videoId.split('\u0001');
    if (parts.length < 2) {
      throw StateError('选集缺少播放线路信息');
    }
    final json = await _call({
      'action': 'resolve',
      'flag': parts[0],
      'playId': parts.sublist(1).join('\u0001'),
    });
    return parseTvboxPlay(json);
  }

  @override
  Future<LocalProxyResponse?> localProxy(Uri uri) async {
    final json = await _call({
      'action': 'proxy',
      'param': uri.queryParameters,
    });
    return parseLocalProxyResponse(json);
  }
}

class JsSiteContentClient extends DramaSiteContentClient {
  JsSiteContentClient(this.script);

  final String script;

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final home = await JsBridge.run(script: script, operation: 'home');
    return parseTvboxCategories(home);
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final json = await JsBridge.run(
      script: script,
      operation: 'category',
      tid: categoryId == 'all' ? '' : categoryId,
      page: page,
    );
    return parseTvboxCatalog(json);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final json = await JsBridge.run(
      script: script,
      operation: 'detail',
      vodId: seriesId,
    );
    return parseTvboxDetail(json);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final json = await JsBridge.run(
      script: script,
      operation: 'search',
      query: query,
      page: 1,
    );
    return parseTvboxItems(json);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final parts = episode.videoId.split('\u0001');
    if (parts.length < 2) {
      throw StateError('选集缺少播放线路信息');
    }
    final json = await JsBridge.run(
      script: script,
      operation: 'player',
      flag: parts[0],
      playId: parts.sublist(1).join('\u0001'),
    );
    return parseTvboxPlay(json);
  }
}

class JarSiteContentClient extends DramaSiteContentClient
    implements LocalProxyCapable {
  JarSiteContentClient(this.spec);

  final JarSiteSpec spec;

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final home = await JarBridge.callJson(spec, 'homeContent', {
      'filter': true,
    });
    return parseTvboxCategories(home);
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (categoryId == 'all') {
      final json = await JarBridge.callJson(spec, 'homeVideoContent');
      return DramaSiteCatalogPage(
        items: parseTvboxItems(json),
        hasMore: false,
      );
    }
    final json = await JarBridge.callJson(spec, 'categoryContent', {
      'tid': categoryId,
      'pg': '$page',
      'filter': true,
      'extend': <String, dynamic>{},
    });
    return parseTvboxCatalog(json);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final json = await JarBridge.callJson(spec, 'detailContent', {
      'ids': [seriesId],
    });
    return parseTvboxDetail(json);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final json = await JarBridge.callJson(spec, 'searchContent', {
      'key': query,
      'quick': false,
      'pg': '1',
    });
    return parseTvboxItems(json);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final parts = episode.videoId.split('\u0001');
    if (parts.length < 2) {
      throw StateError('选集缺少播放线路信息');
    }
    final json = await JarBridge.callJson(spec, 'playerContent', {
      'flag': parts[0],
      'id': parts.sublist(1).join('\u0001'),
      'vipFlags': <String>[],
    });
    return parseTvboxPlay(json);
  }

  @override
  Future<LocalProxyResponse?> localProxy(Uri uri) async {
    final json = await JarBridge.jarProxy(spec, uri.queryParameters);
    return parseLocalProxyResponse(json);
  }
}
