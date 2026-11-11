import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'local_proxy_preferences.dart';
import 'shell_proxy_url.dart';

/// 单个已取回的分片/密钥：整包字节 + 上游类型 + 状态码，供缓存直出。
class _CachedSegment {
  const _CachedSegment(this.body, this.contentType, this.status);

  final List<int> body;
  final String? contentType;
  final int status;
}

/// 预取并发门：同时最多 4 路上游拉取；播放器当次请求不走这道门，
/// 永远直接拉，预取排队绝不拖住正在播的分片。
class _PrefetchGate {
  _PrefetchGate(this.maxConcurrent);

  final int maxConcurrent;
  int _running = 0;
  final _waiters = <Completer<void>>[];

  bool get isIdle => _running == 0 && _waiters.isEmpty;

  Future<void> acquire() {
    if (_running < maxConcurrent) {
      _running++;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // 名额直接转给下一个排队者，_running 不变。
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }
}

/// 蜘蛛本地代理一次调用的回包：状态码、类型、字节与头。
class LocalProxyResponse {
  const LocalProxyResponse({
    required this.status,
    required this.mime,
    required this.body,
    this.headers = const {},
  });

  final int status;
  final String mime;
  final List<int> body;
  final Map<String, String> headers;
}

typedef LocalProxyHandler = Future<LocalProxyResponse?> Function(Uri uri);

class _ProxySession {
  _ProxySession(this.headers, {this.handler});

  final Map<String, String> headers;

  /// 非空时为蜘蛛本地代理会话：不再向上游取数，改调蜘蛛的 localProxy。
  final LocalProxyHandler? handler;
}

class LocalMediaProxy {
  LocalMediaProxy._();

  static final LocalMediaProxy instance = LocalMediaProxy._();

  /// FongMiTV 的本地代理从 9978 起找空闲端口（9978–9998）：jar 蜘蛛包出
  /// 的 `http://127.0.0.1:9978/proxy?...` 地址就是按这个约定写的，本应用
  /// 以前随机端口、9978 上没有服务在听，那类地址只能靠各处解包绕过。
  /// 这里跟 FongMiTV 对齐：先试 9978–9998，全占才回落随机端口。
  static const int _firstPort = 9978;
  static const int _lastPort = 9998;

  HttpServer? _server;
  Future<void>? _starting;
  final _sessions = <String, _ProxySession>{};
  final _order = <String>[];
  http.Client _client = http.Client();

  /// FongMiTV 形态的代理分发：`proxy://do=py&siteKey=xxx&u=...` 这类
  /// 地址（见 danai.py）没有蜘蛛上下文可解，交给调用方按 siteKey 找
  /// 客户端再调蜘蛛 localProxy；未接线时 /proxy 回 404，不猜。
  /// 由 local_proxy_route.dart 的 bindLocalProxyRoutes 接线。
  LocalProxyHandler? onProxyRequest;

  /// 开关状态（偏好里的实时值）：FongMiTV 常驻无开关，等价默认开。
  bool get enabled => LocalProxyPreferences.instance.enabled.value;

  /// 服务跑没跑、监听端口、对外地址（设置页直接读这三项）。
  bool get isRunning => _server != null;

  int? get port => _server?.port;

  String get baseUrl =>
      _server == null ? '' : 'http://127.0.0.1:${_server!.port}';

  /// 显式启动（设置开关打开、应用启动时开关开着）：已在跑直接回 true。
  Future<bool> start() async {
    if (_server != null) return true;
    if (_starting != null) {
      await _starting;
      return _server != null;
    }
    _starting = () async {
      _server = await _bindServer();
      _server!.listen(_handle);
    }();
    try {
      await _starting;
    } catch (_) {
      _starting = null;
      return false;
    }
    _starting = null;
    return _server != null;
  }

  /// 显式停止（设置开关关闭）：正在播的代理流会断一次；会话里记的
  /// 地址都带旧端口，停掉即失效，下次启动重建，不留僵尸地址。
  /// 正在起服务时先等它起完再关：否则起服务的闭包随后把 _server
  /// 重新赋值，关完又活过来（测试里 AppBootstrap 异步起服务、
  /// 体末调 stop() 时正好撞上此竞态）。
  Future<void> stop() async {
    final starting = _starting;
    _starting = null;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {}
    }
    final server = _server;
    _server = null;
    _sessions.clear();
    _order.clear();
    _playlistSegments.clear();
    if (server != null) {
      await server.close(force: true);
    }
  }

  /// 按开关起服务：关着就绝不偷偷起来，回 false 让调用方走直连或报错。
  Future<bool> ensureStarted() async {
    if (!enabled) return false;
    return start();
  }

  Future<HttpServer> _bindServer() async {
    for (var port = _firstPort; port <= _lastPort; port++) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      } catch (_) {
        // 端口被占就试下一个，9978–9998 全占才回落随机端口。
      }
    }
    return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }

  // 多线程拉流（B 路：中继侧并发预取分片）：ExoPlayer 的 HLS 分片是
  // 顺序拉取的，改原生 ChunkSource 风险大、本机也验不了；本地代理
  // 改写播放列表后全部变体/分片/密钥本来就走 /r/ 地址，所以在代理
  // 侧做——播放列表下发后并发拉取随后 4 个分片进缓存，播放器随后取
  // 分片时直接命中缓存；取到某分片后滑动窗口再往后预取 4 个。只预取
  // 媒体分片：变体播放列表（.m3u8/.mpd 行）不预取、不缓存，避免未经
  // 改写的播放列表被直接回给播放器；/h/ 蜘蛛会话（localProxy 回包
  // 不透明）不动。预取失败一律静默丢弃，绝不拦播放。
  static const int _prefetchWindow = 4;
  static const int _prefetchMaxEntries = 64;
  static const int _prefetchMaxBytes = 64 * 1024 * 1024;
  final _segmentCache = <String, _CachedSegment>{};
  final _segmentInflight = <String, Future<_CachedSegment?>>{};
  final _playlistSegments = <String, List<String>>{};
  int _segmentCacheBytes = 0;
  int _prefetchStarted = 0;
  int _prefetchCompleted = 0;
  int _cacheHits = 0;
  int _epoch = 0;
  final _prefetchGate = _PrefetchGate(4);

  /// 预取统计（单测/诊断用）：发起数、完成数、缓存命中数、缓存现况。
  Map<String, int> prefetchStatsForTest() => {
        'started': _prefetchStarted,
        'completed': _prefetchCompleted,
        'cacheHits': _cacheHits,
        'cachedEntries': _segmentCache.length,
        'cachedBytes': _segmentCacheBytes,
      };

  /// 等预取全部落定（在途取完、门空闲），超时即返回，不抛错。
  Future<void> debugWaitForPrefetchIdle({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_segmentInflight.isNotEmpty || !_prefetchGate.isIdle) {
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  void debugResetForTest() {
    _client.close();
    _client = http.Client();
    _sessions.clear();
    _order.clear();
    _segmentCache.clear();
    _segmentInflight.clear();
    _playlistSegments.clear();
    _segmentCacheBytes = 0;
    _prefetchStarted = 0;
    _prefetchCompleted = 0;
    _cacheHits = 0;
    onProxyRequest = null;
    // 世代 +1：在途的旧预取回包时按世代丢弃，不污染新缓存。
    _epoch++;
  }

  Future<String> register({
    required String targetUrl,
    required Map<String, String> headers,
  }) async {
    // 开关关着：不起服务，直接回原地址（直链原样，丢代理头——用户主动
    // 关的后果，设置页写明）；服务起不来也一样回原地址，不拦播放。
    if (!enabled) return targetUrl;
    final started = await ensureStarted();
    if (!started) return targetUrl;
    final token = _randomToken();
    _sessions[token] = _ProxySession(Map<String, String>.from(headers));
    _order.add(token);
    while (_order.length > 200) {
      _sessions.remove(_order.removeAt(0));
    }
    // 无后缀 HLS：播放器只凭地址后缀认流类型，目标本身没后缀时先探一次
    // 上游（HEAD 看类型，类型含糊或 HEAD 失败时 Range GET 嗅首字节
    // #EXTM3U），探到是 HLS 就给代理地址补 .m3u8 后缀；探不到或探失败
    // 一律走老路（只按目标后缀），不拦播放。只探顶层播放地址，分片与
    // 密钥地址不走这里（_rewritePlaylist 直接调 _proxyUrl，不探不加）。
    String? detectedSuffix;
    try {
      if (await _isHlsTarget(targetUrl, headers)) {
        detectedSuffix = '.m3u8';
      }
    } catch (_) {
      detectedSuffix = null;
    }
    return _proxyUrl(token, targetUrl, detectedSuffix: detectedSuffix);
  }

  /// 蜘蛛本地代理会话：播放器请求的路径与查询原样交给 handler（蜘蛛的
  /// localProxy），返回的地址形如 `http://127.0.0.1:端口/h/令牌?原查询`。
  /// 开关关着时不建会话、报诚实错误（调用方 _proxyIfNeeded 本来就会把
  /// StateError 往上抛，播放失败时报「本地代理已关闭」，不静默）。
  Future<String> registerHandler({
    required LocalProxyHandler handler,
  }) async {
    if (!enabled) {
      throw StateError('本地代理已关闭，请在设置 → 服务 → 本地代理里开启');
    }
    final started = await ensureStarted();
    if (!started) throw StateError('本地代理启动失败');
    final token = _randomToken();
    _sessions[token] = _ProxySession(const {}, handler: handler);
    _order.add(token);
    while (_order.length > 200) {
      _sessions.remove(_order.removeAt(0));
    }
    return 'http://127.0.0.1:${_server!.port}/h/$token';
  }

  /// 该地址是不是本代理自己的会话地址（上游代理 /h 会话都算）。
  bool owns(String url) {
    final server = _server;
    if (server == null) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.host != '127.0.0.1' && uri.host != 'localhost') return false;
    if (uri.port != server.port) return false;
    return uri.pathSegments.isNotEmpty &&
        (uri.pathSegments.first == 'r' || uri.pathSegments.first == 'h');
  }

  String _proxyUrl(String token, String targetUrl, {String? detectedSuffix}) {
    final encoded = base64Url
        .encode(utf8.encode(targetUrl))
        .replaceAll('=', '');
    // ExoPlayer 只凭地址后缀（或显式 mimeType）认流类型：/r/ 地址原来
    // 是纯 base64，没有 .m3u8，DefaultMediaSourceFactory 会把它当成
    // Progressive 流，拿 MP4 解析器读 #EXTM3U 文本必然失败（报
    // “视频解析失败”）。目标本身带 .m3u8/.mpd 时把后缀留在地址尾巴上，
    // 让播放器走 HLS/DASH；分片与密钥地址不靠后缀认类型，不加。
    // detectedSuffix 非空时是 register() 探到的结论（无后缀 HLS 补
    // .m3u8），它只能补后缀、不能去掉路径本身带出的后缀。
    final path = Uri.tryParse(targetUrl)?.path.toLowerCase() ?? '';
    final suffix = detectedSuffix ??
        (path.endsWith('.m3u8')
            ? '.m3u8'
            : path.endsWith('.mpd')
            ? '.mpd'
            : '');
    return 'http://127.0.0.1:${_server!.port}/r/$token/$encoded$suffix';
  }

  /// 是不是 HLS 的 Content-Type：大小写不敏感，
  /// application/vnd.apple.mpegurl 与 application/x-mpegURL 都算。
  bool _isHlsContentType(String? contentType) =>
      (contentType ?? '').toLowerCase().contains('mpegurl');

  /// 首字节是不是播放列表：允许 UTF-8 BOM 与前导空白，之后必须是
  /// #EXTM3U。只看前几个字节，不读全包；mp4（ftyp）与 ts（0x47 同步
  /// 字节）都不会误判。
  bool _startsWithExtM3u(List<int> bytes) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0D ||
            bytes[i] == 0x0A)) {
      i++;
    }
    const marker = '#EXTM3U';
    if (bytes.length - i < marker.length) return false;
    for (var j = 0; j < marker.length; j++) {
      if (bytes[i + j] != marker.codeUnitAt(j)) return false;
    }
    return true;
  }

  /// 目标是不是 HLS 播放列表：只在 register() 时对顶层播放地址探一次。
  /// 先 HEAD 看 Content-Type；类型是明确的 video/audio 就直接否定，
  /// 类型含糊（text/plain、application/octet-stream、没给类型）或
  /// HEAD 失败时，再用 Range GET 只读首块嗅 #EXTM3U；任何失败都返回
  /// false，走老路。Range GET 只取首块就断开，绝不拉全包。
  Future<bool> _isHlsTarget(
    String targetUrl,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(targetUrl);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    try {
      final head = await _client
          .head(uri, headers: headers)
          .timeout(const Duration(seconds: 8));
      if (head.statusCode >= 200 && head.statusCode < 300) {
        final type = (head.headers['content-type'] ?? '').toLowerCase();
        if (_isHlsContentType(type)) return true;
        if (type.startsWith('video/') || type.startsWith('audio/')) {
          return false;
        }
        // 类型含糊：HEAD 未必准，继续用 Range GET 嗅首字节。
      }
    } catch (_) {
      // HEAD 不通（405/超时等）不算结论，继续嗅首字节。
    }
    try {
      final request = http.Request('GET', uri);
      request.headers.addAll(headers);
      request.headers[HttpHeaders.rangeHeader] = 'bytes=0-1023';
      final streamed = await _client
          .send(request)
          .timeout(const Duration(seconds: 8));
      if (_isHlsContentType(streamed.headers['content-type'])) {
        await streamed.stream.drain<void>().catchError((_) {});
        return true;
      }
      if (streamed.statusCode != HttpStatus.ok &&
          streamed.statusCode != HttpStatus.partialContent) {
        await streamed.stream.drain<void>().catchError((_) {});
        return false;
      }
      final first = await streamed.stream
          .first
          .timeout(const Duration(seconds: 8));
      // first 取完即取消订阅：只嗅首块，不拉后续正文。
      return _startsWithExtM3u(first);
    } catch (_) {
      return false;
    }
  }

  String _rewritePlaylist(String text, String token, String baseUrl) {
    final lines = text.split('\n');
    final out = <String>[];
    final keyUri = RegExp(r'URI="([^"]+)"');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXT-X-KEY') ||
            trimmed.startsWith('#EXT-X-MAP')) {
          out.add(
            line.replaceAllMapped(keyUri, (match) {
              final resolved = _resolveUrl(baseUrl, match.group(1)!);
              return 'URI="${_proxyUrl(token, resolved)}"';
            }),
          );
        } else {
          out.add(line);
        }
        continue;
      }
      out.add(_proxyUrl(token, _resolveUrl(baseUrl, trimmed)));
    }
    return out.join('\n');
  }

  String _resolveUrl(String baseUrl, String ref) {
    if (ref.isEmpty) return baseUrl;
    final base = Uri.tryParse(baseUrl);
    final rel = Uri.tryParse(ref);
    if (base == null || rel == null) return ref;
    return base.resolveUri(rel).toString();
  }

  /// 媒体目标才可缓存/预取：变体播放列表（.m3u8/.mpd）永远重新拉取
  /// 并改写，不进缓存。
  bool _isCacheableTarget(String target) {
    final path = target.split('?').first.toLowerCase();
    return !path.endsWith('.m3u8') && !path.endsWith('.mpd');
  }

  /// 播放列表里的媒体分片目标（按顺序）：# 标签行跳过，变体播放列表
  /// 行（.m3u8/.mpd）跳过，只留分片/密钥类相对或绝对地址。
  List<String> _playlistSegmentTargets(String text, String baseUrl) {
    final targets = <String>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final resolved = _resolveUrl(baseUrl, trimmed);
      if (_isCacheableTarget(resolved)) targets.add(resolved);
    }
    return targets;
  }

  void _storeSegment(String target, _CachedSegment segment) {
    final old = _segmentCache.remove(target);
    if (old != null) _segmentCacheBytes -= old.body.length;
    while (_segmentCache.isNotEmpty &&
        (_segmentCache.length >= _prefetchMaxEntries ||
            _segmentCacheBytes + segment.body.length > _prefetchMaxBytes)) {
      final oldestKey = _segmentCache.keys.first;
      final evicted = _segmentCache.remove(oldestKey)!;
      _segmentCacheBytes -= evicted.body.length;
    }
    _segmentCache[target] = segment;
    _segmentCacheBytes += segment.body.length;
  }

  /// 单路预取拉取：过并发门、30 秒超时；非 200、播放列表正文、失败
  /// 一律回 null（不缓存、不抛错）。
  Future<_CachedSegment?> _fetchSegment(
    String target,
    Map<String, String> headers,
    int epoch,
  ) async {
    await _prefetchGate.acquire();
    try {
      final res = await _client
          .get(Uri.parse(target), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != HttpStatus.ok) return null;
      if (_isHlsContentType(res.headers['content-type']) ||
          _startsWithExtM3u(res.bodyBytes)) {
        return null;
      }
      if (epoch != _epoch) return null;
      return _CachedSegment(
        res.bodyBytes,
        res.headers['content-type'],
        res.statusCode,
      );
    } catch (_) {
      return null;
    } finally {
      _prefetchGate.release();
    }
  }

  /// 并发预取一批分片：已缓存/在途的去重跳过，其余各起一路拉取；
  /// 落定后进缓存。调用方不 await（fire-and-forget），内部绝不抛错。
  void _prefetchSegments(
    List<String> targets,
    Map<String, String> headers,
  ) {
    for (final target in targets) {
      if (_segmentCache.containsKey(target) ||
          _segmentInflight.containsKey(target)) {
        continue;
      }
      _prefetchStarted++;
      final epoch = _epoch;
      final future = _fetchSegment(target, headers, epoch);
      _segmentInflight[target] = future;
      future.then((cached) {
        if (identical(_segmentInflight[target], future)) {
          _segmentInflight.remove(target);
        }
        if (cached != null && epoch == _epoch) {
          _prefetchCompleted++;
          _storeSegment(target, cached);
        }
      }).catchError((_) {});
    }
  }

  /// 滑动窗口：刚取到第 i 个分片，往后预取 i+1..i+4。
  void _prefetchFollowing(
    String token,
    String target,
    Map<String, String> headers,
  ) {
    final list = _playlistSegments[token];
    if (list == null) return;
    final index = list.indexOf(target);
    if (index < 0) return;
    final end = min(index + 1 + _prefetchWindow, list.length);
    if (index + 1 < end) {
      _prefetchSegments(list.sublist(index + 1, end), headers);
    }
  }

  /// 缓存直出：整包 200 或按 Range 切 206，类型沿用上游回的类型。
  Future<void> _serveCachedSegment(
    HttpRequest request,
    _CachedSegment cached,
    String? rangeHeader,
  ) async {
    final response = request.response;
    var body = cached.body;
    var status = cached.status;
    if (rangeHeader != null) {
      final sliced = _sliceRange(body, rangeHeader);
      if (sliced != null) {
        body = sliced.body;
        status = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          sliced.contentRange,
        );
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
    }
    response.statusCode = status;
    if (cached.contentType != null) {
      response.headers.set(HttpHeaders.contentTypeHeader, cached.contentType!);
    }
    response.headers.contentLength = body.length;
    response.add(body);
    await response.close();
  }

  /// Range 切片：解析 bytes=a-b / bytes=a- / bytes=-n，非法时返回 null
  /// 走整包 200，不谎报 416。
  ({List<int> body, String contentRange})? _sliceRange(
    List<int> body,
    String range,
  ) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (match == null) return null;
    final total = body.length;
    final startText = match.group(1)!;
    final endText = match.group(2)!;
    int start;
    int end;
    if (startText.isEmpty) {
      if (endText.isEmpty) return null;
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      start = total - suffix;
      if (start < 0) start = 0;
      end = total - 1;
    } else {
      start = int.tryParse(startText) ?? -1;
      if (start < 0 || start >= total) return null;
      end = endText.isEmpty ? total - 1 : (int.tryParse(endText) ?? total - 1);
      if (end >= total) end = total - 1;
      if (end < start) return null;
    }
    return (
      body: body.sublist(start, end + 1),
      contentRange: 'bytes $start-$end/$total',
    );
  }

  /// 蜘蛛本地代理回包的 m3u8 里残留的外壳代理地址（127.0.0.1:9978/proxy
  /// 之类）改写回本代理的 h 会话，否则播放器会去敲一个不存在的端口。
  String _rewriteForeignProxyUrls(String text, String token) {
    final pattern = RegExp(
      r'https?://(?:127\.0\.0\.1|localhost):\d+/proxy(\?[^\s"''#]*)?',
    );
    return text.replaceAllMapped(pattern, (match) {
      final query = match.group(1) ?? '';
      return 'http://127.0.0.1:${_server!.port}/h/$token$query';
    });
  }

  /// 蜘蛛本地代理会话的播放列表改写：外壳代理地址改回本会话；相对
  /// 分片行（播放器会按会话地址解析，丢 token）也改成带 token 的
  /// 绝对地址，# 开头的标签行与绝对 http 行不动。
  String _rewriteHandlerPlaylist(String text, String token) {
    final rewritten = _rewriteForeignProxyUrls(text, token);
    final lines = rewritten.split('\n');
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('http://') ||
          trimmed.startsWith('https://')) {
        out.add(line);
        continue;
      }
      final path = trimmed.replaceFirst(RegExp(r'^/+'), '');
      out.add('http://127.0.0.1:${_server!.port}/h/$token/$path');
    }
    return out.join('\n');
  }

  /// FongMiTV 同款 `/proxy` 入口：蜘蛛包出的
  /// `http://127.0.0.1:9978/proxy?type=img&site=<站>&p=<base64 JSON>` 在
  /// 本应用以前没有服务接，播放器或图片组件直接拿它请求只会失败。
  /// 两形态：
  /// - `p=` 打包载荷：解出真实地址 + Referer，直接带头取回（蜘蛛
  ///   proxy() 里实际干的就是这件事，见 ZakaSex8Amns.proxy；解不出
  ///   `u` 的令牌型地址回 404，调用方走 /h/ 会话 + 蜘蛛 localProxy）。
  /// - `do`/`siteKey` 形态（`proxy://do=py&siteKey=xxx&u=...`，见
  ///   danai.py 的封面地址）：交给 onProxyRequest 按站找蜘蛛
  ///   localProxy（danai 的封面还要蜘蛛侧 AES 解密，Dart 侧取不来），
  ///   未接线回 404，不猜。
  Future<void> _handleProxy(HttpRequest request) async {
    final response = request.response;
    final query = request.uri.queryParameters;
    final packed = query['p'];
    if (packed != null && packed.isNotEmpty) {
      final unwrapped = unwrapShellProxyUrl(
        'http://127.0.0.1/proxy?${request.uri.query}',
      );
      if (unwrapped != null) {
        await _serveProxiedFetch(request, unwrapped.url, unwrapped.headers);
        return;
      }
      response
        ..statusCode = HttpStatus.notFound
        ..write('unknown proxy payload');
      await response.close();
      return;
    }
    final handler = onProxyRequest;
    if (handler != null &&
        (query.containsKey('do') || query.containsKey('siteKey'))) {
      final proxied = await handler(request.uri);
      if (proxied == null) {
        response
          ..statusCode = HttpStatus.notFound
          ..write('local proxy not implemented');
        await response.close();
        return;
      }
      await _serveProxiedResult(request, proxied);
      return;
    }
    response
      ..statusCode = HttpStatus.notFound
      ..write('unknown proxy request');
    await response.close();
  }

  /// 打包载荷的直取：带 Referer（图床没它就 406）与图片 Accept 头取回。
  Future<void> _serveProxiedFetch(
    HttpRequest request,
    String target,
    Map<String, String> headers,
  ) async {
    final response = request.response;
    final uri = Uri.tryParse(target);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      response
        ..statusCode = HttpStatus.badRequest
        ..write('bad target');
      await response.close();
      return;
    }
    try {
      final upstream = await _client
          .get(
            uri,
            headers: {
              ...headers,
              HttpHeaders.acceptHeader:
                  'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (upstream.statusCode != HttpStatus.ok) {
        response.statusCode = upstream.statusCode;
        await response.close();
        return;
      }
      // bodyBytes 是 Uint8List，Range 切片回的是 List<int>：显式声明
      // List<int>，否则切片赋值报类型错。
      List<int> body = upstream.bodyBytes;
      var status = HttpStatus.ok;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) {
        final sliced = _sliceRange(body, rangeHeader);
        if (sliced != null) {
          body = sliced.body;
          status = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            sliced.contentRange,
          );
          response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        }
      }
      response.statusCode = status;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        _sniffMime(target, upstream.headers['content-type']),
      );
      response.headers.contentLength = body.length;
      response.add(body);
      await response.close();
    } catch (_) {
      try {
        response
          ..statusCode = HttpStatus.badGateway
          ..write('proxy error');
        await response.close();
      } catch (_) {}
    }
  }

  /// 蜘蛛 localProxy 回包的直出：类型与头沿用蜘蛛回的；Range 按需切 206；
  /// 是播放列表时相对行按查询里的 `u`（上游播放列表地址）解析成绝对
  /// 地址，否则播放器按 /proxy 地址解析分片行必 404。
  Future<void> _serveProxiedResult(
    HttpRequest request,
    LocalProxyResponse proxied,
  ) async {
    final response = request.response;
    var body = proxied.body;
    var status = proxied.status;
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader != null) {
      final sliced = _sliceRange(body, rangeHeader);
      if (sliced != null) {
        body = sliced.body;
        status = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          sliced.contentRange,
        );
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
    }
    final isPlaylist = _isHlsContentType(proxied.mime) ||
        _startsWithExtM3u(proxied.body);
    if (isPlaylist && status == 200) {
      final base = request.uri.queryParameters['u'] ?? '';
      final text = utf8.decode(body, allowMalformed: true);
      final lines = text.split('\n');
      final out = <String>[];
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('http://') ||
            trimmed.startsWith('https://')) {
          out.add(line);
          continue;
        }
        out.add(base.isEmpty ? line : _resolveUrl(base, trimmed));
      }
      body = utf8.encode(out.join('\n'));
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
    } else if (proxied.mime.isNotEmpty) {
      response.headers.set(HttpHeaders.contentTypeHeader, proxied.mime);
    }
    for (final entry in proxied.headers.entries) {
      response.headers.set(entry.key, entry.value);
    }
    response.statusCode = status;
    response.headers.contentLength = body.length;
    response.add(body);
    await response.close();
  }

  /// 按上游类型或地址后缀猜类型：上游给了明确类型就用上游的，否则按
  /// 后缀；都认不出回通用二进制，不谎报图片类型。
  String _sniffMime(String target, String? contentType) {
    final type = (contentType ?? '').split(';').first.trim().toLowerCase();
    if (type.isNotEmpty && type != 'application/octet-stream') return type;
    final path = target.split('?').first.toLowerCase();
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'image/jpeg';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.gif')) return 'image/gif';
    if (path.endsWith('.webp')) return 'image/webp';
    if (path.endsWith('.m3u8')) return 'application/vnd.apple.mpegurl';
    if (path.endsWith('.mp4')) return 'video/mp4';
    return 'application/octet-stream';
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        // 探活：设置页自测打这个地址，200 即服务在听。
        request.response
          ..statusCode = HttpStatus.ok
          ..write('local-proxy-ok');
        await request.response.close();
        return;
      }
      if (segments.first == 'proxy') {
        await _handleProxy(request);
        return;
      }
      if (segments.length < 2) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
        return;
      }
      final token = segments[1];
      final session = _sessions[token];
      if (session == null) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('session expired');
        await request.response.close();
        return;
      }
      if (session.handler != null) {
        final proxied = await session.handler!(request.uri);
        final response = request.response;
        if (proxied == null) {
          response
            ..statusCode = HttpStatus.notFound
            ..write('local proxy not implemented');
          await response.close();
          return;
        }
        var body = proxied.body;
        var status = proxied.status;
        final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
        if (rangeHeader != null) {
          final sliced = _sliceRange(body, rangeHeader);
          if (sliced != null) {
            body = sliced.body;
            status = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              sliced.contentRange,
            );
            response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          }
        }
        final isPlaylist = _isHlsContentType(proxied.mime) ||
            request.uri.path.toLowerCase().endsWith('.m3u8') ||
            _startsWithExtM3u(proxied.body);
        if (isPlaylist && status == 200) {
          final rewritten = _rewriteHandlerPlaylist(
            utf8.decode(body, allowMalformed: true),
            token,
          );
          body = utf8.encode(rewritten);
          response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
            charset: 'utf-8',
          );
        } else if (proxied.mime.isNotEmpty) {
          response.headers.set(HttpHeaders.contentTypeHeader, proxied.mime);
        }
        for (final entry in proxied.headers.entries) {
          response.headers.set(entry.key, entry.value);
        }
        response.statusCode = status;
        response.headers.contentLength = body.length;
        response.add(body);
        await response.close();
        return;
      }
      if (segments[0] != 'r') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
        return;
      }
      var target = '';
      if (segments.length > 2) {
        // _proxyUrl 给自适应流地址尾巴上留的 .m3u8/.mpd 后缀：base64url
        // 字母表里没有 '.'，从第一个 '.' 起截掉即还原出原始编码。
        final encoded = segments.sublist(2).join('/');
        final dot = encoded.indexOf('.');
        final clean = dot >= 0 ? encoded.substring(0, dot) : encoded;
        final padded = clean + ('=' * ((4 - clean.length % 4) % 4));
        target = utf8.decode(base64Url.decode(padded));
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('missing target');
        await request.response.close();
        return;
      }
      final headers = Map<String, String>.from(session.headers);
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) headers[HttpHeaders.rangeHeader] = rangeHeader;
      // 多线程拉流：媒体目标先查预取缓存，命中直接回（并滑动窗口往后
      // 预取）；在途的等它落定（比重新拉上游快）；都落空才走下面正常拉取。
      if (_isCacheableTarget(target)) {
        final cached = _segmentCache[target];
        if (cached != null) {
          _cacheHits++;
          _prefetchFollowing(token, target, session.headers);
          await _serveCachedSegment(request, cached, rangeHeader);
          return;
        }
        final inflight = _segmentInflight[target];
        if (inflight != null) {
          final done = await inflight;
          if (done != null) {
            _cacheHits++;
            _prefetchFollowing(token, target, session.headers);
            await _serveCachedSegment(request, done, rangeHeader);
            return;
          }
          // 预取失败：落到下面正常拉取，不拦播放。
        }
      }
      final upstream = await _client
          .get(Uri.parse(target), headers: headers)
          .timeout(const Duration(seconds: 30));
      final isPlaylist = _isHlsContentType(upstream.headers['content-type']) ||
          target.split('?').first.toLowerCase().endsWith('.m3u8') ||
          _startsWithExtM3u(upstream.bodyBytes);
      final response = request.response;
      response.statusCode = upstream.statusCode;
      final contentRange = upstream.headers['content-range'];
      if (contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      final acceptRanges = upstream.headers['accept-ranges'];
      if (acceptRanges != null) {
        response.headers.set(HttpHeaders.acceptRangesHeader, acceptRanges);
      }
      if (isPlaylist && upstream.statusCode == 200) {
        final playlistText =
            utf8.decode(upstream.bodyBytes, allowMalformed: true);
        final rewritten = _rewritePlaylist(playlistText, token, target);
        // 播放列表下发即触发并发预取：取随后 4 个分片（变体播放列表行
        // 已在 _playlistSegmentTargets 里排除）。
        final segmentTargets = _playlistSegmentTargets(playlistText, target);
        if (segmentTargets.isNotEmpty) {
          _playlistSegments[token] = segmentTargets;
          _prefetchSegments(
            segmentTargets.take(_prefetchWindow).toList(),
            session.headers,
          );
        }
        final bytes = utf8.encode(rewritten);
        response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        response.headers.contentLength = bytes.length;
        response.add(bytes);
      } else {
        // 媒体直取也进缓存：下次同分片/密钥直接命中；取到后滑动窗口
        // 往后预取（播放器顺序取分片时窗口跟着走）。
        if (upstream.statusCode == HttpStatus.ok &&
            _isCacheableTarget(target)) {
          _storeSegment(
            target,
            _CachedSegment(
              upstream.bodyBytes,
              upstream.headers['content-type'],
              upstream.statusCode,
            ),
          );
          _prefetchFollowing(token, target, session.headers);
        }
        final contentType = upstream.headers['content-type'];
        if (contentType != null) {
          response.headers.set(HttpHeaders.contentTypeHeader, contentType);
        }
        response.headers.contentLength = upstream.bodyBytes.length;
        response.add(upstream.bodyBytes);
      }
      await response.close();
    } catch (_) {
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('proxy error');
        await request.response.close();
      } catch (_) {}
    }
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
