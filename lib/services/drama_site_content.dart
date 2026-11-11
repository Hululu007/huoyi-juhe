import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as dom;

import 'aes_cipher.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'backend_transport.dart';
import 'drama_playback.dart';
import 'drama_sites.dart';
import 'local_media_proxy.dart';
import 'hgtv_content.dart';
import 'huangju_content.dart';
import 'original_site_content.dart';
import 'yeguo_content.dart';

class DramaSiteItem {
  final String id;
  final String title;
  final String cover;
  final String remark;

  const DramaSiteItem({
    required this.id,
    required this.title,
    required this.cover,
    this.remark = '',
  });
}

class DramaSiteEpisode {
  final String videoId;
  final String title;
  final String seriesId;

  const DramaSiteEpisode({
    required this.videoId,
    required this.title,
    this.seriesId = '',
  });
}

class DramaSiteDetail {
  final String id;
  final String title;
  final String cover;
  final String synopsis;

  /// 详情页原字段扩展：通用列之外的站原字段（演员、年份、地区、
  /// 播放线路等），按站原样保留，键就是源字段名。
  final Map<String, String> extra;

  /// 本片剧照（详情页自带）：核心详情 `extra['stills']` 列表、
  /// TVBox 详情 `stills` / `vod_stills` 字段。没有的站为空，
  /// 详情页不画剧照区，不冒充。
  final List<String> stills;
  final List<DramaSiteEpisode> episodes;

  const DramaSiteDetail({
    required this.id,
    required this.title,
    required this.cover,
    this.synopsis = '',
    this.extra = const {},
    this.stills = const [],
    required this.episodes,
  });
}

/// 详情剧照解析（核心 / TVBox 两路共用）：列表原样取；字符串按
/// `$$$` / `#` / 逗号 / 换行拆，只留 http(s) 地址，去重保序。
List<String> parseDetailStills(dynamic value) {
  final raw = <String>[];
  if (value is List) {
    for (final entry in value) {
      raw.add(entry.toString().trim());
    }
  } else if (value is String) {
    raw.addAll(value.split(RegExp(r'\$\$\$|#|,|\n')));
  }
  final seen = <String>{};
  final stills = <String>[];
  for (final url in raw) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) continue;
    if (!trimmed.startsWith('http://') &&
        !trimmed.startsWith('https://')) {
      continue;
    }
    if (seen.add(trimmed)) stills.add(trimmed);
  }
  return stills;
}

class DramaSiteCatalogPage {
  final List<DramaSiteItem> items;
  final bool hasMore;

  /// 该分类页的题材选项（红果 `selectorList`；没有的站为空）。
  final List<HongguoDramaTopic> topics;

  const DramaSiteCatalogPage({
    required this.items,
    required this.hasMore,
    this.topics = const [],
  });
}

/// 蜘蛛本地代理能力：py/jar/js 三个引擎客户端都实现。基类不给默认实现，
/// 因为十多个 implements 客户端都要跟着补方法；不具备的站由调用方
/// （drama_site_play 的 _proxyIfNeeded）如实报错，不静默回空。
/// 入参是待播地址的完整 URI（查询参数即蜘蛛 localProxy 的 param）。
abstract interface class LocalProxyCapable {
  Future<LocalProxyResponse?> localProxy(Uri uri);
}

abstract class DramaSiteContentClient {
  Future<List<DramaSiteCategory>> categories();
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page);
  Future<DramaSiteDetail> detail(String seriesId);
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode);

  /// 全局搜索：各站按自家搜索接口实现，未实现的站返回空，
  /// 搜索页只展示有结果的站，不把未实现当成失败。
  Future<List<DramaSiteItem>> search(String query) async => const [];
}

/// 按名在站分类表里找分类 id：先精确匹配 `name` / `displayName`，
/// 再匹配多级分类展示路径的末段（如 `电影/动作` 认标签 `动作`）。
/// 找不到回 null（调用方退到站源搜索，不出空白页）。
String? findSiteCategoryIdIn(List<DramaSiteCategory> categories, String name) {
  final wanted = name.trim();
  if (wanted.isEmpty) return null;
  for (final category in categories) {
    if (category.name.trim() == wanted ||
        category.displayName.trim() == wanted) {
      return category.id;
    }
  }
  for (final category in categories) {
    final path = category.displayName.trim();
    final last = path.split('/').map((part) => part.trim()).last;
    if (last.isNotEmpty && last == wanted) return category.id;
  }
  return null;
}

/// 按名在站分类里找分类 id（先取一次分类表，再按
/// [findSiteCategoryIdIn] 匹配）。相关推荐（[loadSiteRelatedItems]）
/// 与详情页标签点按共用这一个匹配口径。
Future<String?> findSiteCategoryIdForName(
  DramaSiteContentClient client,
  String name,
) async {
  final categories = await client.categories();
  return findSiteCategoryIdIn(categories, name);
}

/// 同站相关推荐（影视区详情页用）：先按详情 `category` / `tags` 里
/// 的名去匹配站分类，拉同分类第一页；取不到（无匹配分类、分类页
/// 为空、请求失败）退两步兜底——①本站首页（`catalog('all', 1)`；
/// jar 站走 homeVideoContent，py / 核心 / JS 站把 'all' 转空串走
/// 首页）；②分类表第一个真实分类（py 站的 'all' 会被转成空串，
/// 空 tid 在个别站（如 mjv011）上拼不出有效地址，只有这一步对
/// py 站也生效）；仍取不到回空列表，详情页不画推荐区。排除本片、
/// 按 id 去重、最多 [maxItems] 条。
///
/// [allowCatalogFallback] 默认 true（影视站老行为，测试钉住）。
/// 阅读站（小说/漫画/听书）的详情 extra 是空 `{}`，本来就没有
/// 分类信号，两步兜底等于在详情页固定多抓两次上游首页/分类，
/// 对“相关”毫无意义还拖慢详情页；阅读站调用方传 false，
/// 同分类取不到直接回空。
Future<List<DramaSiteItem>> loadSiteRelatedItems(
  DramaSiteContentClient client,
  DramaSiteDetail detail,
  String selfId, {
  int maxItems = 10,
  bool allowCatalogFallback = true,
}) async {
  List<DramaSiteItem> pick(List<DramaSiteItem> items) {
    final seen = <String>{};
    final out = <DramaSiteItem>[];
    for (final item in items) {
      if (item.id == selfId) continue;
      if (item.title.isEmpty) continue;
      if (!seen.add(item.id)) continue;
      out.add(item);
      if (out.length >= maxItems) break;
    }
    return out;
  }

  // 同分类：详情分类 / 标签里的名去匹配站分类 id。
  try {
    final names = <String>{};
    for (final key in const ['category', 'tags']) {
      final raw = detail.extra[key] ?? '';
      for (final part in raw.split(RegExp(r'[,，、/｜|]+'))) {
        final name = part.trim();
        if (name.isNotEmpty) names.add(name);
      }
    }
    if (names.isNotEmpty) {
      final categories = await client.categories();
      String? categoryId;
      for (final name in names) {
        categoryId = findSiteCategoryIdIn(categories, name);
        if (categoryId != null) break;
      }
      if (categoryId != null && categoryId.isNotEmpty) {
        final page = await client.catalog(categoryId, 1);
        final related = pick(page.items);
        if (related.isNotEmpty) return related;
      }
    }
  } catch (_) {
    // 同分类取不到就退首页，不把失败当结果。
  }
  if (!allowCatalogFallback) return const <DramaSiteItem>[];
  // 兜底一：本站首页。jar 站走 homeVideoContent；py / 核心 / JS 站
  // 把 'all' 转成空串走首页。
  try {
    final page = await client.catalog('all', 1);
    final related = pick(page.items);
    if (related.isNotEmpty) return related;
  } catch (_) {
    // 首页拉不到就退分类表第一项。
  }
  // 兜底二：分类表第一个真实分类（跳过 'all' 伪分类，它与兜底一
  // 是同一路）。空 tid 在个别站上拼不出有效地址，首页兜底回空时
  // 只有这一步能出东西。
  try {
    final categories = await client.categories();
    for (final category in categories) {
      if (category.id.isEmpty || category.id == 'all') continue;
      final page = await client.catalog(category.id, 1);
      return pick(page.items);
    }
  } catch (_) {
    // 取不到就回空，详情页不画推荐区。
  }
  return const <DramaSiteItem>[];
}

String _unescape(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .trim();
}

String _firstGroup(RegExp pattern, String input) {
  final match = pattern.firstMatch(input);
  if (match == null || match.groupCount < 1) return '';
  return _unescape(match.group(1) ?? '');
}

Map<String, dynamic>? _extractRouterData(String body) {
  final marker = body.indexOf('_ROUTER_DATA');
  if (marker < 0) return null;
  final start = body.indexOf('{', marker);
  if (start < 0) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < body.length; i++) {
    final ch = body[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch == '\\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
    } else if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        try {
          final decoded = jsonDecode(body.substring(start, i + 1));
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          return null;
        }
        return null;
      }
    }
  }
  return null;
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return const {};
}

String _stringOf(dynamic value) {
  if (value == null) return '';
  return value.toString().trim();
}

/// 黄豆 HLS 密钥校验：站方返回的密钥是 32 位十六进制（16 字节 AES 密钥）。
/// 注意不能用 int.tryParse 做十六进制校验：32 位十六进制是 128 位整数，
/// 远超 Dart int（64 位）范围，合法密钥也会解析失败返回 null，导致
/// 每个带密钥的正片都被误判为“无效的 HLS 密钥”。改用正则按字符校验。
String huangdouHlsKeyHex(String rawKey) {
  if (rawKey.isEmpty) return '';
  if (rawKey.length != 32 ||
      !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(rawKey)) {
    throw StateError('黄豆返回了无效的 HLS 密钥');
  }
  return rawKey;
}

/// 红果镜像：与红果共用 hongguoduanju.com 网页端，分类与卡片取自
/// 分类页，详情取自详情页的 router 数据，播放走备用接口加 360p 直链，
/// 再以原始播放流程的播放源形状交回播放页，不另起播放器。
class HgtvMirrorContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://hongguoduanju.com';

  final http.Client _client;

  HgtvMirrorContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static const fallbackCategories = [
    DramaSiteCategory('real-drama', '真人剧'),
    DramaSiteCategory('comic-drama', '漫剧'),
    DramaSiteCategory('ai-drama', 'AI剧'),
  ];

  static List<DramaSiteCategory> parseCategories(String body) {
    final pattern = RegExp(
      r'href="/category/([a-z0-9\-/]+)"[^>]*class="[^"]*pc-content-type[^"]*">\s*<span[^>]*>([^<]+)</span>',
    );
    final seen = <String>{};
    final categories = <DramaSiteCategory>[];
    for (final match in pattern.allMatches(body)) {
      final id = (match.group(1) ?? '').trim().replaceAll(RegExp(r'^/+|/+$'), '');
      final name = _unescape(match.group(2) ?? '');
      if (id.isEmpty || name.isEmpty || seen.contains(id) || id == 'comic') {
        continue;
      }
      seen.add(id);
      categories.add(DramaSiteCategory(id, name));
    }
    return categories.isEmpty ? fallbackCategories : categories;
  }

  static List<DramaSiteItem> parseCards(String body) {
    final linkPattern = RegExp(
      r'<a[^>]*href="/detail\?series_id=(\d+)"[^>]*>(.*?)</a>',
      dotAll: true,
    );
    final titlePattern = RegExp(
      r'<p[^>]*class="[^"]*pc-title-[^"]*"[^>]*>([^<]+)</p>',
    );
    final coverPattern = RegExp(r'<img[^>]*src="([^"]+)"');
    final srcSetPattern = RegExp(r'<source[^>]*srcSet="([^" ]+)"');
    final altPattern = RegExp(r'<img[^>]*alt="([^"]+)"');
    final episodePattern = RegExp(
      r'<p[^>]*class="[^"]*pc-episode-[^"]*"[^>]*>([^<]+)</p>',
    );
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final match in linkPattern.allMatches(body)) {
      final id = match.group(1) ?? '';
      final block = match.group(2) ?? '';
      if (id.isEmpty || seen.contains(id)) continue;
      var title = _firstGroup(titlePattern, block);
      if (title.isEmpty) {
        title = _unescape(_firstGroup(altPattern, block))
            .replaceAll(RegExp(r'封面$'), '')
            .trim();
      }
      if (title.isEmpty) continue;
      var cover = _firstGroup(coverPattern, block);
      if (cover.isEmpty) cover = _firstGroup(srcSetPattern, block);
      final remark = _firstGroup(episodePattern, block);
      seen.add(id);
      items.add(
        DramaSiteItem(id: id, title: title, cover: cover, remark: remark),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(String body, String seriesId) {
    final data = _extractRouterData(body);
    if (data == null) {
      throw StateError('红果镜像详情未返回剧集数据');
    }
    final loader = _asMap(data['loaderData']);
    var page = _asMap(loader['detail_page']);
    if (page.isEmpty) {
      for (final entry in loader.entries) {
        if (entry.key.startsWith('detail_')) {
          page = _asMap(entry.value);
          if (page.isNotEmpty) break;
        }
      }
    }
    final series = _asMap(page['seriesDetail']);
    if (series.isEmpty) {
      throw StateError('红果镜像详情未返回剧集');
    }
    final title = _stringOf(
      series['series_title'] ?? series['series_name'] ?? series['title'],
    );
    final cover = _stringOf(
      series['series_cover'] ?? series['cover'] ?? series['img'],
    );
    final rawList = series['vid_list'];
    final episodes = <DramaSiteEpisode>[];
    final seen = <String>{};
    if (rawList is List) {
      for (var i = 0; i < rawList.length; i++) {
        final videoId = _stringOf(rawList[i]);
        if (!RegExp(r'^\d+$').hasMatch(videoId) || seen.contains(videoId)) {
          continue;
        }
        seen.add(videoId);
        episodes.add(
          DramaSiteEpisode(videoId: videoId, title: '第${episodes.length + 1}集'),
        );
      }
    }
    if (title.isEmpty || episodes.isEmpty) {
      throw StateError('红果镜像详情未返回有效分集');
    }
    final extra = <String, String>{};
    for (final entry in series.entries) {
      final key = entry.key.toString();
      if (const {
        'series_id',
        'series_title',
        'series_name',
        'title',
        'series_cover',
        'cover',
        'img',
        'vid_list',
        'series_desc',
        'desc',
        'introduction',
        'synopsis',
        'content',
      }.contains(key)) {
        continue;
      }
      final value = entry.value;
      if (value is String || value is num || value is bool) {
        final text = value.toString().trim();
        if (text.isNotEmpty) extra[key] = text;
      }
    }
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      synopsis: _stringOf(
        series['series_desc'] ??
            series['desc'] ??
            series['introduction'] ??
            series['synopsis'] ??
            series['content'],
      ),
      extra: extra,
      episodes: episodes,
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/category'),
      headers: {'Referer': '$baseUrl/', 'User-Agent': userAgent},
    );
    if (response.statusCode != 200) {
      throw StateError('红果镜像分类 HTTP ${response.statusCode}');
    }
    return parseCategories(response.body);
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final url = categoryId.isEmpty
        ? '$baseUrl/rank/hot-drama'
        : '$baseUrl/category/$categoryId?page=${page < 1 ? 1 : page}';
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Referer': '$baseUrl/', 'User-Agent': userAgent},
    );
    if (response.statusCode != 200) {
      throw StateError('红果镜像列表 HTTP ${response.statusCode}');
    }
    final items = parseCards(response.body);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: categoryId.isNotEmpty && items.length >= 20,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/detail?series_id=${Uri.encodeComponent(seriesId)}'),
      headers: {'Referer': '$baseUrl/', 'User-Agent': userAgent},
    );
    if (response.statusCode != 200) {
      throw StateError('红果镜像详情 HTTP ${response.statusCode}');
    }
    return parseDetail(response.body, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final direct360 = '$baseUrl/video/public/${episode.videoId}/360p.mp4';
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/video/protected/fallback-play-info?aid=8662'),
        headers: {
          'Referer': '$baseUrl/player',
          'Content-Type': 'application/json; charset=utf-8',
          'User-Agent': userAgent,
        },
        body: jsonEncode({'item_id': episode.videoId}),
      );
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final mainUrl = _stringOf(_asMap(decoded)['main_url']);
        if (mainUrl.isNotEmpty) {
          return DramaPlaySource(
            url: mainUrl,
            variants: [
              DramaPlayVariant(name: '360P', url: direct360, height: 360),
            ],
          );
        }
      }
    } catch (_) {}
    return DramaPlaySource(url: direct360);
  }

  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';

  static List<DramaSiteItem> parseSearch(String body) {
    final data = _extractRouterData(body);
    if (data == null) return const [];
    final loader = _asMap(data['loaderData']);
    var page = <String, dynamic>{};
    for (final entry in loader.entries) {
      final candidate = _asMap(entry.value);
      if (candidate['searchList'] is List) {
        page = candidate;
        break;
      }
    }
    if (page.isEmpty) return const [];
    final rawList = page['searchList'];
    if (rawList is! List) return const [];
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final raw in rawList) {
      var node = _asMap(raw);
      final video = _asMap(node['video_data']);
      if (video.isNotEmpty) node = video;
      final id = _stringOf(
        node['series_id_str'] ?? node['series_id'] ?? node['keyword'],
      );
      if (!RegExp(r'^\d+$').hasMatch(id) || seen.contains(id)) continue;
      final title = _stringOf(
        node['series_title'] ?? node['series_name'] ?? node['title'] ?? node['name'],
      );
      if (title.isEmpty) continue;
      var remark = _stringOf(node['episode_right_text']);
      if (remark.isEmpty) {
        final count = _stringOf(node['episode_cnt']);
        if (count.isNotEmpty) remark = '共$count集';
      }
      seen.add(id);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _stringOf(node['series_cover'] ?? node['cover']),
          remark: remark,
        ),
      );
    }
    return items;
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/search/${Uri.encodeComponent(query)}'),
      headers: {'Referer': '$baseUrl/', 'User-Agent': userAgent},
    );
    if (response.statusCode != 200) {
      throw StateError('红果镜像搜索 HTTP ${response.statusCode}');
    }
    return parseSearch(response.body);
  }
}

/// 红果题材：分类页 `selectorList` 里的 `selector_item_id` / `show_name`。
/// 口径与 hongguoTV `DiscoveryParser.info` 一致：id 只认
/// `[a-z0-9]+(-[a-z0-9]+)*`、名非空且不超过 40 字、去重、上限 128 个。
class HongguoDramaTopic {
  const HongguoDramaTopic({required this.id, required this.label});

  final String id;
  final String label;
}

/// 红果榜单：hongguoTV `RankBoard` 四榜。`route` 是榜单页路径段，
/// `key` 是站方 `rankKey`，`loader` 是 router 数据里的榜单节键。
class HongguoRankBoard {
  const HongguoRankBoard({
    required this.id,
    required this.label,
    required this.route,
    required this.key,
  });

  final String id;
  final String label;
  final String route;
  final String key;

  String get loader => 'rank_$route/page';

  static const List<HongguoRankBoard> all = [
    HongguoRankBoard(id: 'all', label: '综合', route: 'hot-drama', key: 'hongguo'),
    HongguoRankBoard(id: 'real', label: '真人剧', route: 'hot-real-drama', key: 'real'),
    HongguoRankBoard(id: 'comic', label: '漫剧', route: 'hot-comic-drama', key: 'comic'),
    HongguoRankBoard(id: 'ai', label: 'AI剧', route: 'hot-ai-drama', key: 'ai'),
  ];

  static HongguoRankBoard byId(String id) =>
      all.firstWhere((board) => board.id == id, orElse: () => all.first);
}

/// 红果榜单里的一部：名次与热度照 hongguoTV `RankPosition`
///（`rank` / `heatText` / `scoreText`·`favoriteText`·`likeText`）。
class HongguoRankEntry {
  const HongguoRankEntry({
    required this.item,
    this.rank,
    this.heat = '',
    this.metrics = '',
    this.tags = const [],
  });

  final DramaSiteItem item;

  /// 1 起的名次；站方没给时为空（不编名次）。
  final int? rank;

  /// 热度文案，如「9320万热度」。
  final String heat;

  /// 评分/收藏/点赞拼成的文案。
  final String metrics;

  /// 该条的完整题材 token（至多 5 个），题材筛选只按它匹配，
  /// 不按标题或简介猜——与 hongguoTV `RankSnapshot.topics` 同口径。
  final List<String> tags;
}

/// 一页红果榜单。
class HongguoRankPageData {
  const HongguoRankPageData({
    required this.entries,
    required this.hasMore,
    this.updatedText = '',
    this.totalPages = 1,
  });

  final List<HongguoRankEntry> entries;
  final bool hasMore;

  /// 站方榜单更新文案。
  final String updatedText;
  final int totalPages;

  /// 题材：各条 tags 的完整 token，按出现次数排——
  /// 与 hongguoTV `RankSnapshot.topics` 同口径。
  List<String> get topics {
    final counts = <String, int>{};
    for (final entry in entries) {
      for (final tag in entry.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final sorted = counts.entries.toList()
      ..sort(
        (a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key),
      );
    return [for (final entry in sorted) entry.key];
  }

  /// 按题材筛本榜作品，保留原榜名次。
  List<HongguoRankEntry> filtered(String topic) => topic.isEmpty
      ? entries
      : [for (final entry in entries) if (entry.tags.contains(topic)) entry];
}

/// 红果网页端：与红果镜像同域名同详情页，但分类页取 router 数据的
/// recommendList，不取卡片 HTML；播放取播放页 video_player_info 的
/// 地址列表，取不到才退 360p 直链。App 签名线不在此，网页线能播就进。
class HongguoContentClient implements DramaSiteContentClient {
  static const baseUrl = HgtvMirrorContentClient.baseUrl;

  final http.Client _client;

  /// 搜索联想的匿名会话 id：hongguoTV `ContentRepository` 是进程内随机
  /// UUID，这里同口径、每客户端实例一个，不入库、不关联账号。
  final String _suggestionWebId;

  HongguoContentClient([http.Client? client])
    : _client = client ?? http.Client(),
      _suggestionWebId = _newWebId();

  static String _newWebId() {
    final random = math.Random.secure();
    final raw = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String routeForCategory(String categoryId) {
    switch (categoryId) {
      case 'real-drama':
      case 'comic-drama':
      case 'ai-drama':
      case 'comic':
        return categoryId;
      default:
        return 'real-drama';
    }
  }

  static List<DramaSiteItem> parseCatalog(String body) {
    final data = _extractRouterData(body);
    if (data == null) return const [];
    final loader = _asMap(data['loaderData']);
    var page = _asMap(loader['category_page']);
    if (page.isEmpty) {
      for (final entry in loader.entries) {
        if (entry.key.startsWith('category_')) {
          page = _asMap(entry.value);
          if (page.isNotEmpty) break;
        }
      }
    }
    final rawList = page['recommendList'];
    final list = rawList is List
        ? rawList
        : _asMap(page['categoryData'])['recommendList'];
    if (list is! List) return const [];
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final raw in list) {
      var node = _asMap(raw);
      final video = _asMap(node['video_data']);
      if (video.isNotEmpty) node = video;
      final id = _stringOf(
        node['series_id_str'] ?? node['series_id'] ?? node['keyword'],
      );
      if (!RegExp(r'^\d+$').hasMatch(id) || seen.contains(id)) continue;
      final title = _stringOf(
        node['series_title'] ?? node['series_name'] ?? node['title'] ?? node['name'],
      );
      if (title.isEmpty) continue;
      var remark = _stringOf(node['episode_right_text']);
      if (remark.isEmpty) {
        final count = _stringOf(node['episode_cnt']);
        if (count.isNotEmpty) remark = '共$count集';
      }
      seen.add(id);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _stringOf(node['series_cover'] ?? node['cover']),
          remark: remark,
        ),
      );
    }
    return items;
  }

  static List<String> parsePlayerAddresses(String body) {
    final data = _extractRouterData(body);
    if (data == null) return const [];
    final loader = _asMap(data['loaderData']);
    var page = _asMap(loader['player_page']);
    if (page.isEmpty) {
      for (final entry in loader.entries) {
        if (entry.key.startsWith('player_')) {
          page = _asMap(entry.value);
          if (page.isNotEmpty) break;
        }
      }
    }
    final info = _asMap(page['video_player_info']);
    final addresses = <String>[];
    final seen = <String>{};
    void add(dynamic value) {
      if (value is String) {
        var address = value.trim();
        if (address.isEmpty || address.length > 8192) return;
        if (!_isHttpMedia(address)) {
          try {
            address = utf8.decode(base64Decode(address)).trim();
          } catch (_) {
            return;
          }
        }
        if (_isHttpMedia(address) && seen.add(address)) {
          addresses.add(address);
        }
      } else if (value is List) {
        for (final entry in value) {
          add(entry);
        }
      }
    }

    for (final key in [
      'main_url',
      'backup_url',
      'backup_url_1',
      'backup_url_2',
      'backup_urls',
      'url_list',
    ]) {
      add(info[key]);
    }
    return addresses;
  }

  /// 分类页的题材选项：取 router 数据里第一个带 `selectorList` 的节，
  /// 与 hongguoTV `DiscoveryParser.info` 同口径校验 id 与名。
  static List<HongguoDramaTopic> parseTopics(String body) {
    final data = _extractRouterData(body);
    if (data == null) return const [];
    final loader = _asMap(data['loaderData']);
    final topicId = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
    for (final entry in loader.entries) {
      final section = _asMap(entry.value);
      final selectors = section['selectorList'];
      if (selectors is! List) continue;
      final seen = <String>{};
      final topics = <HongguoDramaTopic>[];
      for (final group in selectors) {
        final items = _asMap(group)['items'];
        if (items is! List) continue;
        for (final raw in items) {
          final node = _asMap(raw);
          final id = _stringOf(node['selector_item_id']);
          final label = _stringOf(node['show_name']);
          if (id.isEmpty || id.length > 80 || !topicId.hasMatch(id)) continue;
          if (label.isEmpty || label.length > 40) continue;
          if (seen.add(id)) topics.add(HongguoDramaTopic(id: id, label: label));
          if (topics.length >= 128) return topics;
        }
      }
      if (topics.isNotEmpty) return topics;
    }
    return const [];
  }

  /// 服务端搜索联想：`suggest_list` 的 `name`，空时取
  /// `display_words` 首项。口径与 hongguoTV
  /// `ContentRepository.searchSuggestions` 一致（匿名、无签名，
  /// 拼音匹配由服务端做）。
  static List<String> parseSuggestions(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    final rows = _asMap(decoded)['suggest_list'];
    if (rows is! List) return const [];
    final out = <String>[];
    for (final raw in rows) {
      final node = _asMap(raw);
      var name = _stringOf(node['name']);
      if (name.isEmpty) {
        final words = node['display_words'];
        if (words is List && words.isNotEmpty) name = _stringOf(words.first);
      }
      if (name.isNotEmpty && name.length <= 80 && !out.contains(name)) {
        out.add(name);
      }
      if (out.length >= 8) break;
    }
    return out;
  }

  /// 一页红果榜单：取 router 数据 `rank_<route>/page` 节的 `rankList`
  /// 与 `pagination`，口径与 hongguoTV `ComicRank.parse` 的 JSON 主路
  /// 一致。站方渲染兜底（读卡片 HTML）未移植：榜单页以 router 数据为
  /// 准，拿不到时如实报错，不拿残缺卡片冒充完整榜。
  static HongguoRankPageData parseRank(
    String body,
    String boardRoute,
    int page,
  ) {
    final data = _extractRouterData(body);
    if (data == null) throw StateError('红果榜单暂不可用');
    final loader = _asMap(data['loaderData']);
    final section = _asMap(loader['rank_$boardRoute/page']);
    if (section.isEmpty) throw StateError('红果榜单暂不可用');
    if (section['isSuccess'] == false) throw StateError('红果榜单暂不可用');
    final pagination = _asMap(section['pagination']);
    final totalPages = _firstInt(pagination, ['totalPages']);
    final pageNum = pagination['pageNum'];
    if (totalPages < 1 ||
        (pageNum != null && _firstInt(pagination, ['pageNum']) != page)) {
      throw StateError('红果榜单分页异常');
    }
    final rawList = section['rankList'];
    if (rawList is! List) throw StateError('红果榜单格式已变化');
    final updatedText = _stringOf(section['updatedText']);
    final seen = <String>{};
    final entries = <HongguoRankEntry>[];
    for (final raw in rawList) {
      final row = _asMap(raw);
      final id = _stringOf(row['seriesId']).isNotEmpty
          ? _stringOf(row['seriesId'])
          : _stringOf(row['id']);
      final title = _stringOf(row['title']);
      if (!RegExp(r'^[0-9]{1,30}$').hasMatch(id) ||
          title.isEmpty ||
          !seen.add(id)) {
        continue;
      }
      final heat = _stringOf(row['heatText']);
      final count = _firstInt(row, ['episodeCount']);
      final episodeVids = row['episodeVids'];
      final vidCount = episodeVids is List ? episodeVids.length : 0;
      final total = count > 0 ? count : vidCount;
      final metrics = [
        _stringOf(row['scoreText']),
        _stringOf(row['favoriteText']),
        _stringOf(row['likeText']),
      ].where((part) => part.isNotEmpty).join(' · ');
      final tags = <String>[];
      final rawTags = row['tags'];
      if (rawTags is List) {
        for (final tag in rawTags.take(5)) {
          final text = _stringOf(tag);
          if (text.isNotEmpty) tags.add(text);
        }
      }
      final rankValue = _firstInt(row, ['rank']);
      entries.add(
        HongguoRankEntry(
          item: DramaSiteItem(
            id: id,
            title: title,
            cover: _stringOf(row['cover']),
            remark: total > 0 ? '全$total集' : heat,
          ),
          rank: rankValue > 0 ? rankValue : null,
          heat: heat,
          metrics: metrics,
          tags: tags,
        ),
      );
    }
    return HongguoRankPageData(
      entries: entries,
      hasMore: entries.isNotEmpty && page < totalPages.clamp(1, 100),
      updatedText: updatedText,
      totalPages: totalPages.clamp(1, 100),
    );
  }

  static bool _isHttpMedia(String address) {
    final uri = Uri.tryParse(address);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('all', '全部'),
    DramaSiteCategory('real-drama', '真人剧'),
    DramaSiteCategory('comic-drama', '漫剧'),
    DramaSiteCategory('ai-drama', 'AI剧'),
    DramaSiteCategory('comic', '动漫'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    // 「全部」不是真人剧：hongguoTV 首页（`ContentRepository.home`）
    // 取推荐流 `/category?tab=1&sort_type=1`，此前把它默默映射成
    // 真人剧是错的。`routeForCategory('all')` 的映射本身不动，
    // 只是这里不再用它。
    if (categoryId == 'all') return _homeCatalog(page);
    final route = routeForCategory(categoryId);
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/category/$route?page=${page < 1 ? 1 : page}',
      ),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果列表 HTTP ${response.statusCode}');
    }
    final items = parseCatalog(response.body);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: items.length >= 24,
      topics: parseTopics(response.body),
    );
  }

  /// 首页推荐流（hongguoTV `ContentRepository.home`）。
  Future<DramaSiteCatalogPage> _homeCatalog(int page) async {
    final safePage = page < 1 ? 1 : page;
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/category?tab=1&sort_type=1${safePage > 1 ? '&page=$safePage' : ''}',
      ),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果列表 HTTP ${response.statusCode}');
    }
    final items = parseCatalog(response.body);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: items.length >= 24,
      topics: parseTopics(response.body),
    );
  }

  /// 分类 + 题材（hongguoTV `ContentRepository.discover`）：
  /// `/category/<route>/<topic>?page=`，题材为空时与 [catalog] 同路。
  /// 带题材的多维筛选（主题/设定/背景/排序/受众/时间/状态）走的是
  /// 带签名的筛选接口，不在本方法里——签名是另一组的活，这里不编。
  Future<DramaSiteCatalogPage> discover(
    String categoryId,
    String topic,
    int page,
  ) async {
    if (topic.isNotEmpty &&
        !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(topic)) {
      throw StateError('题材参数异常');
    }
    if (topic.isEmpty) return catalog(categoryId, page);
    final route = routeForCategory(categoryId);
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/category/$route/${Uri.encodeComponent(topic)}'
        '?page=${page < 1 ? 1 : page}',
      ),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果列表 HTTP ${response.statusCode}');
    }
    final items = parseCatalog(response.body);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: items.length >= 24,
      topics: parseTopics(response.body),
    );
  }

  /// 一页红果榜单（hongguoTV `ContentRepository.rankPage`）：
  /// `GET /rank/<route>?page=`，无签名。
  Future<HongguoRankPageData> rankPage(
    HongguoRankBoard board, {
    int page = 1,
  }) async {
    final safePage = page < 1 ? 1 : page;
    if (safePage > 100) throw StateError('红果榜单页码异常');
    final response = await _client.get(
      Uri.parse('$baseUrl/rank/${board.route}?page=$safePage'),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果榜单 HTTP ${response.statusCode}');
    }
    return parseRank(response.body, board.route, safePage);
  }

  /// 服务端搜索联想（hongguoTV `ContentRepository.searchSuggestions`）：
  /// 匿名 GET，无签名；失败回空列表，不挡搜索。
  Future<List<String>> searchSuggestions(String query) async {
    final clean = query.trim();
    if (clean.isEmpty || clean.length > 80) return const [];
    try {
      final response = await _client.get(
        Uri.parse(
          '$baseUrl/incent_resource/suggestion?app_id=8662'
          '&web_id=$_suggestionWebId'
          '&query=${Uri.encodeQueryComponent(clean)}&count=8',
        ),
        headers: {
          'Referer': '$baseUrl/',
          'User-Agent': HgtvMirrorContentClient.userAgent,
        },
      );
      if (response.statusCode != 200) return const [];
      return parseSuggestions(response.body);
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/detail?series_id=${Uri.encodeComponent(seriesId)}'),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果详情 HTTP ${response.statusCode}');
    }
    return HgtvMirrorContentClient.parseDetail(response.body, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final direct360 = '$baseUrl/video/public/${episode.videoId}/360p.mp4';
    if (episode.seriesId.isNotEmpty) {
      try {
        final response = await _client.get(
          Uri.parse(
            '$baseUrl/player/${Uri.encodeComponent(episode.seriesId)}/${Uri.encodeComponent(episode.videoId)}',
          ),
          headers: {
            'Referer': '$baseUrl/',
            'User-Agent': HgtvMirrorContentClient.userAgent,
          },
        );
        if (response.statusCode == 200) {
          final addresses = parsePlayerAddresses(response.body);
          if (addresses.isNotEmpty) {
            return DramaPlaySource(
              url: addresses.first,
              variants: [
                for (var i = 1; i < addresses.length; i++)
                  DramaPlayVariant(name: '线路${i + 1}', url: addresses[i]),
              ],
            );
          }
        }
      } catch (_) {}
    }
    // 播放页已不再带 video_player_info（站方改版：loaderData 里只有
    // protectedPlayback/publicVideoSeo，实测 2026-11-11 各集的
    // video_player_info 恒为空），直接退 360p 公开 mp4 会播到 10 秒
    // 预告片就停。先走备用接口 fallback-play-info 拿正片 main_url
    //（与 HgtvMirrorContentClient.playSource 同路，匿名可取全长，
    // 实测第 1/2/3/5 集 112~172 秒），360p 只留作最后一档兜底。
    try {
      final response = await _client.post(
        Uri.parse('$baseUrl/api/video/protected/fallback-play-info?aid=8662'),
        headers: {
          'Referer': '$baseUrl/player',
          'Content-Type': 'application/json; charset=utf-8',
          'User-Agent': HgtvMirrorContentClient.userAgent,
        },
        body: jsonEncode({'item_id': episode.videoId}),
      );
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final mainUrl = _stringOf(_asMap(decoded)['main_url']);
        if (mainUrl.isNotEmpty) {
          return DramaPlaySource(
            url: mainUrl,
            variants: [
              DramaPlayVariant(name: '360P', url: direct360, height: 360),
            ],
          );
        }
      }
    } catch (_) {}
    return DramaPlaySource(url: direct360);
  }

  static List<DramaSiteItem> parseSearch(String body) {
    final data = _extractRouterData(body);
    if (data == null) return const [];
    final loader = _asMap(data['loaderData']);
    var page = <String, dynamic>{};
    for (final entry in loader.entries) {
      final candidate = _asMap(entry.value);
      if (candidate['searchList'] is List) {
        page = candidate;
        break;
      }
    }
    if (page.isEmpty) return const [];
    final rawList = page['searchList'];
    if (rawList is! List) return const [];
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final raw in rawList) {
      var node = _asMap(raw);
      final video = _asMap(node['video_data']);
      if (video.isNotEmpty) node = video;
      final id = _stringOf(
        node['series_id_str'] ?? node['series_id'] ?? node['keyword'],
      );
      if (!RegExp(r'^\d+$').hasMatch(id) || seen.contains(id)) continue;
      final title = _stringOf(
        node['series_title'] ?? node['series_name'] ?? node['title'] ?? node['name'],
      );
      if (title.isEmpty) continue;
      var remark = _stringOf(node['episode_right_text']);
      if (remark.isEmpty) {
        final count = _stringOf(node['episode_cnt']);
        if (count.isNotEmpty) remark = '共$count集';
      }
      seen.add(id);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _stringOf(node['series_cover'] ?? node['cover']),
          remark: remark,
        ),
      );
    }
    return items;
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/search/${Uri.encodeComponent(query)}'),
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': HgtvMirrorContentClient.userAgent,
      },
    );
    if (response.statusCode != 200) {
      throw StateError('红果搜索 HTTP ${response.statusCode}');
    }
    return parseSearch(response.body);
  }}

String _firstString(Map<String, dynamic> node, List<String> keys) {
  for (final key in keys) {
    final value = _stringOf(node[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

int _firstInt(Map<String, dynamic> node, List<String> keys) {
  for (final key in keys) {
    final value = node[key];
    if (value is num) return value.toInt();
    final parsed = int.tryParse(_stringOf(value));
    if (parsed != null) return parsed;
  }
  return 0;

}

/// 饭果：西饭接口站，分类即搜索关键词，详情直接给每集播放直链，
/// 取流就是详情里那条直链，不另调播放接口。
class FanguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://xifan-api-cn.youlishipin.com';

  final http.Client _client;

  FanguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    final result = _asMap(response['result']);
    final elements = result['elements'];
    if (elements is! List) return const [];
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final block in elements) {
      final mapped = _asMap(block);
      final contents = mapped['contents'];
      if (contents is! List) continue;
      for (final entry in contents) {
        final node = _asMap(_asMap(entry)['duanjuVo']);
        var id = _firstString(node, ['duanjuId', 'duanju_id', 'id']);
        if (id.isEmpty) continue;
        final source = _firstString(node, ['source']);
        if (source.isNotEmpty) id = '$id#$source';
        if (seen.contains(id)) continue;
        final title = _firstString(node, ['title', 'name']);
        if (title.isEmpty) continue;
        seen.add(id);
        items.add(
          DramaSiteItem(
            id: id,
            title: title,
            cover: _firstString(node, [
              'coverImageUrl',
              'cover_image_url',
              'cover',
            ]),
            remark: _firstInt(node, ['total', 'totalEpisodeNum']) > 0
                ? '共${_firstInt(node, ['total', 'totalEpisodeNum'])}集'
                : '',
          ),
        );
      }
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    final data = _asMap(response['result']);
    if (data.isEmpty) {
      throw StateError('饭果未返回剧集资料');
    }
    final title = _firstString(data, ['title', 'name']);
    final cover = _firstString(data, [
      'coverImageUrl',
      'cover_image_url',
      'cover',
    ]);
    final rawList = data['episodeList'];
    if (rawList is! List) {
      throw StateError('饭果未返回可播放分集');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < rawList.length; i++) {
      final node = _asMap(rawList[i]);
      final url = _firstString(node, ['playUrl', 'play_url', 'videoUrl']);
      if (url.isEmpty) continue;
      var number = _firstInt(node, ['index', 'episode', 'sort']);
      if (number <= 0) number = i + 1;
      final nodeTitle = _firstString(node, ['title', 'name']);
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: url,
          title: nodeTitle.isNotEmpty ? nodeTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('饭果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('都市', '都市'),
    DramaSiteCategory('甜宠', '甜宠'),
    DramaSiteCategory('逆袭', '逆袭'),
    DramaSiteCategory('战神', '战神'),
    DramaSiteCategory('古装', '古装'),
    DramaSiteCategory('穿越', '穿越'),
    DramaSiteCategory('萌宝', '萌宝'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page > 1) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    final keyword = categoryId.isEmpty ? '都市' : categoryId;
    final uri = Uri.parse('$baseUrl/xifan/search/getSearchList').replace(
      queryParameters: {
        'reqType': 'search',
        'offset': '0',
        'keyword': keyword,
        'quickEngineVersion': '-1',
        'scene': '',
      },
    );
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('饭果列表 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('饭果列表数据格式无法识别');
    }
    return DramaSiteCatalogPage(
      items: parseCatalog(decoded),
      hasMore: false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    var duanjuId = seriesId;
    var source = '';
    final cut = seriesId.indexOf('#');
    if (cut >= 0) {
      duanjuId = seriesId.substring(0, cut);
      source = seriesId.substring(cut + 1);
    }
    final uri = Uri.parse('$baseUrl/xifan/drama/getDuanjuInfo').replace(
      queryParameters: {'duanjuId': duanjuId, 'source': source},
    );
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('饭果详情 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('饭果详情数据格式无法识别');
    }
    return parseDetail(decoded, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.videoId.startsWith('http')) {
      return DramaPlaySource(url: episode.videoId);
    }
    throw StateError('饭果该集没有播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final page = await catalog(query, 1);
    return page.items;
  }
}

/// 观果：围观接口站，分类只有全部，列表用 POST 搜索接口，
/// 详情给每集直链或清晰度列表里最高清晰度那条。
class GuanguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://api.drama.9ddm.com';

  final http.Client _client;

  GuanguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static String _clientInfo() {
    var stamp = DateTime.now().millisecondsSinceEpoch.toString();
    if (stamp.length > 10) stamp = stamp.substring(stamp.length - 10);
    return md5.convert(utf8.encode(stamp)).toString();
  }

  static Map<String, String> _query(Map<String, String> extra) {
    return {
      'version_code': '1500',
      'version_name': '1.5.0',
      'device_name': 'Pixel 8 Pro',
      'device_type': 'phone',
      'is_first_day': 'true',
      'is_first_24h': 'true',
      'app_launch_way': 'icon',
      'default_homepage': 'homepage_interaction',
      'device_owning_firm': 'Google',
      'font_scale': 'default',
      'os_type': '1',
      'clientInfo': _clientInfo(),
      ...extra,
    };
  }

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    final data = response['data'];
    if (data is! List) return const [];
    final items = <DramaSiteItem>[];
    for (final entry in data) {
      final node = _asMap(entry);
      final id = _firstString(node, ['oneId', 'one_id', 'id']);
      if (id.isEmpty) continue;
      final title = _firstString(node, ['title', 'name']);
      if (title.isEmpty) continue;
      var remark = '';
      final count = _firstInt(node, ['episodeCount', 'totalEpisodeCount']);
      if (count > 0) remark = '共$count集';
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(node, ['horzPoster', 'vertPoster', 'cover']),
          remark: remark,
        ),
      );
    }
    return items;
  }

  static String _episodeUrl(Map<String, dynamic> node) {
    final direct = _firstString(node, ['playUrl', 'videoUrl', 'play_url']);
    if (direct.isNotEmpty) return direct;
    final clarities = node['videoClarityList'];
    if (clarities is! List) return '';
    var best = '';
    var bestQuality = -1;
    for (final entry in clarities) {
      final clarity = _asMap(entry);
      final address = _firstString(clarity, ['playUrl', 'videoUrl', 'url']);
      if (address.isEmpty) continue;
      final quality = _firstInt(clarity, ['clarity', 'quality', 'definition']);
      if (quality > bestQuality) {
        best = address;
        bestQuality = quality;
      }
    }
    return best;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    final title = _firstString(response, ['title']);
    final data = response['data'];
    if (title.isEmpty && data is! List) {
      throw StateError('观果详情接口当前返回空数据');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    if (data is List) {
      for (var i = 0; i < data.length; i++) {
        final node = _asMap(data[i]);
        final url = _episodeUrl(node);
        if (url.isEmpty) continue;
        var number = _firstInt(node, [
          'playOrder',
          'episodeOrder',
          'index',
          'episode',
        ]);
        if (number <= 0) number = i + 1;
        final nodeTitle = _firstString(node, ['title', 'name']);
        indexed.add((
          number: number,
          episode: DramaSiteEpisode(
            videoId: url,
            title: nodeTitle.isNotEmpty ? nodeTitle : '第$number集',
            seriesId: seriesId,
          ),
        ));
      }
    }
    if (indexed.isEmpty) {
      throw StateError('观果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: _firstString(response, ['vertPoster', 'horzPoster']),
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('all', '全部'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (page > 500) {
      return const DramaSiteCatalogPage(items: [], hasMore: false);
    }
    final uri = Uri.parse('$baseUrl/drama/home/search').replace(
      queryParameters: _query({}),
    );
    final response = await _client.post(
      uri,
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': 'okhttp/5.1.0',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode({
        'audience': '全部',
        'order': '最新',
        'page': page < 1 ? 1 : page,
        'pageSize': 30,
        'searchWord': '',
        'subject': '',
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('观果列表 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('观果列表数据格式无法识别');
    }
    final items = parseCatalog(decoded);
    return DramaSiteCatalogPage(items: items, hasMore: items.length >= 30);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final uri = Uri.parse('$baseUrl/drama/home/shortVideoDetail').replace(
      queryParameters: _query({
        'oneId': seriesId,
        'page': '1',
        'pageSize': '1000',
        'userId': '0',
        'queryAll': 'true',
      }),
    );
    final response = await _client.get(
      uri,
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': 'okhttp/5.1.0',
        'Content-Type': 'application/json; charset=utf-8',
      },
    );
    if (response.statusCode != 200) {
      throw StateError('观果详情 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('观果详情数据格式无法识别');
    }
    return parseDetail(decoded, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.videoId.startsWith('http')) {
      return DramaPlaySource(url: episode.videoId);
    }
    throw StateError('观果该集没有播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final uri = Uri.parse('$baseUrl/drama/home/search').replace(
      queryParameters: _query({}),
    );
    final response = await _client.post(
      uri,
      headers: {
        'Referer': '$baseUrl/',
        'User-Agent': 'okhttp/5.1.0',
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonEncode({
        'audience': '全部',
        'order': '最新',
        'page': 1,
        'pageSize': 30,
        'searchWord': query,
        'subject': '',
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('观果搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('观果搜索数据格式无法识别');
    }
    return parseCatalog(decoded);
  }
}

/// 河果：Next.js 网页站，无登录，列表与详情都取 __NEXT_DATA__ 的
/// pageProps，分集播放取分集页里出现的 mp4/m3u8 直链。
class HeguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://www.kuaikaw.cn';

  final http.Client _client;

  HeguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static Map<String, dynamic>? parsePageProps(String body) {
    final match = RegExp(
      r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
      dotAll: true,
    ).firstMatch(body);
    if (match == null) return null;
    try {
      final decoded = jsonDecode(match.group(1) ?? '');
      if (decoded is! Map<String, dynamic>) return null;
      final props = _asMap(decoded['props']);
      return _asMap(props['pageProps']);
    } catch (_) {
      return null;
    }
  }

  static List<DramaSiteItem> parseCatalog(
    Map<String, dynamic> pageProps,
  ) {
    final items = <DramaSiteItem>[];
    final seen = <String>{};
    void addBooks(dynamic rows) {
      if (rows is! List) return;
      for (final entry in rows) {
        final book = _asMap(entry);
        final id = _firstString(book, ['bookId', 'book_id', 'id']);
        if (id.isEmpty || seen.contains(id)) continue;
        final title = _firstString(book, ['bookName', 'title', 'name']);
        if (title.isEmpty) continue;
        seen.add(id);
        final total = _firstInt(book, ['totalChapterNum']);
        var remark = _firstString(book, ['statusDesc']);
        if (total > 0) {
          remark = remark.isEmpty ? '共$total集' : '$remark 共$total集';
        }
        items.add(
          DramaSiteItem(
            id: id,
            title: title,
            cover: _firstString(book, ['coverWap', 'cover', 'coverUrl']),
            remark: remark.trim(),
          ),
        );
      }
    }

    for (final key in ['bannerList', 'bookList', 'recommendList']) {
      addBooks(pageProps[key]);
    }
    final columns = pageProps['seoColumnVos'];
    if (columns is List) {
      for (final column in columns) {
        addBooks(_asMap(column)['bookInfos']);
      }
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> pageProps,
    String seriesId,
  ) {
    final book = _asMap(pageProps['bookInfoVo']);
    if (book.isEmpty) {
      throw StateError('河果未返回剧集资料');
    }
    final title = _firstString(book, ['bookName', 'title', 'name']);
    final cover = _firstString(book, ['coverWap', 'cover', 'coverUrl']);
    final rawList = pageProps['chapterList'];
    if (rawList is! List) {
      throw StateError('河果未返回可播放分集');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < rawList.length; i++) {
      final node = _asMap(rawList[i]);
      final chapterId = _firstString(node, ['chapterId', 'chapter_id', 'id']);
      if (chapterId.isEmpty) continue;
      var number = _firstInt(node, ['chapterNum', 'sort', 'index']);
      if (number <= 0) number = i + 1;
      final nodeTitle = _firstString(node, ['chapterName', 'title']);
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: chapterId,
          title: nodeTitle.isNotEmpty ? nodeTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('河果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  static List<String> parseEpisodeUrls(String body) {
    final pattern = RegExp(
      r'''https?://[^"' \s<>\\]+\.(?:mp4|m3u8)[^"' \s<>\\]*''',
    );
    final seen = <String>{};
    final urls = <String>[];
    for (final match in pattern.allMatches(body)) {
      final url = match.group(0) ?? '';
      if (url.isNotEmpty && seen.add(url)) urls.add(url);
    }
    return urls;
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('462', '甜宠'),
    DramaSiteCategory('1102', '古装仙侠'),
    DramaSiteCategory('1145', '现代言情'),
    DramaSiteCategory('1170', '青春'),
    DramaSiteCategory('585', '豪门恩怨'),
    DramaSiteCategory('417-464', '逆袭'),
    DramaSiteCategory('439-465', '重生'),
    DramaSiteCategory('1159', '系统'),
    DramaSiteCategory('1147', '总裁'),
    DramaSiteCategory('943', '职场商战'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final url = categoryId.isEmpty
        ? '$baseUrl/'
        : '$baseUrl/browse/${Uri.encodeComponent(categoryId)}/${page < 1 ? 1 : page}';
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('河果列表 HTTP ${response.statusCode}');
    }
    final pageProps = parsePageProps(response.body);
    if (pageProps == null) {
      throw StateError('河果页面结构无法识别');
    }
    final items = parseCatalog(pageProps);
    final totalPages = _firstInt(pageProps, ['pages']);
    final current = _firstInt(pageProps, ['page']);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: totalPages > (current > 0 ? current : page),
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/drama/${Uri.encodeComponent(seriesId)}'),
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('河果详情 HTTP ${response.statusCode}');
    }
    final pageProps = parsePageProps(response.body);
    if (pageProps == null) {
      throw StateError('河果详情页结构无法识别');
    }
    return parseDetail(pageProps, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.seriesId.isEmpty) {
      throw StateError('河果分集缺少剧集 ID');
    }
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/episode/${Uri.encodeComponent(episode.seriesId)}/${Uri.encodeComponent(episode.videoId)}',
      ),
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('河果分集页 HTTP ${response.statusCode}');
    }
    final urls = parseEpisodeUrls(response.body);
    if (urls.isEmpty) {
      throw StateError('河果分集页未找到播放地址');
    }
    return DramaPlaySource(
      url: urls.first,
      variants: [
        for (var i = 1; i < urls.length; i++)
          DramaPlayVariant(name: '线路${i + 1}', url: urls[i]),
      ],
    );
  }

  static List<DramaSiteItem> parseSearch(Map<String, dynamic> response) {
    final data = _asMap(response['data']);
    final rows = data['bookList'];
    if (rows is! List) return const [];
    final items = <DramaSiteItem>[];
    final seen = <String>{};
    for (final entry in rows) {
      final book = _asMap(entry);
      final id = _firstString(book, ['bookId', 'book_id', 'id']);
      if (id.isEmpty || seen.contains(id)) continue;
      final title = _firstString(book, ['bookName', 'title', 'name']);
      if (title.isEmpty) continue;
      seen.add(id);
      final total = _firstInt(book, ['totalChapterNum']);
      var remark = _firstString(book, ['statusDesc']);
      if (total > 0) {
        remark = remark.isEmpty ? '共$total集' : '$remark 共$total集';
      }
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(book, ['coverWap', 'cover', 'coverUrl']),
          remark: remark.trim(),
        ),
      );
    }
    return items;
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/seo/video/6007'),
      headers: {
        'Referer': '$baseUrl/',
        'Content-Type': 'application/json',
        'pname': 'www.kuaikaw.cn',
      },
      body: jsonEncode({'sourceType': 1, 'keyword': query, 'index': 1}),
    );
    if (response.statusCode != 200) {
      throw StateError('河果搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('河果搜索数据格式无法识别');
    }
    return parseSearch(decoded);
  }
}

/// 星果：多多接口站，分类是资源编号，详情直接给每集播放直链。
class XingguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://read.api.duodutek.com';
  static const _productId = '2a8c14d1-72e7-498b-af23-381028eb47c0';
  static const _vestId = '2be070e0-c824-4d0e-a67a-8f688890cadb';
  static const _token = '202509271001001446030204698626';

  final http.Client _client;

  XingguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static Map<String, String> _query(Map<String, String> extra) {
    return {
      'productId': _productId,
      'vestId': _vestId,
      'channel': 'oppo19',
      'osType': 'android',
      'version': '20',
      'token': _token,
      ...extra,
    };
  }

  static String _episodeUrl(Map<String, dynamic> node) {
    final direct = _firstString(node, ['shortPlayUrl', 'playUrl', 'url']);
    if (direct.isNotEmpty) return direct;
    for (final key in ['shortPlayList', 'chapterShortPlayVoList']) {
      final list = node[key];
      if (list is! List) continue;
      for (final entry in list) {
        final url = _episodeUrl(_asMap(entry));
        if (url.isNotEmpty) return url;
      }
    }
    return '';
  }

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    final data = _asMap(response['data']);
    final rows = data['datalist'];
    if (rows is! List) return const [];
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _firstString(node, ['id', 'bookId']);
      if (id.isEmpty) continue;
      final title = _firstString(node, ['name', 'title']);
      if (title.isEmpty) continue;
      var sourceKey = id;
      final intro = _firstString(node, ['introduction']);
      if (intro.isNotEmpty) sourceKey = '$id@$intro';
      final count = _firstInt(node, ['chapterCount', 'total']);
      items.add(
        DramaSiteItem(
          id: sourceKey,
          title: title,
          cover: _firstString(node, ['icon', 'cover']),
          remark: count > 0 ? '共$count集' : '',
        ),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    final rows = response['data'];
    if (rows is! List) {
      throw StateError('星果未返回可播放分集');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < rows.length; i++) {
      final node = _asMap(rows[i]);
      final url = _episodeUrl(node);
      if (url.isEmpty) continue;
      var number = _firstInt(node, ['chapterNum', 'sort', 'index']);
      if (number <= 0) number = i + 1;
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: url,
          title: '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('星果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: '',
      cover: '',
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('1287', '推荐一'),
    DramaSiteCategory('1288', '推荐二'),
    DramaSiteCategory('1289', '推荐三'),
    DramaSiteCategory('1290', '推荐四'),
    DramaSiteCategory('1291', '推荐五'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final resourceId = categoryId.isEmpty ? '1287' : categoryId;
    final uri = Uri.parse(
      '$baseUrl/novel-api/app/pageModel/getResourceById',
    ).replace(
      queryParameters: _query({
        'resourceId': resourceId,
        'pageNum': '${page < 1 ? 1 : page}',
        'pageSize': '10',
      }),
    );
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('星果列表 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('星果列表数据格式无法识别');
    }
    final items = parseCatalog(decoded);
    return DramaSiteCatalogPage(items: items, hasMore: items.length >= 10);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final bookId = seriesId.contains('@')
        ? seriesId.substring(0, seriesId.indexOf('@'))
        : seriesId;
    final uri = Uri.parse(
      '$baseUrl/novel-api/basedata/book/getChapterList',
    ).replace(queryParameters: _query({'bookId': bookId}));
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('星果详情 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('星果详情数据格式无法识别');
    }
    return parseDetail(decoded, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.videoId.startsWith('http')) {
      return DramaPlaySource(url: episode.videoId);
    }
    throw StateError('星果该集没有播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final uri = Uri.parse(
      '$baseUrl/novel-api/basedata/book/searchBook',
    ).replace(
      queryParameters: _query({'key': query, 'pageNum': '1', 'pageSize': '20'}),
    );
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('星果搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('星果搜索数据格式无法识别');
    }
    return parseCatalog(decoded);
  }
}

/// 猫果：七猫接口站，请求头要带 qm-params（JSON 经字符映射的
/// Base64）与签名字段，分类从标签接口取、取不到时只留推荐。
class MaoguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://api-store.qmplaylet.com';
  static const readUrl = 'https://api-read.qmplaylet.com';
  static const _key = 'd3dGiJc651gSQ8w1';

  static const _charMap = {
    '+': 'P', '/': 'X', '0': 'M', '1': 'U', '2': 'l', '3': 'E', '4': 'r',
    '5': 'Y', '6': 'W', '7': 'b', '8': 'd', '9': 'J', 'A': '9', 'B': 's',
    'C': 'a', 'D': 'I', 'E': '0', 'F': 'o', 'G': 'y', 'H': '_', 'I': 'H',
    'J': 'G', 'K': 'i', 'L': 't', 'M': 'g', 'N': 'N', 'O': 'A', 'P': '8',
    'Q': 'F', 'R': 'k', 'S': '3', 'T': 'h', 'U': 'f', 'V': 'R', 'W': 'q',
    'X': 'C', 'Y': '4', 'Z': 'p', 'a': 'm', 'b': 'B', 'c': 'O', 'd': 'u',
    'e': 'c', 'f': '6', 'g': 'K', 'h': 'x', 'i': '5', 'j': 'T', 'k': '-',
    'l': '2', 'm': 'z', 'n': 'S', 'o': 'Z', 'p': '1', 'q': 'V', 'r': 'v',
    's': 'j', 't': 'Q', 'u': '7', 'v': 'D', 'w': 'w', 'x': 'n', 'y': 'L',
    'z': 'e',
  };

  final http.Client _client;

  MaoguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static Map<String, String> _headers() {
    final session = DateTime.now().millisecondsSinceEpoch.toString();
    final payload = jsonEncode({
      'static_score': '0.8',
      'uuid': '00000000-7fc7-08dc-0000-000000000000',
      'device-id': '20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70',
      'mac': '',
      'sourceuid': 'aa7de295aad621a6',
      'refresh-type': '0',
      'model': '22021211RC',
      'wlb-imei': '',
      'client-id': 'aa7de295aad621a6',
      'brand': 'Redmi',
      'oaid': '',
      'oaid-no-cache': '',
      'sys-ver': '12',
      'trusted-id': '',
      'phone-level': 'H',
      'imei': '',
      'wlb-uid': 'aa7de295aad621a6',
      'session-id': session,
    });
    final base = base64Encode(utf8.encode(payload));
    final mapped = StringBuffer();
    for (var i = 0; i < base.length; i++) {
      mapped.write(_charMap[base[i]] ?? base[i]);
    }
    final qmParams = mapped.toString();
    final sign = md5
        .convert(
          utf8.encode(
            'AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=unknownis-white=net-env=5platform=androidqm-params=${qmParams}reg=$_key',
          ),
        )
        .toString();
    return {
      'net-env': '5',
      'reg': '',
      'channel': 'unknown',
      'is-white': '',
      'platform': 'android',
      'application-id': 'com.duoduo.read',
      'authorization': '',
      'app-version': '10001',
      'user-agent': 'webviewversion/0',
      'qm-params': qmParams,
      'sign': sign,
      'Accept': 'application/json',
      'X-Requested-With': 'com.duoduo.read',
    };
  }

  static String _sign(String raw) =>
      md5.convert(utf8.encode(raw)).toString();

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    final data = _asMap(response['data']);
    final rows = data['list'];
    if (rows is! List) return const [];
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _firstString(node, ['playlet_id', 'playletId', 'id']);
      if (id.isEmpty) continue;
      final title = _firstString(node, ['title', 'playlet_name', 'name']);
      if (title.isEmpty) continue;
      final count = _firstInt(node, [
        'total_episode_num',
        'totalEpisodeNum',
        'total',
      ]);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(node, [
            'image_link',
            'imageLink',
            'cover',
            'cover_url',
          ]),
          remark: count > 0 ? '共$count集' : '',
        ),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    final data = _asMap(response['data']);
    if (data.isEmpty) {
      throw StateError('猫果未返回剧集资料');
    }
    final title = _firstString(data, ['title', 'playlet_name', 'name']);
    final cover = _firstString(data, [
      'image_link',
      'imageLink',
      'cover',
      'cover_url',
    ]);
    final rawList = data['play_list'];
    if (rawList is! List) {
      throw StateError('猫果未返回可播放分集');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < rawList.length; i++) {
      final node = _asMap(rawList[i]);
      final url = _firstString(node, ['video_url', 'videoUrl', 'url']);
      if (url.isEmpty) continue;
      var number = _firstInt(node, ['sort', 'episode', 'index']);
      if (number <= 0) number = i + 1;
      final nodeTitle = _firstString(node, ['title', 'name']);
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: url,
          title: nodeTitle.isNotEmpty ? nodeTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('猫果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    try {
      final sign = _sign('operation=1$_key');
      final uri = Uri.parse('$baseUrl/api/v1/playlet/tag/list').replace(
        queryParameters: {'operation': '1', 'sign': sign},
      );
      final response = await _client.get(uri, headers: _headers());
      if (response.statusCode != 200) {
        return const [DramaSiteCategory('0', '推荐')];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const [DramaSiteCategory('0', '推荐')];
      }
      final data = _asMap(decoded['data']);
      final rows = data['list'];
      if (rows is! List) return const [DramaSiteCategory('0', '推荐')];
      final categories = <DramaSiteCategory>[];
      for (final entry in rows) {
        final node = _asMap(entry);
        final id = _firstString(node, ['tag_id', 'id']);
        final name = _firstString(node, ['tag_name', 'name', 'title']);
        if (id.isEmpty || name.isEmpty || name.runes.length > 24) continue;
        categories.add(DramaSiteCategory(id, name));
      }
      if (categories.isEmpty) return const [DramaSiteCategory('0', '推荐')];
      return categories;
    } catch (_) {
      return const [DramaSiteCategory('0', '推荐')];
    }
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    var tagId = categoryId;
    if (tagId.isEmpty || int.tryParse(tagId) == null) tagId = '0';
    final query = <String, String>{
      'tag_id': tagId,
      'playlet_privacy': '1',
      'operation': '1',
    };
    String signRaw;
    if (page > 1) {
      query['next_id'] = '$page';
      signRaw = 'next_id=${page}operation=1playlet_privacy=1tag_id=$tagId$_key';
    } else {
      signRaw = 'operation=1playlet_privacy=1tag_id=$tagId$_key';
    }
    query['sign'] = _sign(signRaw);
    final uri = Uri.parse('$baseUrl/api/v1/playlet/index').replace(
      queryParameters: query,
    );
    final response = await _client.get(uri, headers: _headers());
    if (response.statusCode != 200) {
      throw StateError('猫果列表 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('猫果列表数据格式无法识别');
    }
    final items = parseCatalog(decoded);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: page > 1 ? items.isNotEmpty : false,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final sign = _sign('playlet_id=$seriesId$_key');
    final uri = Uri.parse('$readUrl/player/api/v1/playlet/info').replace(
      queryParameters: {'playlet_id': seriesId, 'sign': sign},
    );
    final response = await _client.get(uri, headers: _headers());
    if (response.statusCode != 200) {
      throw StateError('猫果详情 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('猫果详情数据格式无法识别');
    }
    return parseDetail(decoded, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.videoId.startsWith('http')) {
      return DramaPlaySource(url: episode.videoId);
    }
    throw StateError('猫果该集没有播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    const trackId = 'ec1280db127955061754851657967';
    final sign = _sign('extend=page=1read_preference=0track_id=$trackId' 'wd=$query$_key');
    final uri = Uri.parse('$baseUrl/api/v1/playlet/search').replace(
      queryParameters: {
        'extend': '',
        'page': '1',
        'wd': query,
        'read_preference': '0',
        'track_id': trackId,
        'sign': sign,
      },
    );
    final response = await _client.get(uri, headers: _headers());
    if (response.statusCode != 200) {
      throw StateError('猫果搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('猫果搜索数据格式无法识别');
    }
    return parseCatalog(decoded);
  }
}

/// 芽果：先以固定设备号登录拿令牌（6 小时内复用），再带令牌调接口；
/// 分类从分类接口取、取不到时用剧场与榜单兜底。
class YaguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://app.whjzjx.cn';
  static const loginUrl = 'https://u.shytkjgs.com/user/v1/account/login';
  static const _device = '24250683a3bdb3f118dff25ba4b1cba1a';

  final http.Client _client;
  String? _token;
  DateTime? _tokenExpiresAt;

  YaguoContentClient([http.Client? client]) : _client = client ?? http.Client();

  Future<String> _tokenValue() async {
    if (_token != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _token!;
    }
    final response = await _client.post(
      Uri.parse(loginUrl),
      headers: {'platform': '1', 'Content-Type': 'application/json'},
      body: jsonEncode({'device': _device}),
    );
    if (response.statusCode != 200) {
      throw StateError('芽果登录 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('芽果登录数据格式无法识别');
    }
    var token = _firstString(decoded, ['token', 'access_token', 'accessToken']);
    if (token.isEmpty) {
      // 有些响应把令牌嵌在 data 里，兼容一层嵌套。
      token = _firstString(
        _asMap(decoded['data']),
        ['token', 'access_token', 'accessToken'],
      );
    }
    if (token.isEmpty) {
      final detail = _firstString(decoded, ['msg', 'message', 'error']);
      final code = _stringOf(decoded['code'] ?? decoded['errorCode']);
      throw StateError(
        '芽果未返回有效的访问令牌'
        '${code.isNotEmpty ? '（$code）' : ''}'
        '${detail.isNotEmpty ? '：$detail' : ''}',
      );
    }
    _token = token;
    _tokenExpiresAt = DateTime.now().add(const Duration(hours: 6));
    return token;
  }

  Future<Map<String, dynamic>> _request(
    String path,
    Map<String, String> query,
  ) async {
    final token = await _tokenValue();
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final response = await _client.get(
      uri,
      headers: {
        'Referer': '$baseUrl/',
        'authorization': token,
        'platform': '1',
        'version_name': '3.8.3.1',
      },
    );
    if (response.statusCode != 200) {
      throw StateError('芽果请求 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('芽果数据格式无法识别');
    }
    return decoded;
  }

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    final data = _asMap(response['data']);
    final rows = data['list'];
    if (rows is! List) return const [];
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final theater = _asMap(node['theater']);
      final target = theater.isNotEmpty ? theater : node;
      final id = _firstString(target, ['id', 'theater_id', 'theater_parent_id']);
      if (id.isEmpty) continue;
      final title = _firstString(target, ['title', 'name']);
      if (title.isEmpty) continue;
      final count = _firstInt(target, ['total', 'total_num', 'current_num']);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(target, ['cover_url', 'son_cover_url', 'cover']),
          remark: count > 0 ? '共$count集' : '',
        ),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    final data = _asMap(response['data']);
    if (data.isEmpty) {
      throw StateError('芽果未返回剧集资料');
    }
    final title = _firstString(data, ['title', 'share_title']);
    final cover = _firstString(data, ['cover_url', 'share_cover']);
    final rawList = data['theaters'];
    if (rawList is! List) {
      throw StateError('芽果未返回可播放分集');
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < rawList.length; i++) {
      final node = _asMap(rawList[i]);
      final url = _firstString(node, ['son_video_url', 'video_url']);
      if (url.isEmpty) continue;
      var number = _firstInt(node, ['num', 'sort']);
      if (number <= 0) number = i + 1;
      final nodeTitle = _firstString(node, ['son_title', 'title']);
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: url,
          title: nodeTitle.isNotEmpty ? nodeTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('芽果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    try {
      final response = await _request('/cloud/v2/theater/classes', {});
      final groups = response['data'];
      if (groups is! List) throw StateError('empty');
      final seen = <String>{};
      final categories = <DramaSiteCategory>[];
      for (final group in groups) {
        final classes = _asMap(group)['alg_class'];
        if (classes is! List) continue;
        for (final entry in classes) {
          final node = _asMap(entry);
          final id = _firstString(node, ['id']);
          final name = _firstString(node, ['class_name', 'name']);
          if (id.isEmpty || name.isEmpty || name.runes.length > 24) continue;
          if (!seen.add(id)) continue;
          categories.add(DramaSiteCategory(id, name));
        }
      }
      if (categories.isEmpty) throw StateError('empty');
      return categories;
    } catch (_) {
      return const [
        DramaSiteCategory('1', '剧场'),
        DramaSiteCategory('9', '榜单'),
      ];
    }
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (categoryId == '9') {
      final response = await _request(
        '/cloud/v1/first_level_ranking/detail',
        {'id': '1'},
      );
      final data = _asMap(response['data']);
      final rows = data['list'];
      if (rows is! List) {
        return const DramaSiteCatalogPage(items: [], hasMore: false);
      }
      return DramaSiteCatalogPage(
        items: parseCatalog({'data': {'list': rows}}),
        hasMore: false,
      );
    }
    final classId = int.tryParse(categoryId) == null ? '' : categoryId;
    final response = await _request('/cloud/v2/theater/home_page', {
      'theater_class_id': classId,
      'type': '1',
      'class2_ids': '0',
      'page_num': '${page < 1 ? 1 : page}',
      'page_size': '24',
    });
    final data = _asMap(response['data']);
    final items = parseCatalog(response);
    final total = _firstInt(data, ['total']);
    final isEnd = data['is_end'] == true || data['is_end'] == 'true';
    return DramaSiteCatalogPage(
      items: items,
      hasMore: !isEnd && items.isNotEmpty && total > page * items.length,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final response = await _request('/v2/theater_parent/detail', {
      'theater_parent_id': seriesId,
    });
    return parseDetail(response, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    if (episode.videoId.startsWith('http')) {
      return DramaPlaySource(url: episode.videoId);
    }
    throw StateError('芽果该集没有播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final token = await _tokenValue();
    final response = await _client.post(
      Uri.parse('$baseUrl/v3/search'),
      headers: {
        'Referer': '$baseUrl/',
        'authorization': token,
        'platform': '1',
        'version_name': '3.8.3.1',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'text': query}),
    );
    if (response.statusCode != 200) {
      throw StateError('芽果搜索 HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('芽果搜索数据格式无法识别');
    }
    final data = _asMap(decoded['data']);
    var rows = data['list'];
    if (rows is! List) {
      rows = _asMap(data['theater'])['search_data'];
    }
    if (rows is! List) return const [];
    return parseCatalog({'data': {'list': rows}});
  }
}

/// 苹果 CMS 网页站：花果、发果、伍果、网果共用一套解析，
/// 每站只差基址、目录地址与详情候选地址；播放取播放页的
/// player_aaaa / player_data，按 encrypt 0/1/2 还原直链。
class MaccmsContentClient implements DramaSiteContentClient {
  final String siteId;
  final String baseUrl;

  MaccmsContentClient(this.siteId, this.baseUrl, [http.Client? client])
    : _client = client ?? http.Client();

  /// 网页引擎取页：只给伍果用（指纹门），测试可直接赋值假取页。
  /// 生产由主树绑定到 WebViewPageFetcher.fetch（见 main.dart）。
  Future<String> Function(String url)? webFetch;
  static Future<String> Function(String url)? defaultWebFetch;

  Future<String> Function(String url)? get _effectiveWebFetch =>
      webFetch ?? defaultWebFetch;
  bool get _useWebFetch =>
      siteId == 'wuguo' && _effectiveWebFetch != null;

  final http.Client _client;

  static const _cardClasses = [
    'col-lg-2',
    'col-xl-2',
    'module-item',
    'module-poster-item',
    'public-list-box',
    'videoBox',
    'detail-list-item',
    'col-md-6',
    'col-6',
    'listItem',
    'vodlist__item',
    'v_list',
    'myui-vodlist__box',
    'macplus-vodlist__bag',
    'myui-vodlist__thumb',
    'macplus-vodlist__thumb',
  ];

  static final _detailLink = RegExp(
    r'/(?:index\.php/vod/)?(?:detail|vod|show|view|movie|drama|zywview|xzyxvd)/|[a-z0-9_]*detail/|(?:voddetail|detail|show|vod|drama|movie|tv|xs|vs)[0-9]{2,}',
    caseSensitive: false,
  );
  static final _detailPath = RegExp(
    r'/(?:voddetail|detail|show|vod|drama|movie|tv)/([0-9]+)(?:[-./]|$)',
    caseSensitive: false,
  );
  static final _detailGlued = RegExp(
    r'/(?:voddetail|detail|show|vod|drama|movie|tv|xs|vs)([1-9][0-9]{0,17})(?:[-./]|$)',
    caseSensitive: false,
  );
  static final _playLink = RegExp(
    r'/(?:vod/)?play/|/[a-z0-9_]*play/|/drama-play|episode_id=|/nr/|/bofang/|/vplay/|/zplay/|/mplay/',
    caseSensitive: false,
  );

  static String _resolve(String base, String ref) {
    if (ref.isEmpty) return '';
    if (ref.startsWith('//')) return 'https:$ref';
    try {
      return Uri.parse(base).resolve(ref).toString();
    } catch (_) {
      return ref;
    }
  }

  static String? _sourceIdFromUrl(String link) {
    String path;
    try {
      path = Uri.parse(link).path;
    } catch (_) {
      path = link;
    }
    final trimmed = path.endsWith('.html')
        ? path.substring(0, path.length - 5)
        : path;
    var match = _detailPath.firstMatch('$trimmed/');
    if (match != null) return match.group(1);
    match = _detailGlued.firstMatch('$trimmed/');
    if (match != null) return match.group(1);
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    for (var i = parts.length - 1; i >= 0; i--) {
      final part = parts[i];
      if (int.tryParse(part) != null) return part;
      final dash = part.indexOf('-');
      if (dash >= 0 && int.tryParse(part.substring(dash + 1)) != null) {
        return part.substring(dash + 1);
      }
    }
    try {
      final id = Uri.parse(link).queryParameters['id'];
      if (id != null && int.tryParse(id) != null) return id;
    } catch (_) {}
    return null;
  }

  static bool _isNavLink(String link) {
    String path;
    try {
      path = Uri.parse(link).path.toLowerCase();
    } catch (_) {
      return false;
    }
    if (path.contains('---')) return true;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg == 'type' || seg.endsWith('type')) return true;
      if (seg == 'page') return true;
      if (seg == 'show' && i + 1 < segments.length) {
        if (segments[i + 1] == 'id' || segments[i + 1] == 'page') return true;
      }
    }
    return false;
  }

  static String _elementText(dom.Element element) =>
      element.text.replaceAll(RegExp(r'\s+'), ' ').trim();

  static String? _cardCover(dom.Element card, String base) {
    for (final img in card.querySelectorAll('img')) {
      for (final attr in ['data-original', 'data-src', 'src']) {
        final value = (img.attributes[attr] ?? '').trim();
        if (value.isNotEmpty) return _resolve(base, value);
      }
    }
    return null;
  }

  static List<DramaSiteItem> parseCatalog(String body, String base) {
    final document = html_parser.parse(body);
    final cards = <dom.Element>[];
    final seenElements = <dom.Element>{};
    for (final name in _cardClasses) {
      for (final node in document.querySelectorAll('.$name')) {
        if (seenElements.add(node)) cards.add(node);
      }
    }
    final items = <DramaSiteItem>[];
    final seenIds = <String>{};
    void addCard(dom.Element card) {
      dom.Element? linkNode;
      for (final anchor in card.querySelectorAll('a')) {
        final href = (anchor.attributes['href'] ?? '').trim();
        if (href.isNotEmpty && _detailLink.hasMatch(href)) {
          linkNode = anchor;
          break;
        }
      }
      if (linkNode == null) return;
      final href = (linkNode.attributes['href'] ?? '').trim();
      if (_isNavLink(href)) return;
      final absolute = _resolve(base, href);
      final sourceId = _sourceIdFromUrl(absolute);
      if (sourceId == null || !seenIds.add(sourceId)) return;
      var title = '';
      for (final img in card.querySelectorAll('img')) {
        title = (img.attributes['alt'] ?? img.attributes['title'] ?? '').trim();
        if (title.isNotEmpty) break;
      }
      if (title.isEmpty) {
        title = (linkNode.attributes['title'] ?? '').trim();
      }
      if (title.isEmpty) title = _elementText(card);
      if (title.isEmpty) return;
      final text = _elementText(card);
      var remark = '';
      final remarkMatch = RegExp(r'(共\d+集|更新至[^\s]+|完结)').firstMatch(text);
      if (remarkMatch != null) remark = remarkMatch.group(0)!;
      items.add(
        DramaSiteItem(
          id: sourceId,
          title: title,
          cover: _cardCover(card, base) ?? '',
          remark: remark,
        ),
      );
    }

    for (final card in cards) {
      addCard(card);
    }
    if (items.isEmpty) {
      for (final anchor in document.querySelectorAll('a')) {
        final href = (anchor.attributes['href'] ?? '').trim();
        if (href.isEmpty || !_detailLink.hasMatch(href)) continue;
        dom.Element? parent;
        var node = anchor.parent;
        while (node != null) {
          if (node.localName == 'li' || node.localName == 'div') {
            parent = node;
            break;
          }
          node = node.parent;
        }
        if (parent != null) addCard(parent);
      }
    }
    return items;
  }

  static String _cleanTitle(String raw) {
    var text = raw.trim();
    for (final sep in [' - ', ' _ ']) {
      final cut = text.indexOf(sep);
      if (cut >= 0) text = text.substring(0, cut).trim();
    }
    for (final suffix in [
      '在线观看',
      '免费观看',
      '高清完整版',
      '完整版',
      '全集',
      '在线播放',
      '高清',
      '免费',
    ]) {
      while (text.endsWith(suffix) && text.length > suffix.length) {
        text = text.substring(0, text.length - suffix.length).trim();
      }
    }
    return text.trim();
  }

  static DramaSiteDetail parseDetail(String body, String seriesId) {
    final document = html_parser.parse(body);
    var title = '';
    for (final name in [
      'module-info-heading',
      'detail-title',
      'video-info-title',
      'page-title',
    ]) {
      final node = document.querySelector('.$name');
      if (node != null && _elementText(node).isNotEmpty) {
        title = _cleanTitle(_elementText(node));
        break;
      }
    }
    if (title.isEmpty) {
      final titleNode = document.querySelector('title');
      if (titleNode != null) title = _cleanTitle(_elementText(titleNode));
    }
    var cover = '';
    for (final name in ['module-item-pic', 'detail-pic', 'video-info-pic']) {
      final node = document.querySelector('.$name');
      if (node != null) {
        final found = _cardCover(node, '');
        if (found != null && found.isNotEmpty) {
          cover = found;
          break;
        }
      }
    }
    if (cover.isEmpty) {
      final img = document.querySelector('img');
      if (img != null) {
        for (final attr in ['data-original', 'data-src', 'src']) {
          final value = (img.attributes[attr] ?? '').trim();
          if (value.isNotEmpty) {
            cover = value;
            break;
          }
        }
      }
    }
    final anchors = <dom.Element>[];
    for (final name in [
      'content__playlist',
      'content__list',
      'playlink',
      'pcDrama_catalogItem',
      'catalogItem',
      'playlist',
      'module-play-list-content',
      'tab-pane',
    ]) {
      for (final container in document.querySelectorAll('.$name')) {
        anchors.addAll(container.querySelectorAll('a'));
      }
    }
    if (anchors.isEmpty) {
      anchors.addAll(document.querySelectorAll('a'));
    }
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    final seenLinks = <String>{};
    for (var i = 0; i < anchors.length; i++) {
      final anchor = anchors[i];
      final href = (anchor.attributes['href'] ?? '').trim();
      if (href.isEmpty || !_playLink.hasMatch(href)) continue;
      final lower = href.toLowerCase();
      if (lower.startsWith('javascript') ||
          lower.startsWith('#') ||
          lower.startsWith('mailto') ||
          lower.startsWith('data:')) {
        continue;
      }
      if (!seenLinks.add(href)) continue;
      final anchorTitle = _elementText(anchor);
      if (anchorTitle.contains('APP') || anchorTitle.contains('下载')) continue;
      var number = i + 1;
      final digitMatch = RegExp(r'(\d+)').firstMatch(anchorTitle);
      if (digitMatch != null) {
        number = int.tryParse(digitMatch.group(1)!) ?? i + 1;
      }
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: href,
          title: anchorTitle.isNotEmpty ? anchorTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    if (indexed.isEmpty) {
      throw StateError('未解析到分集列表');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  static String _jsUnescape(String value) {
    var out = value;
    out = out.replaceAllMapped(RegExp(r'%u([0-9a-fA-F]{4})'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    try {
      return Uri.decodeComponent(out);
    } catch (_) {
      return out.replaceAllMapped(RegExp(r'%([0-9a-fA-F]{2})'), (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      });
    }
  }

  static String _decryptPlayerUrl(String raw, String encrypt) {
    switch (encrypt) {
      case '1':
        return _jsUnescape(raw);
      case '2':
        try {
          return _jsUnescape(utf8.decode(base64Decode(raw)));
        } catch (_) {
          if (raw.contains('%')) {
            try {
              final unescaped = Uri.decodeComponent(raw);
              if (unescaped != raw) {
                return _jsUnescape(utf8.decode(base64Decode(unescaped)));
              }
            } catch (_) {}
          }
          return raw;
        }
      default:
        return raw;
    }
  }

  static String parsePlayerUrl(String body) {
    final playerMatch = RegExp(
      r'player_(?:aaaa|data)\s*=\s*(\{.*?\})\s*(?:</script>|;|$)',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    String? fieldUrl;
    String encrypt = '';
    if (playerMatch != null) {
      var blob = playerMatch.group(1)!.replaceAll(r'\/', '/');
      final urlMatch = RegExp(
        r'"url"\s*:\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(blob);
      if (urlMatch != null) fieldUrl = urlMatch.group(1);
      final encryptMatch = RegExp(
        r'"encrypt"\s*:\s*"?([0-9])"?',
        caseSensitive: false,
      ).firstMatch(blob);
      if (encryptMatch != null) encrypt = encryptMatch.group(1)!;
      if (fieldUrl != null) {
        final decrypted = _decryptPlayerUrl(fieldUrl, encrypt);
        if (decrypted.toLowerCase().startsWith('http')) return decrypted;
      }
    }
    for (final pattern in [
      RegExp(r'''\$\.url\s*=\s*"([^"]+)"''', caseSensitive: false),
      RegExp(
        r'"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"',
        caseSensitive: false,
      ),
      RegExp(
        r'''(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)''',
        caseSensitive: false,
      ),
    ]) {
      final match = pattern.firstMatch(body);
      if (match != null) return match.group(1)!.replaceAll(r'\/', '/');
    }
    if (fieldUrl != null) {
      return _decryptPlayerUrl(fieldUrl, encrypt);
    }
    final iframeMatch = RegExp(
      r'<iframe[^>]*?[?&]url=([A-Za-z0-9+/]{20,}={0,2})',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(body);
    if (iframeMatch != null) {
      var encoded = iframeMatch.group(1)!;
      try {
        final padded =
            encoded + '=' * ((4 - encoded.length % 4) % 4);
        final decoded = utf8.decode(base64Decode(padded));
        for (final candidate in decoded.split(',')) {
          if (candidate.trim().toLowerCase().startsWith('http')) {
            return candidate.trim();
          }
        }
      } catch (_) {}
    }
    return '';
  }

  String _catalogUrl(String categoryId, int page) {
    final pageSafe = page < 1 ? 1 : page;
    final category = categoryId == 'all' ? '' : categoryId;
    switch (siteId) {
      case 'huaguo':
        if (pageSafe <= 1 && category.isEmpty) return '$baseUrl/';
        final tid = category.isEmpty ? '27' : category;
        return '$baseUrl/search.html?page=$pageSafe&searchtype=5&tid=${Uri.encodeComponent(tid)}&year=';
      case 'faguo':
        if (category.isEmpty) return '$baseUrl/xzyxvt/${pageSafe}zmn.html';
        if (!category.contains('zmn')) {
          throw StateError('发果分类无效');
        }
        return '$baseUrl${category.split('zmn').first}${pageSafe}zmn.html';
      case 'wuguo':
        if (category.isEmpty) return '$baseUrl/';
        final trimmed = category.endsWith('.html')
            ? category.substring(0, category.length - 5)
            : category;
        return '$baseUrl$trimmed/page/$pageSafe.html';
      case 'wangguo':
        if (category.isEmpty) {
          return '$baseUrl/show/duanju-----------.html';
        }
        return '$baseUrl${category.split('---.html').first}$pageSafe---.html';
      default:
        return '$baseUrl/';
    }
  }

  List<String> _detailCandidates(String seriesId) {
    switch (siteId) {
      case 'faguo':
        return [
          '$baseUrl/xzyxvd/$seriesId.html',
          '$baseUrl/detail/$seriesId.html',
          '$baseUrl/voddetail/$seriesId.html',
        ];
      case 'wuguo':
        return [
          '$baseUrl/index.php/vod/detail/id/$seriesId.html',
          '$baseUrl/dramaDetail/$seriesId.html',
          '$baseUrl/detail/$seriesId.html',
        ];
      case 'wangguo':
        return [
          '$baseUrl/vod/$seriesId.html',
          '$baseUrl/index.php/vod/detail/id/$seriesId.html',
          '$baseUrl/detail/$seriesId.html',
        ];
      case 'huaguo':
        return [
          '$baseUrl/zywview/$seriesId.html',
          '$baseUrl/zywdetail/$seriesId.html',
          '$baseUrl/detail/$seriesId.html',
        ];
      default:
        return [
          '$baseUrl/detail/$seriesId.html',
          '$baseUrl/voddetail/$seriesId.html',
          '$baseUrl/index.php/vod/detail/id/$seriesId.html',
        ];
    }
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    if (siteId == 'huaguo') {
      return const [DramaSiteCategory('27', '短剧')];
    }
    return const [DramaSiteCategory('all', '全部')];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final url = _catalogUrl(categoryId, page);
    if (_useWebFetch) {
      final items = parseCatalog(await _effectiveWebFetch!(url), baseUrl);
      return DramaSiteCatalogPage(items: items, hasMore: items.isNotEmpty);
    }
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('目录 HTTP ${response.statusCode}');
    }
    final items = parseCatalog(response.body, baseUrl);
    return DramaSiteCatalogPage(items: items, hasMore: items.isNotEmpty);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    StateError? lastError;
    for (final url in _detailCandidates(seriesId)) {
      String body;
      if (_useWebFetch) {
        try {
          body = await _effectiveWebFetch!(url);
        } catch (e) {
          lastError = StateError(e.toString());
          continue;
        }
      } else {
        http.Response response;
        try {
          response = await _client.get(
            Uri.parse(url),
            headers: {'Referer': '$baseUrl/'},
          );
        } catch (e) {
          // 单个候选地址网络中断（如连接被服务端掐断）不能断掉整个详情查找，
          // 记下错误继续试下一个候选地址。
          lastError = StateError(e.toString());
          continue;
        }
        if (response.statusCode != 200) {
          lastError = StateError('详情 HTTP ${response.statusCode}');
          continue;
        }
        body = response.body;
      }
      try {
        final parsed = parseDetail(body, seriesId);
        return DramaSiteDetail(
          id: seriesId,
          title: parsed.title,
          cover: parsed.cover.isEmpty
              ? ''
              : _resolve(baseUrl, parsed.cover),
          episodes: [
            for (final episode in parsed.episodes)
              DramaSiteEpisode(
                videoId: _resolve(baseUrl, episode.videoId),
                title: episode.title,
                seriesId: seriesId,
              ),
          ],
        );
      } catch (e) {
        lastError = StateError(e.toString());
      }
    }
    throw lastError ?? StateError('未找到该剧的详情页');
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final String body;
    if (_useWebFetch) {
      body = await _effectiveWebFetch!(episode.videoId);
    } else {
      final response = await _client.get(
        Uri.parse(episode.videoId),
        headers: {'Referer': '$baseUrl/'},
      );
      if (response.statusCode != 200) {
        throw StateError('播放页 HTTP ${response.statusCode}');
      }
      body = response.body;
    }
    var url = parsePlayerUrl(body);
    if (url.contains('#')) {
      for (final part in url.split('#')) {
        if (part.trim().toLowerCase().startsWith('http')) {
          url = part.trim();
          break;
        }
      }
    }
    if (url.isEmpty || !url.toLowerCase().startsWith('http')) {
      throw StateError('播放页未找到播放地址');
    }
    return DramaPlaySource(url: url);
  }

  String _searchUrl(String query) {
    final encoded = Uri.encodeComponent(query);
    switch (siteId) {
      case 'huaguo':
        return '$baseUrl/search.html?searchword=${Uri.encodeQueryComponent(query)}';
      case 'faguo':
        return '$baseUrl/xzyxvc/$encoded-wdyswzqun1num.html';
      case 'wuguo':
        return '$baseUrl/index.php/vod/search/page/1/wd/$encoded.html';
      case 'wangguo':
        return '$baseUrl/search/$encoded----------1---.html';
      default:
        throw StateError('未知的苹果 CMS 站点');
    }
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final url = _searchUrl(query);
    if (_useWebFetch) {
      return parseCatalog(await _effectiveWebFetch!(url), baseUrl);
    }
    final response = await _client.get(
      Uri.parse(url),
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('搜索 HTTP ${response.statusCode}');
    }
    return parseCatalog(response.body, baseUrl);
  }
}

/// 牛果：响应是 Base64 + AES-ECB，密钥取请求地址前 16 字节；
/// 分集播放走解析服务，详情里的链接只是待解析地址。
class NiuguoContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://ccc.chaojichaojichanga.com:35620';
  static const _parseBases = [
    'http://ccs.jshh.gzbaoxian.com',
    'http://101.42.92.211:5560',
  ];

  final http.Client _client;

  NiuguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

  static List<int> _keyFor(String requestUri) {
    final key = List<int>.filled(16, 0);
    final bytes = utf8.encode(requestUri);
    key.setRange(0, bytes.length > 16 ? 16 : bytes.length, bytes);
    return key;
  }

  static Map<String, dynamic> decryptResponse(String body, String requestUri) {
    final encoded = body.trim();
    if (encoded.isEmpty) {
      throw StateError('牛果返回了空响应');
    }
    List<int> raw;
    try {
      raw = base64Decode(encoded);
    } catch (_) {
      final padded = encoded + '=' * ((4 - encoded.length % 4) % 4);
      raw = base64Decode(padded);
    }
    final plain = aesEcbDecrypt(raw, _keyFor(requestUri));
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map<String, dynamic>) {
      throw StateError('牛果响应格式无法识别');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _fetch(String path, Map<String, String> query) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final requestUri = uri.path + (uri.query.isNotEmpty ? '?${uri.query}' : '');
    final response = await _client.get(
      uri,
      headers: {'Referer': '$baseUrl/'},
    );
    if (response.statusCode != 200) {
      throw StateError('牛果请求 HTTP ${response.statusCode}');
    }
    return decryptResponse(response.body, requestUri);
  }

  static List<DramaSiteItem> parseCatalog(Map<String, dynamic> response) {
    dynamic rows = response['list'] ?? response['data'];
    if (rows is Map<String, dynamic>) rows = rows['list'];
    if (rows is! List) return const [];
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _firstString(node, ['vod_id', 'vodId', 'id']);
      if (id.isEmpty) continue;
      final title = _firstString(node, ['vod_name', 'vodName', 'title']);
      if (title.isEmpty) continue;
      final count = _firstInt(node, ['vod_total', 'total', 'episodes']);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(node, ['vod_pic', 'vodPic', 'cover']),
          remark: _firstString(node, ['vod_remarks', 'vodRemarks']).isNotEmpty
              ? _firstString(node, ['vod_remarks', 'vodRemarks'])
              : (count > 0 ? '共$count集' : ''),
        ),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(
    Map<String, dynamic> response,
    String seriesId,
  ) {
    var node = response;
    final nested = _asMap(response['data']);
    if (nested.isNotEmpty) node = nested;
    final listed = node['list'];
    if (listed is List && listed.isNotEmpty) {
      node = _asMap(listed.first);
    }
    final title = _firstString(node, ['vod_name', 'vodName', 'title']);
    final cover = _firstString(node, ['vod_pic', 'vodPic', 'cover']);
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    final seenNumbers = <int>{};
    void addEpisode(String episodeTitle, String link) {
      if (link.isEmpty) return;
      var number = indexed.length + 1;
      final digitMatch = RegExp(r'(\d+)').firstMatch(episodeTitle);
      if (digitMatch != null) {
        number = int.tryParse(digitMatch.group(1)!) ?? number;
      }
      if (!seenNumbers.add(number)) return;
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: link,
          title: episodeTitle.isNotEmpty ? episodeTitle : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }

    final sources = node['sources'];
    if (sources is List) {
      for (final source in sources) {
        final episodes = _asMap(source)['episodes'];
        if (episodes is! List) continue;
        for (final entry in episodes) {
          final episode = _asMap(entry);
          addEpisode(
            _firstString(episode, ['name', 'title']),
            _firstString(episode, ['url', 'playUrl']),
          );
        }
      }
    }
    if (indexed.isEmpty) {
      final playUrls = node['vod_play_url'];
      if (playUrls is List) {
        for (final entry in playUrls) {
          for (final line in entry.toString().split('#')) {
            final cut = line.indexOf('\$');
            if (cut < 0) continue;
            addEpisode(
              line.substring(0, cut).trim(),
              line.substring(cut + 1).trim(),
            );
          }
        }
      }
    }
    if (indexed.isEmpty) {
      throw StateError('牛果未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    // 服务端按 class=1/2/4/5 查多为空，不带 class 才能拿到内容；
    // 把“全部”放首位，打开牛果默认就有内容，不再一打开就是暂无内容。
    DramaSiteCategory('', '全部'),
    DramaSiteCategory('1', '短剧'),
    DramaSiteCategory('2', '电影'),
    DramaSiteCategory('3', '电视剧'),
    DramaSiteCategory('4', '动漫'),
    DramaSiteCategory('5', '综艺'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final response = await _fetch('/list', {
      'class': categoryId.isEmpty ? '' : categoryId,
      'order': '最新',
      'type_id': '5',
      'area': '',
      'year': '',
      'state': '',
      'wd': '',
      'page': '${page < 1 ? 1 : page}',
    });
    final items = parseCatalog(response);
    return DramaSiteCatalogPage(items: items, hasMore: items.isNotEmpty);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final response = await _fetch('/detail', {'vod_id': seriesId});
    return parseDetail(response, seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    StateError? lastError;
    for (final base in _parseBases) {
      for (final script in ['qy.php', 'dj.php']) {
        final uri = Uri.parse('$base/jx/$script').replace(
          queryParameters: {'url': episode.videoId},
        );
        try {
          final response = await _client.get(
            uri,
            headers: {'Referer': '$base/'},
          );
          if (response.statusCode != 200) continue;
          final decoded = jsonDecode(response.body);
          if (decoded is! Map<String, dynamic>) continue;
          final url = _firstString(decoded, ['url']);
          if (url.isNotEmpty) return DramaPlaySource(url: url);
          lastError = StateError('牛果解析服务未返回播放地址');
        } catch (e) {
          lastError = StateError(e.toString());
        }
      }
    }
    throw lastError ?? StateError('牛果未返回有效播放地址');
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final response = await _fetch('/list', {
      'class': '',
      'order': '最新',
      'type_id': '5',
      'area': '',
      'year': '',
      'state': '',
      'wd': query,
      'page': '1',
    });
    return parseCatalog(response);
  }
}

class _HuangdouApiError implements Exception {
  const _HuangdouApiError(this.message);

  final String message;

  @override
  String toString() => message;
}

class HuangdouContentClient implements DramaSiteContentClient {
  static const baseUrl = 'https://tideember.cc';
  static const fallbackUrl = 'https://xqjurgek.top';
  static const _platformKey = '7961beb44246e3012ce228d6b5ced05a';

  final http.Client _client;
  final String _sessionId;
  String _lastHost = baseUrl;

  HuangdouContentClient([http.Client? client])
    : _client = client ?? http.Client(),
      _sessionId = _randomHex(16);

  static String _randomHex(int bytes) {
    final random = math.Random.secure();
    final raw = List<int>.generate(bytes, (_) => random.nextInt(256));
    return raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _uuidLike() {
    final raw = _randomHex(16);
    return '${raw.substring(0, 8)}-${raw.substring(8, 12)}-'
        '${raw.substring(12, 16)}-${raw.substring(16, 20)}-${raw.substring(20)}';
  }

  static List<int> _keyFor(String rid) {
    final clean = rid.replaceAll('-', '');
    final message = <int>[];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      message.add(int.parse(clean.substring(i, i + 2), radix: 16));
    }
    final hmac = Hmac(sha256, utf8.encode(_platformKey));
    return hmac.convert(message).bytes;
  }

  static Map<String, dynamic> _dataMap(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      final data = decoded['data'];
      if (data is Map<String, dynamic>) return data;
      return decoded;
    }
    return const {};
  }

  Future<dynamic> _callOnce(
    String host,
    String path,
    Map<String, dynamic> data,
  ) async {
    final rid = _uuidLike();
    final key = _keyFor(rid);
    final random = math.Random.secure();
    final iv = List<int>.generate(16, (_) => random.nextInt(256));
    final plain = jsonEncode({
      'token': '',
      'deviceId': _sessionId,
      'data': data,
    });
    final gzipped = GZipEncoder().encode(utf8.encode(plain));
    final cipher = aesCbcEncrypt(gzipped, key, iv);
    final body = [...iv, ...cipher];
    final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
        .toString();
    final signRaw = 'Dart|$_sessionId|$rid|$timestamp|$path';
    final sign =
        '${sha256.convert(utf8.encode(signRaw))}-$timestamp';
    final response = await _client.post(
      Uri.parse('$host/api$path'),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
        'Accept': '*/*',
        'Origin': host,
        'Referer': '$host/home',
        'Content-Type': 'application/octet-stream',
        'version': '2.0.0',
        'deviceType': 'web',
        'requestId': rid,
        'sessionId': _sessionId,
        'time': timestamp,
        'sign': sign,
      },
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('黄豆请求 HTTP ${response.statusCode}');
    }
    final blob = response.bodyBytes;
    dynamic decoded;
    var direct = false;
    try {
      decoded = jsonDecode(utf8.decode(blob));
      direct = true;
    } catch (_) {}
    if (!direct) {
      if (blob.length < 32) {
        throw StateError('黄豆响应过短');
      }
      final plainBytes = aesCbcDecrypt(
        blob.sublist(16),
        key,
        blob.sublist(0, 16),
      );
      var plainText = plainBytes;
      if (plainText.length >= 2 &&
          plainText[0] == 0x1f &&
          plainText[1] == 0x8b) {
        plainText = GZipDecoder().decodeBytes(plainText);
      }
      decoded = jsonDecode(utf8.decode(plainText));
    }
    if (decoded is Map<String, dynamic>) {
      final status = _stringOf(decoded['status']);
      if (status.isNotEmpty && status != 'y') {
        final code = _stringOf(
          decoded['errorCode'] ?? decoded['error_code'] ?? decoded['code'],
        );
        final message = _firstString(decoded, ['msg', 'message', 'error']);
        throw _HuangdouApiError(
          '黄豆接口拒绝请求${code.isNotEmpty ? '($code)' : ''}: '
          '${message.isNotEmpty ? message : status}',
        );
      }
    }
    _lastHost = host;
    return decoded;
  }

  Future<dynamic> _call(String path, Map<String, dynamic> data) async {
    try {
      return await _callOnce(baseUrl, path, data);
    } on _HuangdouApiError {
      rethrow;
    } catch (_) {
      return _callOnce(fallbackUrl, path, data);
    }
  }

  static List<DramaSiteItem> parseCatalog(dynamic decoded) {
    List<dynamic>? rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map<String, dynamic>) {
      for (final key in ['list', 'items', 'data']) {
        final value = decoded[key];
        if (value is List) {
          rows = value;
          break;
        }
        if (value is Map<String, dynamic>) {
          for (final inner in ['list', 'items', 'data']) {
            if (value[inner] is List) {
              rows = value[inner] as List<dynamic>;
              break;
            }
          }
        }
        if (rows != null) break;
      }
    }
    if (rows == null) return const [];
    final items = <DramaSiteItem>[];
    final seen = <String>{};
    for (final entry in rows) {
      final node = _asMap(entry);
      var id = _firstString(node, ['id', 'drama_id']);
      if (id.startsWith('rp_')) id = id.substring(3);
      if (id.isEmpty || !seen.add(id)) continue;
      final title = _firstString(node, ['name', 'title', 't']);
      if (title.isEmpty) continue;
      var remark = _firstString(node, ['update_label', 'corner']);
      if (remark.isEmpty) {
        final count = _firstString(node, ['episode_count']);
        if (count.isNotEmpty) remark = '全$count集';
      }
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _firstString(node, ['img_y', 'img_x', 'img', 'cover', 'pic']),
          remark: remark,
        ),
      );
    }
    return items;
  }

  static DramaSiteDetail parseDetail(dynamic decoded, String seriesId) {
    final node = _dataMap(decoded);
    final title = _firstString(node, ['name', 'title', 't']);
    final cover = _firstString(node, ['img_y', 'img_x', 'img', 'cover', 'pic']);
    final rawList = node['episodes'];
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    if (rawList is List) {
      for (var i = 0; i < rawList.length; i++) {
        final episode = _asMap(rawList[i]);
        var number = _firstInt(episode, ['seq', 'episode', 'ep']);
        if (number <= 0) number = i + 1;
        final episodeTitle = _firstString(episode, ['name', 'title']);
        indexed.add((
          number: number,
          episode: DramaSiteEpisode(
            videoId: '$number',
            title: episodeTitle.isNotEmpty
                ? episodeTitle
                : '第$number集',
            seriesId: seriesId,
          ),
        ));
      }
    }
    if (indexed.isEmpty) {
      final count = _firstInt(node, ['episode_count', 'free_episodes']);
      for (var i = 1; i <= count; i++) {
        indexed.add((
          number: i,
          episode: DramaSiteEpisode(
            videoId: '$i',
            title: '第$i集',
            seriesId: seriesId,
          ),
        ));
      }
    }
    if (indexed.isEmpty) {
      throw StateError('黄豆未返回可播放分集');
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
      episodes: [for (final entry in indexed) entry.episode],
    );
  }

  static bool _isPreview(Map<String, dynamic> data, String media) {
    final flag = _stringOf(
      data['is_preview'] ?? data['isPreview'],
    ).toLowerCase();
    if (flag == 'true' || flag == '1' || flag == 'y') return true;
    final preview = _firstString(data, ['preview_m3u8', 'preview_url']);
    if (preview.isNotEmpty && media.isNotEmpty && preview == media) {
      return true;
    }
    final lower = media.toLowerCase();
    return lower.endsWith('/preview.mp4') ||
        lower.endsWith('/preview.m3u8') ||
        lower == 'preview.mp4' ||
        lower == 'preview.m3u8';
  }

  @override
  Future<List<DramaSiteCategory>> categories() async => const [
    DramaSiteCategory('all', '全部'),
  ];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final decoded = await _call('/drama/list', {
      'page': '${page < 1 ? 1 : page}',
      'page_size': '30',
    });
    final items = parseCatalog(decoded);
    return DramaSiteCatalogPage(items: items, hasMore: items.length >= 30);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final id = seriesId.startsWith('rp_')
        ? seriesId.substring(3)
        : seriesId;
    final decoded = await _call('/drama/detail', {'id': id});
    return parseDetail(decoded, seriesId);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final decoded = await _call('/drama/list', {
      'keywords': query,
      'page': '1',
      'page_size': '50',
    });
    return parseCatalog(decoded);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final seq = int.tryParse(episode.videoId) ?? 1;
    final id = episode.seriesId.startsWith('rp_')
        ? episode.seriesId.substring(3)
        : episode.seriesId;
    final decoded = await _call('/drama/play', {'id': id, 'seq': '$seq'});
    final data = _dataMap(decoded);
    var media = _firstString(data, ['m3u8', 'url', 'play_url', 'playUrl']);
    if (_isPreview(data, media)) {
      throw StateError('黄豆仅提供试看，未取得该集正片；不会把试看内容当作完整分集');
    }
    if (media.isEmpty) {
      final fallbackUrl =
          '$_lastHost/api/drama/hls/${Uri.encodeComponent(id)}/$seq/play.m3u8?line=free';
      final response = await _client.get(
        Uri.parse(fallbackUrl),
        headers: {'Referer': '$_lastHost/home'},
      );
      if (response.statusCode == 200 &&
          response.body.trimLeft().startsWith('#EXTM3U')) {
        media = fallbackUrl;
      } else {
        throw StateError('黄豆未提供有效的播放地址，备用播放列表也不可用');
      }
    }
    if (!media.toLowerCase().startsWith('http')) {
      final base = '$_lastHost/';
      try {
        media = Uri.parse(base).resolve(media).toString();
      } catch (_) {}
    }
    final keyHex = huangdouHlsKeyHex(_stringOf(data['hls_key']));
    return DramaPlaySource(url: media, keyHex: keyHex);
  }
}

/// 还留在 Rust 核心里的午夜视频站 id（批量转站后只剩 hgdj/hgdj58/hgdjv
/// 3 站；删站前这里是 201 站，其余 198 站已转成内嵌版 py/jar，另有
/// yaguo 那个模块也已删、但它从不在这份分档表里）。
/// 只用于核心路由（dramaSiteContentClient）与影视区核心站表
/// （videoZoneSites）；成人分档不再读这里，改读 adultVideoSiteOrder
/// （分档登记顺序，删核心前的顺序，见 cultivation.dart）。
const coreVideoSiteIds = <String>{
  'hgdjv',
  'hgdj',
  'hgdj58',
};

/// 只走核心的午夜视频站：没有 Dart 版客户端，核心报错时直接把错
/// 抛出去，界面如实显示，不兜底、不冒充（与阅读区
/// CoreReadingContentClient 同款：核心未起、站未进核心、返回格式
/// 不对时都不静默回空）。
class _CoreOnlyFallback implements DramaSiteContentClient {
  const _CoreOnlyFallback();

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      throw StateError('该站只走核心，核心未返回分类');

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async =>
      throw StateError('该站只走核心，核心未返回目录');

  @override
  Future<DramaSiteDetail> detail(String seriesId) async =>
      throw StateError('该站只走核心，核心未返回详情');

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async =>
      throw StateError('该站只走核心，核心未返回播放地址');

  @override
  Future<List<DramaSiteItem>> search(String query) async =>
      throw StateError('该站只走核心，核心未返回搜索结果');
}

DramaSiteContentClient? dramaSiteContentClient(String siteId) {
  if (siteId == 'original') return OriginalContentClient();
  if (siteId == 'huangju') {
    return CoreDramaContentClient(
      siteId: 'huangju',
      fallback: HuangjuContentClient(),
    );
  }
  if (siteId == 'yeguo') {
    return CoreDramaContentClient(
      siteId: 'yeguo',
      fallback: YeguoContentClient(),
    );
  }
  if (siteId == 'hgtvmirror') return HgtvMirrorContentClient();
  if (siteId == 'hongguo') return HongguoContentClient();
  if (siteId == 'hgtv') return HgtvContentClient();
  if (siteId == 'fanguo') return FanguoContentClient();
  if (siteId == 'guanguo') return GuanguoContentClient();
  if (siteId == 'heguo') return HeguoContentClient();
  if (siteId == 'xingguo') return XingguoContentClient();
  if (siteId == 'maoguo') return MaoguoContentClient();
  if (siteId == 'yaguo') return CoreDramaContentClient();
  if (siteId == 'niuguo') {
    return CoreDramaContentClient(
      siteId: 'niuguo',
      fallback: NiuguoContentClient(),
    );
  }
  if (siteId == 'huangdou') {
    return CoreDramaContentClient(
      siteId: 'huangdou',
      fallback: HuangdouContentClient(),
    );
  }
  if (siteId == 'huangdou_yh') return HuangdouContentClient();
  if (coreVideoSiteIds.contains(siteId)) {
    return CoreDramaContentClient.coreOnly(siteId: siteId);
  }
  if (siteId == 'huaguo') {
    return MaccmsContentClient('huaguo', 'https://www.zywest263.com');
  }
  if (siteId == 'faguo') {
    return MaccmsContentClient('faguo', 'https://www.xzyx168.com');
  }
  if (siteId == 'wuguo') {
    return MaccmsContentClient('wuguo', 'https://www.duanju55.com');
  }
  if (siteId == 'wangguo') {
    return MaccmsContentClient('wangguo', 'https://www.duanju2.com');
  }
  if (coreReadingSiteIds.contains(siteId)) {
    return CoreReadingContentClient(siteId: siteId);
  }
  return null;
}

/// 影视区走核心的客户端：请求发往核心的影视区路由，返回的 JSON 与
/// Dart 模型一一对应，这里只做直译。siteId 与 Rust 影视区路由的
/// site_id 一一对应（芽果首个进核心，现已扩到剧果/黄豆/野果/牛果）。
///
/// 核心一旦报错（未进核心的站、核心未起、返回格式不对），一律回退到
/// 本站的原 Dart 版客户端——原始实现不动、仍在树里兜底，核心侧手机
/// 验通后再摘掉回退。
class CoreDramaContentClient implements DramaSiteContentClient {
  /// 核心侧站点 id（与 Rust 影视区路由的 site_id 一一对应）。
  final String siteId;

  final ApiClient _api;
  final DramaSiteContentClient _fallback;

  static DramaSiteContentClient _defaultFallback(
    String siteId, [
    http.Client? client,
  ]) {
    switch (siteId) {
      case 'huangju':
        return HuangjuContentClient(client: client);
      case 'yeguo':
        return YeguoContentClient(client: client);
      case 'niuguo':
        return NiuguoContentClient(client);
      case 'huangdou':
        return HuangdouContentClient(client);
      case 'yaguo':
        return YaguoContentClient(client);
      default:
        throw ArgumentError('未知核心站点 $siteId，未给回退客户端');
    }
  }

  CoreDramaContentClient({
    this.siteId = 'yaguo',
    ApiClient? api,
    DramaSiteContentClient? fallback,
    http.Client? fallbackClient,
  })  : _api = api ?? ApiClient.instance,
        _fallback = fallback ?? _defaultFallback(siteId, fallbackClient);

  /// 只走核心的站用：回退就是 [_CoreOnlyFallback]，没有真实 Dart
  /// 客户端；核心任何错都不走回退、直接把原错抛出去（超时/断网换成
  /// 「加载超时，请重试」，其余错原样 rethrow，见 [_coreOrFallback]），
  /// 不兜底、不冒充。工厂里核心站走这个构造，测试也用它。
  CoreDramaContentClient.coreOnly({required this.siteId, ApiClient? api})
    : _api = api ?? ApiClient.instance,
      _fallback = const _CoreOnlyFallback();

  List<DramaSiteItem> _itemsOf(dynamic rows) {
    if (rows is! List) throw StateError('核心目录格式错误');
    return [
      for (final entry in rows)
        DramaSiteItem(
          id: _stringOf(_asMap(entry)['id']),
          title: _stringOf(_asMap(entry)['title']),
          cover: _stringOf(_asMap(entry)['cover']),
          remark: _stringOf(_asMap(entry)['remark']),
        ),
    ];
  }

  /// 该站是不是只走核心（回退是 [_CoreOnlyFallback]，没有真实 Dart
  /// 客户端）：是才走下面的超时直抛分支；huangju/yeguo/niuguo/
  /// huangdou/yaguo 有真实回退客户端，保持原有回退行为不动。
  bool get _coreOnly => _fallback is _CoreOnlyFallback;

  /// 超时/断网错：Dart 超时（ApiClient 的 [BackendRequestAborted]
  /// timedOut、widget 层 `.timeout()` 的 [TimeoutException]）、
  /// Socket/HTTP 客户端错。取消（timedOut 为 false 的
  /// [BackendRequestAborted]）不算——取消不是超时，不该报超时。
  static bool _isTimeoutOrNetwork(Object error) =>
      error is TimeoutException ||
      (error is BackendRequestAborted && error.timedOut) ||
      error is SocketException ||
      error is http.ClientException;

  /// 核心先行，失败再回退——只在核心站上加一条例外：核心站（回退是
  /// [_CoreOnlyFallback]，没有真实 Dart 客户端）任何错都不再走回退，
  /// 直接把原错抛出去，界面显示的就是核心/传输返回的真实原因：
  /// 超时/断网错先换成带 timedOut 的 [BackendRequestAborted]（文案
  /// 「加载超时，请重试」），其余错（核心未起、格式错、被墙拦等）原样
  /// rethrow，不再被回退的「该站只走核心，核心未返回…」盖住。
  /// 有真实回退客户端的站（huangju/yeguo/niuguo/huangdou/yaguo）
  /// 保持原有回退行为不动，任何错都仍走回退。
  ///
  /// 核心正常回空列表（items/categories/episodes 为空）不是错：
  /// 直接回空页/空列表，界面显示「暂无内容」类如实空态，不抛错。
  Future<T> _coreOrFallback<T>(
    Future<T> Function() core,
    Future<T> Function() fallback,
  ) async {
    try {
      return await core();
    } catch (error) {
      if (_coreOnly) {
        if (_isTimeoutOrNetwork(error)) {
          throw BackendRequestAborted('加载超时，请重试', timedOut: true);
        }
        rethrow;
      }
      return await fallback();
    }
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    return _coreOrFallback(() async {
      final payload = await _api.dramaCategories(siteId);
      final rows = payload['categories'];
      if (rows is! List) throw StateError('核心分类格式错误');
      return [
        for (final entry in rows)
          DramaSiteCategory(
            _stringOf(_asMap(entry)['id']),
            _stringOf(_asMap(entry)['name']),
          ),
      ];
    }, () => _fallback.categories());
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    return _coreOrFallback(() async {
      final payload = await _api.dramaCatalog(siteId, categoryId, page);
      return DramaSiteCatalogPage(
        items: _itemsOf(payload['items']),
        hasMore: payload['has_more'] == true,
      );
    }, () => _fallback.catalog(categoryId, page));
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    return _coreOrFallback(() async {
      final payload = await _api.dramaDetail(siteId, seriesId);
      final rows = payload['episodes'];
      if (rows is! List) throw StateError('核心详情格式错误');
      final extra = <String, String>{};
      for (final entry in _asMap(payload['extra']).entries) {
        extra[entry.key.toString()] = _stringOf(entry.value);
      }
      // 剧照不进 extra 字符串：列表 toString 会变成 "[url, url]"，
      // 单独走 stills 字段；详情顶层带 stills 的站也认。
      final stills = parseDetailStills(
        _asMap(payload['extra'])['stills'] ?? payload['stills'],
      );
      extra.remove('stills');
      return DramaSiteDetail(
        id: _stringOf(payload['id']),
        title: _stringOf(payload['title']),
        cover: _stringOf(payload['cover']),
        synopsis: _stringOf(payload['synopsis']),
        extra: extra,
        stills: stills,
        episodes: [
          for (final entry in rows)
            DramaSiteEpisode(
              videoId: _stringOf(_asMap(entry)['video_id']),
              title: _stringOf(_asMap(entry)['title']),
              seriesId: _stringOf(_asMap(entry)['series_id']),
            ),
        ],
      );
    }, () => _fallback.detail(seriesId));
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return _coreOrFallback(() async {
      final payload = await _api.dramaPlay(siteId, episode.videoId);
      final url = _stringOf(payload['url']);
      if (url.isEmpty) throw StateError('核心取流无地址');
      // 核心取流回的字典头原样带出：取流层凭它决定是否经本地媒体代理
      // 转接（见 drama_site_play 的 _proxyIfNeeded）。aisxpc 这类
      // 无后缀 HLS 代理地址就靠这个头进代理、由代理探到 HLS 后补
      // .m3u8 后缀，否则播放器会把它当 Progressive 流读 #EXTM3U
      // 而报“视频解析失败”。没回头的站不受影响。
      final headers = <String, String>{};
      for (final entry in _asMap(payload['headers']).entries) {
        final value = _stringOf(entry.value);
        if (entry.key.isNotEmpty && value.isNotEmpty) {
          headers[entry.key] = value;
        }
      }
      return DramaPlaySource(url: url, headers: headers);
    }, () => _fallback.playSource(episode));
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    return _coreOrFallback(() async {
      final payload = await _api.dramaSearch(siteId, query);
      return _itemsOf(payload['items']);
    }, () => _fallback.search(query));
  }
}

/// 阅读区走核心的客户端：请求发往核心的阅读区路由，返回的 JSON 与
/// Dart 模型一一对应，这里只做直译。siteId 与 Rust 阅读区路由的
/// site_id 一一对应（火蚁TV 内置 28 个阅读源，全部写进核心）。
///
/// 只有核心，没有回退：用户令阅读源只写核心，不走 Java、不走 py 内置
/// 种子，Dart 侧也不另写一套。所以核心报错（核心未起、站未进核心、
/// 返回格式不对）时直接把错抛出去，界面如实显示，不兜底、不冒充。
/// 取流回的字典头随 DramaPlaySource.headers 原样带出，取流层经本地
/// 媒体代理带上（与影视区同路）。
///
/// 注意：红果听书（hongguo）签名内核与 CENC 解密尚未移植，核心侧全
/// 动作都报错，不是这个客户端的问题，等签名补齐后不用改这里。
class CoreReadingContentClient implements DramaSiteContentClient {
  /// 核心侧站点 id（与 Rust 阅读区路由的 site_id 一一对应）。
  final String siteId;

  final ApiClient _api;

  CoreReadingContentClient({required this.siteId, ApiClient? api})
    : _api = api ?? ApiClient.instance;

  List<DramaSiteItem> _itemsOf(dynamic rows) {
    if (rows is! List) throw StateError('核心阅读目录格式错误');
    return [
      for (final entry in rows)
        DramaSiteItem(
          id: _stringOf(_asMap(entry)['id']),
          title: _stringOf(_asMap(entry)['title']),
          cover: _stringOf(_asMap(entry)['cover']),
          remark: _stringOf(_asMap(entry)['remark']),
        ),
    ];
  }

  Map<String, String> _headersOf(dynamic value) {
    if (value is! Map) return const {};
    return {
      for (final entry in value.entries)
        entry.key.toString(): _stringOf(entry.value),
    };
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final payload = await _api.readingCategories(siteId);
    final rows = payload['categories'];
    if (rows is! List) throw StateError('核心阅读分类格式错误');
    return [
      for (final entry in rows)
        DramaSiteCategory(
          _stringOf(_asMap(entry)['id']),
          _stringOf(_asMap(entry)['name']),
        ),
    ];
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final payload = await _api.readingCatalog(siteId, categoryId, page);
    return DramaSiteCatalogPage(
      items: _itemsOf(payload['items']),
      hasMore: payload['has_more'] == true,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final payload = await _api.readingDetail(siteId, seriesId);
    final rows = payload['episodes'];
    if (rows is! List) throw StateError('核心阅读详情格式错误');
    final extra = <String, String>{};
    for (final entry in _asMap(payload['extra']).entries) {
      extra[entry.key.toString()] = _stringOf(entry.value);
    }
    return DramaSiteDetail(
      id: _stringOf(payload['id']),
      title: _stringOf(payload['title']),
      cover: _stringOf(payload['cover']),
      synopsis: _stringOf(payload['synopsis']),
      extra: extra,
      episodes: [
        for (final entry in rows)
          DramaSiteEpisode(
            videoId: _stringOf(_asMap(entry)['video_id']),
            title: _stringOf(_asMap(entry)['title']),
            seriesId: _stringOf(_asMap(entry)['series_id']),
          ),
      ],
    );
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final payload = await _api.readingPlay(siteId, episode.videoId);
    final url = _stringOf(payload['url']);
    if (url.isEmpty) throw StateError('核心阅读取流无地址');
    return DramaPlaySource(
      url: url,
      headers: _headersOf(payload['header']),
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final payload = await _api.readingSearch(siteId, query);
    return _itemsOf(payload['items']);
  }
}

/// 核心阅读站 id（与 Rust 阅读区路由的 site_id 一一对应）。
/// 小说 14、漫画 11、听书 6，共 31 个（火蚁TV 内置全部）。
const Set<String> coreReadingSiteIds = {
  // 小说
  '1000novel', '69story', 'aabook', 'buliang', 'canovel', 'cheniyo',
  'cjg', 'h528', 'hwg4', 'jywx2', 'lbwen', 'ssxxs', 'ylxs', 'yinse',
  // 漫画
  '55comics', 'csmanhua', 'dongmanla', 'ho5ho', 'kmh001', 'kuaikan',
  'kxmanhua', 'mhbl', 'modu18', 'nnhanman', 'tencent',
  // 听书
  'tingyou', 'hsvoice31', 'hysxs', 'ximalaya', 'hongguo', 'shuyinfm',
};

/// 核心阅读站的类型：novel（小说）、comic（漫画）、audio（听书）。
const Map<String, String> coreReadingKinds = {
  '1000novel': 'novel', '69story': 'novel', 'aabook': 'novel',
  'buliang': 'novel', 'canovel': 'novel', 'cheniyo': 'novel',
  'cjg': 'novel', 'h528': 'novel', 'hwg4': 'novel', 'jywx2': 'novel',
  'lbwen': 'novel', 'ssxxs': 'novel', 'ylxs': 'novel', 'yinse': 'novel',
  '55comics': 'comic', 'csmanhua': 'comic', 'dongmanla': 'comic',
  'ho5ho': 'comic', 'kmh001': 'comic', 'kuaikan': 'comic',
  'kxmanhua': 'comic', 'mhbl': 'comic', 'modu18': 'comic',
  'nnhanman': 'comic', 'tencent': 'comic',
  'tingyou': 'audio', 'hsvoice31': 'audio', 'hysxs': 'audio',
  'ximalaya': 'audio', 'hongguo': 'audio', 'shuyinfm': 'audio',
};

/// 核心阅读站的显示名（站名取 Rust 模块头里的站名；成人站按规则
/// 带 🔞 前缀）。只做显示标签：站表本身仍以 coreReadingSiteIds
/// 为准，没进这张表的站用 id 当名显示，不会因此漏站。
const Map<String, String> coreReadingSiteNames = {
  // 小说
  '1000novel': '🔞1000novel', '69story': '🔞69story', 'aabook': 'aabook',
  'buliang': '🔞不良小说', 'canovel': '🔞canovel', 'cheniyo': '🔞cheniyo',
  'cjg': '🔞cjg', 'h528': '🔞h528', 'hwg4': '🔞hwg4', 'jywx2': '🔞jywx2',
  'lbwen': '🔞lbwen', 'ssxxs': '🔞ssxxs', 'ylxs': 'ylxs',
  'yinse': '🔞yinse',
  // 漫画
  '55comics': '🔞55comics', 'csmanhua': '🔞csmanhua',
  'dongmanla': '动漫啦', 'ho5ho': '🔞ho5ho', 'kmh001': 'kmh001',
  'kuaikan': '快看漫画', 'kxmanhua': 'kxmanhua', 'mhbl': 'mhbl',
  'modu18': '🔞modu18', 'nnhanman': 'nnhanman', 'tencent': '腾讯动漫',
  // 听书
  'tingyou': '听友听书', 'hsvoice31': '🔞黄色有声小说',
  'hysxs': '🔞H有声小说', 'ximalaya': '喜马拉雅', 'hongguo': '红果听书',
  'shuyinfm': '书音FM',
};

/// 核心阅读站里的成人站（按 py 源内自带成人标识判定，与站名猜测无关）。
/// 小说 12、漫画 4、听书 2，共 18 个；其余 13 个为非成人。
const Set<String> coreAdultReadingSiteIds = {
  // 小说 12
  '1000novel', '69story', 'buliang', 'canovel', 'cheniyo', 'cjg',
  'h528', 'hwg4', 'jywx2', 'lbwen', 'ssxxs', 'yinse',
  // 漫画 4
  '55comics', 'csmanhua', 'ho5ho', 'modu18',
  // 听书 2
  'hsvoice31', 'hysxs',
};

/// 阅读区核心站的客户端工厂：核心站 id 进，核心阅读客户端出；
/// 不是核心阅读站时回 null（不兜底、不冒充）。
DramaSiteContentClient? readingSiteContentClient(String siteId) {
  if (!coreReadingSiteIds.contains(siteId)) return null;
  return CoreReadingContentClient(siteId: siteId);
}
