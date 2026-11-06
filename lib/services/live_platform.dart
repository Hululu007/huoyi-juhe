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
