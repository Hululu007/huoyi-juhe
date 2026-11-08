import 'dart:convert';

/// 旧壳本地代理地址解包：jar 蜘蛛常把封面/图片包成
/// `http://127.0.0.1:9978/proxy?type=img&site=<站>&p=<base64 JSON>`，
/// 其中 `p` 解开是 `{"u": <真实图片地址>, "r": <Referer>, "s": <站>}`。
/// 本应用里 9978 端口没有服务在听，这类地址直接交给图片组件永远
/// 加载失败（棕色占位图）；解包后用真实地址 + Referer 直取。
/// 非壳代理地址、解不开的地址一律返回 null，调用方原样用原地址。
({String url, Map<String, String> headers})? unwrapShellProxyUrl(
  String raw,
) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (uri.host != '127.0.0.1' &&
      uri.host != 'localhost' &&
      uri.host != '::1' &&
      uri.host != '[::1]') {
    return null;
  }
  if (!uri.path.contains('proxy')) return null;
  final packed = uri.queryParameters['p'];
  if (packed == null || packed.isEmpty) return null;
  final decoded = _decodePayload(packed);
  if (decoded == null) return null;
  final target = decoded['u'];
  if (target is! String || target.isEmpty) return null;
  if (!target.startsWith('http://') && !target.startsWith('https://')) {
    return null;
  }
  final headers = <String, String>{};
  final referer = decoded['r'];
  if (referer is String && referer.isNotEmpty) {
    headers['Referer'] = referer;
  }
  return (url: target, headers: headers);
}

Map<String, dynamic>? _decodePayload(String packed) {  for (final candidate in _base64Candidates(packed)) {
    try {
      final text = utf8.decode(base64.decode(candidate));
      final parsed = jsonDecode(text);
      if (parsed is Map<String, dynamic>) return parsed;
      if (parsed is Map) {
        return {
          for (final entry in parsed.entries)
            entry.key.toString(): entry.value,
        };
      }
    } catch (_) {
      // 换一种 base64 形态再试。
    }
  }
  return null;
}

/// base64 的几种写法都试一遍：标准 / URL 安全、带 / 不带补位；
/// 查询串里 `+` 可能被转成空格，也还原回去再试。
List<String> _base64Candidates(String packed) {
  final out = <String>[];
  void add(String value) {
    if (value.isNotEmpty && !out.contains(value)) out.add(value);
  }

  for (final base in [packed, packed.replaceAll(' ', '+')]) {
    add(base);
    add(base.replaceAll('-', '+').replaceAll('_', '/'));
  }
  final normalized = <String>[];
  for (final value in out) {
    var v = value;
    final pad = (4 - v.length % 4) % 4;
    if (pad > 0) v += '=' * pad;
    normalized.add(v);
  }
  return [...out, ...normalized];
}

/// 打包一条本地代理取图载荷：`{"u": 真实地址, "r": Referer}` 的
/// URL 安全 base64（无补位），与 [unwrapShellProxyUrl] 互为逆操作。
/// 本地代理的 /proxy?p= 入口收到后带 Referer 与图片 Accept 头取回
/// （见 LocalMediaProxy._serveProxiedFetch）。
String packShellProxyPayload(String url, {String? referer}) {
  final payload = <String, String>{'u': url};
  if (referer != null && referer.isNotEmpty) payload['r'] = referer;
  return base64Url
      .encode(utf8.encode(jsonEncode(payload)))
      .replaceAll('=', '');
}

bool _isLoopbackHost(String host) =>
    host == '127.0.0.1' ||
    host == 'localhost' ||
    host == '::1' ||
    host == '[::1]';

/// 封面地址统一解析：把蜘蛛给的各种形态都换成图片组件能直接取的地址。
///
/// 之前只有 `127.0.0.1:9978/proxy?p=` 这一种形态会被解包，其余形态
/// 原样交给 CachedNetworkImage，手机上必失败：
/// - `proxy://do=py&siteKey=danai&u=...`：不是合法 http(s) 地址，图片
///   组件根本发不出请求（danai 的加密图只有蜘蛛 localProxy 能解）；
/// - `http://...` 明文图：系统网络安全配置禁明文（只放行 127.0.0.1），
///   直取必被拦；
/// - 回环 `/proxy?do=...`（无 p 的不透明形态）：蜘蛛写死 9978 端口，
///   本地代理被占时绑到别的端口就敲错门。
/// 换法（proxyBase 为当前本地代理地址，如 `http://127.0.0.1:9978`；
/// 传空时退化为老行为，只解包、不改写）：
/// - `proxy://` → `$proxyBase/proxy?` + 原查询串，走蜘蛛 localProxy；
/// - 回环 proxy 地址 → p= 能解开时按老路直取（https）或改走代理打包
///   取回（http 明文图）；解不开时把 host/端口改写到当前 proxyBase；
/// - `http://` → `$proxyBase/proxy?p=` 打包取回；
/// - 其余（https 直链等）原样返回。
/// 返回的 headers 非空时调用方要把它传给图片组件（Referer 在里面）。
({String url, Map<String, String>? headers}) resolveCoverUrl(
  String raw, {
  String proxyBase = '',
}) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return (url: '', headers: null);
  // proxy://do=py&siteKey=danai&u=...：Uri 会把整个查询串吞进
  // host，字符串处理更稳：去掉前缀后剩下的就是查询串。
  if (trimmed.startsWith('proxy://')) {
    if (proxyBase.isEmpty) return (url: trimmed, headers: null);
    final query = trimmed.substring('proxy://'.length);
    return (url: '$proxyBase/proxy?$query', headers: null);
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return (url: trimmed, headers: null);
  if (_isLoopbackHost(uri.host) && uri.path.contains('proxy')) {
    final packed = uri.queryParameters['p'];
    if (packed != null && packed.isNotEmpty) {
      final unwrapped = unwrapShellProxyUrl(trimmed);
      if (unwrapped != null) {
        if (unwrapped.url.startsWith('http://')) {
          if (proxyBase.isEmpty) {
            return (url: unwrapped.url, headers: unwrapped.headers);
          }
          return (
            url:
                '$proxyBase/proxy?p=${packShellProxyPayload(unwrapped.url, referer: unwrapped.headers['Referer'])}',
            headers: null,
          );
        }
        return (url: unwrapped.url, headers: unwrapped.headers);
      }
    }
    if (proxyBase.isEmpty) return (url: trimmed, headers: null);
    final suffix = uri.hasQuery ? '?${uri.query}' : '';
    return (url: '$proxyBase${uri.path}$suffix', headers: null);
  }
  if (uri.scheme == 'http') {
    if (proxyBase.isEmpty) return (url: trimmed, headers: null);
    return (
      url: '$proxyBase/proxy?p=${packShellProxyPayload(trimmed)}',
      headers: null,
    );
  }
  return (url: trimmed, headers: null);
}
