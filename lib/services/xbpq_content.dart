import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'gbk_codec.dart';
import 'drama_sites.dart';

String? _field(Map<String, dynamic> rule, List<String> keys) {
  for (final key in keys) {
    final value = rule[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

List<String> _splitReplacements(String raw) {
  final pattern = RegExp(r'\[替换:([^\]]*)\]');
  final replacements = <String>[];
  var base = raw;
  for (final match in pattern.allMatches(raw)) {
    replacements.add(match.group(1)!);
  }
  base = base.replaceAll(pattern, '');
  return [base, ...replacements];
}

RegExp _anchorPattern(String anchor) {
  final buffer = StringBuffer();
  for (var i = 0; i < anchor.length; i++) {
    final ch = anchor[i];
    if (ch == '*') {
      buffer.write('.*?');
    } else {
      buffer.write(RegExp.escape(ch));
    }
  }
  return RegExp(buffer.toString(), dotAll: true);
}

String _applyReplacements(String value, List<String> replacements) {
  var result = value;
  for (final replacement in replacements) {
    final cut = replacement.lastIndexOf('>>');
    if (cut < 0) continue;
    result = result.replaceAll(
      replacement.substring(0, cut),
      replacement.substring(cut + 2),
    );
  }
  return result;
}

String xbpqExtract(String source, String rule) {
  if (rule.isEmpty) return '';
  final parts = _splitReplacements(rule);
  final base = parts.first;
  final replacements = parts.sublist(1);
  final anchors = base.split('&&');
  if (anchors.length < 2) return '';
  final startMatch = _anchorPattern(anchors.first).firstMatch(source);
  if (startMatch == null) return '';
  final rest = source.substring(startMatch.end);
  final endMatch = _anchorPattern(anchors.last).firstMatch(rest);
  if (endMatch == null) return '';
  final raw = rest.substring(0, endMatch.start);
  return _applyReplacements(raw, replacements).trim();
}

List<String> xbpqExtractBlocks(String source, String rule) {
  final blocks = <String>[];
  if (rule.isEmpty) return blocks;
  final parts = _splitReplacements(rule);
  final anchors = parts.first.split('&&');
  if (anchors.length < 2) return blocks;
  final startPattern = _anchorPattern(anchors.first);
  final endPattern = _anchorPattern(anchors.last);
  var rest = source;
  while (true) {
    final startMatch = startPattern.firstMatch(rest);
    if (startMatch == null) break;
    final afterStart = rest.substring(startMatch.end);
    final endMatch = endPattern.firstMatch(afterStart);
    if (endMatch == null) break;
    final blockEnd = startMatch.end + endMatch.end;
    blocks.add(rest.substring(startMatch.start, blockEnd));
    rest = rest.substring(blockEnd);
  }
  return blocks;
}

String xbpqStripTags(String value) {
  var text = value.replaceAll(RegExp(r'<[^>]*>'), '');
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();
  return text;
}

String xbpqResolve(String base, String ref) {
  if (ref.isEmpty) return '';
  if (ref.startsWith('//')) return 'https:$ref';
  try {
    return Uri.parse(base).resolve(ref).toString();
  } catch (_) {
    return ref;
  }
}

List<DramaSiteCategory> xbpqParseCategories(Map<String, dynamic> rule) {
  final namesRaw = _field(rule, ['分类', 'class_name', 'className']);
  if (namesRaw == null) return [const DramaSiteCategory('all', '全部')];
  if (namesRaw.contains('\$')) {
    final categories = <DramaSiteCategory>[];
    for (final part in namesRaw.split('#')) {
      final cut = part.indexOf('\$');
      if (cut <= 0) continue;
      categories.add(
        DramaSiteCategory(part.substring(cut + 1).trim(), part.substring(0, cut).trim()),
      );
    }
    if (categories.isNotEmpty) return categories;
    return [const DramaSiteCategory('all', '全部')];
  }
  final valuesRaw = _field(rule, ['分类值', 'class_url', 'classUrl']);
  if (valuesRaw != null) {
    final names = namesRaw.split('&');
    final values = valuesRaw.split('&');
    final categories = <DramaSiteCategory>[];
    for (var i = 0; i < names.length && i < values.length; i++) {
      final name = names[i].trim();
      final value = values[i].trim();
      if (name.isEmpty || value.isEmpty) continue;
      categories.add(DramaSiteCategory(value, name));
    }
    if (categories.isNotEmpty) return categories;
  }
  return [const DramaSiteCategory('all', '全部')];
}

String xbpqFillTemplate(
  String template, {
  String cateId = '',
  int page = 1,
  String keyword = '',
  Map<String, String> filters = const {},
}) {
  var out = template
      .replaceAll('{cateId}', cateId)
      .replaceAll('{catePg}', '$page')
      .replaceAll('{pg}', '$page')
      .replaceAll('{wd}', Uri.encodeComponent(keyword));
  for (final entry in filters.entries) {
    out = out.replaceAll('{${entry.key}}', entry.value);
  }
  return out
      .replaceAll('{area}', '')
      .replaceAll('{by}', '')
      .replaceAll('{class}', '')
      .replaceAll('{lang}', '')
      .replaceAll('{letter}', '')
      .replaceAll('{year}', '');
}

class XbpqFilterOption {
  const XbpqFilterOption(this.name, this.value);

  final String name;
  final String value;
}

class XbpqFilterGroup {
  const XbpqFilterGroup(this.key, this.options);

  final String key;
  final List<XbpqFilterOption> options;
}

List<XbpqFilterGroup> xbpqParseFilters(
  Map<String, dynamic> rule,
  String categoryId,
) {
  final raw = rule['筛选'];
  if (raw is! Map) return const [];
  final groupsRaw = raw[categoryId];
  if (groupsRaw is! List) return const [];
  final groups = <XbpqFilterGroup>[];
  for (final group in groupsRaw) {
    if (group is! Map) continue;
    final key = '${group['key'] ?? ''}';
    final values = group['value'];
    if (key.isEmpty || values is! List) continue;
    final options = <XbpqFilterOption>[const XbpqFilterOption('全部', '')];
    for (final option in values) {
      if (option is! Map) continue;
      options.add(
        XbpqFilterOption('${option['n'] ?? ''}', '${option['v'] ?? ''}'),
      );
    }
    if (options.length > 1) groups.add(XbpqFilterGroup(key, options));
  }
  return groups;
}

class XbpqListFields {
  const XbpqListFields({
    required this.array,
    required this.pic,
    required this.name,
    required this.link,
    required this.remark,
  });

  final String array;
  final String pic;
  final String name;
  final String link;
  final String remark;
}

List<DramaSiteItem> xbpqParseList(
  String body,
  XbpqListFields fields,
  String host,
) {
  final items = <DramaSiteItem>[];
  if (fields.array.isEmpty) return items;
  for (final block in xbpqExtractBlocks(body, fields.array)) {
    final link = xbpqResolve(host, xbpqExtract(block, fields.link));
    final name = xbpqStripTags(xbpqExtract(block, fields.name));
    final remark = xbpqStripTags(xbpqExtract(block, fields.remark));
    if (link.isEmpty && name.isEmpty) continue;
    items.add(
      DramaSiteItem(
        id: link.isEmpty ? name : link,
        title: name.isEmpty ? remark : name,
        cover: xbpqResolve(host, xbpqExtract(block, fields.pic)),
        remark: remark,
      ),
    );
  }
  return items;
}

List<DramaSiteEpisode> xbpqParseEpisodes(
  String body,
  String lineArray,
  String lineTitle,
  String playArray,
  String playTitle,
  String playLink,
  String host,
) {
  final episodes = <DramaSiteEpisode>[];
  void addFromBlock(String block, String lineName) {
    if (playArray.isEmpty) return;
    for (final epBlock in xbpqExtractBlocks(block, playArray)) {
      final epName = xbpqStripTags(xbpqExtract(epBlock, playTitle));
      final epLink = xbpqResolve(host, xbpqExtract(epBlock, playLink));
      if (epLink.isEmpty) continue;
      episodes.add(
        DramaSiteEpisode(
          videoId: epLink,
          title: lineName == '在线播放' || lineName.isEmpty
              ? (epName.isEmpty ? '正片' : epName)
              : '$lineName-${epName.isEmpty ? '正片' : epName}',
        ),
      );
    }
  }

  if (lineArray.isNotEmpty) {
    for (final block in xbpqExtractBlocks(body, lineArray)) {
      final lineName = xbpqStripTags(xbpqExtract(block, lineTitle));
      addFromBlock(block, lineName.isEmpty ? '在线播放' : lineName);
    }
  } else {
    addFromBlock(body, '在线播放');
  }
  return episodes;
}

class XbpqRule {
  XbpqRule(Map<String, dynamic> raw)
      : raw = raw,
        host = _field(raw, ['主页url', 'host', 'homeUrl']) ?? '',
        homeUrl = _field(raw, ['homeUrl', '主页url']) ?? '',
        categories = xbpqParseCategories(raw),
        cateUrl = _field(raw, ['分类url', 'cateUrl', 'classUrl']) ?? '',
        listFields = XbpqListFields(
          array: _field(raw, ['数组', 'listNode', 'cateNode']) ?? '',
          pic: _field(raw, ['图片', 'listPic', 'catePic']) ?? '',
          name: _field(raw, ['标题', 'listName', 'cateName']) ?? '',
          link: _field(raw, ['链接', 'listLink', 'cateId', 'cateLink']) ?? '',
          remark: _field(raw, ['副标题', 'listMark', 'cateMark']) ?? '',
        ),
        searchMode = _field(raw, ['搜索模式', 'searchMode']) ?? '',
        searchUrl = _field(raw, ['搜索url', 'searchUrl']) ?? '',
        searchPrefix = _field(raw, ['搜索前缀', 'searchPrefix']) ?? '',
        searchSuffix = _field(raw, ['搜索后缀', 'searchSuffix']) ?? '',
        searchFields = XbpqListFields(
          array:
              _field(raw, ['搜索数组', 'searchNode']) ??
              _field(raw, ['数组', 'listNode', 'cateNode']) ??
              '',
          pic:
              _field(raw, ['搜索图片', 'searchPic']) ??
              _field(raw, ['图片', 'listPic', 'catePic']) ??
              '',
          name:
              _field(raw, ['搜索标题', 'searchName']) ??
              _field(raw, ['标题', 'listName', 'cateName']) ??
              '',
          link:
              _field(raw, ['搜索链接', 'searchLink']) ??
              _field(raw, ['链接', 'listLink', 'cateId', 'cateLink']) ??
              '',
          remark:
              _field(raw, ['搜索副标题', 'searchMark']) ??
              _field(raw, ['副标题', 'listMark', 'cateMark']) ??
              '',
        ),
        lineArray = _field(raw, ['线路数组', 'lineNode', 'playFromNode']) ?? '',
        lineTitle = _field(raw, ['线路标题', 'lineTitle', 'playFrom']) ?? '',
        playArray = _field(raw, ['播放数组', 'playNode']) ?? '',
        playTitle = _field(raw, ['播放标题', 'playTitle']) ?? '',
        playLink = _field(raw, ['播放链接', 'playLink', 'playUrl']) ?? '';

  final Map<String, dynamic> raw;
  final String host;
  final String homeUrl;
  final List<DramaSiteCategory> categories;
  final String cateUrl;
  final XbpqListFields listFields;
  final String searchMode;
  final String searchUrl;
  final String searchPrefix;
  final String searchSuffix;
  final XbpqListFields searchFields;
  final String lineArray;
  final String lineTitle;
  final String playArray;
  final String playTitle;
  final String playLink;

  String get base {
    if (host.isNotEmpty) return host;
    if (homeUrl.isNotEmpty) {
      final uri = Uri.tryParse(homeUrl);
      if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
        return '${uri.scheme}://${uri.host}';
      }
    }
    return '';
  }
}

class XbpqContentClient implements DramaSiteContentClient {
  XbpqContentClient(this.siteId, Map<String, dynamic> rule, {http.Client? client})
      : _rule = XbpqRule(rule),
        _client = client ?? http.Client();

  final String siteId;
  final XbpqRule _rule;
  final http.Client _client;

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      'Chrome/120.0 Mobile Safari/537.36';

  Future<String> _fetch(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    return decodeHttpBody(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => _rule.categories;

  List<XbpqFilterGroup> filterGroups(String categoryId) =>
      xbpqParseFilters(_rule.raw, categoryId);

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) =>
      catalogFiltered(categoryId, page, const {});

  Future<DramaSiteCatalogPage> catalogFiltered(
    String categoryId,
    int page,
    Map<String, String> filters,
  ) async {
    String url;
    if (categoryId == 'all') {
      if (_rule.homeUrl.isNotEmpty) {
        url = _rule.homeUrl;
      } else if (_rule.categories.isNotEmpty &&
          _rule.categories.first.id != 'all') {
        if (_rule.cateUrl.isEmpty) {
          throw StateError('该规则未给分类url模板，无法拉分类');
        }
        url = xbpqFillTemplate(
          _rule.cateUrl,
          cateId: _rule.categories.first.id,
          page: page,
          filters: filters,
        );
      } else {
        throw StateError('该规则没有分类与首页地址，无法拉列表');
      }
    } else {
      if (_rule.cateUrl.isEmpty) {
        throw StateError('该规则未给分类url模板，无法拉分类');
      }
      url = xbpqFillTemplate(
        _rule.cateUrl,
        cateId: categoryId,
        page: page,
        filters: filters,
      );
    }
    final body = await _fetch(xbpqResolve(_rule.base, url));
    final items = xbpqParseList(body, _rule.listFields, _rule.base);
    return DramaSiteCatalogPage(items: items, hasMore: items.isNotEmpty);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final body = await _fetch(seriesId);
    final titleMatch = RegExp(
      r'<title[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    var title = titleMatch == null
        ? ''
        : xbpqStripTags(titleMatch.group(1) ?? '');
    for (final suffix in ['在线观看', '免费观看', '高清完整版', '完整版']) {
      if (title.endsWith(suffix) && title.length > suffix.length) {
        title = title.substring(0, title.length - suffix.length).trim();
      }
    }
    final coverMatch = RegExp(
      r'''<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(body);
    final cover = coverMatch == null
        ? ''
        : xbpqResolve(_rule.base, coverMatch.group(1) ?? '');
    final episodes = xbpqParseEpisodes(
      body,
      _rule.lineArray,
      _rule.lineTitle,
      _rule.playArray,
      _rule.playTitle,
      _rule.playLink,
      _rule.base,
    );
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: episodes,
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    String url;
    if (_rule.searchMode == '1' && _rule.searchUrl.isNotEmpty) {
      url = xbpqFillTemplate(_rule.searchUrl, keyword: query, page: 1);
    } else if (_rule.searchPrefix.isNotEmpty ||
        _rule.searchSuffix.isNotEmpty) {
      url = '${_rule.searchPrefix}${Uri.encodeComponent(query)}'
          '${_rule.searchSuffix}';
    } else {
      url = '${_rule.base}/index.php/vod/search/page/1/wd/'
          '${Uri.encodeComponent(query)}.html';
    }
    final body = await _fetch(xbpqResolve(_rule.base, url));
    return xbpqParseList(body, _rule.searchFields, _rule.base);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final link = episode.videoId;
    final lower = link.toLowerCase().split('?').first;
    if (lower.endsWith('.m3u8') || lower.endsWith('.mp4')) {
      return DramaPlaySource(url: link);
    }
    final body = await _fetch(link);
    final direct = MaccmsContentClient.parsePlayerUrl(body);
    if (direct.isNotEmpty && direct.toLowerCase().startsWith('http')) {
      return DramaPlaySource(url: direct);
    }
    throw StateError('该集播放页未取到直链，需要壳解析，当前播放合同只支持直链');
  }
}
