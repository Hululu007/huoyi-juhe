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

Map<String, dynamic>? _decodePayload(String packed) {
  for (final candidate in _base64Candidates(packed)) {
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
