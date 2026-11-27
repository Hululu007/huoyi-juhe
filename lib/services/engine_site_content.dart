import 'dart:convert';

import 'drama_playback.dart';
import 'local_media_proxy.dart';
import 'player_tracks.dart';
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

/// 详情扩展字段键名归一：TVBox/MacCMS 回包用 vod_ 前缀长键，页面只读
/// 短键（actor/category/tags/year/area/remarks 等），不归一则分类标签、
/// 演员恒空、推荐同分类匹配失效。这里只改名不造值：原 vod_ 键保留，
/// 已有短键优先不覆盖；vod_class 与 vod_tag 同映射 tags，先到者占位。
Map<String, String> normalizeTvboxDetailExtra(Map<String, String> extra) {
  const aliases = <String, String>{
    'vod_actor': 'actor',
    'vod_actress': 'actress',
    'vod_director': 'director',
    'vod_year': 'year',
    'vod_area': 'area',
    'vod_remarks': 'remarks',
    'vod_lang': 'lang',
    'vod_score': 'score',
    'vod_play_from': 'play_from',
    'vod_type_name': 'category',
    'vod_class': 'tags',
    'vod_tag': 'tags',
  };
  final result = Map<String, String>.from(extra);
  for (final entry in extra.entries) {
    final shortKey = aliases[entry.key];
    if (shortKey == null || entry.value.isEmpty) continue;
    result.putIfAbsent(shortKey, () => entry.value);
  }
  return result;
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
  final extra = <String, String>{};
  for (final entry in row.entries) {
    final key = entry.key.toString();
    if (const {
      'vod_id',
      'vod_name',
      'vod_pic',
      'vod_content',
      'vod_play_url',
      'stills',
      'vod_stills',
      'vod_pic_screenshot',
    }.contains(key)) {
      continue;
    }
    final value = _text(entry.value);
    if (value.isNotEmpty) extra[key] = value;
  }
  return DramaSiteDetail(
    id: vodId,
    title: title,
    cover: cover,
    synopsis: _text(row['vod_content']),
    extra: normalizeTvboxDetailExtra(extra),
    stills: parseDetailStills(
      row['stills'] ?? row['vod_stills'] ?? row['vod_pic_screenshot'],
    ),
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

/// 播放地址多候选（同步批 A2 核查补缺）：playerContent 的 url 除
/// 字符串外，TVBox 约定里还有数组形态——[名, 址, 名, 址…] 成对、
/// 纯地址列表、或 [{name, url}…] 对象列表。此前 _text 会把数组
/// 拼成 "[名, 址, …]" 的垃圾串直接播不了，这里归一成候选列表：
/// 第一条作主址，其余作 variants（与换变体/回退链的候选同路）。
List<({String name, String url})> playUrlCandidates(Object? raw) {
  if (raw is! List) return const [];
  final objects = <({String name, String url})>[];
  final strings = <String>[];
  for (final entry in raw) {
    if (entry is Map) {
      final url = _text(
        entry['url'] ?? entry['v'] ?? entry['src'] ?? entry['address'],
      );
      if (url.isEmpty) continue;
      final name = _text(entry['name'] ?? entry['n'] ?? entry['title']);
      objects.add((name: name, url: url));
    } else {
      final text = _text(entry);
      if (text.isNotEmpty) strings.add(text);
    }
  }
  if (objects.isNotEmpty) {
    return <({String name, String url})>[
      for (var i = 0; i < objects.length; i++)
        (
          name: objects[i].name.isEmpty ? '线路${i + 1}' : objects[i].name,
          url: objects[i].url,
        ),
    ];
  }
  if (strings.isEmpty) return const [];
  bool looksLikeUrl(String text) => text.contains('://');
  final urlsOnly = strings.every(looksLikeUrl);
  final paired = strings.length >= 2 &&
      strings.length.isEven &&
      <int>[for (var i = 1; i < strings.length; i += 2) i].every(
        (i) => looksLikeUrl(strings[i]),
      );
  if (urlsOnly) {
    return <({String name, String url})>[
      for (var i = 0; i < strings.length; i++)
        (name: '线路${i + 1}', url: strings[i]),
    ];
  }
  if (paired) {
    return <({String name, String url})>[
      for (var i = 0; i < strings.length; i += 2)
        (name: strings[i], url: strings[i + 1]),
    ];
  }
  // 形状不明时只取像地址的串，宁少勿错。
  final urls = strings.where(looksLikeUrl).toList();
  return <({String name, String url})>[
    for (var i = 0; i < urls.length; i++) (name: '线路${i + 1}', url: urls[i]),
  ];
}

DramaPlaySource parseTvboxPlay(Map<String, dynamic> json) {
  final parse = _text(json['parse']);
  if (parse == '1') {
    throw StateError('该集需要壳解析，当前播放合同只支持直链');
  }
  final headers = <String, String>{};
  final headerRaw = json['header'];
  if (headerRaw is Map) {
    for (final entry in headerRaw.entries) {
      headers[entry.key.toString()] = entry.value.toString();
    }
  }
  final rawUrl = json['url'];
  var url = '';
  var variants = const <DramaPlayVariant>[];
  if (rawUrl is List) {
    final candidates = playUrlCandidates(rawUrl);
    if (candidates.isNotEmpty) {
      url = candidates.first.url;
      variants = <DramaPlayVariant>[
        for (var i = 1; i < candidates.length; i++)
          DramaPlayVariant(name: candidates[i].name, url: candidates[i].url),
      ];
    }
  } else {
    url = _text(rawUrl);
  }
  if (url.isEmpty) {
    throw StateError('该集没有可播地址');
  }
  return DramaPlaySource(
    url: url,
    headers: headers,
    variants: variants,
    // 外挂字幕（A8）：playerContent 的 subs 在此归一，全引擎站共用。
    subs: parseExternalSubtitles(json['subs']),
  );
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

class JsSiteContentClient extends DramaSiteContentClient
    implements LocalProxyCapable {
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

  @override
  Future<LocalProxyResponse?> localProxy(Uri uri) async {
    Map<String, dynamic> json;
    try {
      json = await JsBridge.run(
        script: script,
        operation: 'proxy',
        params: uri.queryParameters,
      );
    } on StateError catch (error) {
      // 脚本根本没定义 localProxy：按“未实现”回空，让调用方
      // （drama_site_play 的会话转接）报统一的未实现错误，
      // 而不是把引擎的缺函数报错当成代理执行失败。
      if (error.message.contains('does not provide localProxy')) {
        return null;
      }
      rethrow;
    }
    return parseLocalProxyResponse(json);
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
