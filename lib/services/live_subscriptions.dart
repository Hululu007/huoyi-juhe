import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'live_sources.dart';

/// 直播多槽订阅（第 4 包，移植魔蚁 m3u_subscriptions 的形状）：
/// 多个导入源并存，SharedPreferences 落盘，源 id 前缀 `m3u:`。
///
/// 每条订阅含名称 / 类型（本地文件内容快照 file / 远程地址 url）/
/// 导入时间；远程源另存地址与最近一次拉到的内容快照（离线也能
/// 先出频道，刷新时才重拉更新）。频道不单独存：用时从内容快照
/// 现解析（parseM3u / parseTxtList），与魔蚁「按需重解析」同口径。
///
/// 老单槽导入（LiveSources 旧三件套的 juhe_live_m3u_channels /
/// juhe_live_m3u_url 两键）由 [LiveSubscriptionStore.load] 一次性
/// 迁成一条订阅记录：频道 JSON 原样带过来（[LiveSubscription]
/// 的 legacyChannels），转存成功后删旧键，不丢用户已导入的源。
class LiveSubscription {
  const LiveSubscription({
    required this.id,
    required this.name,
    required this.kind,
    this.url = '',
    this.content = '',
    this.epg = '',
    this.channelCount = 0,
    this.groupCount = 0,
    this.updatedAtMs = 0,
    this.legacyChannels = const [],
  });

  static const kindFile = 'file';
  static const kindUrl = 'url';

  /// 订阅自身 id（不带前缀）；对外源 id 是 `m3u:<id>`。
  final String id;
  final String name;
  final String kind;

  /// 远程源的订阅地址；本地源为空。
  final String url;

  /// 内容快照：本地源是导入文件全文，远程源是最近一次拉到的
  /// 全文。迁移来的老导入没有原文，靠 [legacyChannels] 兜底。
  final String content;

  /// 文件头声明的节目单地址（#EXTM3U 的 tvg-url 等），没有为空。
  final String epg;
  final int channelCount;
  final int groupCount;
  final int updatedAtMs;

  /// 仅迁移路径用：老单槽导入只存了频道 JSON、没有原文，
  /// 转存时把频道原样带进这条订阅，[LiveSubscriptionStore]
  /// 取频道时 content 为空就用它。正常导入恒为空。
  final List<LiveChannel> legacyChannels;

  String get sourceId => 'm3u:$id';
  bool get isUrl => kind == kindUrl;

  LiveSubscription copyWith({
    String? name,
    String? content,
    String? epg,
    int? channelCount,
    int? groupCount,
    int? updatedAtMs,
    List<LiveChannel>? legacyChannels,
  }) => LiveSubscription(
    id: id,
    name: name ?? this.name,
    kind: kind,
    url: url,
    content: content ?? this.content,
    epg: epg ?? this.epg,
    channelCount: channelCount ?? this.channelCount,
    groupCount: groupCount ?? this.groupCount,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    legacyChannels: legacyChannels ?? this.legacyChannels,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'url': url,
    'content': content,
    'epg': epg,
    'channelCount': channelCount,
    'groupCount': groupCount,
    'updatedAtMs': updatedAtMs,
    if (legacyChannels.isNotEmpty)
      'channels': [for (final channel in legacyChannels) channel.toJson()],
  };

  factory LiveSubscription.fromJson(Map<String, dynamic> json) {
    return LiveSubscription(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      kind: json['kind'] as String? ?? kindFile,
      url: json['url'] as String? ?? '',
      content: json['content'] as String? ?? '',
      epg: json['epg'] as String? ?? '',
      channelCount: json['channelCount'] as int? ?? 0,
      groupCount: json['groupCount'] as int? ?? 0,
      updatedAtMs: json['updatedAtMs'] as int? ?? 0,
      legacyChannels: [
        for (final row in json['channels'] as List? ?? const [])
          if (row is Map)
            LiveChannel.fromJson(Map<String, dynamic>.from(row)),
      ].whereType<LiveChannel>().toList(),
    );
  }
}

/// 订阅源对应的直播源登记（协议 list、非内置，进选源弹窗的
/// 「导入源」组；epg 随订阅带上，信息行节目单照常工作）。
LiveSource liveSourceForSubscription(LiveSubscription sub) => LiveSource(
  id: sub.sourceId,
  name: sub.name,
  description: sub.isUrl ? '远程订阅' : '本地导入',
  protocol: LiveProtocol.list,
  epg: sub.epg,
  builtin: false,
);

/// 一段播放列表文本是不是 TXT 行式：文件名 .txt、带 #genre#
/// 分组行、或通篇没有 m3u 标记，都按 TXT 解析；否则按 m3u。
bool livePlaylistIsTxt(String text, {String fileName = ''}) {
  if (fileName.toLowerCase().endsWith('.txt')) return true;
  if (text.contains('#genre#')) return true;
  return !text.contains('#EXTINF') && !text.trimLeft().startsWith('#EXTM3U');
}

/// 解析播放列表文本为频道表（按扩展名/内容选 parseM3u 或
/// parseTxtList）。失败按原因抛 FormatException，文案各说各的：
/// 内容为空 / 不是播放列表 / 解析出 0 频道（m3u 与 txt 分开说）。
({List<LiveChannel> channels, String epg, bool isTxt}) parseLivePlaylist(
  String text, {
  required String sourceId,
  String fileName = '',
}) {
  if (text.trim().isEmpty) {
    throw const FormatException('内容为空，没有可解析的频道');
  }
  final isTxt = livePlaylistIsTxt(text, fileName: fileName);
  final channels = isTxt
      ? parseTxtList(text, sourceId: sourceId)
      : parseM3u(text, sourceId: sourceId);
  if (channels.isEmpty) {
    if (isTxt) {
      throw const FormatException(
        '未解析到任何频道：请确认文件是标准 txt 直播列表'
        '（「分组名,#genre#」分组行 +「频道名,播放地址」行）',
      );
    }
    var totalEntries = 0;
    for (final line in text.split('\n')) {
      if (line.trimLeft().startsWith('#EXTINF')) totalEntries++;
    }
    throw FormatException(
      totalEntries > 0
          ? '未解析到任何频道：共 $totalEntries 条 #EXTINF，但地址都不可用，'
                '请确认文件是标准 m3u'
          : '未解析到任何频道：请确认文件是标准 m3u（含 #EXTINF 与播放地址）'
                '或 txt 直播列表',
    );
  }
  var epg = '';
  if (!isTxt) {
    for (final line in text.split('\n').take(5)) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('#EXTM3U')) continue;
      final match = RegExp(
        r'(?:tvg-url|url-tvg|x-tvg-url)="([^"]+)"',
      ).firstMatch(trimmed);
      epg = match?.group(1)?.trim() ?? '';
      break;
    }
  }
  return (channels: channels, epg: epg, isTxt: isTxt);
}

/// 远程订阅的默认源名：文件头 #EXTM3U 带 name 属性用它，
/// 否则用链接主机名，都拿不到回「未命名订阅」（魔蚁同口径）。
String liveRemoteSubscriptionName(String text, String url) {
  for (final line in text.split('\n').take(5)) {
    if (!line.trimLeft().startsWith('#EXTM3U')) continue;
    final name = RegExp(r'name="([^"]+)"').firstMatch(line)?.group(1)?.trim();
    if (name != null && name.isNotEmpty) return name;
    break;
  }
  final host = Uri.tryParse(url.trim())?.host ?? '';
  return host.isEmpty ? '未命名订阅' : host;
}

class LiveSubscriptionStore extends ChangeNotifier {
  LiveSubscriptionStore._();

  static final LiveSubscriptionStore instance = LiveSubscriptionStore._();

  static const _key = 'juhe_live_subscriptions';

  /// 老单槽导入的两键（与旧 LiveSources.importM3uUrl 写入的一致），
  /// 只在迁移时读，迁完即删。
  static const _legacyChannelsKey = 'juhe_live_m3u_channels';
  static const _legacyUrlKey = 'juhe_live_m3u_url';

  /// 测试注入：非空时远程拉取用它代替真实 HTTP。
  @visibleForTesting
  static Future<String> Function(String url)? fetchTextForTest;

  List<LiveSubscription> _items = const [];
  bool _loaded = false;

  List<LiveSubscription> get items => List.unmodifiable(_items);

  LiveSubscription? bySourceId(String sourceId) {
    for (final sub in _items) {
      if (sub.sourceId == sourceId) return sub;
    }
    return null;
  }

  @visibleForTesting
  void resetForTest() {
    _items = const [];
    _loaded = false;
    fetchTextForTest = null;
  }

  /// 读盘（进程内只读一次，后续靠内存 + 每次写盘同步）；
  /// 首次读时顺带把老单槽导入迁成一条订阅（见文件头注释）。
  Future<List<LiveSubscription>> load() async {
    if (_loaded) return items;
    _loaded = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _items = [
            for (final entry in decoded)
              if (entry is Map)
                LiveSubscription.fromJson(Map<String, dynamic>.from(entry)),
          ].where((sub) => sub.id.isNotEmpty).toList();
        }
      }
      if (_items.isEmpty) await _migrateLegacy(preferences);
    } catch (_) {
      // 读盘失败不掀页面：当作没有订阅，导入功能照常可用。
      _items = const [];
    }
    notifyListeners();
    return items;
  }

  /// 老单槽导入迁移：旧键里有频道才迁；迁成一条订阅后删旧键，
  /// 避免下次启动重复迁。频道没有原文，靠 legacyChannels 承载，
  /// 有远程地址的 kind 记 url（刷新时重拉后自然换成内容快照）。
  Future<void> _migrateLegacy(SharedPreferences preferences) async {
    final raw = preferences.getString(_legacyChannelsKey);
    if (raw == null || raw.isEmpty) return;
    List<LiveChannel> channels;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      channels = [
        for (final entry in decoded)
          if (entry is Map)
            LiveChannel.fromJson(Map<String, dynamic>.from(entry)),
      ].whereType<LiveChannel>().toList();
    } catch (_) {
      return;
    }
    if (channels.isEmpty) return;
    final url = preferences.getString(_legacyUrlKey) ?? '';
    final host = Uri.tryParse(url)?.host ?? '';
    _items = [
      LiveSubscription(
        id: 'legacy',
        name: host.isNotEmpty ? host : '导入的频道',
        kind: url.isEmpty
            ? LiveSubscription.kindFile
            : LiveSubscription.kindUrl,
        url: url,
        channelCount: channels.length,
        groupCount: channels.map((channel) => channel.group).toSet().length,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        legacyChannels: channels,
      ),
    ];
    await _persist(preferences);
    await preferences.remove(_legacyChannelsKey);
    await preferences.remove(_legacyUrlKey);
  }

  Future<void> _persist([SharedPreferences? preferences]) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final sub in _items) sub.toJson()]),
    );
  }

  static String _newId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// 本地文件导入：内容先解析验真（0 频道按原因抛错、不落盘），
  /// 通过才存成一条 file 订阅（内容快照随记录落盘）。
  Future<LiveSubscription> addLocal({
    required String name,
    required String content,
    String fileName = '',
  }) async {
    await load();
    final id = _newId();
    final report = parseLivePlaylist(
      content,
      sourceId: 'm3u:$id',
      fileName: fileName,
    );
    final sub = LiveSubscription(
      id: id,
      name: name.trim().isEmpty ? '未命名订阅' : name.trim(),
      kind: LiveSubscription.kindFile,
      content: content,
      epg: report.epg,
      channelCount: report.channels.length,
      groupCount: report.channels.map((c) => c.group).toSet().length,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _items = [..._items, sub];
    await _persist();
    notifyListeners();
    return sub;
  }

  /// 远程订阅：拉取 → 解析验真 → 落盘（地址 + 内容快照）。
  /// 地址不合法 / 拉不到 / 解析 0 频道分别按原因抛错，不落盘。
  Future<LiveSubscription> addRemote(String url) async {
    await load();
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw StateError('订阅地址无效：需要以 http:// 或 https:// 开头的完整地址');
    }
    final text = await fetchSubscriptionText(trimmed);
    final id = _newId();
    final report = parseLivePlaylist(text, sourceId: 'm3u:$id');
    final sub = LiveSubscription(
      id: id,
      name: liveRemoteSubscriptionName(text, trimmed),
      kind: LiveSubscription.kindUrl,
      url: trimmed,
      content: text,
      epg: report.epg,
      channelCount: report.channels.length,
      groupCount: report.channels.map((c) => c.group).toSet().length,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _items = [..._items, sub];
    await _persist();
    notifyListeners();
    return sub;
  }

  /// 远程订阅刷新：重拉地址、重解析、原地更新快照（魔蚁口径：
  /// 远程源刷新重拉，本地快照源不走这里）。拉取或解析失败抛错，
  /// 旧快照保留不动。
  Future<LiveSubscription> refreshRemote(LiveSubscription sub) async {
    await load();
    if (!sub.isUrl) return sub;
    final text = await fetchSubscriptionText(sub.url);
    final report = parseLivePlaylist(text, sourceId: sub.sourceId);
    final updated = sub.copyWith(
      content: text,
      epg: report.epg,
      channelCount: report.channels.length,
      groupCount: report.channels.map((c) => c.group).toSet().length,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      legacyChannels: const [],
    );
    _items = [
      for (final item in _items) item.id == sub.id ? updated : item,
    ];
    await _persist();
    notifyListeners();
    return updated;
  }

  /// 删一条订阅（记录与快照都在同一条 JSON 里，一并消失）。
  Future<void> remove(String id) async {
    await load();
    final next = _items.where((sub) => sub.id != id).toList();
    if (next.length == _items.length) return;
    _items = next;
    await _persist();
    notifyListeners();
  }

  /// 取一条订阅的频道：有内容快照现解析；迁移来的老订阅没有
  /// 原文，用 legacyChannels（sourceId 对齐到订阅源 id）。
  List<LiveChannel> channelsFor(LiveSubscription sub) {
    if (sub.content.trim().isNotEmpty) {
      return parseLivePlaylist(sub.content, sourceId: sub.sourceId).channels;
    }
    return [
      for (final channel in sub.legacyChannels)
        channel.sourceId == sub.sourceId
            ? channel
            : channel.copyWith(sourceId: sub.sourceId),
    ];
  }

  /// 拉远程订阅全文。失败按原因抛 StateError（HTTP 状态 / 网络
  /// 原话），不吞错装成功。
  static Future<String> fetchSubscriptionText(String url) async {
    final injected = fetchTextForTest;
    if (injected != null) return injected(url);
    try {
      final response = await http
          .get(Uri.parse(url.trim()))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('订阅拉取失败：HTTP ${response.statusCode}');
      }
      return response.body;
    } on StateError {
      rethrow;
    } catch (error) {
      throw StateError('订阅拉取失败：$error');
    }
  }
}
