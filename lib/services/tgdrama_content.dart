import 'dart:convert';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'tgdrama_service.dart';

/// TG影视库：插件 tgdrama-android 在手机本地跑的 Go 服务
/// （127.0.0.1:5278），内容走插件接口取，不走核心、不走远程站。
/// 接口形状是 strings 反推、未实跑验证，所以解析处处多键容错：
/// 字段缺失或类型不对只跳过该条，不抛错；只有整包 JSON 解不出
/// 来才抛 StateError（带接口名）。
///
/// 每次调接口前先过 TgdramaService.ensureRunning()：服务没起来
/// （没解压、没拉起、没登录）就诚实抛错，不静默回空、不假装有
/// 内容。只有 categories() 例外：分类页要能打开，失败时回
/// [全部]兜底。
class TgdramaContentClient implements DramaSiteContentClient {
  static const baseUrl = TgdramaService.baseUrl;

  final http.Client _client;
  final TgdramaService _service;

  TgdramaContentClient({http.Client? httpClient, TgdramaService? service})
    : _client = httpClient ?? http.Client(),
      _service = service ?? TgdramaService.instance;

  Future<void> _ensureRunning() async {
    final ok = await _service.ensureRunning();
    if (!ok) {
      final reason = _service.lastError;
      throw StateError(
        reason == null || reason.isEmpty
            ? 'TG影视库本地服务未启动，请先到设置里登录 Telegram'
            : 'TG影视库本地服务未启动：$reason，请先到设置里登录 Telegram',
      );
    }
  }

  static String _stringOf(dynamic value) {
    if (value == null) return '';
    return value.toString().trim();
  }

  static int _intOf(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(_stringOf(value)) ?? 0;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    return const {};
  }

  /// 封面相对路径按本地服务地址补全成绝对地址；已是绝对地址原样回。
  static String _coverOf(Map<String, dynamic> node) {
    final raw = _stringOf(
      node['cover_path'] ?? node['cover'] ?? node['poster'],
    );
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '$baseUrl$raw';
    return '$baseUrl/$raw';
  }

  /// 列表里的集数备注：total / episode_count / episodes 长度，
  /// 有哪个用哪个，都没有就不写备注。
  static String _remarkOf(Map<String, dynamic> node) {
    var count = _intOf(node['total']);
    if (count <= 0) count = _intOf(node['episode_count']);
    if (count <= 0) {
      final episodes = node['episodes'];
      if (episodes is List) count = episodes.length;
    }
    return count > 0 ? '共$count集' : '';
  }

  /// 标签解析：字符串数组与含 name/tag 的对象数组都接受；
  /// 顶层包一层 {tags/list/data} 也接受。没有可用标签时回
  /// [全部]兜底，分类页总能打开。
  static List<DramaSiteCategory> parseTags(dynamic decoded) {
    var rows = decoded;
    if (rows is Map) {
      for (final key in ['tags', 'list', 'data', 'items']) {
        if (rows[key] is List) {
          rows = rows[key];
          break;
        }
      }
    }
    if (rows is! List) return const [DramaSiteCategory('all', '全部')];
    final seen = <String>{};
    final categories = <DramaSiteCategory>[];
    for (final entry in rows) {
      String id;
      String name;
      if (entry is String) {
        id = entry.trim();
        name = id;
      } else {
        final node = _asMap(entry);
        name = _stringOf(
          node['name'] ?? node['tag'] ?? node['title'] ?? node['label'],
        );
        id = _stringOf(node['tag'] ?? node['name'] ?? node['id']);
        if (name.isEmpty) name = id;
      }
      if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
      categories.add(DramaSiteCategory(id, name));
    }
    return categories.isEmpty
        ? const [DramaSiteCategory('all', '全部')]
        : categories;
  }

  /// 剧列表解析：顶层可以是数组，也可以是 {list/shows/items}
  /// 三键中第一个是 List 的那一项；包一层 {data:{list:[...]}}
  /// 也接受。单条缺 id 或缺标题时跳过该条，不抛错。
  static List<DramaSiteItem> parseShows(dynamic decoded) {
    final rows = _showRows(decoded);
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _stringOf(node['id'] ?? node['show_id']);
      if (id.isEmpty || !seen.add(id)) continue;
      final title = _stringOf(node['name'] ?? node['title']);
      if (title.isEmpty) continue;
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _coverOf(node),
          remark: _remarkOf(node),
        ),
      );
    }
    return items;
  }

  static List<dynamic> _showRows(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is! Map) return const [];
    for (final key in ['list', 'shows', 'items']) {
      if (decoded[key] is List) return decoded[key] as List;
    }
    final data = _asMap(decoded['data']);
    if (data.isNotEmpty) {
      for (final key in ['list', 'shows', 'items']) {
        if (data[key] is List) return data[key] as List;
      }
    }
    return const [];
  }

  /// 列表总数：total / total_count，都没有回 0（未知）。
  static int parseTotal(dynamic decoded) {
    if (decoded is! Map) return 0;
    var total = _intOf(decoded['total'] ?? decoded['total_count']);
    if (total <= 0) {
      total = _intOf(
        _asMap(decoded['data'])['total'] ??
            _asMap(decoded['data'])['total_count'],
      );
    }
    return total < 0 ? 0 : total;
  }

  /// 分集解析：videoId 取 id（字符串化）；标题取 name，
  /// 为空时按 episode_no 取“第N集”（episode_no 取
  /// episode_no/episodeNo，没有时按位置 index+1）。
  /// 缺 id 的分集跳过，不抛错。
  static List<DramaSiteEpisode> parseEpisodes(
    dynamic raw,
    String seriesId,
  ) {
    if (raw is! List) return const [];
    final indexed = <({int number, DramaSiteEpisode episode})>[];
    for (var i = 0; i < raw.length; i++) {
      final node = _asMap(raw[i]);
      final videoId = _stringOf(node['id'] ?? node['episode_id']);
      if (videoId.isEmpty) continue;
      var number = _intOf(node['episode_no'] ?? node['episodeNo']);
      if (number <= 0) number = i + 1;
      final name = _stringOf(node['name'] ?? node['title']);
      indexed.add((
        number: number,
        episode: DramaSiteEpisode(
          videoId: videoId,
          title: name.isNotEmpty ? name : '第$number集',
          seriesId: seriesId,
        ),
      ));
    }
    indexed.sort((a, b) => a.number.compareTo(b.number));
    return [for (final entry in indexed) entry.episode];
  }

  /// 详情解析：标题取 name/title，简介取
  /// synopsis/description/introduction，封面与列表同规则。
  /// 详情包一层 {show/data:{...}} 也接受。没有分集时抛
  /// StateError（拿 total 也拼不出可播的分集，episode id
  /// 不能猜），不回空详情假装有内容。
  static DramaSiteDetail parseDetail(dynamic decoded, String seriesId) {
    var node = _asMap(decoded);
    for (final key in ['show', 'data']) {
      final inner = _asMap(node[key]);
      if (inner.isNotEmpty && (inner['episodes'] is List || inner['name'] != null || inner['title'] != null)) {
        node = inner;
        break;
      }
    }
    final episodes = parseEpisodes(node['episodes'], seriesId);
    if (episodes.isEmpty) {
      throw StateError('该剧未返回分集');
    }
    return DramaSiteDetail(
      id: seriesId,
      title: _stringOf(node['name'] ?? node['title']),
      cover: _coverOf(node),
      synopsis: _stringOf(
        node['synopsis'] ?? node['description'] ?? node['introduction'],
      ),
      episodes: episodes,
    );
  }

  static dynamic _decodeJson(String body, String apiName) {
    try {
      return jsonDecode(body);
    } catch (_) {
      throw StateError('TG影视库$apiName接口数据格式无法识别');
    }
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    try {
      await _ensureRunning();
      final response = await _client.get(Uri.parse('$baseUrl/api/tags'));
      if (response.statusCode != 200) {
        return const [DramaSiteCategory('all', '全部')];
      }
      return parseTags(_decodeJson(response.body, '标签'));
    } catch (_) {
      return const [DramaSiteCategory('all', '全部')];
    }
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    await _ensureRunning();
    final p = page < 1 ? 1 : page;
    final query = <String, String>{'page': '$p'};
    if (categoryId.isNotEmpty && categoryId != 'all') {
      query['tag'] = categoryId;
    }
    final uri = Uri.parse(
      '$baseUrl/api/shows',
    ).replace(queryParameters: query);
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw StateError('TG影视库列表 HTTP ${response.statusCode}');
    }
    final decoded = _decodeJson(response.body, '列表');
    final items = parseShows(decoded);
    final total = parseTotal(decoded);
    final hasMore = total > 0
        ? items.length >= 20 && total > p * items.length
        : items.length >= 20;
    return DramaSiteCatalogPage(items: items, hasMore: hasMore);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    await _ensureRunning();
    final response = await _client.get(
      Uri.parse('$baseUrl/api/shows/${Uri.encodeComponent(seriesId)}'),
    );
    if (response.statusCode != 200) {
      throw StateError('TG影视库详情 HTTP ${response.statusCode}');
    }
    return parseDetail(_decodeJson(response.body, '详情'), seriesId);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    await _ensureRunning();
    return DramaPlaySource(
      url:
          '$baseUrl/api/episodes/${Uri.encodeComponent(episode.videoId)}/hls/index.m3u8',
    );
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    await _ensureRunning();
    final uri = Uri.parse(
      '$baseUrl/api/search',
    ).replace(queryParameters: {'q': query});
    final response = await _client.get(uri);
    if (response.statusCode != 200) {
      throw StateError('TG影视库搜索 HTTP ${response.statusCode}');
    }
    return parseShows(_decodeJson(response.body, '搜索'));
  }
}
