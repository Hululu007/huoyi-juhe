import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
      .get(Uri.parse(url), headers: {'User-Agent': _userAgent, ...headers})
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
  final withCount = [
    for (final item in all)
      if (item.count > 0) item,
  ];
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
  final withCount = [
    for (final item in all)
      if (item.count > 0) item,
  ];
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
  var number = 0;
  for (final row in rows.whereType<Map>()) {
    final name = _text(row['title']);
    final url = _text(row['address']);
    if (name.isEmpty || !isPlayableLiveUrl(url) || !seen.add(name)) continue;
    if (_cctv.hasMatch(name)) continue;
    number++;
    final channel = LiveChannel(
      title: name,
      url: url,
      group: platform.name,
      sourceId: source.id,
      cover: _text(row['img']),
      number: number.toString().padLeft(3, '0'),
    );
    (url.startsWith('rtmp') ? fallback : reliable).add(channel);
  }
  return [...reliable, ...fallback];
}

/// 直播流本地中继：把播放器不能直接拉的明文 http 流转成 127.0.0.1 上的
/// 本地地址再交给 ExoPlayer。
///
/// 根因：平台房间地址全是 `http://…flv?wsSecret=…&wsTime=…` 明文流；
/// App 的 network_security_config 只放行 127.0.0.1/localhost 的明文，
/// ExoPlayer 走平台网络栈会被系统直接拦掉，表现为列表能拉、一点播就
/// 「播放失败」。Dart 自身的 HttpClient 不受该策略限制，所以由 Dart
/// 侧把上游流式转发到本地回环地址，播放器只连 127.0.0.1，不再触网。
/// 中继只做字节转发、不缓冲整条流（直播流没有尽头，缓冲写法永远等不到
/// 第一个字节）；播放器断开即丢弃上游流。
class LiveRelay {
  LiveRelay._();

  static final LiveRelay instance = LiveRelay._();

  HttpServer? _server;
  Future<void>? _starting;
  final _targets = <String, String>{};
  final _order = <String>[];
  final _client = HttpClient();

  /// 中继转发的累计字节与采样点（每 200ms 记一个点），供全屏顶栏网速
  /// 显示用：火蚁TV 的网速来自 mpv 的 demuxer 采样，修仙版 NativePlayer
  /// 没有这个接口；但直播流本身就走这条 Dart 中继，直接数中继字节是最
  /// 准的本地采样。直连 https 流不走中继，采不到，顶栏不显示。

  int _bytesTotal = 0;
  final _byteSamples = <(DateTime, int)>[];

  void _noteBytes(int count) {
    _bytesTotal += count;
    final now = DateTime.now();
    if (_byteSamples.isEmpty ||
        now.difference(_byteSamples.last.$1).inMilliseconds >= 200) {
      _byteSamples.add((now, _bytesTotal));
      if (_byteSamples.length > 200) {
        _byteSamples.removeRange(0, _byteSamples.length - 200);
      }
    }
  }

  /// 最近 10 秒窗口内的平均下行速率（字节/秒）。采样不足 2 秒或
  /// 最近无流量时返回 null，调用方不显示网速。
  double? recentBytesPerSecond() {
    final now = DateTime.now();
    _byteSamples.removeWhere(
      (sample) => now.difference(sample.$1) > const Duration(seconds: 15),
    );
    final kept = [
      for (final sample in _byteSamples)
        if (now.difference(sample.$1) <= const Duration(seconds: 10)) sample,
    ];
    if (kept.length < 2) return null;
    final span = kept.last.$1.difference(kept.first.$1).inMilliseconds / 1000;
    final delta = kept.last.$2 - kept.first.$2;
    if (span < 2 || delta < 0) return null;
    return delta / span;
  }

  /// 换台时清掉旧采样，避免上一条流的速率残留到新台顶栏。
  void resetRateSamples() {
    _byteSamples.clear();
  }

  Future<String> relay(String upstreamUrl) async {
    await _ensureStarted();
    final token = _randomToken();
    _targets[token] = upstreamUrl;
    _order.add(token);
    while (_order.length > 32) {
      _targets.remove(_order.removeAt(0));
    }
    return 'http://127.0.0.1:${_server!.port}/live/$token';
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    if (_starting != null) return _starting!;
    _starting = () async {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handle);
    }();
    await _starting;
  }

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    final target = segments.length == 2 && segments[0] == 'live'
        ? _targets[segments[1]]
        : null;
    if (target == null) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('unknown live relay');
      await request.response.close();
      return;
    }
    final HttpClientResponse upstreamResponse;
    try {
      final upstreamRequest = await _client.getUrl(Uri.parse(target));
      upstreamRequest.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
      }
      upstreamResponse = await upstreamRequest.close();
    } catch (_) {
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('upstream unavailable');
        await request.response.close();
      } catch (_) {}
      return;
    }
    final response = request.response;
    response.statusCode = upstreamResponse.statusCode;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      upstreamResponse.headers.value(HttpHeaders.contentTypeHeader) ??
          'video/x-flv',
    );
    if (upstreamResponse.contentLength >= 0) {
      response.headers.contentLength = upstreamResponse.contentLength;
    }
    final contentRange = upstreamResponse.headers.value(
      HttpHeaders.contentRangeHeader,
    );
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    try {
      await response.addStream(
        upstreamResponse.map((chunk) {
          _noteBytes(chunk.length);
          return chunk;
        }),
      );
    } catch (_) {
      // 播放器断开：上游流随之丢弃，不再写。
    }
    try {
      await response.close();
    } catch (_) {}
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 播放器能直接播的地址：https 原样返回；明文 http 走本地中继，
/// 否则 ExoPlayer 会被明文策略拦掉。中继起不来时回退原地址。
Future<String> playableLiveUrl(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != 'http') return url;
  if (uri.host == '127.0.0.1' || uri.host == 'localhost') return url;
  try {
    return await LiveRelay.instance.relay(url);
  } catch (_) {
    return url;
  }
}
