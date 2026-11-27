import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart' show DramaSiteCategory;
import 'idj_plugin_store.dart';
import 'js_bridge.dart';

/// idj1 插件运行时（修仙版）：把 `.idjplugin` 的入口脚本跑在安卓
/// 现行 QuickJS 桥上，用一段 host 垫片脚本把桥的原生全局
/// （request/get/post/pdfa/pdfh/pd）包成 idj1 规格的 `host.*`，
/// 再经统一驱动调用插件的 home/category/search/detail/play，
/// 结果按契约转成宿主的内容模型（与魔蚁 idj_contract 同口径）。
///
/// 与魔蚁 Go 核运行时的已知差异（如实标注，不假装等价）：
/// - 原生 `request` 只回正文、不回状态码与响应头：垫片合成
///   `status: 200, headers: {}`；请求失败与空正文无法区分，
///   一律按 E_NET 处理。Cookie 罐没有（原生请求层不带罐），
///   依赖登录态的插件跑不了（host 规格里 login 本就不开放）。
/// - 请求体由原生层固定按表单编码发送，插件发 JSON 体会被
///   按表单发（Content-Type 覆盖行为以原生 OkHttp 为准）。
/// - host.html 的节点 text/html/attr 是基于 outerHtml 字符串的
///   近似实现（select/selectFirst 走原生 jsoup，是精确的）。
/// - host.crypto 的 sha512/rsa、host.codec.gunzip 未实现，
///   调用抛 E_UNSUPPORTED，host.has 对应项回 false。
/// - iOS 没有 QuickJS 桥：本运行时在 iOS 上经 [JsBridge.status]
///   如实报不可用，插件装不上（probe 失败）、站打不开。

/// 插件调用失败：带 idj 错误码（E_*），看门狗按码分瞬时/非瞬时。
class IdjCallException implements Exception {
  IdjCallException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// _invoke 归一化后的通用失败文案：插件自抛的错误与引擎异常多为
/// 英文原文，只进日志（debugPrint），异常里带给上层的只剩这句；
/// 内容客户端再按 op 换成「哪一步失败＋怎么办」的具体文案。
const String idjGenericCallFailureMessage = '插件执行失败';

/// 驱动/垫片自产错误码：这些码的 message 是驱动模板与 host 垫片里
/// 写死的中文（缺能力、域名白名单、网络、权限、未实现、加解密
/// 参数等），可以原样给用户看。其余码（E_PLUGIN 与插件自造码）
/// 的 message 来自插件脚本自抛，内容不可控，一律换通用文案。
const Set<String> _idjDriverErrorCodes = {
  'E_PROBE',
  'E_NO_CAPABILITY',
  'E_DOMAIN',
  'E_NET',
  'E_UNSUPPORTED',
  'E_CRYPTO',
  'E_PERMISSION',
};

/// 评估注入点：生产走 [JsBridge.evalRaw]，测试可换假实现。
typedef IdjEvalFn = Future<dynamic> Function(String script, int timeoutMs);

/// 组装一次插件调用的完整脚本：host 垫片 + 插件域/存储/能力注入
/// + 插件脚本（`export default` 改写为赋值）+ 驱动。
/// Node 全链验证台从本文件按标记抽取垫片与驱动原文复用同一份文本，
/// 不另抄一份。
String buildIdjDriverScript({
  required String pluginScript,
  required IdjPluginManifest manifest,
  required String op,
  required Map<String, dynamic> args,
  required Map<String, dynamic> storage,
}) {
  final transformed = pluginScript.replaceFirst(
    RegExp(r'export\s+default'),
    'var __idj_plugin =',
  );
  final domains = [
    ...manifest.httpDomains,
    for (final domain in manifest.mediaDomains)
      if (!manifest.httpDomains.contains(domain)) domain,
  ];
  return [
    idjHostPrelude,
    'var __idjDomains = ${jsonEncode(domains)};',
    'var __idjStorageAllowed = ${manifest.storagePermission};',
    'var __idjStorage = ${jsonEncode(storage)};',
    'var __idjCaps = ${jsonEncode(manifest.capabilities)};',
    transformed,
    idjDriverTemplate
        .replaceAll('__IDJ_OP__', op)
        .replaceAll('__IDJ_ARGS__', jsonEncode(args)),
  ].join('\n');
}

// __IDJ_DRIVER_BEGIN__
/// 驱动模板：占位符 __IDJ_OP__ / __IDJ_ARGS__ 由组装方替换。
/// probe 形态（op == '__probe__'）额外调 init 并核对能力函数齐全。
const String idjDriverTemplate = r'''
;(async function () {
  try {
    if (typeof __idj_plugin === 'undefined' || !__idj_plugin) {
      throw { code: 'E_PLUGIN', message: '入口脚本没有 export default' };
    }
    if ('__IDJ_OP__' === '__probe__') {
      var missing = __idjCaps.filter(function (c) {
        return typeof __idj_plugin[c] !== 'function';
      });
      if (missing.length) {
        throw {
          code: 'E_PROBE',
          message: '插件缺少 manifest 声明的能力函数：' + missing.join(', '),
        };
      }
      if (typeof __idj_plugin.init === 'function') {
        await __idj_plugin.init(__IDJ_ARGS__);
      }
      setResult(JSON.stringify({ ok: true, result: null, storage: __idjStorage }));
      return;
    }
    var fn = __idj_plugin['__IDJ_OP__'];
    if (typeof fn !== 'function') {
      throw { code: 'E_NO_CAPABILITY', message: '插件没有实现 __IDJ_OP__ 能力' };
    }
    var r = await fn(__IDJ_ARGS__);
    setResult(JSON.stringify({
      ok: true,
      result: r === undefined ? null : r,
      storage: __idjStorage,
    }));
  } catch (e) {
    setResult(JSON.stringify({
      ok: false,
      code: (e && e.code) || 'E_PLUGIN',
      message: String((e && e.message) || e),
    }));
  }
})();
''';
// __IDJ_DRIVER_END__

// __IDJ_PRELUDE_BEGIN__
/// host 垫片（第一段：原生捕获、白名单、HTTP、HTML 节点）：
/// 捕获原生全局后立即从全局删除，插件只能走 host.*。
/// 白名单在垫片内按 manifest 域名清单判定（原生请求层没有域名
/// 校验，绕不过去的口子在这里堵上）。
const String idjHostPreludePart1 = r'''
var __idjNative = (function () {
  var n = {};
  try { n.request = request; } catch (e) {}
  try { n.get = get; } catch (e) {}
  try { n.post = post; } catch (e) {}
  try { n.pdfa = pdfa; } catch (e) {}
  try { n.pdfh = pdfh; } catch (e) {}
  try { n.pd = pd; } catch (e) {}
  try {
    n.log = (typeof print === 'function') ? print
      : ((typeof log === 'function') ? log : null);
  } catch (e) {}
  return n;
})();
try { delete globalThis.request; } catch (e) {}
try { delete globalThis.get; } catch (e) {}
try { delete globalThis.post; } catch (e) {}
try { delete globalThis.pdfa; } catch (e) {}
try { delete globalThis.pdfh; } catch (e) {}
try { delete globalThis.pd; } catch (e) {}
try { globalThis.fetch = undefined; } catch (e) {}
try { globalThis.XMLHttpRequest = undefined; } catch (e) {}
try { globalThis.WebSocket = undefined; } catch (e) {}

function __idjStrToBytes(str) {
  var out = [];
  var s = String(str);
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) { out.push(c); }
    else if (c < 0x800) {
      out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
    } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      var c2 = s.charCodeAt(++i);
      var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
  }
  return out;
}

function __idjBytesToStr(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var b = bytes[i];
    if (b < 0x80) { out += String.fromCharCode(b); i += 1; }
    else if (b >= 0xc0 && b < 0xe0 && i + 1 < bytes.length) {
      out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
      i += 2;
    } else if (b >= 0xe0 && b < 0xf0 && i + 2 < bytes.length) {
      out += String.fromCharCode(((b & 0x0f) << 12) |
        ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f));
      i += 3;
    } else if (b >= 0xf0 && i + 3 < bytes.length) {
      var cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      i += 4;
    } else { out += '�'; i += 1; }
  }
  return out;
}

var __idjB64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __idjBytesToB64(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var a = bytes[i], b = i + 1 < bytes.length ? bytes[i + 1] : 0,
      c = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += __idjB64Chars[a >> 2];
    out += __idjB64Chars[((a & 3) << 4) | (b >> 4)];
    out += i + 1 < bytes.length ? __idjB64Chars[((b & 15) << 2) | (c >> 6)] : '=';
    out += i + 2 < bytes.length ? __idjB64Chars[c & 63] : '=';
  }
  return out;
}

function __idjB64ToBytes(text) {
  var clean = String(text).replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < clean.length; i += 4) {
    var a = __idjB64Chars.indexOf(clean[i]);
    var b = __idjB64Chars.indexOf(clean[i + 1]);
    var c = clean[i + 2] === '=' ? -1 : __idjB64Chars.indexOf(clean[i + 2]);
    var d = clean[i + 3] === '=' ? -1 : __idjB64Chars.indexOf(clean[i + 3]);
    if (a < 0 || b < 0) break;
    out.push(((a << 2) | (b >> 4)) & 0xff);
    if (c >= 0) out.push((((b & 15) << 4) | (c >> 2)) & 0xff);
    if (d >= 0 && c >= 0) out.push((((c & 3) << 6) | d) & 0xff);
  }
  return out;
}

function __idjBytesToHex(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) {
    out += ('0' + bytes[i].toString(16)).slice(-2);
  }
  return out;
}

function __idjHexToBytes(text) {
  var clean = String(text).replace(/[^0-9a-fA-F]/g, '');
  var out = [];
  for (var i = 0; i + 1 < clean.length; i += 2) {
    out.push(parseInt(clean.substr(i, 2), 16));
  }
  return out;
}

function __idjDecodeInput(value, encoding) {
  var enc = String(encoding || 'utf8').toLowerCase();
  if (enc === 'base64') return __idjB64ToBytes(value);
  if (enc === 'hex') return __idjHexToBytes(value);
  return __idjStrToBytes(value);
}

function __idjEncodeOutput(bytes, encoding) {
  var enc = String(encoding || 'hex').toLowerCase();
  if (enc === 'base64') return __idjBytesToB64(bytes);
  if (enc === 'utf8') return __idjBytesToStr(bytes);
  return __idjBytesToHex(bytes);
}

function __idjParseHost(url) {
  var m = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^/?#]*)/.exec(String(url));
  if (!m) return null;
  var authority = m[1];
  if (authority.indexOf('@') >= 0) return null;
  var host = authority.split(':')[0].toLowerCase();
  return host || null;
}

function __idjHostAllowed(url) {
  var host = __idjParseHost(url);
  if (!host) return false;
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(host)) return false;
  if (host === 'localhost') return false;
  for (var i = 0; i < __idjDomains.length; i++) {
    var d = __idjDomains[i];
    if (d.indexOf('*.') === 0) {
      var suffix = d.slice(2);
      if (host === suffix || host.slice(-(suffix.length + 1)) === '.' + suffix) {
        return true;
      }
    } else if (host === d) { return true; }
  }
  return false;
}

var __idjForbiddenHeaders = {
  'host': 1, 'content-length': 1, 'connection': 1, 'transfer-encoding': 1,
  'cookie': 1, 'set-cookie': 1, 'proxy-authorization': 1,
  'proxy-connection': 1, 'te': 1, 'trailer': 1, 'upgrade': 1,
};

function __idjCleanHeaders(headers) {
  var out = {};
  if (!headers) return out;
  for (var key in headers) {
    if (!__idjForbiddenHeaders[key.toLowerCase()]) {
      out[key] = String(headers[key]);
    }
  }
  return out;
}

function __idjEncodeForm(obj) {
  var parts = [];
  for (var key in obj) {
    var value = obj[key];
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) {
        parts.push(encodeURIComponent(key) + '=' +
          encodeURIComponent(String(value[i])));
      }
    } else if (value !== undefined && value !== null) {
      parts.push(encodeURIComponent(key) + '=' +
        encodeURIComponent(String(value)));
    }
  }
  return parts.join('&');
}

function __idjHttpRequest(opts) {
  opts = opts || {};
  var method = String(opts.method || 'GET').toUpperCase();
  var url = String(opts.url || '');
  if (!__idjHostAllowed(url)) {
    var domainError = new Error('域名不在插件白名单内：' + (__idjParseHost(url) || url));
    domainError.code = 'E_DOMAIN';
    throw domainError;
  }
  var body = '';
  if (opts.body !== undefined && opts.body !== null) {
    body = (typeof opts.body === 'string') ? opts.body : __idjEncodeForm(opts.body);
  }
  var raw = __idjNative.request({
    url: url, method: method,
    headers: __idjCleanHeaders(opts.headers), body: body,
  });
  if (raw === null || raw === undefined || raw === '') {
    var netError = new Error('网络请求失败');
    netError.code = 'E_NET';
    throw netError;
  }
  return { status: 200, url: url, headers: {}, body: String(raw) };
}

function __idjStripTags(html) {
  return String(html).replace(/<[^>]*>/g, '');
}

function __idjDecodeEntities(text) {
  return String(text)
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&#(\d+);/g, function (_, n) {
      return String.fromCharCode(parseInt(n, 10));
    })
    .replace(/&amp;/g, '&');
}

function __idjNode(htmlStr) {
  var self = { __html: String(htmlStr === null || htmlStr === undefined ? '' : htmlStr) };
  self.select = function (selector) {
    if (!self.__html) return [];
    var raw = __idjNative.pdfa(self.__html, selector);
    var list = [];
    try { list = JSON.parse(raw || '[]'); } catch (e) { list = []; }
    return list.map(function (item) { return __idjNode(item); });
  };
  self.selectFirst = function (selector) {
    var all = self.select(selector);
    return all.length ? all[0] : null;
  };
  self.text = function () {
    return __idjDecodeEntities(__idjStripTags(self.__html))
      .replace(/\s+/g, ' ').trim();
  };
  self.html = function () {
    var m = /^<[^>]+>([\s\S]*)<\/[a-zA-Z0-9]+\s*>$/.exec(self.__html.trim());
    return m ? m[1] : '';
  };
  self.outerHtml = function () { return self.__html; };
  self.attr = function (name) {
    var m = /^<([a-zA-Z0-9]+)((?:\s[^>]*)?)>/.exec(self.__html.trim());
    if (!m) return null;
    var re = new RegExp('(?:^|\\s)' + name +
      '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|([^\\s>]+))', 'i');
    var am = re.exec(m[2] || '');
    if (!am) return null;
    if (am[1] !== undefined) return am[1];
    if (am[2] !== undefined) return am[2];
    return am[3];
  };
  return self;
}
''';

/// host 垫片（第二段：加密、编解码、m3u8、URL、host 组装）。
const String idjHostPreludePart2 = r'''
function __idjRotl32(v, c) { return ((v << c) | (v >>> (32 - c))) | 0; }
function __idjRotr32(v, c) { return ((v >>> c) | (v << (32 - c))) | 0; }

function __idjMd5Bytes(input) {
  var S = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  ];
  var K = [];
  for (var ki = 0; ki < 64; ki++) {
    K.push(Math.floor(Math.abs(Math.sin(ki + 1)) * 4294967296) | 0);
  }
  var msg = input.slice();
  var bitLen = msg.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  for (var li = 0; li < 4; li++) msg.push((bitLen >>> (li * 8)) & 0xff);
  for (var hi = 0; hi < 4; hi++) msg.push(0);
  var a0 = 0x67452301 | 0, b0 = 0xefcdab89 | 0, c0 = 0x98badcfe | 0,
    d0 = 0x10325476 | 0;
  for (var off = 0; off < msg.length; off += 64) {
    var M = [];
    for (var wi = 0; wi < 16; wi++) {
      M.push(msg[off + wi * 4] | (msg[off + wi * 4 + 1] << 8) |
        (msg[off + wi * 4 + 2] << 16) | (msg[off + wi * 4 + 3] << 24));
    }
    var A = a0, B = b0, C = c0, D = d0;
    for (var i = 0; i < 64; i++) {
      var F, g;
      if (i < 16) { F = (B & C) | (~B & D); g = i; }
      else if (i < 32) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (i < 48) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      var tmp = D;
      D = C;
      C = B;
      B = (B + __idjRotl32((A + F + K[i] + M[g]) | 0, S[i])) | 0;
      A = tmp;
    }
    a0 = (a0 + A) | 0; b0 = (b0 + B) | 0; c0 = (c0 + C) | 0; d0 = (d0 + D) | 0;
  }
  var out = [];
  [a0, b0, c0, d0].forEach(function (w) {
    out.push(w & 0xff, (w >>> 8) & 0xff, (w >>> 16) & 0xff, (w >>> 24) & 0xff);
  });
  return out;
}

function __idjSha1Bytes(input) {
  var msg = input.slice();
  var bitLen = msg.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  for (var li = 0; li < 4; li++) msg.push(0);
  for (var bi = 3; bi >= 0; bi--) msg.push((bitLen >>> (bi * 8)) & 0xff);
  var h = [0x67452301 | 0, 0xefcdab89 | 0, 0x98badcfe | 0, 0x10325476 | 0,
    0xc3d2e1f0 | 0];
  for (var off = 0; off < msg.length; off += 64) {
    var w = [];
    for (var wi = 0; wi < 16; wi++) {
      w.push(msg[off + wi * 4] << 24 | msg[off + wi * 4 + 1] << 16 |
        msg[off + wi * 4 + 2] << 8 | msg[off + wi * 4 + 3]);
    }
    for (var t = 16; t < 80; t++) {
      w.push(__idjRotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1));
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (var i = 0; i < 80; i++) {
      var f, k;
      if (i < 20) { f = (b & c) | (~b & d); k = 0x5a827999 | 0; }
      else if (i < 40) { f = b ^ c ^ d; k = 0x6ed9eba1 | 0; }
      else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc | 0; }
      else { f = b ^ c ^ d; k = 0xca62c1d6 | 0; }
      var tmp = (__idjRotl32(a, 5) + f + e + k + w[i]) | 0;
      e = d; d = c; c = __idjRotl32(b, 30); b = a; a = tmp;
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0;
    h[3] = (h[3] + d) | 0; h[4] = (h[4] + e) | 0;
  }
  var out = [];
  h.forEach(function (w) {
    out.push((w >>> 24) & 0xff, (w >>> 16) & 0xff, (w >>> 8) & 0xff, w & 0xff);
  });
  return out;
}

var __idjSha256K = [1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580, 3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986, 2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344, 430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298];

function __idjSha256Bytes(input) {
  var H = [1779033703, 3144134277, 1013904242, 2773480762, 1359893119,
    2600822924, 528734635, 1541459225];
  var msg = input.slice();
  var bitLen = msg.length * 8;
  msg.push(0x80);
  while (msg.length % 64 !== 56) msg.push(0);
  for (var li = 0; li < 4; li++) msg.push(0);
  for (var bi = 3; bi >= 0; bi--) msg.push((bitLen >>> (bi * 8)) & 0xff);
  function S0(x) { return __idjRotr32(x, 7) ^ __idjRotr32(x, 18) ^ (x >>> 3); }
  function S1(x) { return __idjRotr32(x, 17) ^ __idjRotr32(x, 19) ^ (x >>> 10); }
  function s0(x) { return __idjRotr32(x, 2) ^ __idjRotr32(x, 13) ^ __idjRotr32(x, 22); }
  function s1(x) { return __idjRotr32(x, 6) ^ __idjRotr32(x, 11) ^ __idjRotr32(x, 25); }
  for (var off = 0; off < msg.length; off += 64) {
    var w = [];
    for (var wi = 0; wi < 16; wi++) {
      w.push((msg[off + wi * 4] << 24 | msg[off + wi * 4 + 1] << 16 |
        msg[off + wi * 4 + 2] << 8 | msg[off + wi * 4 + 3]) | 0);
    }
    for (var t = 16; t < 64; t++) {
      w.push((S1(w[t - 2]) + w[t - 7] + S0(w[t - 15]) + w[t - 16]) | 0);
    }
    var a = H[0] | 0, b = H[1] | 0, c = H[2] | 0, d = H[3] | 0,
      e = H[4] | 0, f = H[5] | 0, g = H[6] | 0, h = H[7] | 0;
    for (var i = 0; i < 64; i++) {
      var ch = (e & f) ^ (~e & g);
      var maj = (a & b) ^ (a & c) ^ (b & c);
      var t1 = (h + s1(e) + ch + (__idjSha256K[i] | 0) + w[i]) | 0;
      var t2 = (s0(a) + maj) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0;
      d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0;
    H[3] = (H[3] + d) | 0; H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0;
    H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
  }
  var out = [];
  H.forEach(function (w) {
    out.push((w >>> 24) & 0xff, (w >>> 16) & 0xff, (w >>> 8) & 0xff, w & 0xff);
  });
  return out;
}

function __idjHashBytes(algo, bytes) {
  if (algo === 'md5') return __idjMd5Bytes(bytes);
  if (algo === 'sha1') return __idjSha1Bytes(bytes);
  if (algo === 'sha256') return __idjSha256Bytes(bytes);
  var e = new Error('不支持的哈希算法：' + algo);
  e.code = 'E_UNSUPPORTED';
  throw e;
}

function __idjHmacBytes(algo, keyBytes, msgBytes) {
  var blockSize = 64;
  var key = keyBytes.slice();
  if (key.length > blockSize) key = __idjHashBytes(algo, key);
  while (key.length < blockSize) key.push(0);
  var inner = key.map(function (b) { return b ^ 0x36; }).concat(msgBytes);
  var outer = key.map(function (b) { return b ^ 0x5c; })
    .concat(__idjHashBytes(algo, inner));
  return __idjHashBytes(algo, outer);
}

var __idjAesCache = null;
function __idjAesTables() {
  if (__idjAesCache) return __idjAesCache;
  function mul(a, b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if (b & 1) p ^= a;
      var hi = a & 0x80;
      a = (a << 1) & 0xff;
      if (hi) a ^= 0x1b;
      b >>= 1;
    }
    return p;
  }
  var sbox = [], invSbox = [];
  for (var x = 0; x < 256; x++) {
    var inv = 0;
    if (x !== 0) {
      for (var y = 1; y < 256; y++) {
        if (mul(x, y) === 1) { inv = y; break; }
      }
    }
    var s = inv;
    function rot(v, c) { return ((v << c) | (v >> (8 - c))) & 0xff; }
    s = (inv ^ rot(inv, 1) ^ rot(inv, 2) ^ rot(inv, 3) ^ rot(inv, 4) ^ 0x63) & 0xff;
    sbox[x] = s;
    invSbox[s] = x;
  }
  __idjAesCache = { sbox: sbox, invSbox: invSbox, mul: mul };
  return __idjAesCache;
}

function __idjAesExpandKey(keyBytes) {
  var tables = __idjAesTables();
  var Nk = keyBytes.length / 4;
  var Nr = Nk + 6;
  var w = [];
  for (var i = 0; i < keyBytes.length; i++) w.push(keyBytes[i]);
  var rcon = 1;
  for (var i = Nk; i < 4 * (Nr + 1); i++) {
    var temp = [w[(i - 1) * 4], w[(i - 1) * 4 + 1], w[(i - 1) * 4 + 2],
      w[(i - 1) * 4 + 3]];
    if (i % Nk === 0) {
      temp = [tables.sbox[temp[1]] ^ rcon, tables.sbox[temp[2]],
        tables.sbox[temp[3]], tables.sbox[temp[0]]];
      rcon = tables.mul(rcon, 2);
    } else if (Nk > 6 && i % Nk === 4) {
      temp = [tables.sbox[temp[0]], tables.sbox[temp[1]],
        tables.sbox[temp[2]], tables.sbox[temp[3]]];
    }
    for (var j = 0; j < 4; j++) {
      w.push(w[(i - Nk) * 4 + j] ^ temp[j]);
    }
  }
  return { roundKeys: w, rounds: Nr };
}

function __idjAesCryptBlock(input, expanded, encrypt) {
  var tables = __idjAesTables();
  var sbox = encrypt ? tables.sbox : tables.invSbox;
  var rk = expanded.roundKeys;
  var state = input.slice();
  function addRoundKey(round) {
    for (var i = 0; i < 16; i++) state[i] ^= rk[round * 16 + i];
  }
  function subBytes() {
    for (var i = 0; i < 16; i++) state[i] = sbox[state[i]];
  }
  function shiftRows() {
    var t = state.slice();
    // state 以列主序存放：state[col*4+row]
    if (encrypt) {
      for (var r = 0; r < 4; r++) {
        for (var c = 0; c < 4; c++) {
          state[c * 4 + r] = t[((c + r) % 4) * 4 + r];
        }
      }
    } else {
      for (var r2 = 0; r2 < 4; r2++) {
        for (var c2 = 0; c2 < 4; c2++) {
          state[c2 * 4 + r2] = t[((c2 - r2 + 4) % 4) * 4 + r2];
        }
      }
    }
  }
  function mixColumns() {
    for (var c = 0; c < 4; c++) {
      var a0 = state[c * 4], a1 = state[c * 4 + 1], a2 = state[c * 4 + 2],
        a3 = state[c * 4 + 3];
      if (encrypt) {
        state[c * 4] = tables.mul(a0, 2) ^ tables.mul(a1, 3) ^ a2 ^ a3;
        state[c * 4 + 1] = a0 ^ tables.mul(a1, 2) ^ tables.mul(a2, 3) ^ a3;
        state[c * 4 + 2] = a0 ^ a1 ^ tables.mul(a2, 2) ^ tables.mul(a3, 3);
        state[c * 4 + 3] = tables.mul(a0, 3) ^ a1 ^ a2 ^ tables.mul(a3, 2);
      } else {
        state[c * 4] = tables.mul(a0, 14) ^ tables.mul(a1, 11) ^
          tables.mul(a2, 13) ^ tables.mul(a3, 9);
        state[c * 4 + 1] = tables.mul(a0, 9) ^ tables.mul(a1, 14) ^
          tables.mul(a2, 11) ^ tables.mul(a3, 13);
        state[c * 4 + 2] = tables.mul(a0, 13) ^ tables.mul(a1, 9) ^
          tables.mul(a2, 14) ^ tables.mul(a3, 11);
        state[c * 4 + 3] = tables.mul(a0, 11) ^ tables.mul(a1, 13) ^
          tables.mul(a2, 9) ^ tables.mul(a3, 14);
      }
    }
  }
  var rounds = expanded.rounds;
  if (encrypt) {
    addRoundKey(0);
    for (var round = 1; round < rounds; round++) {
      subBytes(); shiftRows(); mixColumns(); addRoundKey(round);
    }
    subBytes(); shiftRows(); addRoundKey(rounds);
  } else {
    addRoundKey(rounds);
    for (var round2 = rounds - 1; round2 >= 1; round2--) {
      subBytes(); shiftRows(); addRoundKey(round2); mixColumns();
    }
    subBytes(); shiftRows(); addRoundKey(0);
  }
  return state;
}

function __idjAesRun(text, opts, encrypt) {
  opts = opts || {};
  var key = __idjDecodeInput(opts.key || '', opts.keyEncoding || 'utf8');
  if ([16, 24, 32].indexOf(key.length) < 0) {
    var e = new Error('AES 密钥长度必须是 16/24/32 字节');
    e.code = 'E_CRYPTO';
    throw e;
  }
  var mode = String(opts.mode || 'cbc').toLowerCase();
  var input = __idjDecodeInput(text,
    opts.inputEncoding || (encrypt ? 'utf8' : 'base64'));
  var expanded = __idjAesExpandKey(key);
  var out = [];
  if (mode === 'ecb') {
    if (encrypt) {
      var padLen = 16 - (input.length % 16);
      for (var pi = 0; pi < padLen; pi++) input.push(padLen);
      for (var off = 0; off < input.length; off += 16) {
        out = out.concat(__idjAesCryptBlock(input.slice(off, off + 16),
          expanded, true));
      }
    } else {
      for (var off2 = 0; off2 < input.length; off2 += 16) {
        out = out.concat(__idjAesCryptBlock(input.slice(off2, off2 + 16),
          expanded, false));
      }
      var pad = out.length ? out[out.length - 1] : 0;
      if (pad > 0 && pad <= 16) out = out.slice(0, out.length - pad);
    }
  } else {
    var iv = __idjDecodeInput(opts.iv || '', opts.ivEncoding || 'utf8');
    if (iv.length !== 16) {
      var e2 = new Error('AES-CBC 需要 16 字节 IV');
      e2.code = 'E_CRYPTO';
      throw e2;
    }
    var prev = iv;
    if (encrypt) {
      var padLen2 = 16 - (input.length % 16);
      for (var pj = 0; pj < padLen2; pj++) input.push(padLen2);
      for (var off3 = 0; off3 < input.length; off3 += 16) {
        var block = input.slice(off3, off3 + 16)
          .map(function (b, idx) { return b ^ prev[idx]; });
        var enc = __idjAesCryptBlock(block, expanded, true);
        out = out.concat(enc);
        prev = enc;
      }
    } else {
      for (var off4 = 0; off4 < input.length; off4 += 16) {
        var cipherBlock = input.slice(off4, off4 + 16);
        var dec = __idjAesCryptBlock(cipherBlock, expanded, false)
          .map(function (b, idx) { return b ^ prev[idx]; });
        out = out.concat(dec);
        prev = cipherBlock;
      }
      var pad2 = out.length ? out[out.length - 1] : 0;
      if (pad2 > 0 && pad2 <= 16) out = out.slice(0, out.length - pad2);
    }
  }
  return __idjEncodeOutput(out, opts.outputEncoding || (encrypt ? 'base64' : 'utf8'));
}

function __idjResolveUrl(base, rel) {
  rel = String(rel);
  if (!base) return rel;
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(rel)) return rel;
  var m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)/.exec(String(base));
  if (!m) return rel;
  var prefix = m[1] + '://' + m[2];
  if (rel.indexOf('//') === 0) return m[1] + ':' + rel;
  if (rel.charAt(0) === '/') return prefix + rel;
  if (rel.charAt(0) === '?') return prefix + (m[3] || '/') + rel;
  var dir = (m[3] || '/').slice(0, (m[3] || '/').lastIndexOf('/') + 1);
  var parts = (dir + rel).split('/');
  var outParts = [];
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i];
    if (part === '.') continue;
    if (part === '..') { outParts.pop(); continue; }
    outParts.push(part);
  }
  return prefix + outParts.join('/');
}

function __idjM3u8Parse(text, baseUrl) {
  var lines = String(text).split(/\r?\n/);
  var variants = [];
  var segments = [];
  var pendingAttrs = null;
  var pendingDuration = 0;
  function parseAttrs(raw) {
    var attrs = {};
    var re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g;
    var mm;
    while ((mm = re.exec(raw)) !== null) {
      attrs[mm[1]] = mm[2].replace(/^"|"$/g, '');
    }
    return attrs;
  }
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    if (line.indexOf('#EXT-X-STREAM-INF:') === 0) {
      pendingAttrs = parseAttrs(line.slice('#EXT-X-STREAM-INF:'.length));
      continue;
    }
    if (line.indexOf('#EXTINF:') === 0) {
      pendingDuration = parseFloat(line.slice('#EXTINF:'.length)) || 0;
      continue;
    }
    if (line.charAt(0) === '#') continue;
    var uri = __idjResolveUrl(baseUrl, line);
    if (pendingAttrs) {
      variants.push({
        uri: uri,
        bandwidth: parseInt(pendingAttrs['BANDWIDTH'] || '0', 10) || 0,
        resolution: pendingAttrs['RESOLUTION'] || '',
        codecs: pendingAttrs['CODECS'] || '',
      });
      pendingAttrs = null;
    } else {
      segments.push({ uri: uri, duration: pendingDuration });
      pendingDuration = 0;
    }
  }
  return { variants: variants, segments: segments };
}

function __idjPackerEncode(c, radix) {
  if (c < radix) {
    return (c % radix > 35)
      ? String.fromCharCode((c % radix) + 29)
      : (c % radix).toString(36);
  }
  return __idjPackerEncode(Math.floor(c / radix), radix) +
    __idjPackerEncode(c % radix, radix);
}

function __idjUnpackPacker(text) {
  var m = /\}\s*\(\s*'((?:[^'\\]|\\.)*)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'((?:[^'\\]|\\.)*)'\.split\('\|'\)/.exec(String(text));
  if (!m) {
    var e = new Error('不是可识别的 Packer 压缩文本');
    e.code = 'E_UNSUPPORTED';
    throw e;
  }
  var packed = m[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\');
  var radix = parseInt(m[2], 10);
  var count = parseInt(m[3], 10);
  var keywords = m[4].split('|');
  while (count--) {
    if (keywords[count]) {
      var token = __idjPackerEncode(count, radix);
      packed = packed.replace(new RegExp('\\b' + token + '\\b', 'g'),
        keywords[count]);
    }
  }
  return packed;
}

function __idjUnsupported(what) {
  var e = new Error(what + ' 在当前插件引擎中未实现');
  e.code = 'E_UNSUPPORTED';
  throw e;
}

var host = {
  http: {
    request: function (opts) { return __idjHttpRequest(opts); },
    get: function (url, headers) {
      return __idjHttpRequest({ method: 'GET', url: url, headers: headers });
    },
    post: function (url, body, headers) {
      return __idjHttpRequest({
        method: 'POST', url: url, headers: headers, body: body,
      });
    },
  },
  html: {
    parse: function (htmlText) { return __idjNode(htmlText); },
  },
  crypto: {
    md5: function (text, opts) {
      opts = opts || {};
      return __idjEncodeOutput(
        __idjMd5Bytes(__idjDecodeInput(text, opts.input)), opts.output);
    },
    sha1: function (text, opts) {
      opts = opts || {};
      return __idjEncodeOutput(
        __idjSha1Bytes(__idjDecodeInput(text, opts.input)), opts.output);
    },
    sha256: function (text, opts) {
      opts = opts || {};
      return __idjEncodeOutput(
        __idjSha256Bytes(__idjDecodeInput(text, opts.input)), opts.output);
    },
    sha512: function () { __idjUnsupported('host.crypto.sha512'); },
    hmac: function (algo, key, text, opts) {
      opts = opts || {};
      var keyBytes = __idjDecodeInput(key, opts.keyInput || opts.input);
      var msgBytes = __idjDecodeInput(text, opts.input);
      return __idjEncodeOutput(
        __idjHmacBytes(String(algo).toLowerCase(), keyBytes, msgBytes),
        opts.output);
    },
    aes: {
      encrypt: function (text, opts) { return __idjAesRun(text, opts, true); },
      decrypt: function (text, opts) { return __idjAesRun(text, opts, false); },
    },
    rsa: function () { __idjUnsupported('host.crypto.rsa'); },
    randomHex: function (bytes) {
      var out = '';
      var n = parseInt(bytes, 10) || 0;
      for (var i = 0; i < n * 2; i++) {
        out += '0123456789abcdef'[Math.floor(Math.random() * 16)];
      }
      return out;
    },
  },
  codec: {
    convert: function (value, opts) {
      opts = opts || {};
      return __idjEncodeOutput(
        __idjDecodeInput(value, opts.from || 'utf8'), opts.to || 'utf8');
    },
    base64Encode: function (text) {
      return __idjBytesToB64(__idjStrToBytes(text));
    },
    base64Decode: function (text) {
      return __idjBytesToStr(__idjB64ToBytes(text));
    },
    hexEncode: function (text) {
      return __idjBytesToHex(__idjStrToBytes(text));
    },
    hexDecode: function (text) {
      return __idjBytesToStr(__idjHexToBytes(text));
    },
    gunzip: function () { __idjUnsupported('host.codec.gunzip'); },
    unpackPacker: function (text) { return __idjUnpackPacker(text); },
  },
  m3u8: {
    parse: function (text, baseUrl) { return __idjM3u8Parse(text, baseUrl); },
  },
  url: {
    resolve: function (base, rel) { return __idjResolveUrl(base, rel); },
    encodeForm: function (obj) { return __idjEncodeForm(obj); },
  },
  log: function () {
    if (__idjNative.log) {
      try {
        __idjNative.log(Array.prototype.map.call(arguments, String).join(' '));
      } catch (e) {}
    }
  },
  error: function () {
    if (__idjNative.log) {
      try {
        __idjNative.log('[error] ' +
          Array.prototype.map.call(arguments, String).join(' '));
      } catch (e) {}
    }
  },
  version: { app: '1.5.2', spec: 'idj1' },
  settings: {},
  has: function (feature) {
    var table = {
      'http': true, 'http.request': true, 'html': true, 'html.parse': true,
      'crypto': true, 'crypto.md5': true, 'crypto.sha1': true,
      'crypto.sha256': true, 'crypto.sha512': false, 'crypto.hmac': true,
      'crypto.aes': true, 'crypto.rsa': false, 'crypto.randomHex': true,
      'codec': true, 'codec.convert': true, 'codec.gunzip': false,
      'codec.unpackPacker': true, 'm3u8': true, 'm3u8.parse': true,
      'url': true, 'url.resolve': true, 'log': true,
      'storage': !!__idjStorageAllowed,
      'image.stripes': false, 'image.aes': false,
    };
    return table[feature] === true;
  },
};

if (__idjStorageAllowed) {
  host.storage = {
    get: function (key) {
      var value = __idjStorage[key];
      return value === undefined ? null : value;
    },
    set: function (key, value) { __idjStorage[key] = value; },
    delete: function (key) { delete __idjStorage[key]; },
    keys: function () { return Object.keys(__idjStorage); },
  };
} else {
  host.storage = {
    get: function () {
      var e = new Error('插件未声明 storage 权限');
      e.code = 'E_PERMISSION';
      throw e;
    },
    set: function () {
      var e = new Error('插件未声明 storage 权限');
      e.code = 'E_PERMISSION';
      throw e;
    },
    delete: function () {
      var e = new Error('插件未声明 storage 权限');
      e.code = 'E_PERMISSION';
      throw e;
    },
    keys: function () {
      var e = new Error('插件未声明 storage 权限');
      e.code = 'E_PERMISSION';
      throw e;
    },
  };
}
''';
// __IDJ_PRELUDE_END__

/// 完整垫片 = 第一段 + 第二段（常量拼接，验证台按标记抽两段合用）。
const String idjHostPrelude = idjHostPreludePart1 + idjHostPreludePart2;


/// 插件运行时：一次调用 = 读 storage → 组装脚本 → QuickJS 评估 →
/// 解析信封 → 回写 storage。每次调用全新运行时（与规格一致）。
class IdjRuntime {
  IdjRuntime({required this.store, IdjEvalFn? evalFn})
    : _evalFn = evalFn ?? _defaultEval,
      _checkBridge = evalFn == null;

  final IdjPluginStore store;
  final IdjEvalFn _evalFn;

  /// 是否在调用前查安卓 QuickJS 桥状态：默认评估器（走桥）要查；
  /// 注入评估器时可用性由注入方负责（单元测试、将来 iOS 的
  /// JavaScriptCore 评估器都走这个入口，不该被安卓桥状态误拦）。
  final bool _checkBridge;

  static Future<dynamic> _defaultEval(String script, int timeoutMs) =>
      JsBridge.evalRaw(script, timeoutMs: timeoutMs);

  /// probe 试加载（装包前）：平台没有 JS 桥时如实失败——iOS 上
  /// 这一步就是「引擎未接通」的明确报错，不假装能装。
  Future<void> probe({
    required String pluginId,
    required String script,
    required Map<String, dynamic> manifest,
  }) async {
    final status = await _bridgeStatus();
    if (!status.available) {
      throw IdjPluginFailure(
        '试加载失败：当前平台暂不支持插件引擎'
        '${status.detail.isEmpty ? '' : '（${status.detail}）'}',
      );
    }
    final parsedManifest = IdjPluginManifest.fromJson(manifest);
    try {
      await _invoke(
        pluginId: pluginId,
        manifest: parsedManifest,
        script: script,
        op: '__probe__',
        args: {
          'id': parsedManifest.id,
          'name': parsedManifest.name,
          'version': parsedManifest.version,
        },
      );
    } on IdjCallException catch (error) {
      // 界面口径：只有驱动自产的中文消息（E_PROBE 缺能力函数，
      // 点名缺哪个）透传给用户；插件自己抛的错与引擎异常多为
      // 英文原文，只进日志，界面给中文人话。
      if (error.code == 'E_PROBE') {
        throw IdjPluginFailure('试加载失败：${error.message}');
      }
      debugPrint('idj probe 失败（$pluginId）：${error.code} ${error.message}');
      throw IdjPluginFailure(
        '试加载失败：插件初始化没能完成，请稍后重试；若反复失败，可能是这个插件与当前版本不兼容',
      );
    }
  }

  /// 一次能力调用。失败抛 [IdjCallException]（带错误码）。
  Future<dynamic> call({
    required String pluginId,
    required IdjPluginManifest manifest,
    required String script,
    required String op,
    Map<String, dynamic> args = const {},
  }) async {
    final status = await _bridgeStatus();
    if (!status.available) {
      throw IdjCallException(
        'E_UNSUPPORTED',
        '当前平台暂不支持插件引擎${status.detail.isEmpty ? '' : '（${status.detail}）'}',
      );
    }
    return _invoke(
      pluginId: pluginId,
      manifest: manifest,
      script: script,
      op: op,
      args: args,
    );
  }

  Future<JsRuntimeStatus> _bridgeStatus() async {
    if (!_checkBridge) {
      return const JsRuntimeStatus(available: true);
    }
    return JsBridge.status();
  }

  Future<dynamic> _invoke({
    required String pluginId,
    required IdjPluginManifest manifest,
    required String script,
    required String op,
    required Map<String, dynamic> args,
  }) async {
    final storage = manifest.storagePermission
        ? await _loadStorage(pluginId)
        : <String, dynamic>{};
    final fullScript = buildIdjDriverScript(
      pluginScript: script,
      manifest: manifest,
      op: op,
      args: args,
      storage: storage,
    );
    // 播放调用放宽到 90 秒（与魔蚁口径一致），其余 30 秒。
    final timeoutMs = op == 'play' ? 90000 : 30000;
    dynamic raw;
    try {
      raw = await _evalFn(fullScript, timeoutMs);
    } catch (error) {
      // 引擎异常（如桥层「JS 执行失败：<原文>」）多为英文原文，只进
      // 日志；带给上层的只剩通用文案，具体到哪一步失败由内容客户
      // 端按 op 补。
      debugPrint('idj 调用失败（$pluginId/$op）：$error');
      throw IdjCallException('E_PLUGIN', idjGenericCallFailureMessage);
    }
    final envelope = _parseEnvelope(raw);
    if (envelope == null) {
      throw IdjCallException('E_PLUGIN', '插件没有返回结果');
    }
    if (envelope['ok'] != true) {
      final code = (envelope['code'] as Object?)?.toString() ?? 'E_PLUGIN';
      final message =
          (envelope['message'] as Object?)?.toString() ?? '插件调用失败';
      // 驱动自产码的 message 是写死的中文，照用；插件自抛的
      // message 不可控（多为 JS 引擎英文原文），换通用文案、
      // 原文进日志。错误码原样保留，看门狗计数口径不变。
      if (_idjDriverErrorCodes.contains(code) ||
          message == '入口脚本没有 export default') {
        throw IdjCallException(code, message);
      }
      debugPrint('idj 插件报错（$pluginId/$op）：$code $message');
      throw IdjCallException(code, idjGenericCallFailureMessage);
    }
    if (manifest.storagePermission && envelope['storage'] is Map) {
      await _saveStorage(
        pluginId,
        Map<String, dynamic>.from(envelope['storage'] as Map),
      );
    }
    return envelope['result'];
  }

  /// 信封解析：桥的返回值可能是 JSON 字符串，也可能已解码成 Map。
  Map<String, dynamic>? _parseEnvelope(dynamic raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _loadStorage(String pluginId) async {
    try {
      final dir = await store.runtimeDir(pluginId);
      final file = File(p.join(dir.path, 'storage.json'));
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // storage 读坏不拦调用，按空存储继续。
    }
    return {};
  }

  Future<void> _saveStorage(
    String pluginId,
    Map<String, dynamic> storage,
  ) async {
    try {
      final encoded = jsonEncode(storage);
      // 规格上限 1MB：超了不落盘（插件侧无感知，不拦播放）。
      if (encoded.length > 1024 * 1024) return;
      final dir = await store.runtimeDir(pluginId);
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(
        p.join(dir.path, 'storage.json'),
      ).writeAsString(encoded, flush: true);
    } catch (_) {
      // 落盘失败不拦调用结果。
    }
  }
}

// ---------- 契约转换（与魔蚁 idj_contract 同口径，输出本树模型） ----------

String _idjText(Object? value) => value?.toString() ?? '';

String _idjTruncate(String value, int maxRunes) {
  final runes = value.runes;
  if (runes.length <= maxRunes) return value;
  return String.fromCharCodes(runes.take(maxRunes));
}

Map<String, dynamic> _idjMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

List<dynamic> _idjList(Object? value) => value is List ? value : const [];

/// home 结果 → 分类（前置「全部」id=''）+ 首页条目。
({List<DramaSiteCategory> categories, List<DramaSiteItem> items})
parseIdjHome(Object? raw) {
  final json = _idjMap(raw);
  final categories = <DramaSiteCategory>[
    const DramaSiteCategory('', '全部'),
    for (final row in _idjList(json['categories']))
      if (_idjMap(row)['id'] != null)
        DramaSiteCategory(
          _idjText(_idjMap(row)['id']),
          _idjText(_idjMap(row)['title']).isEmpty
              ? _idjText(_idjMap(row)['id'])
              : _idjText(_idjMap(row)['title']),
        ),
  ];
  return (categories: categories, items: parseIdjItems(json['items']));
}

/// 条目列表 → 站点条目（标题截 200、单页上限 500 条）。
List<DramaSiteItem> parseIdjItems(Object? raw) {
  final items = <DramaSiteItem>[];
  for (final row in _idjList(raw)) {
    final item = _idjMap(row);
    final id = _idjText(item['id']);
    final title = _idjText(item['title']);
    if (id.isEmpty || title.isEmpty) continue;
    items.add(
      DramaSiteItem(
        id: id,
        title: _idjTruncate(title, 200),
        cover: _idjText(item['poster']).isNotEmpty
            ? _idjText(item['poster'])
            : _idjText(item['cover']),
        remark: _idjText(item['subtitle']).isNotEmpty
            ? _idjText(item['subtitle'])
            : _idjText(item['remark']),
      ),
    );
    if (items.length >= 500) break;
  }
  return items;
}

/// detail 结果 → 详情：线路/分集转成宿主选集，
/// episode.videoId 约定 `线路名\u0001集id`（与 py/js 客户端同约定）。
DramaSiteDetail parseIdjDetail(Object? raw, String requestedId) {
  final json = _idjMap(raw);
  final id = _idjText(json['id']).isEmpty ? requestedId : _idjText(json['id']);
  final episodes = <DramaSiteEpisode>[];
  for (final lineRow in _idjList(json['lines'])) {
    final line = _idjMap(lineRow);
    final flag = _idjText(line['name']);
    for (final episodeRow in _idjList(line['episodes'])) {
      final episode = _idjMap(episodeRow);
      final episodeId = _idjText(episode['id']);
      if (episodeId.isEmpty) continue;
      episodes.add(
        DramaSiteEpisode(
          videoId: '$flag\u0001$episodeId',
          title: _idjText(episode['title']).isEmpty
              ? episodeId
              : _idjText(episode['title']),
          seriesId: id,
        ),
      );
      if (episodes.length >= 5000) break;
    }
    if (episodes.length >= 5000) break;
  }
  final extra = <String, String>{};
  for (final key in const [
    'year',
    'region',
    'language',
    'director',
    'actors',
    'status',
  ]) {
    final value = _idjText(json[key]);
    if (value.isNotEmpty) extra[key] = value;
  }
  return DramaSiteDetail(
    id: id,
    title: _idjTruncate(_idjText(json['title']), 200),
    cover: _idjText(json['poster']).isNotEmpty
        ? _idjText(json['poster'])
        : _idjText(json['cover']),
    synopsis: _idjTruncate(
      _idjText(json['description']).isNotEmpty
          ? _idjText(json['description'])
          : _idjText(json['synopsis']),
      4000,
    ),
    extra: extra,
    stills: parseDetailStills(json['stills']),
    episodes: episodes,
  );
}

/// play 结果 → 播放源：只取第一条合规流（https、无 userinfo、
/// 端口不写或 443、主机非 IP 字面量），headers 透传（与魔蚁同口径）。
/// 带 DRM 的结果如实报错——本树 [DramaPlaySource] 没有 DRM 字段，
/// 当前播放链不支持，不硬塞、不假装能播。
DramaPlaySource parseIdjPlay(Object? raw) {
  final json = _idjMap(raw);
  if (json['drm'] != null) {
    throw StateError('该插件返回了 DRM 加密播放地址，当前播放链暂不支持');
  }
  final streams = _idjList(json['streams']);
  var checked = 0;
  for (final row in streams) {
    if (checked >= 12) break;
    checked++;
    final stream = _idjMap(row);
    if (stream['drm'] != null) {
      throw StateError('该插件返回了 DRM 加密播放地址，当前播放链暂不支持');
    }
    final url = _idjText(stream['url']);
    if (!_idjIsPlayableStreamUrl(url)) continue;
    final headers = <String, String>{};
    final rawHeaders = stream['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }
    return DramaPlaySource(url: url, headers: headers);
  }
  throw StateError('插件没有返回可播放地址');
}

bool _idjIsPlayableStreamUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https') return false;
  if (uri.userInfo.isNotEmpty) return false;
  if (uri.hasPort && uri.port != 443) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return false;
  return true;
}

// ---------- 内容客户端 ----------

/// 插件站的内容客户端：分类/列表/详情/搜索/取流全走运行时。
/// 每次操作现读包文件（包是唯一事实来源，更新后立即生效）。
/// 调用成败接看门狗：成功清零、非瞬时失败计数（3 次自动停用）。
class IdjSiteContentClient extends DramaSiteContentClient {
  IdjSiteContentClient({
    required this.pluginId,
    required this.store,
    IdjRuntime? runtime,
  }) : _runtime = runtime ?? IdjRuntime(store: store);

  final String pluginId;
  final IdjPluginStore store;
  final IdjRuntime _runtime;

  Future<({IdjPluginManifest manifest, String script})> _bundle() async {
    final bundle = await store.readBundle(pluginId);
    if (bundle == null) {
      throw StateError('插件包文件已损坏，请在插件区重新安装');
    }
    return (manifest: bundle.manifest, script: bundle.script);
  }

  Future<dynamic> _call(String op, Map<String, dynamic> args) async {
    final bundle = await _bundle();
    try {
      final result = await _runtime.call(
        pluginId: pluginId,
        manifest: bundle.manifest,
        script: bundle.script,
        op: op,
        args: args,
      );
      _watchdog(store.recordSuccess(pluginId));
      return result;
    } on IdjCallException catch (error) {
      _watchdog(store.recordFailure(pluginId, code: error.code));
      // 通用失败（插件自抛/引擎异常，原文已在运行时层进日志）按 op
      // 换成「哪一步失败＋怎么办」；驱动自产的具体中文照用。
      if (error.message == idjGenericCallFailureMessage) {
        throw StateError(_opFailureText(op));
      }
      throw StateError(error.message);
    }
  }

  /// 通用调用失败按 op 的用户文案：说清哪一步失败、怎么办。
  static String _opFailureText(String op) {
    switch (op) {
      case 'home':
        return '首页加载失败，请稍后重试';
      case 'category':
        return '分类加载失败，请稍后重试';
      case 'detail':
        return '详情加载失败，请稍后重试';
      case 'search':
        return '搜索失败，请稍后重试';
      case 'play':
        return '播放地址获取失败，换个线路或稍后再试';
      default:
        return '加载失败，请稍后重试';
    }
  }

  @override
  Future<List<DramaSiteCategory>> categories() async {
    final bundle = await _bundle();
    if (!bundle.manifest.capabilities.contains('home')) {
      return const [DramaSiteCategory('', '全部')];
    }
    final home = parseIdjHome(await _call('home', const {}));
    return home.categories;
  }

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    final bundle = await _bundle();
    final List<DramaSiteItem> items;
    if (categoryId.isEmpty || !bundle.manifest.capabilities.contains('category')) {
      final home = parseIdjHome(await _call('home', const {}));
      items = home.items;
      return DramaSiteCatalogPage(items: items, hasMore: false);
    }
    final raw = await _call('category', {'id': categoryId, 'page': page});
    items = parseIdjItems(_idjMap(raw)['items']);
    final declared = _idjMap(raw)['hasMore'];
    return DramaSiteCatalogPage(
      items: items,
      hasMore: declared is bool ? declared : items.isNotEmpty,
    );
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final raw = await _call('detail', {'id': seriesId});
    return parseIdjDetail(raw, seriesId);
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final bundle = await _bundle();
    if (!bundle.manifest.capabilities.contains('search')) return const [];
    final raw = await _call('search', {'keyword': query, 'page': 1});
    return parseIdjItems(_idjMap(raw)['items']);
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final parts = episode.videoId.split('\u0001');
    if (parts.length < 2) {
      throw StateError('选集缺少播放线路信息');
    }
    final flag = parts[0];
    final episodeId = parts.sublist(1).join('\u0001');
    final raw = await _call('play', {
      'id': episodeId,
      'episodeId': episodeId,
      'line': flag,
      'flag': flag,
    });
    return parseIdjPlay(raw);
  }
}

/// 看门狗记账是旁路动作：不等待、不让它的失败影响调用结果。
void _watchdog(Future<void> future) {
  future.then((_) {}, onError: (_) {});
}
