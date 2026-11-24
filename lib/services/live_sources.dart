import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

enum LiveProtocol { pingtai, list, api }

/// 内置片库源 id：与 services/whos_live_bridge.dart 的桥层共用。
/// 常量放这里（源表要先用 id），避免 live_sources ↔ bridge 循环引用。
const whosLibSourceId = 'whos_lib';

/// 内置片库的直播源地址前缀：走本地库，不联网拉清单。
const whosLibScheme = 'whoslib://';

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
    // 非 http 行（22 个 m3u 清单里混进的 8 行杂文本，如 12_wuma 里的
    // 两行标题残句、20_avxiongdi 第 2 行的 `无码,#genre#`）只跳过，
    // 不清 pending：魔蚁 LiveParser 也是跳过不丢待填标题。旧写法清掉
    // pending 会让紧跟的地址行丢标题、频道名变成地址本身，实测 6 条
    // 受影响（12_wuma 2 条、16_zhifu 1 条、19_zipai 3 条）。
    if (!line.toLowerCase().startsWith('http')) continue;
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
    // 内置片库（2026-11-24 与魔蚁对齐，登记表第 1 项）：优先读本地
    // 数据库 MYTV/db/女优库.db（34 万+，全是 m3u8 直链），没库才读
    // documents/actress_json/ 里的两个 JSON；包里不带任何种子。
    // 走 whoslib:// 由本地库出频道，不联网、不用订阅，分类是最新 /
    // 排行榜 / 厂牌、按页取频道（见 services/whos_live_bridge.dart）。
    // 魔蚁同款，id/端点/顺序一致；名字沿修仙版既有写法不带 🔞 前缀。
    LiveSource(
      id: whosLibSourceId,
      name: '内置片库',
      description: '装机自带片库 · 按厂牌分类 · 点开就播',
      protocol: LiveProtocol.list,
      endpoints: ['${whosLibScheme}all'],
      group: '内置片库',
      adult: true,
    ),
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
    // 2026-11-22 魔蚁合入：22 个清洗版 m3u 清单，每文件一个源，文件对应
    // 分组（group-title 缺失的条目落入 group 默认分组）。资产为魔蚁包内
    // 清洗版字节原样，条目数见 live_REPORT.md（合计 EXTINF 127395 条，
    // 修仙版 parseM3u 实出 127392 条频道，见 parseM3u 注释）。
    // 全部 adult: true，走直播页整页境界门禁；名字沿修仙版既有写法
    // 不带 🔞 前缀（魔蚁侧名字带 🔞，含义相同，见报告对照表）。
    LiveSource(
      id: 'm3u_zhubo',
      name: '主播网红',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/01_zhubo.m3u'],
      group: '主播网红',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_luanlun',
      name: '乱伦精品',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/02_luanlun.m3u'],
      group: '乱伦精品',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_huayu',
      name: '华语精品',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/03_huayu.m3u'],
      group: '华语精品',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_guochan',
      name: '国产精品',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/04_guochan.m3u'],
      group: '国产精品',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_xuesheng',
      name: '学生合集',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/05_xuesheng.m3u'],
      group: '学生合集',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_tanhua',
      name: '探花约炮',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/06_tanhua.m3u'],
      group: '探花约炮',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_riben',
      name: '日本有码',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/07_riben.m3u'],
      group: '日本有码',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_oumei',
      name: '欧美大屌',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/08_oumei.m3u'],
      group: '欧美大屌',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_heilian',
      name: '黑料吃瓜',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/09_heilian.m3u'],
      group: '黑料吃瓜',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_community10',
      name: '社区合集 10',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/10_community10.m3u8'],
      group: '社区合集 10',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_community11',
      name: '社区合集 11',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/11_community11.m3u8'],
      group: '社区合集 11',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_wuma',
      name: '無碼專區',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/12_wuma.m3u'],
      group: '無碼專區',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_wanghong',
      name: '網紅頭條',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/13_wanghong.m3u'],
      group: '網紅頭條',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_xingba',
      name: '杏吧原創',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/14_xingba.m3u'],
      group: '杏吧原創',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_chengtou',
      name: '成人頭條',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/15_chengtou.m3u'],
      group: '成人頭條',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_zhifu',
      name: '制服絲襪',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/16_zhifu.m3u'],
      group: '制服絲襪',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_qunjiao',
      name: '群交淫亂',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/17_qunjiao.m3u'],
      group: '群交淫亂',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_mingxing',
      name: '明星換臉',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/18_mingxing.m3u'],
      group: '明星換臉',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_zipai',
      name: '自拍偷拍',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/19_zipai.m3u'],
      group: '自拍偷拍',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_avxiongdi',
      name: 'AV兄弟无码',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/20_avxiongdi.m3u'],
      group: 'AV兄弟无码',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_guochanse',
      name: '国产色情',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/21_guochanse.m3u'],
      group: '国产色情',
      adult: true,
    ),
    LiveSource(
      id: 'm3u_riben2',
      name: '日本有码 2',
      description: '用户提供的 m3u 清单 · 点开即播',
      protocol: LiveProtocol.list,
      endpoints: ['asset://assets/live/m3u/22_riben2.m3u'],
      group: '日本有码',
      adult: true,
    ),
    // 2026-11-22 魔蚁合入：哔哩哔哩（唯一非成人直播源，adult: false）。
    // 走 LiveProtocol.api：分类与房间列表调 B 站公开接口，播放时按
    // roomId 现取播放地址（见 lib/services/live_api.dart）。
    // 注意：直播页整页仍由 unlockedVideo（元婴）门禁守着，bilibili
    // 目前也随整页上锁，拆分门禁是后续待定项，见 live_REPORT.md。
    LiveSource(
      id: 'bilibili',
      name: '哔哩哔哩',
      description: 'B站直播 · 分区房间 · 列表已验活',
      protocol: LiveProtocol.api,
      adult: false,
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
