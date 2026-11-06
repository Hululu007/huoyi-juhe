import 'dart:convert';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'tgdrama_channel_db.dart';
import 'tgdrama_service.dart';

/// 按频道列剧的加载器：(频道 tg_chat_id, 页码) → 该频道的剧。
/// 默认走本地库直读（见 TgdramaContentClient._defaultChannelShows）；
/// 测试可注入假实现。
typedef ChannelShowsLoader =
    Future<List<DramaSiteItem>> Function(String tgChatId, int page);

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

  /// 「频道」分类 id：只在本客户端内部识别，不发给 /api/shows。
  /// 标签 id 几乎不可能是纯 ASCII 的 channels；万一撞了，
  /// categories() 里以标签为准、不重复加。
  static const channelsCategoryId = 'channels';
  static const channelsCategoryName = '频道';

  /// 频道条目 id 前缀：detail()/catalog() 靠它识别“点开的是频道不是剧”。
  /// 公开给 openDramaSiteItem 用：频道条目点开进频道剧列表页，不进剧详情页。
  static const channelItemPrefix = 'channel:';

  /// 是否频道条目 id（channel: 前缀）。
  static bool isChannelItemId(String id) => id.startsWith(channelItemPrefix);

  final http.Client _client;
  final TgdramaService _service;
  final ChannelShowsLoader? _channelShowsLoader;

  TgdramaContentClient({
    http.Client? httpClient,
    TgdramaService? service,
    this._channelShowsLoader,
  }) : _client = httpClient ?? http.Client(),
       _service = service ?? TgdramaService.instance;

  /// 默认的按频道列剧：读插件本地库 tgdrama.db（只读），按链路
  /// 频道 → sources → episodes → shows 查出该频道的剧。
  /// 库不存在/打不开时抛 StateError（带原因），调用方据此报错或回退。
  Future<List<DramaSiteItem>> _defaultChannelShows(
    String tgChatId,
    int page,
  ) async {
    final dbPath = await _service.databasePath();
    final rows = await TgdramaChannelDb.queryChannelShows(
      dbPath: dbPath,
      tgChatId: tgChatId,
      page: page,
    );
    return parseChannelShows(rows);
  }

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

  /// 开关字段容错：true/false、1/0、'1'/'true' 都接受。
  static bool _boolOf(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    final text = _stringOf(value).toLowerCase();
    return text == '1' || text == 'true' || text == 'yes' || text == 'on';
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

  /// 频道解析：顶层 {list:[...], enabled, syncing}，裸数组也接受。
  /// 单条字段：tg_chat_id（没有就跳过）、name（没有回退“频道 + id”）、
  /// type、username、enabled、message_count、source_count、syncing。
  /// id 用 channel: 前缀，detail() 靠它识别频道。封面频道没有，
  /// 备注写消息数与视频来源数，未启用的加“未启用”。
  static List<DramaSiteItem> parseChats(dynamic decoded) {
    final rows = _chatRows(decoded);
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final tgChatId = _stringOf(
        node['tg_chat_id'] ??
            node['tgChatId'] ??
            node['chat_id'] ??
            node['id'],
      );
      if (tgChatId.isEmpty || tgChatId == '0' || !seen.add(tgChatId)) {
        continue;
      }
      final name = _stringOf(node['name']);
      items.add(
        DramaSiteItem(
          id: '$channelItemPrefix$tgChatId',
          title: name.isEmpty ? '频道 $tgChatId' : name,
          cover: '',
          remark: _chatRemarkOf(node),
        ),
      );
    }
    return items;
  }

  static List<dynamic> _chatRows(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is! Map) return const [];
    for (final key in ['list', 'chats', 'items']) {
      if (decoded[key] is List) return decoded[key] as List;
    }
    final data = _asMap(decoded['data']);
    if (data.isNotEmpty) {
      for (final key in ['list', 'chats', 'items']) {
        if (data[key] is List) return data[key] as List;
      }
    }
    return const [];
  }

  /// 频道备注：消息数、视频来源数；类型不是 channel 时写类型；
  /// 未启用的加“未启用”，同步中的加“同步中”。都没有就不写备注。
  static String _chatRemarkOf(Map<String, dynamic> node) {
    final parts = <String>[];
    final messageCount = _intOf(
      node['message_count'] ?? node['messageCount'],
    );
    if (messageCount > 0) parts.add('$messageCount条消息');
    final sourceCount = _intOf(node['source_count'] ?? node['sourceCount']);
    if (sourceCount > 0) parts.add('$sourceCount个视频来源');
    final type = _stringOf(node['type']);
    if (type.isNotEmpty && type != 'channel') parts.add(type);
    if (!_boolOf(node['enabled'])) parts.add('未启用');
    if (_boolOf(node['syncing'])) parts.add('同步中');
    return parts.join(' · ');
  }

  /// 频道里剧的行解析（本地库查出的原始行）：id/name 必有其一
  /// 缺失跳过该条；同剧去重（同一剧在频道里多集只留一条）；
  /// 封面与列表同规则（cover_path 相对路径按本地服务补全）；
  /// 备注有分集数写“共N集”，没有写空（intro 太长不放备注，
  /// 简介在剧详情页看）。episode_count/intro 缺失都容错。
  static List<DramaSiteItem> parseChannelShows(
    List<Map<String, Object?>> rows,
  ) {
    final seen = <String>{};
    final items = <DramaSiteItem>[];
    for (final row in rows) {
      final node = _asMap(row);
      final id = _stringOf(node['id']);
      if (id.isEmpty || !seen.add(id)) continue;
      final title = _stringOf(node['name'] ?? node['title']);
      if (title.isEmpty) continue;
      final episodeCount = _intOf(node['episode_count']);
      items.add(
        DramaSiteItem(
          id: id,
          title: title,
          cover: _coverOf(node),
          remark: episodeCount > 0 ? '共$episodeCount集' : '',
        ),
      );
    }
    return items;
  }

  /// 频道详情：标题取 name（没有回退“频道 + id”），简介写频道信息。
  /// 分集为空：频道不是剧，没有可播的分集；点开频道看它收录的剧
  /// 走频道剧列表页（catalog('channel:<id>') 读本地库），不走这里。
  /// 详情页对空分集显示空选集区，不会崩。
  static DramaSiteDetail parseChannelDetail(
    Map<String, dynamic> node,
    String tgChatId,
  ) {
    final name = _stringOf(node['name']);
    final title = name.isEmpty ? '频道 $tgChatId' : name;
    final lines = <String>[];
    final type = _stringOf(node['type']);
    lines.add('类型：${type.isEmpty ? '频道' : type}');
    final username = _stringOf(node['username']);
    if (username.isNotEmpty) {
      lines.add('用户名：${username.startsWith('@') ? username : '@$username'}');
    }
    lines.add('TG 频道 ID：$tgChatId');
    final messageCount = _intOf(
      node['message_count'] ?? node['messageCount'],
    );
    final sourceCount = _intOf(node['source_count'] ?? node['sourceCount']);
    final counts = <String>[];
    if (messageCount > 0) counts.add('$messageCount条消息');
    if (sourceCount > 0) counts.add('$sourceCount个视频来源');
    if (counts.isNotEmpty) lines.add(counts.join(' · '));
    lines.add(
      '状态：${_boolOf(node['enabled']) ? '已启用' : '未启用'}${_boolOf(node['syncing']) ? '（同步中）' : ''}',
    );
    lines.add('');
    lines.add('点开该频道可看它收录的剧。');
    return DramaSiteDetail(
      id: '$channelItemPrefix$tgChatId',
      title: title,
      cover: '',
      synopsis: lines.join('\n'),
      episodes: const [],
    );
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
      final categories = parseTags(_decodeJson(response.body, '标签'));
      // 「频道」分类挂在最后；已有同 id 标签时不重复加。
      // 标签失败兜底成裸 [全部] 时不加频道：服务没起来频道也拿不到，
      // 没有真标签时也不硬挂一个频道分类。
      if (categories.length == 1 && categories.first.id == 'all') {
        return categories;
      }
      if (!categories.any((c) => c.id == channelsCategoryId)) {
        return [
          ...categories,
          const DramaSiteCategory(channelsCategoryId, channelsCategoryName),
        ];
      }
      return categories;
    } catch (_) {
      return const [DramaSiteCategory('all', '全部')];
    }
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    await _ensureRunning();
    if (categoryId == channelsCategoryId) {
      return _channelsCatalog();
    }
    if (categoryId.startsWith(channelItemPrefix)) {
      return _channelShowsCatalog(
        categoryId.substring(channelItemPrefix.length),
        page,
      );
    }
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

  /// 频道里的剧：调加载器（默认读本地库）查该频道收录的剧。
  /// 库不存在/打不开时加载器抛 StateError（带原因），网格页如实
  /// 报错，不回空假装频道没剧；库能读但该频道没剧时回空页。
  /// hasMore 按“满页”算：满 20 条认为还有下一页。
  Future<DramaSiteCatalogPage> _channelShowsCatalog(
    String tgChatId,
    int page,
  ) async {
    final loader = _channelShowsLoader ?? _defaultChannelShows;
    final items = await loader(tgChatId, page < 1 ? 1 : page);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: items.length >= TgdramaChannelDb.pageSize,
    );
  }

  /// 频道列表：调 /api/chats，一次全量，没有翻页。
  Future<DramaSiteCatalogPage> _channelsCatalog() async {
    final response = await _client.get(Uri.parse('$baseUrl/api/chats'));
    if (response.statusCode != 200) {
      throw StateError('TG影视库频道 HTTP ${response.statusCode}');
    }
    final items = parseChats(_decodeJson(response.body, '频道'));
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    await _ensureRunning();
    if (seriesId.startsWith(channelItemPrefix)) {
      return _channelDetail(seriesId.substring(channelItemPrefix.length));
    }
    final response = await _client.get(
      Uri.parse('$baseUrl/api/shows/${Uri.encodeComponent(seriesId)}'),
    );
    if (response.statusCode != 200) {
      throw StateError('TG影视库详情 HTTP ${response.statusCode}');
    }
    return parseDetail(_decodeJson(response.body, '详情'), seriesId);
  }

  /// 频道详情：再调一次 /api/chats，按 tg_chat_id 找到该频道，
  /// 回频道信息详情（分集为空）；找不到抛“找不到该频道”。
  Future<DramaSiteDetail> _channelDetail(String tgChatId) async {
    final response = await _client.get(Uri.parse('$baseUrl/api/chats'));
    if (response.statusCode != 200) {
      throw StateError('TG影视库频道 HTTP ${response.statusCode}');
    }
    final rows = _chatRows(_decodeJson(response.body, '频道'));
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _stringOf(
        node['tg_chat_id'] ??
            node['tgChatId'] ??
            node['chat_id'] ??
            node['id'],
      );
      if (id == tgChatId) {
        return parseChannelDetail(node, tgChatId);
      }
    }
    throw StateError('找不到该频道');
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
