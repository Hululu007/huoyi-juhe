/// 通用站点爬取（2026-11-21 用户令「不管什么站点都可以爬取」）：
/// 只认页面上真实存在的结构，不认站点名、不按站点写死选择器。
///
/// 三层：
/// 1. 侦察 [GenericSiteCrawler.probe]：抓起始页 → 判盾 → 探 MacCMS 采集
///    接口 → 探 HTML 卡片簇与分页规律，产出一份 [GenericCrawlPlan]。
/// 2. 列表 [GenericSiteCrawler.fetchPage]：按计划逐页取，解析成
///    [GenericCrawlCard]（标题/封面/详情地址/番号全部来自实爬页面）。
/// 3. 详情 [GenericSiteCrawler.fetchDetail]：抽女优名、番号、封面、简介、
///    直链与播放页地址（多路启发式，认不到就留空，绝不编假值）。
///
/// 认不出的情形一律抛 [GenericCrawlFailure] 并给一句人话原因：盾/验证页、
/// 没有列表卡片、页面是纯脚本渲染。绝不返回空数据冒充成功。
library;

import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'actress_adapter_http.dart';
import 'actress_crosssite_probe.dart';

/// 通用爬取失败：面向用户的中文原因，调用方直接展示。
class GenericCrawlFailure implements Exception {
  const GenericCrawlFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 列表里的一张卡：全部字段来自实爬页面，取不到就空着。
class GenericCrawlCard {
  const GenericCrawlCard({
    required this.url,
    required this.title,
    this.cover = '',
    this.code = '',
    this.actor = '',
    this.playUrl = '',
    this.pubdate = '',
    this.description = '',
  });

  /// 详情页绝对地址（卡片身份）。
  final String url;
  final String title;
  final String cover;
  final String code;
  final String actor;

  /// MacCMS 采集接口直接给的可播地址；HTML 列表页为空，等详情补。
  final String playUrl;
  final String pubdate;
  final String description;
}

/// 详情页抽出来的东西：认不到的字段留空，不编。
class GenericCrawlDetail {
  const GenericCrawlDetail({
    required this.title,
    this.actor = '',
    this.code = '',
    this.cover = '',
    this.description = '',
    this.mediaUrl = '',
    this.playPageUrl = '',
  });

  final String title;
  final String actor;
  final String code;
  final String cover;
  final String description;

  /// 直链（m3u8/mp4），没有就空。
  final String mediaUrl;

  /// 播放页地址（iframe/播放按钮），没有就空。
  final String playPageUrl;
}

/// 侦察结果：一次爬取的全部依据。
class GenericCrawlPlan {
  const GenericCrawlPlan({
    required this.base,
    required this.siteId,
    required this.startUrl,
    required this.kind,
    required this.note,
    this.pageTemplate = '',
    this.pageStart = 1,
    this.sampleCards = const <GenericCrawlCard>[],
  });

  /// scheme://host（不含路径）。
  final String base;

  /// 库内站点标识：`custom_<host slug>`，同一站点多次爬取落同一身份。
  final String siteId;

  /// 用户输入归一化后的起始地址。
  final String startUrl;

  /// 结构类型：`maccms`（采集接口）/ `html`（页面卡片）。
  final String kind;

  /// 给人看的一句侦察结论。
  final String note;

  /// 分页模板（含 {page}）；空表示没探到翻页规律，只爬起始页。
  final String pageTemplate;

  /// 模板里的首页页码（起始地址本身就是第 1 页时为 1）。
  final int pageStart;

  /// 侦察时取到的样本卡片（首页/分类页那一批）。
  final List<GenericCrawlCard> sampleCards;

  bool get hasPagination => pageTemplate.isNotEmpty;

  /// 第 [page] 页地址：首页用起始地址，其余按模板替换。
  String urlForPage(int page) {
    if (page <= pageStart) return startUrl;
    if (!hasPagination) return startUrl;
    return pageTemplate.replaceAll('{page}', '$page');
  }
}

/// 站点标识：host 归一化（去 www、点换下划线），固定前缀 custom_。
String genericSiteIdFor(String base) {
  var host = Uri.tryParse(base)?.host ?? base;
  host = host.toLowerCase();
  if (host.startsWith('www.')) host = host.substring(4);
  final slug = host.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  if (slug.isEmpty) return 'custom_site';
  return 'custom_$slug';
}

const _genericDeadSuffixes = <String>[
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.css',
  '.js',
  '.apk',
  '.zip',
  '.rar',
  '.7z',
  '.mp4',
  '.m3u8',
  '.ico',
  '.svg',
  '.woff',
  '.woff2',
  '.ttf',
];

/// 导航/动作类锚文本：不当卡片标题。
const _genericNavWords = <String>{
  '首页',
  '主页',
  '登录',
  '注册',
  '更多',
  '查看更多',
  '下一页',
  '上一页',
  '末页',
  '尾页',
  '详情',
  '播放',
  '收藏',
  '下载',
  '搜索',
  '评论',
  '分类',
  '标签',
  '排行',
  '会员',
  'home',
  'login',
  'register',
  'more',
  'next',
  'prev',
  'previous',
  'play',
  'detail',
  'download',
  'search',
  'category',
  'tag',
};

/// 分类/标签/片商词：这些长得像名字，但不是演员名（实测 javdb、javbus
/// 的标签链接会被误抽成演员）。
const _tagNoiseWords = <String>[
  '有碼',
  '無碼',
  '有码',
  '无码',
  '歐美',
  '欧美',
  '推薦',
  '推荐',
  '高清',
  '字幕',
  '中字',
  '破解',
  '合集',
  '新作',
  '單體',
  '单体',
  '標籤',
  '标签',
  '類別',
  '类别',
  '論壇',
  '论坛',
  'genre',
  'maker',
  'studio',
  'label',
  'series',
  'vr',
  'english',
  'subtitle',
  'chinese',
  'uncensored',
  'censored',
  'leak',
  'collection',
  'streaming',
  'download',
];

/// 导航/站点功能词：演员名里出现这些就不是人名。
const _actorNoiseWords = <String>[
  'ranking',
  'vip',
  'collection',
  'playlist',
  'history',
  'update',
  'release',
  'watch',
  'login',
  'sign',
  'register',
  'list',
  'genres',
  'makers',
  'saved',
  'my ',
  'home',
  'search',
  '会员',
  '排行',
  '登录',
  '注册',
  '更新',
  '新作',
  '首页',
  '分类',
  '标签',
  '更多',
  '收藏',
  '历史',
];

int _spaceCount(String text) => ' '.allMatches(text).length;

bool _isNavTitle(String text) {
  final trimmed = text.trim();
  if (trimmed.length < 2) return true;
  return _genericNavWords.contains(trimmed.toLowerCase());
}

String _cleanText(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  return raw
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 图片真实地址：懒加载属性优先（列表页 src 多为占位图）。
String _imageSrc(Element img) {
  for (final key in const [
    'data-src',
    'data-original',
    'data-lazy-src',
    'data-lazy',
    'data-echo',
    'data-url',
    'data-img',
    'src',
  ]) {
    final value = img.attributes[key]?.trim() ?? '';
    if (value.isEmpty) continue;
    if (value.startsWith('data:')) continue;
    return value;
  }
  final srcset = img.attributes['srcset'] ?? img.attributes['data-srcset'] ?? '';
  if (srcset.trim().isNotEmpty) {
    final first = srcset.split(',').first.trim().split(' ').first.trim();
    if (first.isNotEmpty) return first;
  }
  return '';
}

/// 路径形状：把变化段抹成 `*`，用于聚类同一类详情链接
/// （`/videos/ssis-123` 与 `/videos/abw-456` → `/videos/*`）。
String _pathShape(String path) {
  final parts = path.split('/');
  final shaped = <String>[];
  for (final part in parts) {
    if (part.isEmpty) {
      shaped.add(part);
      continue;
    }
    if (RegExp(r'\d').hasMatch(part)) {
      // 数字型段：作品详情页的典型形状（ssis-123 / 1pondo-102726 / 4610）。
      shaped.add('*n');
    } else if (part.length >= 16) {
      // 长纯字母段：分类 slug（english-subtitle），与作品分开成簇。
      shaped.add('*a');
    } else {
      shaped.add(part);
    }
  }
  return shaped.join('/');
}

class _CardDraft {
  _CardDraft(this.url);

  final String url;
  String title = '';
  String cover = '';
  String hint = '';

  /// 更好的标题覆盖较差的：卡片常有多个锚点指向同一地址，短的那个
  /// 往往只有番号（missav 的 alt="nghj-073"），长的才是完整标题。
  void _maybeUpgradeTitle(String candidate) {
    final text = _cleanText(candidate);
    if (text.isEmpty || _isNavTitle(text)) return;
    if (title.isEmpty) {
      title = text;
      return;
    }
    if (text.length > title.length + 6) title = text;
  }

  void absorb(Element anchor) {
    // 有些站把标题放在锚点自己的 alt 上（missav 这类：alt="nghj-073"），
    // 非标准属性但真实存在，认它。
    final anchorAlt = _cleanText(anchor.attributes['alt']);
    if (anchorAlt.isNotEmpty && !_isNavTitle(anchorAlt) && anchorAlt.length > 4) {
      _maybeUpgradeTitle(anchorAlt);
    }
    final attrTitle = _cleanText(anchor.attributes['title']);
    if (attrTitle.isNotEmpty) _maybeUpgradeTitle(attrTitle);
    final img = anchor.querySelector('img');
    if (img != null) {
      if (cover.isEmpty) cover = _imageSrc(img);
      final alt = _cleanText(img.attributes['alt']);
      if (alt.isNotEmpty) _maybeUpgradeTitle(alt);
      if (hint.isEmpty) hint = alt;
    }
    final text = _cleanText(anchor.text);
    if (text.isNotEmpty && !_isNavTitle(text) && text.length <= 200) {
      _maybeUpgradeTitle(text);
    }
    // 卡片元数据常在锚点外面（父级 li/.card 的标题/番号）：往上找三层。
    if (title.isEmpty || hint.isEmpty) {
      Element? node = anchor.parent;
      var level = 0;
      while (node != null && level < 3) {
        final element = node;
        final heading = element.querySelector('h1,h2,h3,h4,h5');
        if (heading != null) {
          final text = _cleanText(heading.text);
          if (text.isNotEmpty && !_isNavTitle(text)) {
            if (title.isEmpty) title = text;
            if (hint.isEmpty) hint = text;
          }
        }
        if (hint.isEmpty) {
          final alt = _cleanText(element.querySelector('img')?.attributes['alt']);
          if (alt.isNotEmpty) hint = alt;
        }
        node = element.parent;
        level++;
      }
    }
  }
}

/// 卡片解析：同站带图/带文字的链接按地址聚成组，再按路径形状聚类，
/// 取最大的那一簇当作品列表。认不出（最大簇不足 3 张）返回空。
List<GenericCrawlCard> parseGenericCards(String html, Uri pageUri) {
  if (html.trim().isEmpty) return const <GenericCrawlCard>[];
  final doc = html_parser.parse(html);
  final groups = <String, _CardDraft>{};
  final order = <String>[];
  for (final anchor in doc.querySelectorAll('a[href]')) {
    final href = anchor.attributes['href']?.trim() ?? '';
    if (href.isEmpty) continue;
    final lower = href.toLowerCase();
    if (lower.startsWith('#') ||
        lower.startsWith('javascript:') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('tel:')) {
      continue;
    }
    final resolved = pageUri.resolveUri(Uri.tryParse(href) ?? Uri());
    if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
    if (resolved.host != pageUri.host) continue;
    final path = resolved.path;
    if (path.isEmpty || path == '/') continue;
    if (_genericDeadSuffixes.any((s) => path.toLowerCase().endsWith(s))) {
      continue;
    }
    final url = resolved.removeFragment().toString();
    final draft = groups.putIfAbsent(url, () {
      order.add(url);
      return _CardDraft(url);
    });
    draft.absorb(anchor);
  }
  if (groups.isEmpty) return const <GenericCrawlCard>[];

  // 按路径形状聚类：同一类详情链接的卡片才算作品列表。
  final byShape = <String, List<String>>{};
  for (final url in order) {
    final path = Uri.parse(url).path;
    byShape.putIfAbsent(_pathShape(path), () => <String>[]).add(url);
  }
  // 簇评分：数量打底，带封面的卡片更重（作品卡片几乎都有封面，
  // 导航/分类链接通常没有），避免把分类聚合页当作品列表。
  var bestShape = '';
  var bestScore = 0;
  var bestCount = 0;
  for (final entry in byShape.entries) {
    var withCover = 0;
    for (final url in entry.value) {
      if (groups[url]!.cover.isNotEmpty) withCover++;
    }
    final score = entry.value.length + withCover * 2;
    if (score > bestScore) {
      bestScore = score;
      bestShape = entry.key;
      bestCount = entry.value.length;
    }
  }
  if (bestCount < 3) return const <GenericCrawlCard>[];
  final shapeUrls = byShape[bestShape] ?? const <String>[];
  // 同一形状里「带封面」的才是作品卡：分类入口（10musume、naughty4610）
  // 也会落在 *n 形状里，但它们没有封面。够三张就只留带封面的。
  final withCover = [
    for (final url in shapeUrls)
      if (groups[url]!.cover.isNotEmpty) url,
  ];
  final urls = withCover.length >= 3 ? withCover : shapeUrls;

  final out = <GenericCrawlCard>[];
  final seen = <String>{};
  for (final url in urls) {
    final draft = groups[url]!;
    final title = draft.title.isNotEmpty ? draft.title : draft.hint;
    if (title.isEmpty || _isNavTitle(title)) continue;
    if (!seen.add(title)) continue;
    final cover = _absoluteUrl(draft.cover, pageUri);
    final code = extractAvId(title: title, id: Uri.parse(url).path) ?? '';
    // 没封面、没番号、标题又只有两三个字的，是导航/分类入口，不是作品。
    if (cover.isEmpty && code.isEmpty && title.length <= 6) continue;
    out.add(
      GenericCrawlCard(url: url, title: title, cover: cover, code: code),
    );
  }
  return out;
}

String _absoluteUrl(String raw, Uri pageUri) {
  if (raw.isEmpty) return '';
  final uri = Uri.tryParse(raw);
  if (uri == null) return '';
  if (uri.scheme == 'http' || uri.scheme == 'https') return raw;
  try {
    return pageUri.resolveUri(uri).toString();
  } catch (_) {
    return '';
  }
}

String? _resolveSameHost(String? href, Uri pageUri) {
  if (href == null || href.trim().isEmpty) return null;
  final uri = Uri.tryParse(href.trim());
  if (uri == null) return null;
  final resolved = pageUri.resolveUri(uri);
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  if (resolved.host != pageUri.host) return null;
  return resolved.toString();
}

/// URL 里的页码与模板：`?page=2`、`/page/2`、`/page-2`、`/2.html` 都认。
(int, String)? _pageNumberAndTemplate(String url) {
  const patterns = <String>[
    r'([?&](?:page|p|pg)=)(\d+)',
    r'(/page/)(\d+)',
    r'(/page-)(\d+)',
    r'(/)(\d+)(\.html)$',
  ];
  for (var i = 0; i < patterns.length; i++) {
    final match = RegExp(patterns[i]).firstMatch(url);
    if (match == null) continue;
    final page = int.tryParse(match.group(2) ?? '');
    if (page == null || page < 1) continue;
    final whole = match.group(0) ?? '';
    final index = url.indexOf(whole);
    if (index < 0) continue;
    final template =
        '${url.substring(0, index)}'
        '${whole.replaceFirst(RegExp(r'\d+(?=\D*$)'), '{page}')}'
        '${url.substring(index + whole.length)}';
    if (!template.contains('{page}')) continue;
    return (page, template);
  }
  return null;
}

/// 分页规律识别：只认页面上真实存在的翻页痕迹，认不出返回 null。
///
/// 顺序：rel=next → 「下一页」文本 → 数字分页链接（页码模板）。
String? detectGenericPageTemplate(String html, Uri pageUri) {
  if (html.trim().isEmpty) return null;
  final doc = html_parser.parse(html);

  for (final node in doc.querySelectorAll('a[rel=next], link[rel=next]')) {
    final href = _resolveSameHost(node.attributes['href'], pageUri);
    final template = href == null ? null : _pageNumberAndTemplate(href)?.$2;
    if (template != null) return template;
  }
  for (final anchor in doc.querySelectorAll('a[href]')) {
    final text = _cleanText(anchor.text).toLowerCase();
    if (text == '下一页' || text == 'next' || text == '›' || text == '»') {
      final href = _resolveSameHost(anchor.attributes['href'], pageUri);
      final template = href == null ? null : _pageNumberAndTemplate(href)?.$2;
      if (template != null) return template;
    }
  }

  // 数字分页：同一主机上出现两个以上不同页码 → 归纳成模板。
  final numbers = <int>{};
  final templates = <String>[];
  for (final anchor in doc.querySelectorAll('a[href]')) {
    final href = _resolveSameHost(anchor.attributes['href'], pageUri);
    if (href == null) continue;
    final parsed = _pageNumberAndTemplate(href);
    if (parsed == null) continue;
    numbers.add(parsed.$1);
    if (!templates.contains(parsed.$2)) templates.add(parsed.$2);
  }
  if (numbers.length >= 2 && templates.isNotEmpty) return templates.first;
  return null;
}

/// 详情页解析：女优名 / 番号 / 封面 / 简介 / 直链 / 播放页，认不到留空。
GenericCrawlDetail parseGenericDetail(String html, Uri pageUri) {
  if (html.trim().isEmpty) return const GenericCrawlDetail(title: '');
  final doc = html_parser.parse(html);

  String meta(String key) {
    for (final node in doc.querySelectorAll('meta')) {
      final name =
          (node.attributes['property'] ??
                  node.attributes['name'] ??
                  node.attributes['itemprop'] ??
                  '')
              .toLowerCase();
      if (name == key) return _cleanText(node.attributes['content']);
    }
    return '';
  }

  var title = '';
  for (final node in doc.querySelectorAll('h1')) {
    final text = _cleanText(node.text);
    if (text.isNotEmpty) {
      title = text;
      break;
    }
  }
  if (title.isEmpty) title = meta('og:title');
  if (title.isEmpty) title = _cleanText(doc.querySelector('title')?.text);

  var cover = meta('og:image');
  if (cover.isEmpty) {
    for (final img in doc.querySelectorAll('img')) {
      final src = _imageSrc(img);
      if (src.isEmpty) continue;
      final lower = src.toLowerCase();
      if (lower.contains('logo') || lower.contains('icon')) continue;
      final absolute = _absoluteUrl(src, pageUri);
      if (absolute.isNotEmpty) {
        cover = absolute;
        break;
      }
    }
  }

  var description = meta('description');
  if (description.isEmpty) description = meta('og:description');
  if (description.isEmpty) {
    for (final node in doc.querySelectorAll(
      '.description, .intro, .summary, .content, #description, #intro, '
      'article p, .detail p',
    )) {
      final text = _cleanText(node.text);
      if (text.length > 20) {
        description = text;
        break;
      }
    }
  }

  return GenericCrawlDetail(
    title: title,
    actor: extractGenericActress(doc),
    code: extractAvId(title: title, id: pageUri.path) ?? '',
    cover: cover,
    description: description,
    mediaUrl: extractGenericMedia(doc),
    playPageUrl: extractGenericPlayPage(doc, pageUri),
  );
}

/// 演员名抽取：四路启发式，只认页面上真有的名字。
///
/// 优先级（实测口径）：
/// 1. 演员页锚点（`/actors/`、`/actress/`、`/star/`、`/model/`…）——
///    最可靠。命中即用它，不再掺关键词行，避免把分类标签混进来。
/// 2. JSON-LD 的 actor/performer name。
/// 3. 关键词行（演员/女優/出演/Actress/Starring…）—— 只在没有演员链接时兜底。
/// 4. meta 里的 actor/performer。
String extractGenericActress(Document doc) {
  final pathNames = <String>[];
  final textNames = <String>[];

  bool accept(String raw, List<String> sink) {
    final text = _cleanText(raw);
    if (text.isEmpty || text.length > 40) return false;
    var added = false;
    for (final part in text.split(RegExp(r'[,，、/|&]'))) {
      final name = part.trim();
      if (name.length < 2 || name.length > 16) continue;
      // 名字里不该有数字（番号、年份、榜单期号都不是人名）。
      if (RegExp(r'\d').hasMatch(name)) continue;
      if (RegExp(r'^[\s./:-]+$').hasMatch(name)) continue;
      // 英文名最多一个空格（Rui Akari），再长就是导航句子。
      if (_spaceCount(name) > 1) continue;
      // 全大写 2-5 位（LUXU、LTX）多半是片商/系列代码，不是人名。
      if (RegExp(r'^[A-Z]{2,5}$').hasMatch(name)) continue;
      final lower = name.toLowerCase();
      if (_genericNavWords.contains(lower)) continue;
      if (_actorNoiseWords.any(lower.contains)) continue;
      if (_tagNoiseWords.any(lower.contains)) continue;
      if (name.contains('更多') || name.contains('全部')) continue;
      if (!sink.contains(name)) {
        sink.add(name);
        added = true;
      }
    }
    return added;
  }

  // 1) 演员页锚点（最可靠）
  const actorSegments = <String>[
    '/actors/',
    '/actress/',
    '/actor/',
    '/stars/',
    '/star/',
    '/models/',
    '/model/',
    '/performers/',
    '/performer/',
    '/idols/',
    '/idol/',
    '/avstar/',
    '/nvyou/',
    '/xinggan/',
  ];
  for (final anchor in doc.querySelectorAll('a[href]')) {
    final href = (anchor.attributes['href'] ?? '').toLowerCase();
    if (href.isEmpty) continue;
    if (!actorSegments.any(href.contains)) continue;
    // 列表页（/actresses、/actors）不是演员，要求路径后面还有一段。
    final segments = Uri.tryParse(href)?.pathSegments ?? const <String>[];
    if (segments.isEmpty) continue;
    accept(anchor.text, pathNames);
  }

  // 2) JSON-LD
  for (final script in doc.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    final raw = script.text;
    if (raw.trim().isEmpty) continue;
    try {
      void visit(Object? node) {
        if (node is Map) {
          for (final entry in node.entries) {
            final key = entry.key.toString().toLowerCase();
            if (key == 'actor' || key == 'actors' || key == 'performer') {
              final value = entry.value;
              if (value is List) {
                for (final item in value) {
                  if (item is Map) accept('${item['name'] ?? ''}', pathNames);
                  if (item is String) accept(item, pathNames);
                }
              } else if (value is Map) {
                accept('${value['name'] ?? ''}', pathNames);
              } else if (value is String) {
                accept(value, pathNames);
              }
            } else {
              visit(entry.value);
            }
          }
        } else if (node is List) {
          for (final item in node) {
            visit(item);
          }
        }
      }

      visit(jsonDecode(raw));
    } catch (_) {
      // JSON-LD 坏了就跳过这一块，不影响其它路。
    }
  }

  // 3) 关键词行（兜底）
  const keywords = <String>[
    '演员',
    '演員',
    '女优',
    '女優',
    '出演',
    '主演',
    'actress',
    'actor',
    'starring',
    'performer',
    'cast',
  ];
  for (final node in doc.querySelectorAll(
    'p, div, span, li, td, dd, dt, h2, h3, strong',
  )) {
    if (node.children.length > 6) continue;
    final text = _cleanText(node.text);
    if (text.isEmpty || text.length > 120) continue;
    final lower = text.toLowerCase();
    for (final keyword in keywords) {
      final index = lower.indexOf(keyword);
      if (index < 0) continue;
      var rest = text.substring(index + keyword.length);
      rest = rest.replaceFirst(RegExp(r'^[\s:：\-—]*'), '');
      // 关键词后面什么都没有（导航菜单里的「Actress」单项）不是字段行，
      // 不能把整块菜单链接当演员名。
      if (rest.isEmpty) break;
      var taken = false;
      for (final anchor in node.querySelectorAll('a[href]')) {
        final anchorText = _cleanText(anchor.text);
        if (anchorText.isEmpty) continue;
        if (!rest.contains(anchorText)) continue;
        accept(anchorText, textNames);
        taken = true;
      }
      if (!taken) {
        accept(rest.length > 60 ? rest.substring(0, 60) : rest, textNames);
      }
      break;
    }
  }

  // 4) meta
  for (final key in const ['actor', 'actress', 'performer', 'video:actor']) {
    for (final node in doc.querySelectorAll('meta')) {
      final name =
          (node.attributes['name'] ?? node.attributes['property'] ?? '')
              .toLowerCase();
      if (name != key) continue;
      accept(node.attributes['content'] ?? '', textNames);
      break;
    }
  }

  final names = pathNames.isNotEmpty ? pathNames : textNames;
  if (names.isEmpty) return '';
  return names.take(8).join(',');
}

/// 直链是否真的是媒体文件：路径以 .m3u8/.mp4 结尾，且不是磁链/中转页
/// （javdb 那种 `keepshare.org/xxx/ed2k%3A%2F%2F...mp4` 是磁链落地页，
/// 不是能播的直链，抽到只会变成「点了播不了」）。
bool _isPlayableMediaUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final lower = url.toLowerCase();
  if (lower.contains('ed2k') || lower.contains('magnet')) return false;
  if (lower.contains('%3a') || lower.contains('%2f')) return false;
  final path = uri.path.toLowerCase();
  return path.endsWith('.m3u8') || path.endsWith('.mp4');
}

/// 直链抽取：video/source 标签优先，其次正文里的 m3u8/mp4 地址。
String extractGenericMedia(Document doc) {
  for (final node in doc.querySelectorAll('video, video source, source')) {
    final src = (node.attributes['src'] ?? '').trim();
    if (_isPlayableMediaUrl(src)) return src;
  }
  final html = doc.outerHtml.replaceAll(r'\/', '/');
  final pattern = RegExp(
    r'''https?://[^\s"'<>\\]+?\.(?:m3u8|mp4)(?:\?[^\s"'<>\\]*)?''',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(html)) {
    final candidate = match.group(0)!;
    if (_isPlayableMediaUrl(candidate)) return candidate;
  }
  return '';
}

/// 播放页地址：详情页里的 iframe 链接（拿不到直链时的落地页）。
String extractGenericPlayPage(Document doc, Uri pageUri) {
  for (final node in doc.querySelectorAll('iframe[src]')) {
    final src = (node.attributes['src'] ?? '').trim();
    if (src.isEmpty) continue;
    final lower = src.toLowerCase();
    if (lower.startsWith('http')) return src;
    if (src.startsWith('//')) return 'https:$src';
    final resolved = _absoluteUrl(src, pageUri);
    if (resolved.isNotEmpty) return resolved;
  }
  return '';
}

/// MacCMS 采集接口响应是不是有效数据（有 list / code=1）。
bool looksLikeMacCmsPayload(String body) {
  final text = body.trim();
  if (text.isEmpty) return false;
  if (!text.startsWith('{') && !text.startsWith('[')) return false;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      if (decoded['list'] is List) return true;
      final code = decoded['code'];
      return code == 1 || code == '1';
    }
    if (decoded is List) return decoded.isNotEmpty;
  } catch (_) {
    return false;
  }
  return false;
}

/// MacCMS 采集响应 → 卡片（自带女优名与播放地址，不用再抓详情）。
List<GenericCrawlCard> parseMacCmsCards(String body, String base) {
  if (!looksLikeMacCmsPayload(body)) return const <GenericCrawlCard>[];
  Object? decoded;
  try {
    decoded = jsonDecode(body.trim());
  } catch (_) {
    return const <GenericCrawlCard>[];
  }
  final rows = <Object?>[];
  if (decoded is Map) {
    final list = decoded['list'];
    if (list is List) rows.addAll(list);
    if (list is Map) rows.addAll(list.values);
  } else if (decoded is List) {
    rows.addAll(decoded);
  }
  final baseUri = Uri.parse(base);
  final out = <GenericCrawlCard>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final name = _cleanText('${row['vod_name'] ?? ''}');
    if (name.isEmpty) continue;
    final id = '${row['vod_id'] ?? ''}';
    final playRaw = '${row['vod_play_url'] ?? ''}';
    var playUrl = '';
    for (final part in playRaw.split('#')) {
      final pieces = part.split(r'$');
      final address = pieces.length > 1 ? pieces.last.trim() : '';
      if (address.startsWith('http')) {
        playUrl = address;
        break;
      }
    }
    out.add(
      GenericCrawlCard(
        url: id.isEmpty ? base : '$base/voddetail/$id.html',
        title: name,
        cover: _absoluteUrl('${row['vod_pic'] ?? ''}', baseUri),
        code: extractAvId(title: name) ?? '',
        actor: _cleanText('${row['vod_actor'] ?? ''}').replaceAll(
          RegExp(r'[,，、]+'),
          ',',
        ),
        playUrl: playUrl,
        pubdate: _cleanText('${row['vod_pubdate'] ?? row['vod_time'] ?? ''}'),
        description: _cleanText(
          '${row['vod_content'] ?? row['vod_blurb'] ?? ''}',
        ),
      ),
    );
  }
  return out;
}

typedef GenericSiteFetch = Future<ContentResponse> Function(String url);

/// 通用站点爬取器：侦察 + 分页取列表 + 取详情。所有网络请求真实发生，
/// 盾/验证页一律抛 [GenericCrawlFailure]，不静默返回空。
class GenericSiteCrawler {
  factory GenericSiteCrawler({GenericSiteFetch? fetch, ContentHttp? http}) =>
      GenericSiteCrawler._(fetch, http ?? ContentHttp());

  GenericSiteCrawler._(this._fetch, this._http);

  final GenericSiteFetch? _fetch;
  final ContentHttp _http;

  static const _timeout = Duration(seconds: 25);

  Future<ContentResponse> _get(String url, {String? referer}) {
    final fetch = _fetch;
    if (fetch != null) return fetch(url);
    return _http.getRaw(
      url,
      headers: <String, String>{
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7',
        if (referer != null && referer.isNotEmpty) 'Referer': referer,
      },
      timeout: _timeout,
    );
  }

  /// 侦察：探 MacCMS 接口 → 抓起始页 → 解析卡片簇与分页规律。
  Future<GenericCrawlPlan> probe(String input) async {
    final startUrl = _normalize(input);
    final uri = Uri.parse(startUrl);
    final base = '${uri.scheme}://${uri.host}';
    final siteId = genericSiteIdFor(base);

    if (await _probeMacCms(base)) {
      final plan = GenericCrawlPlan(
        base: base,
        siteId: siteId,
        startUrl: startUrl,
        kind: 'maccms',
        note: '采集接口可用：按接口逐页取（自带女优名与播放地址）',
      );
      final page = await fetchPage(plan, 1);
      if (page.cards.isEmpty) {
        throw const GenericCrawlFailure('站点采集接口能连上，但没有返回数据。');
      }
      return GenericCrawlPlan(
        base: base,
        siteId: siteId,
        startUrl: startUrl,
        kind: 'maccms',
        note: '采集接口可用：第 1 页 ${page.cards.length} 条，带女优名与播放地址',
        sampleCards: page.cards,
      );
    }

    final response = await _get(startUrl);
    final body = decodeContentBytes(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
    _ensureNotShielded(response, body);

    final cards = parseGenericCards(body, uri);
    if (cards.isEmpty) {
      throw const GenericCrawlFailure(
        '没从这个地址认出作品列表：换一个列表页/分类页地址再试；'
        '如果页面是脚本渲染的，把列表页实际地址贴过来。',
      );
    }
    var template = detectGenericPageTemplate(body, uri);
    var planCards = cards;
    var planStart = startUrl;
    var note = '页面列表可用：第 1 页 ${cards.length} 条';
    if (template == null) {
      // 用户常直接粘首页：首页多半是精选页、没有翻页。这时从导航里
      // 找一个真正的列表页（/new、/latest、/videos 这类），换过去爬。
      final discovered = await _discoverListPage(uri, body);
      if (discovered != null) {
        planStart = discovered.startUrl;
        template = discovered.template;
        planCards = discovered.cards;
        note = '首页是精选页，已自动换到列表页：第 1 页 ${planCards.length} 条';
      }
    }
    note =
        '$note'
        '${template == null ? '，没探到翻页，只爬这一页' : '，已识别翻页规律'}';
    return GenericCrawlPlan(
      base: base,
      siteId: siteId,
      startUrl: planStart,
      kind: 'html',
      note: note,
      pageTemplate: template ?? '',
      sampleCards: planCards,
    );
  }

  /// 从首页导航里找真正的列表页：路径像 new/latest/videos/movie/list 的
  /// 同站链接，逐个试，取第一个「有卡片 + 有翻页规律」的。
  /// 找不到返回 null（此时按当前页只爬一页，不硬猜）。
  Future<
    ({String startUrl, String template, List<GenericCrawlCard> cards})?
  >
  _discoverListPage(Uri pageUri, String html) async {
    final doc = html_parser.parse(html);
    const keywords = <String>[
      'new',
      'latest',
      'update',
      'videos',
      'video',
      'movies',
      'movie',
      'list',
      'recent',
      'rank',
      'hot',
      'all',
    ];
    final candidates = <String>[];
    for (final anchor in doc.querySelectorAll('a[href]')) {
      final href = _resolveSameHost(anchor.attributes['href'], pageUri);
      if (href == null) continue;
      final parsed = Uri.parse(href);
      final segments = parsed.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.isEmpty) continue;
      final tail = segments.last.toLowerCase();
      if (!keywords.contains(tail)) continue;
      if (candidates.contains(href)) continue;
      candidates.add(href);
      if (candidates.length >= 3) break;
    }
    for (final candidate in candidates) {
      try {
        final response = await _get(candidate);
        if (response.statusCode != 200) continue;
        final body = decodeContentBytes(
          response.bodyBytes,
          contentType: response.headers['content-type'],
        );
        if (looksLikeShieldBody(body)) continue;
        final listUri = Uri.parse(candidate);
        final cards = parseGenericCards(body, listUri);
        final template = detectGenericPageTemplate(body, listUri);
        if (cards.length >= 3 && template != null) {
          return (startUrl: candidate, template: template, cards: cards);
        }
      } catch (_) {
        // 这个候选不通就试下一个；都不行就按原页只爬一页。
      }
    }
    return null;
  }

  /// 取第 [page] 页列表：首页直接用侦察时的样本，不重复请求。
  Future<({List<GenericCrawlCard> cards, bool hasNext})> fetchPage(
    GenericCrawlPlan plan,
    int page,
  ) async {
    if (plan.kind == 'maccms') {
      final url =
          '${plan.base}/api.php/provide/vod/?ac=detail&pg=$page&pagesize=24';
      final response = await _get(url);
      final body = decodeContentBytes(
        response.bodyBytes,
        contentType: response.headers['content-type'],
      );
      if (response.statusCode != 200) {
        return (cards: const <GenericCrawlCard>[], hasNext: false);
      }
      final cards = parseMacCmsCards(body, plan.base);
      return (cards: cards, hasNext: cards.isNotEmpty);
    }

    if (page <= plan.pageStart && plan.sampleCards.isNotEmpty) {
      return (cards: plan.sampleCards, hasNext: plan.hasPagination);
    }
    final url = plan.urlForPage(page);
    final response = await _get(url, referer: plan.startUrl);
    final body = decodeContentBytes(
      response.bodyBytes,
      contentType: response.headers['content-type'],
    );
    _ensureNotShielded(response, body);
    if (response.statusCode != 200) {
      return (cards: const <GenericCrawlCard>[], hasNext: false);
    }
    final cards = parseGenericCards(body, Uri.parse(url));
    return (cards: cards, hasNext: cards.isNotEmpty && plan.hasPagination);
  }

  /// 取详情：解析出女优名/番号/封面/简介/直链。失败返回 null（不抛）。
  Future<GenericCrawlDetail?> fetchDetail(String url) async {
    try {
      final response = await _get(url, referer: url);
      if (response.statusCode != 200) return null;
      final body = decodeContentBytes(
        response.bodyBytes,
        contentType: response.headers['content-type'],
      );
      if (looksLikeShieldBody(body)) return null;
      return parseGenericDetail(body, Uri.parse(url));
    } catch (_) {
      return null;
    }
  }

  Future<bool> _probeMacCms(String base) async {
    for (final url in [
      '$base/api.php/provide/vod/?ac=list',
      '$base/api.php/provide/vod/?ac=detail&pg=1',
    ]) {
      try {
        final response = await _get(url);
        if (response.statusCode != 200) continue;
        final body = decodeContentBytes(
          response.bodyBytes,
          contentType: response.headers['content-type'],
        );
        if (looksLikeMacCmsPayload(body) &&
            parseMacCmsCards(body, base).isNotEmpty) {
          return true;
        }
      } catch (_) {
        // 这个入口不通就试下一个，探测失败不影响 HTML 通道。
      }
    }
    return false;
  }

  void _ensureNotShielded(ContentResponse response, String body) {
    final headers = <String, List<String>>{
      for (final entry in response.headers.entries) entry.key: [entry.value],
    };
    final verdict = haikuoShieldCheck(
      status: response.statusCode,
      headers: headers,
      body: body,
    );
    if (verdict.blocked || looksLikeShieldBody(body)) {
      throw const GenericCrawlFailure(
        '该站点要求人机验证（Cloudflare 一类的验证页）：'
        '先在应用里对这条站点过一次验证，再回来爬。',
      );
    }
    if (response.statusCode == 403 || response.statusCode == 503) {
      throw GenericCrawlFailure(
        '站点拒绝了这次请求（HTTP ${response.statusCode}）：'
        '可能需要登录，或者挡了这个网络出口。',
      );
    }
  }

  String _normalize(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      throw const GenericCrawlFailure('先填一个站点地址。');
    }
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        !uri.host.contains('.')) {
      throw const GenericCrawlFailure('地址不完整：要 http(s) 开头的完整网址。');
    }
    return uri.toString();
  }
}

/// 正文是不是验证页（不走响应头也能认）：只认特征词。
bool looksLikeShieldBody(String body) {
  if (body.trim().isEmpty) return false;
  final head = body.length > 16384 ? body.substring(0, 16384) : body;
  final lower = head.toLowerCase();
  const markers = <String>[
    'just a moment',
    'checking your browser',
    'verifying you are human',
    'enable javascript and cookies to continue',
    'cf-browser-verification',
    'cloudflare protection detected',
    '/cdn-cgi/challenge-platform',
    '_cf_chl_opt',
  ];
  return markers.any(lower.contains);
}
