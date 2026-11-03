import 'dart:convert';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_sites.dart';

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
  final List<DramaSiteEpisode> episodes;

  const DramaSiteDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.episodes,
  });
}

class DramaSiteCatalogPage {
  final List<DramaSiteItem> items;
  final bool hasMore;

  const DramaSiteCatalogPage({required this.items, required this.hasMore});
}

abstract class DramaSiteContentClient {
  Future<List<DramaSiteCategory>> categories();
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page);
  Future<DramaSiteDetail> detail(String seriesId);
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode);
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
    return DramaSiteDetail(
      id: seriesId,
      title: title,
      cover: cover,
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
}

/// 红果网页端：与红果镜像同域名同详情页，但分类页取 router 数据的
/// recommendList，不取卡片 HTML；播放取播放页 video_player_info 的
/// 地址列表，取不到才退 360p 直链。App 签名线不在此，网页线能播就进。
class HongguoContentClient implements DramaSiteContentClient {
  static const baseUrl = HgtvMirrorContentClient.baseUrl;

  final http.Client _client;

  HongguoContentClient([http.Client? client])
    : _client = client ?? http.Client();

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
    );
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
    return DramaPlaySource(url: direct360);
  }
}

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
}

DramaSiteContentClient? dramaSiteContentClient(String siteId) {
  if (siteId == 'hgtvmirror') return HgtvMirrorContentClient();
  if (siteId == 'hongguo') return HongguoContentClient();
  if (siteId == 'fanguo') return FanguoContentClient();
  return null;
}
