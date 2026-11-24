// 适配层：女优库模块在魔蚁侧依赖的 HTTP / 验活 / 过盾判定。
//
// 覆盖魔蚁三个原文件在女优库里的实际用量：
// - lib/content_http.dart：ContentResponse / ContentHttp /
//   decodeContentBytes（只用 getRaw + 解码；postForm/postJson/getBytes/
//   fetchDecoded 女优库没用到，未搬）；
// - lib/feed_playability.dart：验活探针 probeStreamHead /
//   feedProbePlayable（FeedPlayabilityVerifier 是首页推荐流用的，
//   女优库没用到，未搬）；
// - lib/miniapp/haikuo/haikuo_shield.dart：纯特征判定
//   haikuoShieldCheck（隐藏浏览器解盾那套修仙版没有，只搬判定，
//   判定为挑战时调用方按“取不到”处理，不起浏览器）。
//
// 直连：魔蚁 ContentHttp 同样是直连（应用内代理机件已删），本文件
// 用 dart:io HttpClient 直连，不接修仙版代理设置。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../services/gbk_codec.dart' show gbkDecode;
import 'actress_adapter_models.dart' show AppFailure;

const contentUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const contentTimeout = Duration(seconds: 20);
const _maxContentBytes = 64 << 20;

/// 原始响应：状态码 + 响应头 + 原始字节。不按状态码抛错，供需要自行判断
/// 状态码/验证页的调用方使用；传输层失败仍抛 [AppFailure]。
class ContentResponse {
  const ContentResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;
}

/// 按响应头/页面 meta 声明的字符集解码字节：显式 charset 优先，其次严格
/// UTF-8，失败回落 GBK（中文站常见）。GBK 解码走修仙版现成的 gbk_codec。
String decodeContentBytes(List<int> bytes, {String? contentType}) {
  String? charset;
  final typeMatch = RegExp(
    "charset\\s*=\\s*[\"']?([A-Za-z0-9._-]+)",
    caseSensitive: false,
  ).firstMatch(contentType ?? '');
  charset = typeMatch?.group(1);
  if (charset == null || charset.isEmpty) {
    final head = latin1.decode(bytes.take(8192).toList());
    final metaMatch =
        RegExp(
          r'''<meta[^>]+charset\s*=\s*["']?\s*([A-Za-z0-9._-]+)''',
          caseSensitive: false,
        ).firstMatch(head) ??
        RegExp(
          r'''<meta[^>]+content\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9._-]+)''',
          caseSensitive: false,
        ).firstMatch(head);
    charset = metaMatch?.group(1);
  }
  if (charset != null && charset.isNotEmpty) {
    return _decodeWithCharset(bytes, charset);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbkDecode(bytes);
  }
}

String _decodeWithCharset(List<int> bytes, String charset) {
  final normalized = charset.toLowerCase().replaceAll('_', '').replaceAll(
    '-',
    '',
  );
  if (normalized == 'gbk' ||
      normalized == 'gb2312' ||
      normalized == 'gb18030') {
    return gbkDecode(bytes);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbkDecode(bytes);
  }
}

/// 内容取数客户端：直连。女优库只用 [getRaw]（名册/现爬）与 [get]。
class ContentHttp {
  ContentHttp();

  HttpClient? _client;

  HttpClient get _currentClient {
    final existing = _client;
    if (existing != null) return existing;
    final created = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _client = created;
    return created;
  }

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  Future<String> get(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) async {
    final raw = await getRaw(url, headers: headers, timeout: timeout);
    return decodeContentBytes(
      raw.bodyBytes,
      contentType: raw.headers['content-type'],
    );
  }

  /// GET 并返回原始响应（状态码/响应头/字节），非 200 不抛错。
  Future<ContentResponse> getRaw(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = contentTimeout,
  }) async {
    final client = _currentClient;
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw AppFailure('内容源地址无效');
    }
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = true;
      request.headers.set(
        HttpHeaders.userAgentHeader,
        headers['User-Agent'] ?? contentUserAgent,
      );
      headers.forEach((key, value) {
        if (key.toLowerCase() == 'user-agent' || value.isEmpty) return;
        request.headers.set(key, value);
      });
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > _maxContentBytes) {
          throw AppFailure('内容源返回的数据过大');
        }
      }
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) responseHeaders[name] = values.join(', ');
      });
      return ContentResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        bodyBytes: builder.takeBytes(),
      );
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw AppFailure('内容源连接超时');
    } on HandshakeException {
      throw AppFailure('内容源证书校验失败');
    } on SocketException {
      throw AppFailure('无法连接内容源');
    }
  }
}

/// 挑战判定结果。
class HaikuoShieldVerdict {
  const HaikuoShieldVerdict._(this.blocked, this.reason);

  /// 被盾挡住（需要解一次）。
  final bool blocked;

  /// 判定依据，只用于日志/调试，不影响业务。
  final String reason;

  static const pass = HaikuoShieldVerdict._(false, '');
  static const challenge = HaikuoShieldVerdict._(true, 'cf-mitigated');
  static const challengeBody = HaikuoShieldVerdict._(true, 'challenge-body');
}

/// 判定一次响应是不是「被盾挡住」，而不是站点真返回 403/503。
/// 只认通用特征，避免把正常的鉴权失败、下架、限流误判成挑战。
HaikuoShieldVerdict haikuoShieldCheck({
  required int status,
  required Map<String, List<String>> headers,
  required String body,
}) {
  // 1) CF 直接标注了本次响应是挑战（最可靠，不看正文）。
  for (final key in const ['cf-mitigated', 'cf-mitigated-type']) {
    final raw = headers[key];
    if (raw == null) continue;
    final value = raw.join(',').toLowerCase();
    if (value.contains('challenge') || value.contains('managed')) {
      return HaikuoShieldVerdict.challenge;
    }
  }
  // 2) 正文特征。只在 4xx/5xx 上看，2xx 的正文里出现这些词多半是
  //    站方自己的说明文字，不能动。
  if (status < 400) return HaikuoShieldVerdict.pass;
  final head = body.length > 32768 ? body.substring(0, 32768) : body;
  if (head.isEmpty) return HaikuoShieldVerdict.pass;
  final lower = head.toLowerCase();
  const markers = <String>[
    'just a moment',
    '/cdn-cgi/challenge-platform',
    'challenge-platform/h/',
    'cf-chl',
    '_cf_chl_opt',
    'verifying you are human',
    'checking your browser',
    'enable javascript and cookies to continue',
    'cf-browser-verification',
    // CDN 层的硬化拦截（不是挑战页，同样需要真实会话来过）：
    'cloudflare protection detected',
    'cf-error-details',
    'error 1020',
  ];
  for (final marker in markers) {
    if (lower.contains(marker)) return HaikuoShieldVerdict.challengeBody;
  }
  // 3) CF 的 JSON 错误体（如 1020 防火墙规则）也会给 challenge 提示。
  final server = headers['server']?.join(',').toLowerCase() ?? '';
  if (status == 503 && server.contains('cloudflare')) {
    return HaikuoShieldVerdict.challengeBody;
  }
  return HaikuoShieldVerdict.pass;
}

/// 直接从代理响应的统一结构里判定挑战，省得每个调用点各写一遍。
HaikuoShieldVerdict haikuoShieldVerdictOf(Map<String, dynamic> result) {
  final code = (result['code'] as num?)?.toInt() ?? 0;
  final body = '${result['body'] ?? ''}';
  final map = <String, List<String>>{};
  final raw = result['headers'];
  if (raw is Map) {
    raw.forEach((key, value) {
      map['$key'.toLowerCase()] =
          value is List ? [for (final e in value) '$e'] : ['$value'];
    });
  }
  return haikuoShieldCheck(status: code, headers: map, body: body);
}

/// 判断一个已拿到的页面正文是不是「真内容」（解盾成功），而不是
/// 还在挑战页上。同样只认通用特征。
bool haikuoShieldLooksSolved(String html) {
  if (html.isEmpty) return false;
  final lower = html.toLowerCase();
  const markers = <String>[
    '/cdn-cgi/challenge-platform',
    'just a moment',
    'verifying you are human',
    'checking your browser',
    'cf-browser-verification',
    '_cf_chl_opt',
  ];
  for (final marker in markers) {
    if (lower.contains(marker)) return false;
  }
  return html.length > 800;
}

/// 验播探针响应：状态码 + 响应头 + 响应体首段字节（最多 2KB）。
class FeedProbeResponse {
  const FeedProbeResponse({
    required this.statusCode,
    required this.headers,
    required this.headBytes,
  });

  final int statusCode;

  /// 响应头，键已转小写。
  final Map<String, String> headers;
  final List<int> headBytes;
}

/// 验播探针：取 [url] 的首段字节（Range），供测试注入假实现。
typedef FeedProbeFetch =
    Future<FeedProbeResponse> Function(
      String url,
      Map<String, String> headers,
      Duration timeout,
    );

/// 默认探针：HttpClient GET + Range bytes=0-2047，只读首个数据块
/// 就取消订阅（直链大文件不会整段下载），直连。
Future<FeedProbeResponse> probeStreamHead(
  String url,
  Map<String, String> headers,
  Duration timeout,
) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw AppFailure('验播地址无效');
  }
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    headers.forEach((key, value) {
      if (value.isEmpty) return;
      request.headers.set(key, value);
    });
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');
    if (request.headers.value(HttpHeaders.userAgentHeader) == null) {
      request.headers.set(HttpHeaders.userAgentHeader, contentUserAgent);
    }
    final response = await request.close().timeout(timeout);
    final head = await _firstChunk(response, timeout);
    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      }
    });
    return FeedProbeResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      headBytes: head,
    );
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _firstChunk(
  HttpClientResponse response,
  Duration timeout,
) async {
  final completer = Completer<List<int>>();
  late StreamSubscription<List<int>> subscription;
  subscription = response.listen(
    (chunk) {
      if (!completer.isCompleted) completer.complete(chunk);
      unawaited(subscription.cancel());
    },
    onError: (_) {
      if (!completer.isCompleted) completer.complete(const []);
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(const []);
    },
    cancelOnError: true,
  );
  try {
    return await completer.future.timeout(timeout);
  } on TimeoutException {
    await subscription.cancel();
    return const [];
  }
}

/// 验播判定：m3u8 须 2xx 且首段含 #EXTM3U；直链须 206，或 200
/// 且非 HTML 错误页。其它状态一律不可播。
bool feedProbePlayable(Uri uri, FeedProbeResponse response) {
  final status = response.statusCode;
  final contentType = (response.headers['content-type'] ?? '').toLowerCase();
  final isManifest =
      uri.path.toLowerCase().endsWith('.m3u8') ||
      contentType.contains('mpegurl');
  if (isManifest) {
    if (status < 200 || status >= 300) return false;
    return String.fromCharCodes(response.headBytes).contains('#EXTM3U');
  }
  if (status == 206) return true;
  if (status == 200) {
    return response.headBytes.isNotEmpty && !contentType.contains('text/html');
  }
  return false;
}
