import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum LiveProtocol { pingtai, list }

class LiveSource {
  const LiveSource({
    required this.id,
    required this.name,
    required this.description,
    required this.protocol,
    this.endpoints = const [],
    this.script = '',
    this.headers = const {},
    this.epg = '',
    this.proxies = const [],
    this.group = '',
    this.adult = false,
    this.builtin = true,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String description;
  final LiveProtocol protocol;
  final List<String> endpoints;
  final String script;
  final Map<String, String> headers;
  final String epg;
  final List<String> proxies;
  final String group;
  final bool adult;
  final bool builtin;
  final bool enabled;

  String get endpoint => endpoints.isEmpty ? '' : endpoints.first;

  bool get paginated => protocol != LiveProtocol.pingtai;
}

class LiveChannel {
  LiveChannel({
    required this.title,
    required this.url,
    this.group = '',
    this.sourceId = '',
    this.token = '',
    this.subtitle = '',
    this.cover = '',
    this.number = '',
    List<String>? urls,
  }) : urls = (urls == null || urls.isEmpty) ? [url] : List.unmodifiable(urls);

  final String title;
  final String url;
  final String group;
  final String sourceId;
  final String token;
  final String subtitle;
  final String cover;

  /// 火蚁TV 的 urls：直连型源（pingtai / list）单条地址时就是 [url]；
  /// 平台型源或带代理前缀的列表源可有多条，播放页「线路」按钮按它切线。
  /// 修仙版现有源都只给一条（见 live_platform 的取数），这里先把字段与
  /// 切线通路按火蚁TV 形态接好，有多条数据的源进来即能用。
  final List<String> urls;

  /// 火蚁TV 的频道序号：平台源按接口行序编号（rtmp 沉底前编，
  /// 展示顺序里编号不一定连续）；列表源按 m3u 行序编号，
  /// 有 tvg-chno 时用它。空时展示用显示位序兜底。
  final String number;

  /// 收藏去重键，与火蚁TV 的 makeKey 同形：源、分组、频道名。
  String get key => makeKey(sourceId, group, title);

  static String makeKey(String source, String group, String name) =>
      '$source\u0000$group\u0000$name';

  /// 火蚁TV 的 logo 就是房间图，与这里的 cover 同源。
  String get logo => cover;

  String get label => number.isEmpty ? title : '$number  $title';

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'urls': urls,
    'group': group,
    'sourceId': sourceId,
    'token': token,
    'subtitle': subtitle,
    'cover': cover,
    'number': number,
  };

  static LiveChannel? fromJson(Map<String, dynamic> json) {
    final title = json['title'] as String? ?? '';
    final url = json['url'] as String? ?? '';
    if (title.isEmpty || !url.contains('://')) return null;
    final urls = (json['urls'] as List?)
        ?.whereType<String>()
        .where((value) => value.isNotEmpty)
        .toList();
    return LiveChannel(
      title: title,
      url: url,
      urls: urls,
      group: json['group'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? '',
      token: json['token'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      number: json['number'] as String? ?? '',
    );
  }
}

List<LiveChannel> parseM3u(String text, {String sourceId = ''}) {
  final channels = <LiveChannel>[];
  String? pendingTitle;
  var pendingGroup = '';
  String? pendingNumber;
  var number = 0;
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
      pendingGroup = groupMatch?.group(1) ?? '';
      final chnoMatch = RegExp(r'tvg-chno="([^"]*)"').firstMatch(line);
      final chno = chnoMatch?.group(1)?.trim() ?? '';
      pendingNumber = chno.isEmpty ? null : chno.padLeft(3, '0');
      final comma = line.indexOf(',');
      pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : '未命名频道';
      continue;
    }
    if (line.startsWith('#')) continue;
    if (!line.toLowerCase().startsWith('http')) {
      pendingTitle = null;
      pendingGroup = '';
      pendingNumber = null;
      continue;
    }
    number++;
    channels.add(
      LiveChannel(
        title: pendingTitle ?? line,
        url: line,
        group: pendingGroup,
        sourceId: sourceId,
        number: pendingNumber ?? number.toString().padLeft(3, '0'),
      ),
    );
    pendingTitle = null;
    pendingGroup = '';
    pendingNumber = null;
  }
  return channels;
}

class LiveSources {
  LiveSources._();

  static const builtin = <LiveSource>[
    LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
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
      protocol: LiveProtocol.pingtai,
      endpoints: [
        'http://api.maiyoux.com:81/mf',
        'http://api.vipmisss.com:81/xcdsw',
      ],
      adult: true,
    ),
    LiveSource(
      id: 'bnzb',
      name: '百年直播',
      description: '百年直播 · 多平台聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    LiveSource(
      id: 'user_m3u',
      name: '成人点播',
      description: '用户提供的 m3u · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/user_m3u.m3u'],
      adult: true,
    ),
  ];

  static LiveSource? byId(String id) {
    for (final source in builtin) {
      if (source.id == id) return source;
    }
    return null;
  }

  static Future<List<LiveChannel>> loadBuiltinListChannels(
    LiveSource source,
  ) async {
    final endpoint = source.endpoint;
    final String text;
    if (endpoint.startsWith('asset://')) {
      text = await rootBundle.loadString(endpoint.substring('asset://'.length));
    } else {
      final response = await http
          .get(Uri.parse(endpoint), headers: source.headers)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('频道表拉取失败：HTTP ${response.statusCode}');
      }
      text = response.body;
    }
    return parseM3u(text, sourceId: source.id).map((channel) {
      return LiveChannel(
        title: channel.title,
        url: channel.url,
        group: channel.group.isEmpty ? source.group : channel.group,
        sourceId: source.id,
        number: channel.number,
      );
    }).toList();
  }

  static List<LiveSource> get midnightSources => [
    for (final source in builtin)
      if (source.adult) source,
  ];

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

  static Future<String> loadImportedM3uUrl() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      return preferences.getString(_m3uUrlKey) ?? '';
    } catch (_) {
      return '';
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
