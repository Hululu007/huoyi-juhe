import 'dart:convert';

import 'package:http/http.dart' as http;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'tgdrama_hardcoded_channels.dart';
import 'tgdrama_service.dart';

/// 按频道列剧的加载器：(频道键, 页码) → 该频道的剧。
/// 频道键是插件 /api/chats 里的 tg_chat_id（完整 TG 号，如 -100…），
/// 或硬编频道用户名；默认实现在内部解析，不依赖调用方先换算。
/// 测试可注入假实现。
typedef ChannelShowsLoader =
    Future<List<DramaSiteItem>> Function(String channelKey, int page);

/// TG影视库：插件 tgdrama-android 在手机本地跑的 Go 服务
/// （127.0.0.1:5278），内容走插件接口取，不走核心、不走远程站，
/// 也不直读插件的本地库 tgdrama.db。
///
/// 写法与 jar 站 tg频道（ZakaTgAmns）同构：
/// - 频道只走 /api/chats 解析（按用户名 / 完整 TG 号找频道，
///   拿的是库里 chats.id 本地编号；取视频时按本地编号
///   过滤，不按 tg_chat_id 直读库）；
/// - 频道里的剧没有“按频道列剧”的接口，改走 HTTP 扫描：
///   翻 /api/shows 拿剧 → 每部剧取首集 /api/episodes/{id}/lines，
///   lines 里的 chat_id（本地编号）对上频道才算该频道的剧；
/// - 52 个视频频道是硬编主表（见 tgdrama_hardcoded_channels.dart，
///   与 ZakaTgAmns.HARDCODED 同序）：插件有频道走插件、没频道
///   出硬编；点硬编里插件还没有的频道，调一次
///   POST /api/chats/sync 单频道同步（只同步这一个频道，
///   不走全量同步），同步完重查一次，仍没有就报“正在同步”。
///
/// 接口形状是插件源码（~/workspace/tgdrama_rebuild）核实的：
/// /api/shows?page=N 回 {list, total, page, page_size:30}，
/// /api/shows/{id} 回 {show, episodes:[{id, episode_no, title}]}，
/// /api/episodes/{id}/lines 回 {lines:[{chat_id, ...}]}，
/// /api/chats 回 {list:[{id, tg_chat_id, name, username, type,
/// enabled, message_count, source_count, syncing}]}。
/// 解析处处多键容错：字段缺失或类型不对只跳过该条，不抛错；
/// 只有整包 JSON 解不出来才抛 StateError（带接口名）。
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

  /// 频道一页的剧数（与旧直读库版同值，网格翻页口径不变）。
  static const channelPageSize = 20;

  /// HTTP 扫描上限：一个频道最多扫 200 部剧（与 jar 的
  /// SCAN_MAX_DEFAULT 同值），防插件剧库很大时扫个没完。
  static const _channelScanMax = 200;

  /// 是否频道条目 id（channel: 前缀）。
  static bool isChannelItemId(String id) => id.startsWith(channelItemPrefix);

  final http.Client _client;
  final TgdramaService _service;
  final ChannelShowsLoader? _channelShowsLoader;

  /// 剧 → 它所属频道的本地编号缓存（本客户端实例内有效，
  /// 频道页翻页时不再重复调详情/线路接口）。
  final Map<int, Set<int>> _showChatIdsCache = {};

  /// 已触发过单频道同步的硬编频道（用户名小写，或无用户名时
  /// 用裸号），防同一次打开里对同一频道重复调同步接口。
  final Set<String> _syncTriggered = {};

  TgdramaContentClient({
    http.Client? httpClient,
    TgdramaService? service,
    this._channelShowsLoader,
  }) : _client = httpClient ?? http.Client(),
       _service = service ?? TgdramaService.instance;

  /// 默认的按频道列剧（jar 式 HTTP 扫描，不读库）：
  /// 先按频道键解析出插件里的频道（本地编号），再翻
  /// /api/shows 逐部核对首集线路的 chat_id，筛出该频道的剧，
  /// 按页切片。频道不在插件里时解析步已触发单同步或抛错，
  /// 不会走到扫描；频道未启用也抛错，不回空假装频道没剧。
  Future<List<DramaSiteItem>> _defaultChannelShows(
    String channelKey,
    int page,
  ) async {
    final target = await _resolveChannel(channelKey);
    if (!target.inPlugin) {
      throw StateError('频道 ${target.name} 正在同步，稍后下拉刷新再进');
    }
    if (!target.enabled) {
      throw StateError('频道 ${target.name} 未启用采集，先去 TG影视库的频道管理页启用它');
    }
    return _scanChannelShows(target.localId, page < 1 ? 1 : page);
  }

  /// HTTP 扫描：翻 /api/shows（每页 30 条，插件的 page_size），
  /// 每部剧取首集线路的 chat_id 集合，含本频道本地编号的才算
  /// 该频道的剧；扫到够本页为止，最多扫 [_channelScanMax] 部。
  /// 第 1 页就调不通（非 200 / 坏 JSON / 连不上）时抛错，
  /// 不回空假装频道没剧；后面页调不通就停在已扫到的结果。
  Future<List<DramaSiteItem>> _scanChannelShows(
    int localChatId,
    int page,
  ) async {
    final matched = <Map<String, dynamic>>[];
    var scanned = 0;
    var total = 0;
    var p = 1;
    while (matched.length < page * channelPageSize &&
        scanned < _channelScanMax) {
      List<dynamic> batch;
      try {
        final response = await _client.get(
          Uri.parse(
            '$baseUrl/api/shows',
          ).replace(queryParameters: {'page': '$p'}),
        );
        if (response.statusCode != 200) {
          if (p == 1) {
            throw StateError('TG影视库列表 HTTP ${response.statusCode}');
          }
          break;
        }
        final decoded = _decodeJson(response.body, '列表');
        batch = _showRows(decoded);
        total = parseTotal(decoded);
      } catch (e) {
        if (p == 1) {
          if (e is StateError) rethrow;
          throw StateError('TG影视库列表请求失败：$e');
        }
        break;
      }
      if (batch.isEmpty) break;
      for (final entry in batch) {
        if (scanned >= _channelScanMax) break;
        final node = _asMap(entry);
        final showId = _intOf(node['id']);
        if (showId == 0) continue;
        scanned++;
        if ((await _showChatIds(showId)).contains(localChatId)) {
          // /api/shows 的行用 ep_count，列表解析认 episode_count，
          // 这里补一键，频道页备注才能出“共N集”。
          final normalized = Map<String, dynamic>.from(node);
          if (normalized['episode_count'] == null &&
              normalized['ep_count'] != null) {
            normalized['episode_count'] = normalized['ep_count'];
          }
          matched.add(normalized);
        }
      }
      if (total > 0 && scanned >= total) break;
      p++;
    }
    final start = (page - 1) * channelPageSize;
    if (start >= matched.length) return const [];
    final end = matched.length > start + channelPageSize
        ? start + channelPageSize
        : matched.length;
    return parseShows(matched.sublist(start, end));
  }

  /// 某部剧所属频道的本地编号集合：取详情的首集，
  /// 再调该集的线路接口，lines 里的 chat_id 就是本地编号。
  /// 与 jar 的 showChatIds 同逻辑（只看首集）。调不通时
  /// 回空集（该剧不算任何频道的），不抛错；结果缓存。
  Future<Set<int>> _showChatIds(int showId) async {
    final cached = _showChatIdsCache[showId];
    if (cached != null) return cached;
    final ids = <int>{};
    try {
      final response = await _client.get(
        Uri.parse('$baseUrl/api/shows/$showId'),
      );
      if (response.statusCode == 200) {
        final node = _asMap(_decodeJson(response.body, '详情'));
        final episodes = node['episodes'];
        if (episodes is List && episodes.isNotEmpty) {
          final episodeId = _intOf(_asMap(episodes.first)['id']);
          if (episodeId > 0) {
            final linesResponse = await _client.get(
              Uri.parse('$baseUrl/api/episodes/$episodeId/lines'),
            );
            if (linesResponse.statusCode == 200) {
              final linesNode = _asMap(
                _decodeJson(linesResponse.body, '详情'),
              );
              final lines = linesNode['lines'];
              if (lines is List) {
                for (final line in lines) {
                  final chatId = _intOf(_asMap(line)['chat_id']);
                  if (chatId != 0) ids.add(chatId);
                }
              }
            }
          }
        }
      }
    } catch (_) {
      // 调不通只影响这一部剧的归属判断，不拦整个频道列表。
    }
    _showChatIdsCache[showId] = ids;
    return ids;
  }

  /// 调一次 /api/chats，拿插件里的频道（本地编号 + TG 号 +
  /// 用户名 + 是否启用）。非 200 / 坏 JSON 抛带接口名的
  /// StateError，调用方据此报错，不回空假装没频道。
  Future<List<_PluginChat>> _fetchChats() async {
    final response = await _client.get(Uri.parse('$baseUrl/api/chats'));
    if (response.statusCode != 200) {
      throw StateError('TG影视库频道 HTTP ${response.statusCode}');
    }
    return _pluginChatsFrom(_decodeJson(response.body, '频道'));
  }

  /// 在插件频道里找频道键：纯数字先按完整 TG 号找（负数），
  /// 再按裸号换算（-(1000000000000 + 裸号)，与 jar 的
  /// fullTgId 同算法）；非数字按用户名找（不区分大小写）。
  static _PluginChat? _findPluginChat(
    List<_PluginChat> chats,
    String key,
  ) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return null;
    final number = int.tryParse(trimmed);
    final lower = trimmed.toLowerCase();
    for (final chat in chats) {
      if (number != null) {
        if (chat.tgChatId == number) return chat;
        if (number > 0 &&
            chat.tgChatId == -(1000000000000 + number)) {
          return chat;
        }
      }
      if (chat.username.isNotEmpty &&
          chat.username.toLowerCase() == lower) {
        return chat;
      }
    }
    return null;
  }

  /// 在硬编 52 条里找频道键：用户名（不区分大小写）、
  /// 裸号、完整 TG 号都能找；找不到回 null。
  static TgHardcodedChannel? _findHardcoded(String key) {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    for (final hard in hardcodedChannels) {
      if (hard.username.isNotEmpty &&
          hard.username.toLowerCase() == lower) {
        return hard;
      }
      if (hard.bareTgId == trimmed) return hard;
      if (hard.fullTgId.toString() == trimmed) return hard;
    }
    return null;
  }

  /// 在插件频道里找某条硬编频道：有用户名按用户名找，
  /// 无用户名按裸号算出的完整 TG 号找。
  static _PluginChat? _matchHardcoded(
    List<_PluginChat> chats,
    TgHardcodedChannel hard,
  ) {
    for (final chat in chats) {
      if (hard.username.isNotEmpty) {
        if (chat.username.isNotEmpty &&
            chat.username.toLowerCase() == hard.username.toLowerCase()) {
          return chat;
        }
      } else if (chat.tgChatId == hard.fullTgId) {
        return chat;
      }
    }
    return null;
  }

  /// 解析频道键：插件里有就直接用；没有但在硬编 52 条里，
  /// 触发一次单频道同步再重查一次；两次都没有就回一个
  /// 未进插件的目标（调用方报“正在同步”）；硬编里也
  /// 没有就抛“不在当前账号里”。与 jar 的 categoryContent
  /// 同顺序（先查插件、再查硬编、再同步、再查一次）。
  Future<_ChannelTarget> _resolveChannel(String key) async {
    final trimmed = key.trim();
    var chats = await _fetchChats();
    var chat = _findPluginChat(chats, trimmed);
    if (chat != null) {
      return _ChannelTarget(
        localId: chat.localId,
        tgChatId: chat.tgChatId,
        username: chat.username,
        name: chat.name.isEmpty ? '频道 ${chat.tgChatId}' : chat.name,
        enabled: chat.enabled,
        inPlugin: true,
        node: chat.node,
      );
    }
    final hard = _findHardcoded(trimmed);
    if (hard == null) {
      throw StateError('该频道不在当前账号里：$trimmed');
    }
    await _triggerChannelSync(hard);
    chats = await _fetchChats();
    chat = _findPluginChat(chats, trimmed);
    if (chat != null) {
      return _ChannelTarget(
        localId: chat.localId,
        tgChatId: chat.tgChatId,
        username: chat.username,
        name: chat.name.isEmpty ? hard.name : chat.name,
        enabled: chat.enabled,
        inPlugin: true,
        node: chat.node,
      );
    }
    return _ChannelTarget(
      localId: 0,
      tgChatId: hard.fullTgId,
      username: hard.username,
      name: hard.name,
      enabled: false,
      inPlugin: false,
      node: const {},
    );
  }

  /// 单频道同步：POST /api/chats/sync，只同步这一个频道，
  /// 不走全量同步（tg_chat_id 为 0 才是全量，绝不发 0）。
  /// 同一客户端实例里同一频道只触发一次；接口调不通也
  /// 不抛错（同步是后台任务，重查一次没进插件就报“正在同步”）。
  Future<void> _triggerChannelSync(TgHardcodedChannel hard) async {
    final key = hard.username.isNotEmpty
        ? hard.username.toLowerCase()
        : hard.bareTgId;
    if (!_syncTriggered.add(key)) return;
    try {
      await _client.post(
        Uri.parse('$baseUrl/api/chats/sync'),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({'tg_chat_id': hard.fullTgId}),
      );
    } catch (_) {}
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
    return [
      for (final chat in _pluginChatsFrom(decoded))
        DramaSiteItem(
          id: '$channelItemPrefix${chat.id}',
          title: chat.name.isEmpty ? '频道 ${chat.id}' : chat.name,
          cover: '',
          remark: _chatRemarkOf(chat.node),
        ),
    ];
  }

  /// 插件频道行解析（/api/chats 的原始行）：tg_chat_id 没有
  /// 就依次回退 tgChatId/chat_id/id，仍没有或为 0 就跳过；
  /// 同号去重。localId 取 id 键（库里 chats.id，取视频
  /// 时 sources.chat_id 指的就是它）。
  static List<_PluginChat> _pluginChatsFrom(dynamic decoded) {
    final rows = _chatRows(decoded);
    final seen = <String>{};
    final chats = <_PluginChat>[];
    for (final entry in rows) {
      final node = _asMap(entry);
      final id = _stringOf(
        node['tg_chat_id'] ??
            node['tgChatId'] ??
            node['chat_id'] ??
            node['id'],
      );
      if (id.isEmpty || id == '0' || !seen.add(id)) continue;
      chats.add(
        _PluginChat(
          localId: _intOf(node['id']),
          tgChatId: _intOf(id),
          id: id,
          name: _stringOf(node['name']),
          username: _stringOf(node['username']),
          enabled: _boolOf(node['enabled']),
          node: node,
        ),
      );
    }
    return chats;
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

  /// 频道详情：标题取 name（没有回退“频道 + id”），简介写频道信息。
  /// 分集为空：频道不是剧，没有可播的分集；点开频道看它收录的剧
  /// 走频道剧列表页（catalog('channel:id') 走插件接口扫描），不走这里。
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

  /// 硬编频道还没进插件时的详情：标题用硬编名，简介写清
  /// “未同步到插件”，点开频道会触发单频道同步。
  static DramaSiteDetail _hardcodedChannelDetail(_ChannelTarget target) {
    final lines = <String>['类型：频道'];
    if (target.username.isNotEmpty) {
      lines.add('用户名：@${target.username}');
    }
    lines.add('TG 频道 ID：${target.tgChatId}');
    lines.add('状态：未同步到插件');
    lines.add('');
    lines.add('点开该频道会触发单频道同步，同步完成后下拉刷新再进。');
    return DramaSiteDetail(
      id: '$channelItemPrefix${target.tgChatId}',
      title: target.name,
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

  /// 频道里的剧：调加载器（默认走插件接口扫描）查该频道收录的剧。
  /// 解析步抛 StateError 时原样抛（频道未同步 / 未启用 /
  /// 不在账号里），网格页如实报错，不回空假装频道没剧；
  /// 插件里有且已启用、但还没同步到剧时回空页。
  /// hasMore 按“满页”算：满 20 条认为还有下一页。
  Future<DramaSiteCatalogPage> _channelShowsCatalog(
    String channelKey,
    int page,
  ) async {
    final loader = _channelShowsLoader ?? _defaultChannelShows;
    final items = await loader(channelKey, page < 1 ? 1 : page);
    return DramaSiteCatalogPage(
      items: items,
      hasMore: items.length >= channelPageSize,
    );
  }

  /// 频道列表：插件有频道走插件、没频道出硬编 52 条。
  /// 合并顺序与 jar 的 homeContent 三段式同构（只是把 jar
  /// 的 ext 7 条换成 52 条主表）：①硬编里插件已有且启用的
  /// （显示名用硬编名）；②插件里有且启用、但不在硬编里的；
  /// ③硬编里其余的（未启用、或还没同步到插件）。
  Future<DramaSiteCatalogPage> _channelsCatalog() async {
    final chats = await _fetchChats();
    if (chats.isEmpty) {
      return DramaSiteCatalogPage(
        items: _hardcodedChannelItems(),
        hasMore: false,
      );
    }
    final items = <DramaSiteItem>[];
    final usedTgIds = <int>{};
    for (final hard in hardcodedChannels) {
      final chat = _matchHardcoded(chats, hard);
      if (chat != null && chat.enabled && !usedTgIds.contains(chat.tgChatId)) {
        items.add(
          DramaSiteItem(
            id: '$channelItemPrefix${chat.tgChatId}',
            title: hard.name,
            cover: '',
            remark: _chatRemarkOf(chat.node),
          ),
        );
        usedTgIds.add(chat.tgChatId);
      }
    }
    final hardcodedUsers = <String>{
      for (final hard in hardcodedChannels)
        if (hard.username.isNotEmpty) hard.username.toLowerCase(),
    };
    final hardcodedTgIds = <int>{
      for (final hard in hardcodedChannels) hard.fullTgId,
    };
    for (final chat in chats) {
      if (!chat.enabled) continue;
      if (usedTgIds.contains(chat.tgChatId)) continue;
      if (chat.username.isNotEmpty &&
          hardcodedUsers.contains(chat.username.toLowerCase())) {
        continue;
      }
      if (hardcodedTgIds.contains(chat.tgChatId)) continue;
      items.add(
        DramaSiteItem(
          id: '$channelItemPrefix${chat.tgChatId}',
          title: chat.name.isEmpty ? '频道 ${chat.tgChatId}' : chat.name,
          cover: '',
          remark: _chatRemarkOf(chat.node),
        ),
      );
      usedTgIds.add(chat.tgChatId);
    }
    for (final hard in hardcodedChannels) {
      final chat = _matchHardcoded(chats, hard);
      if (chat != null && usedTgIds.contains(chat.tgChatId)) continue;
      if (chat != null) {
        items.add(
          DramaSiteItem(
            id: '$channelItemPrefix${chat.tgChatId}',
            title: hard.name,
            cover: '',
            remark: _chatRemarkOf(chat.node),
          ),
        );
        usedTgIds.add(chat.tgChatId);
      } else {
        items.add(
          DramaSiteItem(
            id: '$channelItemPrefix${hard.fullTgId}',
            title: hard.name,
            cover: '',
            remark: '未同步，点击同步',
          ),
        );
      }
    }
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  /// 插件没频道时出的硬编 52 条：id 用裸号算出的完整 TG 号，
  /// 点开触发单频道同步。
  static List<DramaSiteItem> _hardcodedChannelItems() {
    return [
      for (final hard in hardcodedChannels)
        DramaSiteItem(
          id: '$channelItemPrefix${hard.fullTgId}',
          title: hard.name,
          cover: '',
          remark: '未同步，点击同步',
        ),
    ];
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

  /// 频道详情：先解析频道键（插件里没有的硬编频道会触发
  /// 一次单同步再重查）；插件里有回插件行详情，没有回
  /// 硬编详情；硬编里也没有解析步已抛“不在当前账号里”。
  Future<DramaSiteDetail> _channelDetail(String channelKey) async {
    final target = await _resolveChannel(channelKey);
    if (target.inPlugin) {
      return parseChannelDetail(target.node, '${target.tgChatId}');
    }
    return _hardcodedChannelDetail(target);
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

/// 插件 /api/chats 的一行：本地编号 + 完整 TG 号 + 显示信息。
/// localId 是库里 chats.id，取视频时 sources.chat_id 指的就是它；
/// tgChatId 是完整 TG 号（负数），频道条目 id 用它。
class _PluginChat {
  const _PluginChat({
    required this.localId,
    required this.tgChatId,
    required this.id,
    required this.name,
    required this.username,
    required this.enabled,
    required this.node,
  });

  final int localId;
  final int tgChatId;

  /// tg_chat_id 的原始字符串（parseChats 的条目 id 用它，
  /// 与旧版输出一致）。
  final String id;
  final String name;
  final String username;
  final bool enabled;

  /// 原始行，供备注与详情复用。
  final Map<String, dynamic> node;
}

/// 解析出的频道目标：插件里有（inPlugin 为真）就带本地编号
/// 与插件行；没有就是硬编里的一条（inPlugin 为假，调用方
/// 报“正在同步”，不再拿本地编号去读库）。
class _ChannelTarget {
  const _ChannelTarget({
    required this.localId,
    required this.tgChatId,
    required this.username,
    required this.name,
    required this.enabled,
    required this.inPlugin,
    required this.node,
  });

  final int localId;
  final int tgChatId;
  final String username;
  final String name;
  final bool enabled;
  final bool inPlugin;
  final Map<String, dynamic> node;
}
