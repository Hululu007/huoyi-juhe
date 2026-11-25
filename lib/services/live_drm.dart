import 'dart:convert';

import 'live_sources.dart';

/// 直播频道 DRM 的种类判定（只做分类，不做任何解密）。
enum LiveDrmKind {
  /// Widevine（license_type 含 widevine）。
  widevine,

  /// PlayReady（license_type 含 playready）。
  playReady,

  /// ClearKey（license_type 含 clearkey，键是本地键）。
  clearKey,

  /// 服务器型：键是 http(s) 许可证服务器地址，但类型认不出
  /// 上面三类（或类型为空但带了服务器地址的残缺形态不会进这里，
  /// 见 liveDrmForChannel 的不猜口径）。
  server,
}

/// DRM 归一化结果：只是把频道里原样存的 license 信息整理成
/// 结构化描述，供页面明示「带 DRM」与后续立项时消费。
/// 本应用当前没有 DRM 解密通路，这个结构不代表频道可播。
class LiveDrmInfo {
  const LiveDrmInfo({
    required this.kind,
    required this.type,
    required this.key,
    this.headers = const {},
  });

  final LiveDrmKind kind;

  /// 频道声明的授权类型原文（如 com.widevine.alpha）。
  final String type;

  /// 服务器型时是许可证服务器地址；ClearKey 本地键时是归一化
  /// 后的 JWK JSON（或频道原样给的 JWK）。
  final String key;

  /// 服务器型时从 key 的 `|` 后段拆出的许可证请求头。
  final Map<String, String> headers;

  bool get isServer => key.startsWith('http://') || key.startsWith('https://');
}

/// 直播频道 DRM 归一化：把 LiveChannel 里原样存的 #KODIPROP
/// license_key / license_type 拆成结构化描述（与魔蚁定版同口径）：
/// - key 以 http(s) 开头 = 许可证服务器地址；第一个 `|` 后是
///   许可证请求头（`名=值&名=值`）。Kodi 四段模板里的
///   `{SSM}`/`{PSSH}` 占位段不是请求头，跳过不硬塞。
/// - drm_legacy 的 `类型|键` 整行被解析器存进 licenseKey、
///   类型另存 licenseType，这里把前缀剥掉还原。
/// - ClearKey 本地键（非 http）：已是 JWK JSON 的原样用；
///   十六进制 `kid:key[,kid:key...]` 对转成 JWK JSON
///   （hex → base64url 无填充，kty=oct，type=temporary）。
/// - type 为空、或 Widevine/PlayReady 给的不是服务器地址：
///   归一化不出，返回 null（不猜体系）。
LiveDrmInfo? liveDrmForChannel(LiveChannel channel) {
  var key = channel.licenseKey.trim();
  var type = channel.licenseType.trim();
  if (key.isEmpty) return null;

  // drm_legacy 形态：licenseKey = "类型|键"，licenseType = 类型。
  if (type.isNotEmpty && key.startsWith('$type|')) {
    key = key.substring(type.length + 1).trim();
  } else if (type.isEmpty && key.contains('|')) {
    final head = key.split('|').first.trim();
    if (_looksLikeDrmType(head)) {
      type = head;
      key = key.substring(head.length + 1).trim();
    }
  }
  if (type.isEmpty || key.isEmpty) return null;

  final lowerType = type.toLowerCase();
  if (key.startsWith('http://') || key.startsWith('https://')) {
    final split = key.split('|');
    final url = split.first.trim();
    if (url.isEmpty) return null;
    final headers = <String, String>{};
    if (split.length > 1) {
      for (final param in split.sublist(1).join('|').split('&')) {
        final eq = param.indexOf('=');
        if (eq <= 0) continue;
        final name = param.substring(0, eq).trim();
        final value = param.substring(eq + 1).trim();
        if (!_isHeaderName(name) || value.contains('{')) continue;
        headers[name] = value;
      }
    }
    return LiveDrmInfo(
      kind: _kindOf(lowerType, server: true),
      type: type,
      key: url,
      headers: headers,
    );
  }

  // 非服务器地址只可能是 ClearKey 本地键。
  if (!lowerType.contains('clearkey')) return null;
  if (key.startsWith('{')) {
    try {
      final decoded = jsonDecode(key);
      if (decoded is Map && decoded['keys'] is List) {
        return LiveDrmInfo(kind: LiveDrmKind.clearKey, type: type, key: key);
      }
    } catch (_) {}
    return null;
  }
  final jwk = clearKeyHexToJwk(key);
  if (jwk == null) return null;
  return LiveDrmInfo(kind: LiveDrmKind.clearKey, type: type, key: jwk);
}

LiveDrmKind _kindOf(String lowerType, {required bool server}) {
  if (lowerType.contains('widevine')) return LiveDrmKind.widevine;
  if (lowerType.contains('playready')) return LiveDrmKind.playReady;
  if (lowerType.contains('clearkey')) return LiveDrmKind.clearKey;
  return LiveDrmKind.server;
}

bool _looksLikeDrmType(String value) {
  final lower = value.toLowerCase();
  return lower.contains('widevine') ||
      lower.contains('clearkey') ||
      lower.contains('playready');
}

bool _isHeaderName(String name) => RegExp(r'^[A-Za-z0-9-]+$').hasMatch(name);

/// 十六进制 `kid:key[,kid:key...]` → ClearKey JWK JSON 字符串。
/// 任一对格式不对（非十六进制、长度不是 16 字节）整体返回 null，
/// 不凑半成品。
String? clearKeyHexToJwk(String raw) {
  final keys = <Map<String, String>>[];
  for (final pair in raw.split(',')) {
    final parts = pair.split(':');
    if (parts.length != 2) return null;
    final kid = _hexToBase64Url(parts[0].trim());
    final k = _hexToBase64Url(parts[1].trim());
    if (kid == null || k == null) return null;
    keys.add({'kty': 'oct', 'k': k, 'kid': kid});
  }
  if (keys.isEmpty) return null;
  return jsonEncode({'keys': keys, 'type': 'temporary'});
}

String? _hexToBase64Url(String hex) {
  if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    return null;
  }
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return base64Url.encode(bytes).replaceAll('=', '');
}
