import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum LiveProtocol { platform, list, aggregate }

class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    this.endpoints = const [],
    this.headers = const {},
    this.group = '',
    this.adult = false,
    this.builtin = true,
  });

  final String id;
  final String name;
  final String description;
  final LiveProtocol protocol;
  final List<String> endpoints;
  final Map<String, String> headers;
  final String group;
  final bool adult;
  final bool builtin;

  String get endpoint => endpoints.isEmpty ? '' : endpoints.first;
}

class LiveChannel {
  const LiveChannel({
    required this.title,
    required this.url,
    this.group = '',
    this.sourceId = '',
  });

  final String title;
  final String url;
  final String group;
  final String sourceId;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'group': group,
    'sourceId': sourceId,
  };

  static LiveChannel? fromJson(Map<String, dynamic> json) {
    final title = json['title'] as String? ?? '';
    final url = json['url'] as String? ?? '';
    if (title.isEmpty || !url.toLowerCase().startsWith('http')) return null;
    return LiveChannel(
      title: title,
      url: url,
      group: json['group'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? '',
    );
  }
}

List<LiveChannel> parseM3u(String text) {
  final channels = <LiveChannel>[];
  String? pendingTitle;
  var pendingGroup = '';
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      final groupMatch = RegExp(
        r'group-title="([^"]*)"',
      ).firstMatch(line);
      pendingGroup = groupMatch?.group(1) ?? '';
      final comma = line.indexOf(',');
      pendingTitle = comma >= 0
          ? line.substring(comma + 1).trim()
          : '未命名频道';
      continue;
    }
    if (line.startsWith('#')) continue;
    if (!line.toLowerCase().startsWith('http')) {
      pendingTitle = null;
      pendingGroup = '';
      continue;
    }
    channels.add(
      LiveChannel(
        title: pendingTitle ?? line,
        url: line,
        group: pendingGroup,
      ),
    );
    pendingTitle = null;
    pendingGroup = '';
  }
  return channels;
}

class LiveSources {
  LiveSources._();

  static const builtin = <LiveSource>[
    LiveSource(
      id: 'bilibili',
      name: '哔哩哔哩',
      description: '哔哩哔哩直播 · 热门推荐',
      protocol: LiveProtocol.platform,
      headers: {'Referer': 'https://live.bilibili.com/'},
    ),
    LiveSource(
      id: 'huya',
      name: '虎牙',
      description: '虎牙直播 · 游戏与娱乐',
      protocol: LiveProtocol.platform,
      headers: {'Referer': 'https://www.huya.com/'},
    ),
    LiveSource(
      id: 'yuhuo_live',
      name: '欲火直播',
      description: '内置频道表 · 未探活，频道表文件不在本包内',
      protocol: LiveProtocol.list,
      group: '欲火直播',
    ),
    LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.aggregate,
      endpoints: [
        'http://api.vipmisss.com:81/xcdsw',
        'http://api.hclyz.com:81/mf',
      ],
      adult: true,
    ),
    LiveSource(
      id: 'maiyoux',
      name: '欲火聚合',
      description: '欲火移植 · 平台动态聚合 · 实时开播',
      protocol: LiveProtocol.aggregate,
      endpoints: [
        'http://api.maiyoux.com:81/mf',
        'http://api.vipmisss.com:81/xcdsw',
      ],
      adult: true,
    ),
  ];

  static List<LiveSource> get mainTabSources =>
      [for (final source in builtin) if (!source.adult) source];

  static List<LiveSource> get midnightSources =>
      [for (final source in builtin) if (source.adult) source];

  static const _m3uKey = 'juhe_live_m3u_channels';
  static const _m3uUrlKey = 'juhe_live_m3u_url';

  static Future<List<LiveChannel>> loadImportedChannels() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_m3uKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map<String, dynamic>) LiveChannel.fromJson(entry),
      ].whereType<LiveChannel>().toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<LiveChannel>> importM3uUrl(String url) async {
    final trimmed = url.trim();
    if (!trimmed.toLowerCase().startsWith('http')) {
      throw StateError('m3u 地址需要以 http 开头');
    }
    final response = await http
        .get(Uri.parse(trimmed))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError('m3u 拉取失败：HTTP ${response.statusCode}');
    }
    final channels = parseM3u(response.body);
    if (channels.isEmpty) {
      throw StateError('m3u 里没有可识别的频道');
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _m3uKey,
      jsonEncode([for (final channel in channels) channel.toJson()]),
    );
    await preferences.setString(_m3uUrlKey, trimmed);
    return channels;
  }
}
