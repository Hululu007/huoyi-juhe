import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

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

/// 回看模板（m3u 的 catchup / catchup-source / catchup-replace）：
/// type 为 default 时 source 本身就是回看地址模板；为 append（或空）
/// 时先按 replace（「正则,替换」）改直播地址、再把 source 模板
/// 拼到地址后面。模板里 ${(b)格式} / ${(e)格式} 是节目起止时间。
/// 地址生成见 live_catchup.dart 的 formatLiveCatchupUrl。
class LiveCatchup {
  const LiveCatchup({this.type = '', this.source = '', this.replace = ''});

  final String type;
  final String source;
  final String replace;

  bool get isEmpty => source.isEmpty;

  Map<String, dynamic> toJson() => {
    'type': type,
    'source': source,
    'replace': replace,
  };

  static LiveCatchup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final item = LiveCatchup(
      type: raw['type'] as String? ?? '',
      source: raw['source'] as String? ?? '',
      replace: raw['replace'] as String? ?? '',
    );
    return item.isEmpty ? null : item;
  }
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
    this.tvgId = '',
    this.tvgName = '',
    this.headers = const {},
    this.catchup,
    this.licenseKey = '',
    this.licenseType = '',
    this.format = '',
    List<String>? urls,
  }) : urls = (urls == null || urls.isEmpty) ? [url] : List.unmodifiable(urls);

  final String title;
  final String url;
  final String group;
  final String sourceId;
  final String token;
  final String subtitle;
  final String cover;

  /// #EXTINF 的 tvg-id：节目单（EPG）对台的第一依据。
  final String tvgId;

  /// #EXTINF 的 tvg-name：节目单对台时 tvg-id 对不上用它按名匹配。
  final String tvgName;

  /// 播放请求头（#EXTVLCOPT / #EXTHTTP / 地址后 | 段攒出来的）。
  final Map<String, String> headers;

  /// 回看模板；null 表示该频道没声明回看。
  final LiveCatchup? catchup;

  /// #KODIPROP 的授权键与类型（原样存储）。是否带 DRM、属于哪类
  /// 由 live_drm.dart 的 liveDrmForChannel 判定归一化；本模型只存
  /// 原始值，不代表本应用能播放这类频道。
  final String licenseKey;
  final String licenseType;

  /// 清单类型提示（#KODIPROP manifest_type / txt 的 format 设置
  /// 行），如 hls / mpd；只存储，播放器按地址自动识别，不强制。
  final String format;

  /// 是否带 DRM 授权信息（licenseKey 非空即算；含 drm_legacy
  /// 整行存进 licenseKey 的形态，归一化时再拆）。
  bool get hasDrm => licenseKey.trim().isNotEmpty;

  LiveChannel copyWith({
    String? title,
    String? url,
    List<String>? urls,
    String? group,
    String? sourceId,
    String? token,
    String? subtitle,
    String? cover,
    String? number,
    String? tvgId,
    String? tvgName,
    Map<String, String>? headers,
    LiveCatchup? catchup,
    String? licenseKey,
    String? licenseType,
    String? format,
  }) {
    return LiveChannel(
      title: title ?? this.title,
      url: url ?? this.url,
      urls: urls ?? this.urls,
      group: group ?? this.group,
      sourceId: sourceId ?? this.sourceId,
      token: token ?? this.token,
      subtitle: subtitle ?? this.subtitle,
      cover: cover ?? this.cover,
      number: number ?? this.number,
      tvgId: tvgId ?? this.tvgId,
      tvgName: tvgName ?? this.tvgName,
      headers: headers ?? this.headers,
      catchup: catchup ?? this.catchup,
      licenseKey: licenseKey ?? this.licenseKey,
      licenseType: licenseType ?? this.licenseType,
      format: format ?? this.format,
    );
  }

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
    'tvgId': tvgId,
    'tvgName': tvgName,
    'headers': headers,
    if (catchup != null) 'catchup': catchup!.toJson(),
    'licenseKey': licenseKey,
    'licenseType': licenseType,
    'format': format,
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
      tvgId: json['tvgId'] as String? ?? '',
      tvgName: json['tvgName'] as String? ?? '',
      headers: (json['headers'] as Map? ?? {}).map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      catchup: LiveCatchup.fromJson(json['catchup']),
      licenseKey: json['licenseKey'] as String? ?? '',
      licenseType: json['licenseType'] as String? ?? '',
      format: json['format'] as String? ?? '',
    );
  }
}

/// 地址是否属于直播可播协议（http/https 与各类推流协议）。
/// 与 live_platform.dart 的 isPlayableLiveUrl 同口径；那边已先有
/// 公开定义，本文件只留私有实现供解析器内部用，避免重名冲突。
bool _isPlayableLiveUrl(String url) {
  final text = url.trim();
  if (!text.contains('://')) return false;
  final scheme = text.split('://').first.toLowerCase();
  return const {
    'http',
    'https',
    'rtmp',
    'rtsp',
    'rtp',
    'udp',
    'rtmps',
    'rtmpe',
    'rtmpt',
  }.contains(scheme);
}

/// 解析请求头文本：JSON 对象，或 `名=值&名=值`（也认 `;` 分隔）。
Map<String, String> parseLiveHeaders(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const {};
  final result = <String, String>{};
  dynamic decoded;
  if (text.startsWith('{')) {
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
  }
  if (decoded is Map) {
    for (final entry in decoded.entries) {
      result[entry.key.toString()] = entry.value.toString();
    }
    return result;
  }
  for (final pair in text.split(RegExp(r'[&;]'))) {
    final at = pair.indexOf('=');
    if (at <= 0) continue;
    final key = pair.substring(0, at).trim();
    final value = pair.substring(at + 1).trim();
    if (key.isEmpty || value.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

String? _m3uAttribute(String line, String key) =>
    RegExp('$key="([^"]*)"').firstMatch(line)?.group(1)?.trim();

/// 回看三属性（#EXTM3U 头上是全源默认、#EXTINF 上是本频道覆盖）；
/// 本行没声明时用 [fallback]。
LiveCatchup? _catchupFromAttrs(String line, LiveCatchup? fallback) {
  final item = LiveCatchup(
    type: _m3uAttribute(line, 'catchup') ?? '',
    source: _m3uAttribute(line, 'catchup-source') ?? '',
    replace: _m3uAttribute(line, 'catchup-replace') ?? '',
  );
  return item.isEmpty ? fallback : item;
}

/// 附加行攒出来的待填设置（请求头 / 授权键 / 清单类型）：跟在
/// #EXTINF（或 txt 分组行）后面、地址行前面，落到紧接着的频道上。
/// 与魔蚁 _Setters 同口径，差别是本树在频道落位后清掉（按频道
/// 作用域），魔蚁是整表不清、后续频道会继承前一频道的设置。
class _LiveSetters {
  final Map<String, String> _headers = {};
  String _userAgent = '';
  String _referer = '';
  String _origin = '';
  String licenseKey = '';
  String licenseType = '';
  String format = '';

  static String _value(String line) {
    final at = line.indexOf('=');
    if (at < 0) return '';
    return line.substring(at + 1).trim();
  }

  void read(String line) {
    if (line.startsWith('#EXTHTTP:')) {
      _headers.addAll(parseLiveHeaders(line.substring(9)));
      return;
    }
    if (line.startsWith('#KODIPROP:inputstream.adaptive.stream_headers') ||
        line.startsWith('#KODIPROP:inputstream.adaptive.common_headers')) {
      readHeader(_value(line));
      return;
    }
    if (line.startsWith('#KODIPROP:inputstream.adaptive.license_key')) {
      licenseKey = _value(line);
      return;
    }
    if (line.startsWith('#KODIPROP:inputstream.adaptive.license_type')) {
      licenseType = _value(line);
      return;
    }
    if (line.startsWith('#KODIPROP:inputstream.adaptive.drm_legacy')) {
      // 老式合并写法（类型与键写在一行）：整行存进 licenseKey，
      // 类型能拆出来就拆（逗号/竖线前一段当类型）。
      final raw = _value(line);
      if (licenseKey.isEmpty) licenseKey = raw;
      if (licenseType.isEmpty) {
        final split = raw.split(RegExp(r'[,|]'));
        if (split.length > 1) licenseType = split.first.trim();
      }
      return;
    }
    if (line.startsWith('#KODIPROP:inputstream.adaptive.manifest_type')) {
      format = _value(line);
      return;
    }
    if (line.startsWith('format')) {
      format = _value(line);
      return;
    }
    if (line.startsWith('#EXTVLCOPT:http-cookie')) {
      _headers['Cookie'] = _value(line);
      return;
    }
    if (line.startsWith('#EXTVLCOPT:http-origin')) {
      _origin = _value(line);
      return;
    }
    if (line.startsWith('#EXTVLCOPT:http-user-agent')) {
      _userAgent = _value(line);
      return;
    }
    if (line.startsWith('#EXTVLCOPT:http-referrer')) {
      _referer = _value(line);
      return;
    }
    if (line.startsWith('ua')) {
      _userAgent = _value(line);
      return;
    }
    if (line.startsWith('referer')) {
      _referer = _value(line);
      return;
    }
    if (line.startsWith('origin')) {
      _origin = _value(line);
      return;
    }
    if (line.startsWith('header')) readHeader(_value(line));
  }

  void readHeader(String raw) {
    if (raw.trim().isEmpty) return;
    _headers.addAll(parseLiveHeaders(raw));
  }

  Map<String, String> headers() {
    final result = <String, String>{};
    if (_userAgent.isNotEmpty) result['User-Agent'] = _userAgent;
    if (_referer.isNotEmpty) result['Referer'] = _referer;
    if (_origin.isNotEmpty) result['Origin'] = _origin;
    result.addAll(_headers);
    return result;
  }

  void clear() {
    _headers.clear();
    _userAgent = '';
    _referer = '';
    _origin = '';
    licenseKey = '';
    licenseType = '';
    format = '';
  }
}

bool _isLiveDirective(String line) =>
    line.startsWith('#EXTVLCOPT:') ||
    line.startsWith('#KODIPROP:') ||
    line.startsWith('#EXTHTTP:');

const _txtMetaPrefixes = [
  '更新时间',
  '更新日期',
  'update time',
  'update date',
  'last update',
];

bool _isTxtMetaChannel(String name) {
  final text = name.trim().toLowerCase();
  if (text.isEmpty) return false;
  return _txtMetaPrefixes.any(text.startsWith);
}

List<LiveChannel> parseM3u(String text, {String sourceId = ''}) {
  final channels = <LiveChannel>[];
  String? pendingTitle;
  var pendingGroup = '';
  String? pendingNumber;
  var pendingTvgId = '';
  var pendingTvgName = '';
  LiveCatchup? pendingCatchup;
  LiveCatchup? globalCatchup;
  final setters = _LiveSetters();
  var number = 0;
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTM3U')) {
      globalCatchup = _catchupFromAttrs(line, globalCatchup);
      continue;
    }
    if (line.startsWith('#EXTINF')) {
      final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
      pendingGroup = groupMatch?.group(1) ?? '';
      final chnoMatch = RegExp(r'tvg-chno="([^"]*)"').firstMatch(line);
      final chno = chnoMatch?.group(1)?.trim() ?? '';
      pendingNumber = chno.isEmpty ? null : chno.padLeft(3, '0');
      pendingTvgId = _m3uAttribute(line, 'tvg-id') ?? '';
      pendingTvgName = _m3uAttribute(line, 'tvg-name') ?? '';
      // 频道自己的回看优先，没有才落全源默认。
      pendingCatchup = _catchupFromAttrs(line, null) ?? globalCatchup;
      final userAgent = _m3uAttribute(line, 'http-user-agent');
      if (userAgent != null && userAgent.isNotEmpty) {
        setters.readHeader('User-Agent=$userAgent');
      }
      final comma = line.indexOf(',');
      pendingTitle = comma >= 0 ? line.substring(comma + 1).trim() : '未命名频道';
      continue;
    }
    if (_isLiveDirective(line)) {
      setters.read(line);
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
        tvgId: pendingTvgId,
        tvgName: pendingTvgName,
        headers: setters.headers(),
        catchup: pendingCatchup,
        licenseKey: setters.licenseKey,
        licenseType: setters.licenseType,
        format: setters.format,
      ),
    );
    pendingTitle = null;
    pendingGroup = '';
    pendingNumber = null;
    pendingTvgId = '';
    pendingTvgName = '';
    pendingCatchup = null;
    setters.clear();
  }
  return channels;
}

class _TxtChannelBuilder {
  _TxtChannelBuilder(this.title, this.group);
  final String title;
  final String group;
  final List<String> urls = [];
  Map<String, String> headers = {};
  String licenseKey = '';
  String licenseType = '';
  String format = '';
}

/// TXT 播放列表解析（与魔蚁 LiveParser 的 TXT 口径一致）：
/// `分组名,#genre#` 是分组行；`ua=` / `referer=` / `origin=` /
/// `header=` / `format=` 是设置行，作用于其后频道、到下一分组行
/// 清掉；`频道名,地址` 是频道行，地址可用 `#` 拼多条线路，每条
/// 地址后可跟 `|请求头`（`名=值&名=值`）。同组同名频道合并线路。
/// 输出与 parseM3u 同模型（LiveChannel），分组写在 group 字段。
List<LiveChannel> parseTxtList(
  String text, {
  String sourceId = '',
  String defaultGroup = '其他',
}) {
  final groupOrder = <String>[];
  final groups = <String, Map<String, _TxtChannelBuilder>>{};
  final setters = _LiveSetters();
  var currentGroup = '';

  Map<String, _TxtChannelBuilder> groupMap(String name) {
    var map = groups[name];
    if (map == null) {
      map = <String, _TxtChannelBuilder>{};
      groups[name] = map;
      groupOrder.add(name);
    }
    return map;
  }

  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    if (RegExp(
      r'^(ua|parse|click|header|format|origin|referer|forceKey)=',
    ).hasMatch(line)) {
      setters.read(line);
      continue;
    }
    final comma = line.indexOf(',');
    if (line.contains('#genre#')) {
      setters.clear();
      final name = comma >= 0 ? line.substring(0, comma).trim() : '';
      currentGroup = name.isEmpty ? defaultGroup : name;
      groupMap(currentGroup);
      continue;
    }
    if (comma < 0) continue;
    final name = line.substring(0, comma).trim();
    if (name.isEmpty || _isTxtMetaChannel(name)) continue;
    final tail = line.substring(comma + 1);
    if (currentGroup.isEmpty) currentGroup = defaultGroup;
    final builder = groupMap(
      currentGroup,
    ).putIfAbsent(name, () => _TxtChannelBuilder(name, currentGroup));
    for (final entry in tail.split('#')) {
      final pipe = entry.indexOf('|');
      final url = (pipe >= 0 ? entry.substring(0, pipe) : entry).trim();
      if (!_isPlayableLiveUrl(url)) continue;
      var headers = setters.headers();
      if (pipe >= 0) {
        final extra = entry.substring(pipe + 1).trim();
        if (extra.isNotEmpty) {
          headers = {...headers, ...parseLiveHeaders(extra)};
        }
      }
      builder.urls.add(url);
      builder.headers = headers;
      if (setters.licenseKey.isNotEmpty) {
        builder.licenseKey = setters.licenseKey;
      }
      if (setters.licenseType.isNotEmpty) {
        builder.licenseType = setters.licenseType;
      }
      if (setters.format.isNotEmpty) builder.format = setters.format;
    }
  }

  final channels = <LiveChannel>[];
  var number = 0;
  for (final groupName in groupOrder) {
    for (final builder in groups[groupName]!.values) {
      if (builder.urls.isEmpty) continue;
      number++;
      channels.add(
        LiveChannel(
          title: builder.title,
          url: builder.urls.first,
          urls: builder.urls,
          group: builder.group,
          sourceId: sourceId,
          number: number.toString().padLeft(3, '0'),
          headers: builder.headers,
          licenseKey: builder.licenseKey,
          licenseType: builder.licenseType,
          format: builder.format,
        ),
      );
    }
  }
  return channels;
}

class LiveSources {
  LiveSources._();

  /// 原生直播行（不进站点库）：whos_lib 读用户外置女优库、没有包内
  /// 定义可搬；bilibili 走 Dart 专用接口代码（live_api.dart），
  /// 同样搬不动。原 23 个 m3u 清单源（含 user_m3u）与 3 个平台源
  /// （秀果/欲火聚合/百年直播）已改由站点库供数（sqlSources），
  /// 数据由生成器进库，本表不再保留那 26 行。
  static const _nativeBuiltin = <LiveSource>[
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

  /// 站点库供数的直播源（SiteLibraryService.load() 组装）：
  /// liveM3u 行的端点是落盘后的本地文件路径，livePlatform 行按
  /// ext JSON 还原。未导入站点库时为空表。
  static List<LiveSource> sqlSources = <LiveSource>[];

  /// 全部内置直播源＝原生行＋站点库行。顺序保持站点库改造前的出厂序：
  /// 内置片库第一、站点库供数的 26 源居中、哔哩哔哩殿后——默认源
  /// （第一个非片库源）与选择器排布都不因改造变样。
  static List<LiveSource> get builtin => [
    if (_nativeBuiltin.isNotEmpty) _nativeBuiltin.first,
    ...sqlSources,
    ..._nativeBuiltin.skip(1),
  ];

  static LiveSource? byId(String id) {
    for (final source in builtin) {
      if (source.id == id) return source;
    }
    return null;
  }

  /// 进页默认源：登记表里第一个真正的直播源，**不是内置片库**。
  /// 内置片库（whos_lib）进页要先开 44.9 万行的大库再做全表聚合，
  /// 压它当默认源时这条链任何一步慢/挂，直播页就永久「载入中…」
  /// （2026-11-26 诊断第 1 位根因）。片库仍留在登记表里，用户在
  /// 切换源弹窗里点选后才加载；这里只改默认选取，登记表不改。
  static LiveSource get defaultSource {
    for (final source in builtin) {
      if (source.id != whosLibSourceId) return source;
    }
    return builtin.first;
  }

  static Future<List<LiveChannel>> loadBuiltinListChannels(
    LiveSource source,
  ) async {
    final endpoint = source.endpoint;
    final String text;
    if (endpoint.startsWith('asset://')) {
      text = await rootBundle.loadString(endpoint.substring('asset://'.length));
    } else if (endpoint.startsWith('/') || endpoint.startsWith('file://')) {
      // 本地文件端点：站点库 liveM3u 行落盘后的代码文件路径。
      final path = endpoint.startsWith('file://')
          ? endpoint.substring('file://'.length)
          : endpoint;
      text = await File(path).readAsString();
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
      return channel.copyWith(
        group: channel.group.isEmpty ? source.group : channel.group,
        sourceId: source.id,
      );
    }).toList();
  }

  static List<LiveSource> get midnightSources => [
    for (final source in builtin)
      if (source.adult) source,
  ];

  // 旧单槽导入（loadImportedChannels / importM3uUrl 三件套）已由
  // 多槽订阅机件接管（services/live_subscriptions.dart）：老键
  // juhe_live_m3u_channels / juhe_live_m3u_url 由订阅机件在首次
  // 加载时迁成一条订阅记录后删除，不再有第二条导入通路。
}
