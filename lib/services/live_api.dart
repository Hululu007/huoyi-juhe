import 'dart:convert';

import 'package:http/http.dart' as http;

import 'live_platform.dart';
import 'live_sources.dart';

/// api 型直播源（魔蚁 lib/live_api.dart 的修仙版移植）。
///
/// 魔蚁侧 LiveRepository 按 protocol 分流：pingtai 走平台接口、list 走
/// m3u、api 走这里的 LiveApiSpec。修仙版此前只有 pingtai/list，2026-11-22
/// 合入 bilibili 时把这一层按最小实现搬过来：只保留 bilibili 一个已验活
/// 的 spec 与三段解析（分类 / 房间列表 / 播放地址），不搬魔蚁的
/// LiveRepository 缓存层与 LiveHttp（cookie 罐、设备信息），取数直接用
/// package:http + 与 live_platform.dart 相同的 UA。
///
/// 待接入清单（魔蚁 live_api.dart 的 pendingLiveApiSources，原样照录，
/// 一个都没登记为内置源）：接口未完整还原，补齐前不翻为可用。

enum LiveApiPlayKind { direct, bilibili }

class LiveApiSpec {
  const LiveApiSpec({
    required this.id,
    required this.listUrl,
    this.listPaths = const ['data.list', 'list', 'data'],
    this.titleKeys = const ['title'],
    this.nameKeys = const ['uname', 'nick', 'username'],
    this.coverKeys = const ['cover'],
    this.idKeys = const ['roomid', 'roomId', 'id'],
    this.playKeys = const ['playUrl', 'streamUrl', 'hlsUrl', 'url'],
    this.playUrl = '',
    this.playKind = LiveApiPlayKind.direct,
    this.playPaths = const ['data.url', 'url'],
    this.platformsUrl = '',
    this.platformPaths = const ['data'],
    this.platformIdKey = 'id',
    this.platformNameKey = 'name',
    this.platformParentKey = 'parent_id',
    this.platformChildKey = 'list',
    this.flattenPlatforms = false,
    this.derivePlatformName = false,
    this.deriveNameKey = 'gameFullName',
    this.deriveCountPath = 'data.totalCount',
    this.singlePlatformId = 'all',
    this.singlePlatformName = '全部',
    this.paginated = false,
    this.headers = const {},
  });

  final String id;
  final String listUrl;
  final List<String> listPaths;
  final List<String> titleKeys;
  final List<String> nameKeys;
  final List<String> coverKeys;
  final List<String> idKeys;
  final List<String> playKeys;
  final String playUrl;
  final LiveApiPlayKind playKind;
  final List<String> playPaths;
  final String platformsUrl;
  final List<String> platformPaths;
  final String platformIdKey;
  final String platformNameKey;
  final String platformParentKey;
  final String platformChildKey;
  final bool flattenPlatforms;
  final bool derivePlatformName;
  final String deriveNameKey;
  final String deriveCountPath;
  final String singlePlatformId;
  final String singlePlatformName;
  final bool paginated;
  final Map<String, String> headers;

  String listUrlFor(LivePlatform platform, {int page = 1}) => listUrl
      .replaceAll('{platform}', platform.id)
      .replaceAll('{endpoint}', platform.endpoint)
      .replaceAll('{page}', '$page');

  String playUrlFor(String roomId) =>
      playUrl.replaceAll('{id}', Uri.encodeComponent(roomId));
}

const liveApiSpecs = <String, LiveApiSpec>{
  'bilibili': LiveApiSpec(
    id: 'bilibili',
    listUrl:
        'https://api.live.bilibili.com/room/v3/area/getRoomList?area_id={platform}&parent_area_id={endpoint}&page={page}&page_size=30',
    listPaths: ['data.list'],
    titleKeys: ['title'],
    nameKeys: ['uname'],
    coverKeys: ['cover'],
    idKeys: ['roomid'],
    playKeys: [],
    playUrl:
        'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id={id}&protocol=0,1&format=0,1,2&codec=0,1&qn=10000&platform=web&ptype=8',
    playKind: LiveApiPlayKind.bilibili,
    platformsUrl: 'https://api.live.bilibili.com/room/v1/Area/getList',
    platformPaths: ['data'],
    flattenPlatforms: true,
    paginated: true,
    headers: {'Referer': 'https://live.bilibili.com/'},
  ),
};

LiveApiSpec? liveApiSpecById(String id) => liveApiSpecs[id];

/// 待接入：已从绿果鉴包里提出地址，但列表或播放接口未完整还原，
/// 暂不登记为内置源，等接口补齐后再翻为可用（魔蚁原样）。
const pendingLiveApiSources = <String, String>{
  'douyu': '列表接口需有效的分类号（type=1 回“分类信息不存在”），取流需加密签名。',
  'yy': '只有站址，没有列表与播放接口。',
  'netease_cc': '分类列表已验活，房间列表接口未还原。',
  'chaturbate': '房间列表匿名调被 302 拦回首页，需登录会话。',
  'stripchat': '只有站址与镜像站，列表接口未还原；播放原走原 App 的 HLS 代理，不用。',
  'myfreecams': 'FcwExtResp.php 已 404，modelobject.php 未验。',
  'bongacams': 'listing_v3.php 匿名调只回 null，需补参数。',
  'cam4': 'directoryCams 片段归属未证实。',
  'livejasmin': 'front models 路径的宿主未证实。',
  'flirt4free': '只有站址，没有列表与播放接口。',
  'secretfriends': '只有站址，没有列表与播放接口。',
  'sinparty': '只有 WebRTC 播放地址，当前播放器不接 WebRTC。',
  'hotica': 'api.hotica.com 匿名调回空响应。',
  'uu': '只有一个类名，没有任何地址。',
};

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

Future<String> _apiGet(String url, {Map<String, String> headers = const {}}) async {
  final response = await http
      .get(Uri.parse(url), headers: {'User-Agent': _userAgent, ...headers})
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw StateError('请求失败：HTTP ${response.statusCode}');
  }
  return response.body;
}

/// 取 api 源的分类（分区）表。spec 没给 platformsUrl 时退回单分区分支，
/// 与魔蚁 LiveRepository._apiPlatforms 同口径。
Future<List<LivePlatform>> fetchApiPlatforms(LiveSource source) async {
  final spec = liveApiSpecById(source.id);
  if (spec == null) throw StateError('该直播源暂未接入');
  if (spec.platformsUrl.isEmpty) {
    if (!spec.derivePlatformName) {
      return [
        LivePlatform(
          id: spec.singlePlatformId,
          name: spec.singlePlatformName,
        ),
      ];
    }
    final text = await _apiGet(
      spec.listUrlFor(
        LivePlatform(id: spec.singlePlatformId, name: spec.singlePlatformName),
        page: 1,
      ),
      headers: spec.headers,
    );
    return [
      LivePlatform(
        id: spec.singlePlatformId,
        name: deriveApiPlatformName(spec, text),
        count: deriveApiPlatformCount(spec, text),
      ),
    ];
  }
  final text = await _apiGet(spec.platformsUrl, headers: spec.headers);
  final result = parseApiPlatforms(spec, text);
  if (result.isEmpty) throw StateError('该直播源没有可用分类');
  return result;
}

/// 取 api 源某分区的一页房间。修仙版直播页 _loadChannels 没有页码透传，
/// 目前只拉第 1 页（bilibili 每页 30 条），滚动续载未接，见 live_REPORT.md。
Future<List<LiveChannel>> fetchApiChannels(
  LiveSource source,
  LivePlatform platform, {
  int page = 1,
}) async {
  final spec = liveApiSpecById(source.id);
  if (spec == null) throw StateError('该直播源暂未接入');
  final text = await _apiGet(
    spec.listUrlFor(platform, page: page),
    headers: spec.headers,
  );
  final result = parseApiChannels(spec, platform, text, source.id);
  if (result.isEmpty) throw StateError('该分类暂时没有频道');
  return result;
}

/// 播放时把房间解析成直链：列表里已带直链的直接用；否则按 token（房间号）
/// 现调播放接口取流。返回空串表示解析失败，调用方按播放失败处理。
Future<String> resolveLiveApiPlayUrl(
  LiveSource source,
  LiveChannel channel,
) async {
  if (channel.url.isNotEmpty && channel.url.contains('://')) {
    return channel.url;
  }
  final spec = liveApiSpecById(source.id);
  if (spec == null) return '';
  if (spec.playUrl.isEmpty || channel.token.isEmpty) return '';
  try {
    final text = await _apiGet(
      spec.playUrlFor(channel.token),
      headers: spec.headers,
    );
    return parseApiPlayUrl(spec, text) ?? '';
  } catch (_) {
    return '';
  }
}

dynamic _atPath(dynamic node, String path) {
  dynamic current = node;
  for (final part in path.split('.')) {
    if (current is Map) {
      current = current[part];
    } else if (current is List) {
      final index = int.tryParse(part);
      if (index == null || index < 0 || index >= current.length) return null;
      current = current[index];
    } else {
      return null;
    }
    if (current == null) return null;
  }
  return current;
}

List<dynamic> _findList(dynamic decoded, List<String> paths) {
  for (final path in paths) {
    final value = _atPath(decoded, path);
    if (value is List) return value;
  }
  return const [];
}

String _pickString(Map row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is num) return '$value';
  }
  return '';
}

dynamic _decodeJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

List<LivePlatform> parseApiPlatforms(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return const [];
  final rows = _findList(decoded, spec.platformPaths);
  final result = <LivePlatform>[];
  for (final row in rows.whereType<Map>()) {
    if (spec.flattenPlatforms) {
      final parentId = _pickString(row, [spec.platformIdKey]);
      final children = row[spec.platformChildKey];
      if (children is List) {
        for (final child in children.whereType<Map>()) {
          final id = _pickString(child, [spec.platformIdKey]);
          final name = _pickString(child, [spec.platformNameKey]);
          if (id.isEmpty || name.isEmpty) continue;
          result.add(LivePlatform(id: id, name: name, endpoint: parentId));
        }
      }
      continue;
    }
    final id = _pickString(row, [spec.platformIdKey]);
    final name = _pickString(row, [spec.platformNameKey]);
    if (id.isEmpty || name.isEmpty) continue;
    result.add(LivePlatform(id: id, name: name));
  }
  return result;
}

String deriveApiPlatformName(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return spec.singlePlatformName;
  final rows = _findList(decoded, spec.listPaths);
  final first = rows.whereType<Map>().firstOrNull;
  if (first == null) return spec.singlePlatformName;
  final name = _pickString(first, [spec.deriveNameKey]);
  return name.isEmpty ? spec.singlePlatformName : name;
}

int deriveApiPlatformCount(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return 0;
  final value = _atPath(decoded, spec.deriveCountPath);
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

List<LiveChannel> parseApiChannels(
  LiveApiSpec spec,
  LivePlatform platform,
  String text,
  String sourceId,
) {
  final decoded = _decodeJson(text);
  if (decoded == null) return const [];
  final rows = _findList(decoded, spec.listPaths);
  final result = <LiveChannel>[];
  var number = 0;
  for (final row in rows.whereType<Map>()) {
    final title = _pickString(row, spec.titleKeys);
    if (title.isEmpty) continue;
    final roomId = _pickString(row, spec.idKeys);
    final play = _pickString(row, spec.playKeys);
    final playable = play.isNotEmpty && isPlayableLiveUrl(play);
    number++;
    // token  carries the room id so playback can resolve it later.
    // 修仙版 LiveChannel 没有 headers 字段：B 站列表与取流要的 Referer
    // 由本文件取数时直接带上，不存在频道上。
    result.add(
      LiveChannel(
        title: title,
        url: playable ? play : '',
        group: platform.name,
        sourceId: sourceId,
        token: roomId,
        subtitle: _pickString(row, spec.nameKeys),
        cover: _pickString(row, spec.coverKeys),
        number: number.toString().padLeft(3, '0'),
      ),
    );
  }
  return result;
}

String? parseApiPlayUrl(LiveApiSpec spec, String text) {
  final decoded = _decodeJson(text);
  if (decoded == null) return null;
  switch (spec.playKind) {
    case LiveApiPlayKind.bilibili:
      return _bilibiliPlayUrl(decoded);
    case LiveApiPlayKind.direct:
      for (final path in spec.playPaths) {
        final value = _atPath(decoded, path);
        if (value is String && isPlayableLiveUrl(value)) return value.trim();
      }
      return null;
  }
}

String? _bilibiliPlayUrl(dynamic decoded) {
  final streams = _atPath(decoded, 'data.playurl_info.playurl.stream');
  if (streams is! List) return null;
  String? fallback;
  for (final stream in streams.whereType<Map>()) {
    final protocol = '${stream['protocol_name'] ?? ''}';
    final formats = stream['format'];
    if (formats is! List) continue;
    for (final format in formats.whereType<Map>()) {
      final formatName = '${format['format_name'] ?? ''}';
      final codecs = format['codec'];
      if (codecs is! List) continue;
      for (final codec in codecs.whereType<Map>()) {
        final base = '${codec['base_url'] ?? ''}';
        if (base.isEmpty) continue;
        final infos = codec['url_info'];
        if (infos is! List) continue;
        for (final info in infos.whereType<Map>()) {
          final host = '${info['host'] ?? ''}'.trim();
          if (host.isEmpty) continue;
          final extra = '${info['extra'] ?? ''}';
          final url = '$host$base$extra';
          if (!isPlayableLiveUrl(url)) continue;
          final preferred =
              protocol == 'http_hls' &&
              formatName == 'ts' &&
              '${codec['codec_name'] ?? ''}' == 'avc';
          if (preferred) return url;
          fallback ??= url;
        }
      }
    }
  }
  return fallback;
}
