import 'dart:convert';

import 'package:http/http.dart' as http;

import 'live_sources.dart';

class LivePlatform {
  const LivePlatform({
    required this.id,
    required this.name,
    this.logo = '',
    this.count = 0,
    this.endpoint = '',
  });

  final String id;
  final String name;
  final String logo;
  final int count;
  final String endpoint;
}

bool isPlayableLiveUrl(String url) {
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

const _userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36';

Future<String> _get(
  String url, {
  Map<String, String> headers = const {},
}) async {
  final response = await http
      .get(
        Uri.parse(url),
        headers: {'User-Agent': _userAgent, ...headers},
      )
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw StateError('请求失败：HTTP ${response.statusCode}');
  }
  return response.body;
}

String _text(Object? value) => '${value ?? ''}'.trim();

List<LivePlatform> livePlatformCategories(String sourceId) {
  switch (sourceId) {
    case 'bilibili':
      return const [LivePlatform(id: 'rec', name: '热门推荐')];
    case 'huya':
      return const [
        LivePlatform(id: '0', name: '全部'),
        LivePlatform(id: '2336', name: '王者荣耀'),
        LivePlatform(id: '1', name: '英雄联盟'),
        LivePlatform(id: '1663', name: '星秀'),
        LivePlatform(id: '3203', name: '和平精英'),
        LivePlatform(id: '2165', name: '户外'),
        LivePlatform(id: '1732', name: '我的世界'),
        LivePlatform(id: '100029', name: '暗区突围'),
        LivePlatform(id: '2633', name: '二次元'),
        LivePlatform(id: '1964', name: '主机游戏'),
        LivePlatform(id: '2793', name: '天天吃鸡'),
        LivePlatform(id: '4', name: '穿越火线'),
        LivePlatform(id: '8', name: '魔兽世界'),
        LivePlatform(id: '2', name: '地下城与勇士'),
        LivePlatform(id: '7', name: 'DOTA2'),
      ];
    default:
      return const [];
  }
}

String liveRoomsUrl(String sourceId, String platformId, int page) {
  switch (sourceId) {
    case 'bilibili':
      return 'https://api.live.bilibili.com/xlive/web-interface/v1/webMain/getMoreRecList'
          '?platform=web&page=$page';
    case 'huya':
      return 'https://www.huya.com/cache.php?m=LiveList&do=getLiveListByPage'
          '&tagAll=0&page=$page'
          '${platformId == '0' ? '' : '&gameId=$platformId'}';
    default:
      return '';
  }
}

Future<List<LiveChannel>> fetchPlatformRooms(
  String sourceId,
  LivePlatform platform,
  int page,
) async {
  final url = liveRoomsUrl(sourceId, platform.id, page);
  if (url.isEmpty) return const [];
  final headers = LiveSources.byId(sourceId)?.headers ?? const {};
  final body = await _get(url, headers: headers);
  return liveParseRooms(sourceId, platform, body, firstNumber: 1);
}

List<LiveChannel> liveParseRooms(
  String sourceId,
  LivePlatform platform,
  String body, {
  int firstNumber = 1,
}) {
  switch (sourceId) {
    case 'bilibili':
      return _bilibiliRooms(sourceId, platform, body, firstNumber);
    case 'huya':
      return _huyaRooms(sourceId, platform, body, firstNumber);
    default:
      return const [];
  }
}

List<LiveChannel> _bilibiliRooms(
  String sourceId,
  LivePlatform platform,
  String body,
  int firstNumber,
) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final data = decoded is Map ? decoded['data'] : null;
  final rows = data is Map ? data['recommend_room_list'] : null;
  if (rows is! List) return const [];
  final channels = <LiveChannel>[];
  for (final row in rows.whereType<Map>()) {
    final roomId = _text(row['roomid']);
    if (roomId.isEmpty) continue;
    final uname = _text(row['uname']);
    final title = _text(row['title']);
    final area = [
      _text(row['area_v2_parent_name']),
      _text(row['area_v2_name']),
    ].where((value) => value.isNotEmpty).join('/');
    final online = row['online'];
    final subtitle = [
      if (uname.isNotEmpty) uname,
      if (area.isNotEmpty) area,
      if (online is num && online > 0) '$online 人气',
    ].join(' · ');
    channels.add(
      LiveChannel(
        title: title.isEmpty ? (uname.isEmpty ? '直播间 $roomId' : uname) : title,
        url: 'https://live.bilibili.com/$roomId',
        group: platform.name,
        sourceId: sourceId,
        token: roomId,
        subtitle: subtitle,
      ),
    );
  }
  return channels;
}

List<LiveChannel> _huyaRooms(
  String sourceId,
  LivePlatform platform,
  String body,
  int firstNumber,
) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final data = decoded is Map ? decoded['data'] : null;
  final rows = data is Map ? data['datas'] : null;
  if (rows is! List) return const [];
  final channels = <LiveChannel>[];
  for (final row in rows.whereType<Map>()) {
    final room = _text(row['profileRoom']);
    if (room.isEmpty || room == '0') continue;
    final nick = _text(row['nick']);
    final title = _text(row['introduction']).isNotEmpty
        ? _text(row['introduction'])
        : _text(row['roomName']);
    final game = _text(row['gameFullName']);
    final subtitle = [
      if (nick.isNotEmpty) nick,
      if (game.isNotEmpty) game,
    ].join(' · ');
    channels.add(
      LiveChannel(
        title: title.isEmpty ? (nick.isEmpty ? '直播间 $room' : nick) : title,
        url: 'https://www.huya.com/$room',
        group: platform.name,
        sourceId: sourceId,
        token: room,
        subtitle: subtitle,
      ),
    );
  }
  return channels;
}

String livePlaybackRequestUrl(String sourceId, LiveChannel channel) {
  switch (sourceId) {
    case 'bilibili':
      return 'https://api.live.bilibili.com/room/v1/Room/playUrl'
          '?cid=${channel.token}&qn=10000&platform=web';
    case 'huya':
      return 'https://www.huya.com/${channel.token}';
    default:
      return '';
  }
}

List<String> liveParsePlaybackUrls(String sourceId, String body) {
  switch (sourceId) {
    case 'bilibili':
      return _bilibiliPlaybackUrls(body);
    case 'huya':
      return _huyaPlaybackUrls(body);
    default:
      return const [];
  }
}

Future<String?> resolvePlatformPlaybackUrl(LiveChannel channel) async {
  final sourceId = channel.sourceId;
  final url = livePlaybackRequestUrl(sourceId, channel);
  if (url.isEmpty) return null;
  final headers = LiveSources.byId(sourceId)?.headers ?? const {};
  final body = await _get(url, headers: headers);
  final urls = liveParsePlaybackUrls(sourceId, body);
  return urls.isEmpty ? null : urls.first;
}

List<String> _bilibiliPlaybackUrls(String body) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final data = decoded is Map ? decoded['data'] : null;
  final rows = data is Map ? data['durl'] : null;
  if (rows is! List) return const [];
  return [
    for (final row in rows.whereType<Map>())
      if (_text(row['url']).isNotEmpty &&
          isPlayableLiveUrl(_text(row['url'])))
        _text(row['url']),
  ];
}

int _jsonValueEnd(String text, int start) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final ch = text[i];
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
    } else if (ch == '[' || ch == '{') {
      depth++;
    } else if (ch == ']' || ch == '}') {
      depth--;
      if (depth == 0) return i + 1;
    }
  }
  return -1;
}

List<String> _huyaPlaybackUrls(String body) {
  final at = body.indexOf('"gameStreamInfoList"');
  if (at < 0) return const [];
  final start = body.indexOf('[', at);
  if (start < 0) return const [];
  final end = _jsonValueEnd(body, start);
  if (end < 0) return const [];
  final dynamic decoded;
  try {
    decoded = jsonDecode(body.substring(start, end));
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final entries = decoded.whereType<Map>().toList()
    ..sort(
      (a, b) => ((b['iPCPriorityRate'] as num?) ?? 0).compareTo(
        (a['iPCPriorityRate'] as num?) ?? 0,
      ),
    );
  String build(Map entry, String urlKey, String suffixKey, String codeKey) {
    final base = _text(entry[urlKey]);
    final name = _text(entry['sStreamName']);
    final suffix = _text(entry[suffixKey]);
    final code = _text(entry[codeKey]);
    if (base.isEmpty || name.isEmpty || suffix.isEmpty) return '';
    return code.isEmpty ? '$base/$name.$suffix' : '$base/$name.$suffix?$code';
  }

  final urls = <String>[];
  for (final entry in entries) {
    final hls = build(entry, 'sHlsUrl', 'sHlsUrlSuffix', 'sHlsAntiCode');
    if (hls.isNotEmpty && !urls.contains(hls)) urls.add(hls);
  }
  for (final entry in entries) {
    final flv = build(entry, 'sFlvUrl', 'sFlvUrlSuffix', 'sFlvAntiCode');
    if (flv.isNotEmpty && !urls.contains(flv)) urls.add(flv);
  }
  return urls.where(isPlayableLiveUrl).toList();
}

const _retiredCategories = ['weishizhibo'];
final _cctv = RegExp(r'^(cctv|央视|中央电视台)', caseSensitive: false);

Future<List<LivePlatform>> fetchPingtaiPlatforms(LiveSource source) async {
  final byId = <String, LivePlatform>{};
  final failures = <String>[];
  for (final endpoint in source.endpoints) {
    final List<dynamic> rows;
    try {
      final text = await _get('$endpoint/json.txt');
      final dynamic decoded = jsonDecode(text);
      final raw = decoded is Map ? decoded['pingtai'] : decoded;
      if (raw is! List) continue;
      rows = raw;
    } catch (error) {
      failures.add('$error');
      continue;
    }
    for (final row in rows.whereType<Map>()) {
      final id = _text(row['address']);
      final name = _text(row['title']);
      if (id.isEmpty || name.isEmpty) continue;
      if (_retiredCategories.any(id.contains)) continue;
      final count = int.tryParse(_text(row['Number'])) ?? 0;
      final item = LivePlatform(
        id: id,
        name: name,
        logo: _text(row['xinimg']),
        count: count,
        endpoint: endpoint,
      );
      final previous = byId[id];
      if (previous == null || count > previous.count) byId[id] = item;
    }
  }
  if (byId.isEmpty) {
    throw StateError(
      failures.isEmpty ? '该直播源没有可用分类' : '该直播源暂时不可用：${failures.first}',
    );
  }
  final all = byId.values.toList();
  final withCount = [for (final item in all) if (item.count > 0) item];
  return withCount.isEmpty ? all : withCount;
}

List<LivePlatform> parsePingtaiPlatforms(String body, String endpoint) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return const [];
  }
  final raw = decoded is Map ? decoded['pingtai'] : decoded;
  if (raw is! List) return const [];
  final byId = <String, LivePlatform>{};
  for (final row in raw.whereType<Map>()) {
    final id = _text(row['address']);
    final name = _text(row['title']);
    if (id.isEmpty || name.isEmpty) continue;
    if (_retiredCategories.any(id.contains)) continue;
    final count = int.tryParse(_text(row['Number'])) ?? 0;
    final item = LivePlatform(
      id: id,
      name: name,
      logo: _text(row['xinimg']),
      count: count,
      endpoint: endpoint,
    );
    final previous = byId[id];
    if (previous == null || count > previous.count) byId[id] = item;
  }
  final all = byId.values.toList();
  final withCount = [for (final item in all) if (item.count > 0) item];
  return withCount.isEmpty ? all : withCount;
}

Future<List<LiveChannel>> fetchPingtaiChannels(
  LiveSource source,
  LivePlatform platform,
) async {
  final candidates = <String>{
    if (platform.endpoint.isNotEmpty) platform.endpoint,
    ...source.endpoints,
  };
  String? text;
  Object? lastError;
  for (final endpoint in candidates) {
    try {
      text = await _get('$endpoint/${platform.id}');
      break;
    } catch (error) {
      lastError = error;
    }
  }
  if (text == null) throw StateError('$lastError');
  return parsePingtaiChannels(source, platform, text);
}

List<LiveChannel> parsePingtaiChannels(
  LiveSource source,
  LivePlatform platform,
  String text,
) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  final rows = decoded is Map
      ? decoded['zhubo'] ?? decoded['list'] ?? decoded['data']
      : decoded;
  if (rows is! List) return const [];
  final reliable = <LiveChannel>[];
  final fallback = <LiveChannel>[];
  final seen = <String>{};
  for (final row in rows.whereType<Map>()) {
    final name = _text(row['title']);
    final url = _text(row['address']);
    if (name.isEmpty || !isPlayableLiveUrl(url) || !seen.add(name)) continue;
    if (_cctv.hasMatch(name)) continue;
    final channel = LiveChannel(
      title: name,
      url: url,
      group: platform.name,
      sourceId: source.id,
    );
    (url.startsWith('rtmp') ? fallback : reliable).add(channel);
  }
  return [...reliable, ...fallback];
}
