import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'gbk_codec.dart';
import 'drama_sites.dart';
import 'js_bridge.dart';
import 'xbpq_content.dart';

Map<String, String> _stringRuleMap(dynamic raw) {
  final result = <String, String>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      if (entry.value is String) {
        result['${entry.key}'] = entry.value as String;
      }
    }
  }
  return result;
}

class LegadoSource {
  LegadoSource(Map<String, dynamic> json)
      : name = '${json['bookSourceName'] ?? ''}',
        url = '${json['bookSourceUrl'] ?? ''}',
        sourceType =
            int.tryParse('${json['bookSourceType'] ?? 0}') ?? 0,
        group = '${json['bookSourceGroup'] ?? ''}',
        searchUrl = '${json['searchUrl'] ?? ''}',
        exploreUrl = '${json['exploreUrl'] ?? ''}',
        header = '${json['header'] ?? ''}',
        jsLib = '${json['jsLib'] ?? ''}',
        ruleSearch = _stringRuleMap(json['ruleSearch']),
        ruleBookInfo = _stringRuleMap(json['ruleBookInfo']),
        ruleToc = _stringRuleMap(json['ruleToc']),
        ruleContent = _stringRuleMap(json['ruleContent']),
        ruleExplore = _stringRuleMap(json['ruleExplore']);

  final String name;
  final String url;
  final int sourceType;
  final String group;
  final String searchUrl;
  final String exploreUrl;
  final String header;
  final String jsLib;
  final Map<String, String> ruleSearch;
  final Map<String, String> ruleBookInfo;
  final Map<String, String> ruleToc;
  final Map<String, String> ruleContent;
  final Map<String, String> ruleExplore;

  List<({String id, String title, String url})> get exploreEntries {
    final raw = exploreUrl.trim();
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return [
          for (final entry in decoded)
            if (entry is Map)
              (
                id: '${entry['title'] ?? entry['url'] ?? ''}',
                title: '${entry['title'] ?? ''}',
                url: '${entry['url'] ?? ''}',
              ),
        ].where((e) => e.url.isNotEmpty).toList();
      }
    } catch (_) {}
    return [(id: 'all', title: '全部', url: raw)];
  }
}

String legadoFillUrl(
  String template, {
  String key = '',
  int page = 1,
}) {
  return template
      .replaceAll('{{key}}', Uri.encodeQueryComponent(key))
      .replaceAll('{{page}}', '$page')
      .replaceAll('{{page-1}}', '${page - 1}');
}

String _jsString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  return jsonEncode(value);
}

String _stripJsPrefix(String rule) {
  var code = rule.trim();
  if (code.startsWith('@js:')) return code.substring(4);
  if (code.startsWith('<js>')) {
    code = code.substring(4);
    if (code.endsWith('</js>')) {
      code = code.substring(0, code.length - 5);
    }
  }
  return code;
}

bool _isJsRule(String rule) {
  final trimmed = rule.trim();
  return trimmed.startsWith('@js:') || trimmed.startsWith('<js>');
}

Future<String> legadoEvalJs(
  String rule, {
  required String result,
  required String baseUrl,
  String key = '',
  int page = 1,
  String jsLib = '',
}) async {
  final code = _stripJsPrefix(rule);
  final script = StringBuffer()
    ..writeln('var result = ${jsonEncode(result)};')
    ..writeln('var baseUrl = ${jsonEncode(baseUrl)};')
    ..writeln('var key = ${jsonEncode(key)};')
    ..writeln('var page = $page;')
    ..writeln(
      'var java = {ajax: function(u){ try { return fetch(u); } catch(e) { return ""; } }};',
    )
    ..writeln(
      'var cookie = {setCookie:function(){}, getCookie:function(){return "";}, deleteCookie:function(){}};',
    );
  if (jsLib.trim().isNotEmpty) script.writeln(jsLib);
  script.writeln(code);
  final value = await JsBridge.evalRaw(script.toString());
  return _jsString(value);
}

List<String> _splitAlternatives(String rule) {
  if (_isJsRule(rule)) return [rule];
  return rule.split('||');
}

String _applyRegexParts(String value, List<String> parts) {
  var result = value;
  for (var i = 1; i + 1 < parts.length; i += 2) {
    try {
      final pattern = RegExp(parts[i]);
      final match = pattern.firstMatch(result);
      if (match == null) continue;
      var replaced = parts[i + 1];
      for (var g = 1; g <= match.groupCount; g++) {
        replaced = replaced.replaceAll('\$$g', match.group(g) ?? '');
      }
      result = replaced;
    } catch (_) {}
  }
  return result;
}

List<String> _splitRegexParts(String rule) {
  return rule.split('##');
}

bool _isExtractionToken(String token) {
  const keywords = {
    'text',
    'html',
    'outerHtml',
    'href',
    'src',
    'content',
    'title',
    'alt',
    'value',
  };
  return keywords.contains(token) || token.startsWith('data-');
}

dom.Element? _asElement(dom.Node node) => node is dom.Element ? node : null;

List<dom.Element> _selectAll(dom.Node root, String selector) {
  var base = selector.trim();
  var eqIndex = -1;
  final eqMatch = RegExp(r'^(.*):eq\((\d+)\)$').firstMatch(base);
  if (eqMatch != null) {
    base = eqMatch.group(1)!;
    eqIndex = int.tryParse(eqMatch.group(2)!) ?? -1;
  }
  List<dom.Element> found;
  if (root is dom.Document) {
    found = root.querySelectorAll(base);
  } else if (root is dom.Element) {
    found = root.querySelectorAll(base);
  } else {
    found = const [];
  }
  if (eqIndex >= 0) {
    if (eqIndex < found.length) return [found[eqIndex]];
    return const [];
  }
  return found;
}

String _extractFromNodes(List<dom.Element> nodes, String token) {
  if (nodes.isEmpty) return '';
  if (token == 'text') {
    return nodes.map((e) => e.text.trim()).where((t) => t.isNotEmpty).join('\n');
  }
  if (token == 'html') {
    return nodes.map((e) => e.innerHtml.trim()).join('\n');
  }
  if (token == 'outerHtml') {
    return nodes.map((e) => e.outerHtml.trim()).join('\n');
  }
  return nodes
      .map((e) => (e.attributes[token] ?? '').trim())
      .where((t) => t.isNotEmpty)
      .join('\n');
}

List<String> _chainTokens(String chain) {
  final tokens = <String>[];
  for (final segment in chain.split('&&')) {
    for (final part in segment.split('@')) {
      final token = part.trim();
      if (token.isNotEmpty) tokens.add(token);
    }
  }
  return tokens;
}

List<dom.Element> legadoSelectElements(dom.Node root, String chain) {
  var current = <dom.Node>[root];
  final tokens = _chainTokens(chain);
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (i == tokens.length - 1 && _isExtractionToken(token)) break;
    final next = <dom.Node>[];
    for (final node in current) {
      next.addAll(_selectAll(node, token));
    }
    current = next;
    if (current.isEmpty) break;
  }
  return [for (final node in current) if (_asElement(node) != null) node as dom.Element];
}

List<String> _splitCssAlternatives(String rule) {
  final alternatives = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i + 1 < rule.length; i++) {
    final ch = rule[i];
    if (ch == '(') depth++;
    if (ch == ')' && depth > 0) depth--;
    if (depth == 0 && ch == '|' && rule[i + 1] == '|') {
      alternatives.add(rule.substring(start, i));
      start = i + 2;
      i++;
    }
  }
  alternatives.add(rule.substring(start));
  return alternatives;
}

String _legadoEvalCssTextOne(dom.Node root, String rule) {
  final parts = _splitRegexParts(rule);
  final chain = parts.first;
  final tokens = _chainTokens(chain);
  final last = tokens.isEmpty ? '' : tokens.last;
  final nodes = legadoSelectElements(root, chain);
  String value;
  if (tokens.isNotEmpty && _isExtractionToken(last)) {
    value = _extractFromNodes(nodes, last);
  } else {
    value = _extractFromNodes(nodes, 'text');
  }
  return _applyRegexParts(value, parts);
}

String legadoEvalCssText(dom.Node root, String rule) {
  for (final alternative in _splitCssAlternatives(rule)) {
    final value = _legadoEvalCssTextOne(root, alternative);
    if (value.isNotEmpty) return value;
  }
  return '';
}

List<dom.Element> legadoEvalCssList(dom.Node root, String rule) {
  for (final alternative in _splitCssAlternatives(rule)) {
    final parts = _splitRegexParts(alternative);
    final nodes = legadoSelectElements(root, parts.first);
    if (nodes.isNotEmpty) return nodes;
  }
  return const [];
}

dynamic _jsonPathWalk(dynamic data, List<String> segments) {
  var current = <dynamic>[data];
  for (final segment in segments) {
    final next = <dynamic>[];
    final bracket = RegExp(r'^([^\[]*)\[(\d+|\*)\]$').firstMatch(segment);
    String key = segment;
    String? indexPart;
    if (bracket != null) {
      key = bracket.group(1)!;
      indexPart = bracket.group(2);
    }
    for (final item in current) {
      dynamic value = item;
      if (key.isNotEmpty) {
        if (value is Map && value.containsKey(key)) {
          value = value[key];
        } else {
          continue;
        }
      }
      if (indexPart != null) {
        if (value is List) {
          if (indexPart == '*') {
            next.addAll(value);
          } else {
            final index = int.tryParse(indexPart) ?? -1;
            if (index >= 0 && index < value.length) next.add(value[index]);
          }
        }
      } else {
        next.add(value);
      }
    }
    current = next;
    if (current.isEmpty) break;
  }
  return current;
}

dynamic legadoEvalJson(dynamic data, String rule) {
  final parts = _splitRegexParts(rule);
  final path = parts.first.trim();
  if (!path.startsWith(r'$.')) return null;
  final segments = path.substring(2).split('.');
  final values = _jsonPathWalk(data, segments) as List<dynamic>;
  if (values.isEmpty) return null;
  if (values.length == 1) return values.first;
  return values;
}

String _jsonValueToString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num || value is bool) return '$value';
  if (value is List) {
    return value.map(_jsonValueToString).where((t) => t.isNotEmpty).join('\n');
  }
  return jsonEncode(value);
}

dynamic legadoJsonSubValue(dynamic item, String rule) {
  var path = rule.trim();
  if (path.startsWith(r'$.')) path = path.substring(2);
  if (path.isEmpty) return item;
  dynamic current = item;
  for (final segment in path.split('.')) {
    if (current is Map && current.containsKey(segment)) {
      current = current[segment];
    } else if (current is List) {
      final index = int.tryParse(segment) ?? -1;
      if (index >= 0 && index < current.length) {
        current = current[index];
      } else {
        return null;
      }
    } else {
      return null;
    }
  }
  return current;
}

class _LegadoDoc {
  _LegadoDoc.html(String body)
      : document = html_parser.parse(body),
        json = null,
        raw = body;

  _LegadoDoc.json(this.json)
      : document = null,
        raw = jsonEncode(json);

  final dom.Document? document;
  final dynamic json;
  final String raw;

  bool get isJson => json != null;
}

class LegadoContentClient implements DramaSiteContentClient {
  LegadoContentClient(
    this.siteId,
    this.source, {
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String siteId;
  final LegadoSource source;
  final http.Client _client;

  Map<String, String> get _headers {
    final raw = source.header.trim();
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries)
              '${entry.key}': '${entry.value}',
          };
        }
      } catch (_) {}
    }
    return const {};
  }

  Map<String, String> get _defaultHeaders => {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
        'Chrome/120.0 Mobile Safari/537.36',
    ..._headers,
  };

  Future<String> _fetch(String url, {String? postBody}) async {
    final uri = Uri.parse(url);
    final response = postBody == null
        ? await _client
            .get(uri, headers: _defaultHeaders)
            .timeout(const Duration(seconds: 20))
        : await _client
            .post(
              uri,
              headers: {
                ..._defaultHeaders,
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: postBody,
            )
            .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return decodeHttpBody(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  String _resolve(String pageUrl, String ref) {
    if (ref.isEmpty) return '';
    return xbpqResolve(pageUrl, ref);
  }

  Future<String> _evalField(
    String rule,
    _LegadoDoc doc,
    String pageUrl, {
    String key = '',
    int page = 1,
  }) async {
    if (rule.trim().isEmpty) return '';
    for (final alternative in _splitAlternatives(rule)) {
      final candidate = alternative.trim();
      if (candidate.isEmpty) continue;
      String value = '';
      if (_isJsRule(candidate)) {
        value = await legadoEvalJs(
          candidate,
          result: doc.raw,
          baseUrl: pageUrl,
          key: key,
          page: page,
          jsLib: source.jsLib,
        );
        if (value.isNotEmpty) return value;
        continue;
      }
      if (doc.isJson) {
        final found = legadoEvalJson(doc.json, candidate);
        value = _applyRegexParts(
          _jsonValueToString(found),
          _splitRegexParts(candidate),
        );
      } else {
        final document = doc.document!;
        value = legadoEvalCssText(document, candidate);
      }
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<List<dynamic>> _evalListField(
    String rule,
    _LegadoDoc doc,
    String pageUrl, {
    String key = '',
    int page = 1,
  }) async {
    if (rule.trim().isEmpty) return const [];
    for (final alternative in _splitAlternatives(rule)) {
      final candidate = alternative.trim();
      if (candidate.isEmpty) continue;
      if (_isJsRule(candidate)) {
        final value = await legadoEvalJs(
          candidate,
          result: doc.raw,
          baseUrl: pageUrl,
          key: key,
          page: page,
          jsLib: source.jsLib,
        );
        if (value.isEmpty) continue;
        try {
          final decoded = jsonDecode(value);
          if (decoded is List) return decoded;
          if (decoded is Map) return [decoded];
        } catch (_) {}
        return [value];
      }
      if (doc.isJson) {
        final found = legadoEvalJson(doc.json, candidate);
        if (found is List && found.isNotEmpty) return found;
        if (found != null) return [found];
        continue;
      }
      final nodes = legadoEvalCssList(doc.document!, candidate);
      if (nodes.isNotEmpty) return nodes;
    }
    return const [];
  }

  _LegadoDoc _docOf(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _LegadoDoc.json(jsonDecode(body));
      } catch (_) {}
    }
    return _LegadoDoc.html(body);
  }

  Future<String> _fieldOnNode(
    String rule,
    dynamic node,
    String pageUrl,
  ) async {
    if (rule.trim().isEmpty) return '';
    for (final alternative in _splitAlternatives(rule)) {
      final candidate = alternative.trim();
      if (candidate.isEmpty) continue;
      if (_isJsRule(candidate)) {
        final result = node is dom.Element
            ? node.outerHtml
            : (node is Map ? jsonEncode(node) : '$node');
        final value = await legadoEvalJs(
          candidate,
          result: result,
          baseUrl: pageUrl,
          jsLib: source.jsLib,
        );
        if (value.isNotEmpty) return value;
        continue;
      }
      String value = '';
      if (node is dom.Element) {
        value = legadoEvalCssText(node, candidate);
      } else if (node is Map) {
        value = _jsonValueToString(legadoJsonSubValue(node, candidate));
        value = _applyRegexParts(value, _splitRegexParts(candidate));
      } else {
        value = '$node';
      }
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final entries = source.exploreEntries;
    if (entries.isEmpty) return [const DramaSiteCategory('all', '全部')];
    return [
      for (final entry in entries)
        DramaSiteCategory(entry.id, entry.title),
    ];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final entries = source.exploreEntries;
    if (entries.isEmpty) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    final entry = entries.firstWhere(
      (e) => e.id == categoryId,
      orElse: () => entries.first,
    );
    final listRule = source.ruleExplore['bookList'] ?? '';
    if (listRule.isEmpty) {
      throw StateError('该书源未给发现列表规则');
    }
    var exploreUrl = entry.url;
    if (_isJsRule(exploreUrl)) {
      exploreUrl = await legadoEvalJs(
        exploreUrl,
        result: '',
        baseUrl: source.url,
        page: page,
        jsLib: source.jsLib,
      );
    } else {
      exploreUrl = legadoFillUrl(exploreUrl, page: page);
    }
    final url = _resolve(source.url, exploreUrl);
    final body = await _fetch(url);
    final doc = _docOf(body);
    final nodes = await _evalListField(listRule, doc, url);
    final items = <DramaSiteItem>[];
    for (final node in nodes) {
      final name = await _fieldOnNode(source.ruleExplore['name'] ?? '', node, url);
      final bookUrl = await _fieldOnNode(
        source.ruleExplore['bookUrl'] ?? '',
        node,
        url,
      );
      if (bookUrl.isEmpty) continue;
      final author = await _fieldOnNode(
        source.ruleExplore['author'] ?? '',
        node,
        url,
      );
      final cover = await _fieldOnNode(
        source.ruleExplore['coverUrl'] ?? '',
        node,
        url,
      );
      items.add(
        DramaSiteItem(
          id: _resolve(url, bookUrl),
          title: name,
          cover: _resolve(url, cover),
          remark: author,
        ),
      );
    }
    return DramaSiteCatalogPage(items: items, hasMore: items.isNotEmpty);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    var searchUrl = source.searchUrl.trim();
    if (searchUrl.isEmpty) {
      throw StateError('该书源未给搜索地址');
    }
    String? postBody;
    final postCut = searchUrl.indexOf(',{');
    if (postCut >= 0) {
      try {
        final suffix = jsonDecode(searchUrl.substring(postCut + 1));
        if (suffix is Map && '${suffix['method'] ?? ''}'.toUpperCase() == 'POST') {
          postBody = '${suffix['body'] ?? ''}';
          searchUrl = searchUrl.substring(0, postCut);
        }
      } catch (_) {}
    }
    if (_isJsRule(searchUrl)) {
      searchUrl = await legadoEvalJs(
        searchUrl,
        result: '',
        baseUrl: source.url,
        key: query,
        page: 1,
        jsLib: source.jsLib,
      );
    } else {
      searchUrl = legadoFillUrl(searchUrl, key: query, page: 1);
      if (postBody != null) {
        postBody = legadoFillUrl(postBody, key: query, page: 1);
      }
    }
    final url = _resolve(source.url, searchUrl);
    final body = await _fetch(url, postBody: postBody);
    final doc = _docOf(body);
    final listRule = source.ruleSearch['bookList'] ?? '';
    if (listRule.isEmpty) {
      throw StateError('该书源未给搜索列表规则');
    }
    final nodes = await _evalListField(listRule, doc, url, key: query);
    final items = <DramaSiteItem>[];
    for (final node in nodes) {
      final name = await _fieldOnNode(source.ruleSearch['name'] ?? '', node, url);
      final bookUrl = await _fieldOnNode(
        source.ruleSearch['bookUrl'] ?? '',
        node,
        url,
      );
      if (bookUrl.isEmpty) continue;
      final author = await _fieldOnNode(
        source.ruleSearch['author'] ?? '',
        node,
        url,
      );
      final cover = await _fieldOnNode(
        source.ruleSearch['coverUrl'] ?? '',
        node,
        url,
      );
      items.add(
        DramaSiteItem(
          id: _resolve(url, bookUrl),
          title: name,
          cover: _resolve(url, cover),
          remark: author,
        ),
      );
    }
    return items;
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final bookBody = await _fetch(seriesId);
    final bookDoc = _docOf(bookBody);
    var title = await _evalField(
      source.ruleBookInfo['name'] ?? '',
      bookDoc,
      seriesId,
    );
    var cover = await _evalField(
      source.ruleBookInfo['coverUrl'] ?? '',
      bookDoc,
      seriesId,
    );
    if (title.isEmpty) {
      final titleMatch = RegExp(
        r'<title[^>]*>(.*?)</title>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(bookBody);
      if (titleMatch != null) title = xbpqStripTags(titleMatch.group(1) ?? '');
    }
    if (cover.isEmpty) {
      final coverMatch = RegExp(
        r'''<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(bookBody);
      if (coverMatch != null) cover = _resolve(seriesId, coverMatch.group(1)!);
    } else {
      cover = _resolve(seriesId, cover);
    }
    var tocUrl = await _evalField(
      source.ruleBookInfo['tocUrl'] ?? '',
      bookDoc,
      seriesId,
    );
    if (tocUrl.isEmpty) tocUrl = seriesId;
    tocUrl = _resolve(seriesId, tocUrl);
    final episodes = <DramaSiteEpisode>[];
    final seenToc = <String>{};
    var tocPage = tocUrl;
    for (var round = 0; round < 5; round++) {
      if (tocPage.isEmpty || seenToc.contains(tocPage)) break;
      seenToc.add(tocPage);
      final tocBody = await _fetch(tocPage);
      final tocDoc = _docOf(tocBody);
      final listRule = source.ruleToc['chapterList'] ?? '';
      if (listRule.isEmpty) break;
      final nodes = await _evalListField(listRule, tocDoc, tocPage);
      for (final node in nodes) {
        final chapterName = await _fieldOnNode(
          source.ruleToc['chapterName'] ?? '',
          node,
          tocPage,
        );
        final chapterUrl = await _fieldOnNode(
          source.ruleToc['chapterUrl'] ?? '',
          node,
          tocPage,
        );
        if (chapterUrl.isEmpty) continue;
        episodes.add(
          DramaSiteEpisode(
            videoId: _resolve(tocPage, chapterUrl),
            title: chapterName.isEmpty ? '正文' : chapterName,
          ),
        );
      }
      final next = await _evalField(
        source.ruleToc['nextTocUrl'] ?? '',
        tocDoc,
        tocPage,
      );
      if (next.isEmpty) break;
      final resolved = _resolve(tocPage, next);
      if (resolved == tocPage) break;
      tocPage = resolved;
    }
    if (episodes.isEmpty) {
      throw StateError('该书目录为空或目录规则不匹配');
    }
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: episodes,
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final contentRule = source.ruleContent['content'] ?? '';
    if (contentRule.isEmpty) {
      throw StateError('该书源未给正文规则');
    }
    final parts = <String>[];
    final seen = <String>{};
    var pageUrl = episode.videoId;
    for (var round = 0; round < 5; round++) {
      if (pageUrl.isEmpty || seen.contains(pageUrl)) break;
      seen.add(pageUrl);
      final body = await _fetch(pageUrl);
      final doc = _docOf(body);
      final content = await _evalField(contentRule, doc, pageUrl);
      if (content.isNotEmpty) parts.add(content);
      final next = await _evalField(
        source.ruleContent['nextContentUrl'] ?? '',
        doc,
        pageUrl,
      );
      if (next.isEmpty) break;
      final resolved = _resolve(pageUrl, next);
      if (resolved == pageUrl || !resolved.contains('/')) break;
      pageUrl = resolved;
    }
    final text = parts.join('\n').trim();
    if (text.isEmpty) {
      throw StateError('该章节正文为空或正文规则不匹配');
    }
    final httpLines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('http'))
        .toList();
    switch (source.sourceType) {
      case 3:
        throw StateError('该源只提供下载，不支持在线阅读');
      case 1:
        if (httpLines.isEmpty) throw StateError('该章节音频地址为空');
        return DramaPlaySource(url: httpLines.first);
      case 2:
        if (httpLines.isEmpty) throw StateError('该章节图片地址为空');
        return DramaPlaySource(url: 'pics://${httpLines.join('&&')}');
      case 4:
        if (httpLines.isEmpty) throw StateError('该章节视频地址为空');
        return DramaPlaySource(url: httpLines.first);
      default:
        return DramaPlaySource(
          url:
              'novel://${jsonEncode({'title': episode.title, 'content': text})}',
        );
    }
  }
}
