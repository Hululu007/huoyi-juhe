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

  const DramaSiteEpisode({required this.videoId, required this.title});
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
      headers: {'Referer': '$baseUrl/', 'User-Agent': _userAgent},
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
      headers: {'Referer': '$baseUrl/', 'User-Agent': _userAgent},
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
      headers: {'Referer': '$baseUrl/', 'User-Agent': _userAgent},
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
          'User-Agent': _userAgent,
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

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
}

DramaSiteContentClient? dramaSiteContentClient(String siteId) {
  if (siteId == 'hgtvmirror') return HgtvMirrorContentClient();
  return null;
}
