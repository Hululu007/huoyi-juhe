import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'actress_library_db.dart';

/// 合并演员库页向宿主发起的一次播放请求（fm.play / fm.vodInline /
/// fm.pan.play 归一后的形态）：标题、封面与一到多条已解出的直链。
/// 集与集之间只差地址与线路名，宿主播放器按集表推页。
class ActressLibPlayRequest {
  const ActressLibPlayRequest({
    required this.title,
    required this.pic,
    required this.wallPic,
    required this.episodes,
    this.headers = const {},
    this.vodId = '',
  });

  final String title;
  final String pic;
  final String wallPic;
  final List<({String name, String url})> episodes;
  final Map<String, String> headers;
  final String vodId;
}

/// 桥的一次 HTTP 执行入参（fm.req 归一后）。
class ActressLibHttpRequest {
  const ActressLibHttpRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.body,
    this.timeout = const Duration(seconds: 25),
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final String? body;
  final Duration timeout;
}

/// 桥的一次 HTTP 执行结果。
class ActressLibHttpResult {
  const ActressLibHttpResult({
    required this.status,
    required this.headers,
    required this.body,
    required this.finalUrl,
  });

  final int status;
  final Map<String, String> headers;
  final String body;
  final String finalUrl;
}

typedef ActressLibHttpExecutor =
    Future<ActressLibHttpResult> Function(ActressLibHttpRequest request);
typedef ActressLibPlayHandler =
    Future<void> Function(ActressLibPlayRequest request);
typedef ActressLibLibraryQuery =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

/// 桥方法执行失败（参数不合法、嗅探无果等）：宿主页把它转成
/// {ok:false, error} 回给网页，网页据此走自己的兜底分支。
class ActressLibBridgeException implements Exception {
  ActressLibBridgeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 合并演员库页的宿主桥（修仙版自家形态）：网页里的 window.fm
/// 由 [kActressLibraryShim] 定义，调用经 JavaScriptChannel
/// `XiuxianActressHost` 以 {id, method, params} JSON 发到这里，
/// 本类按 method 分发，结果由宿主页回注网页 resolve。
///
/// 方法面只做页面真用到的：req（真 HTTP，带会话级 Cookie 罐）、
/// cache（SharedPreferences 命名空间键值）、play / vodInline
/// （归一成 [ActressLibPlayRequest] 交宿主播放器）、panPlay
/// （嗅探兜底：拉页面正文提首个流地址再播，提不到抛错让网页
/// 自己落回 fm.play）、libraryQuery（女优库数据库兜底，页面里
/// 的 fm.nvku 映射到这个自家方法名，实现见
/// [ActressLibraryDbFallback]）。
///
/// fm.res 在垫片里同步直通（本宿主没有回环网关，封面按原地址
/// 由 WebView 直拉；需要 Referer 的个别封面可能加载失败，属
/// 已知降级，见同步批报告）。
class ActressLibraryBridge {
  ActressLibraryBridge({
    ActressLibHttpExecutor? httpExecutor,
    required this.playHandler,
    ActressLibLibraryQuery? libraryQuery,
    Future<SharedPreferences> Function()? preferences,
  }) : _httpExecutor = httpExecutor ?? _defaultHttpExecutor,
       _libraryQuery =
           libraryQuery ?? ActressLibraryDbFallback.shared.handle,
       _preferences = preferences ?? SharedPreferences.getInstance;

  final ActressLibHttpExecutor _httpExecutor;

  /// 播放请求的宿主落点（宿主页据此推播放器）；公开是为了测试
  /// 可直接断言收到的请求，桥内不改写它。
  final ActressLibPlayHandler playHandler;
  final ActressLibLibraryQuery _libraryQuery;
  final Future<SharedPreferences> Function() _preferences;

  /// 会话级 Cookie 罐：host → name → value。页面 req 带
  /// credentials:'include'，靠它在多次请求间续上站方会话；
  /// 只存内存，页面关掉即清。
  final Map<String, Map<String, String>> _cookies = {};

  static const String _cachePrefix = 'actress_library_web_cache';

  /// 分发入口：回可 JSON 化的结果值；失败抛
  /// [ActressLibBridgeException]（或其余异常由宿主页兜底转错）。
  Future<Object?> dispatch(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'req':
        return _req(params);
      case 'cache':
        return _cache(params);
      case 'play':
        await _play(params);
        return true;
      case 'vodInline':
        await _vodInline(params);
        return true;
      case 'panPlay':
        await _panPlay(params);
        return true;
      case 'libraryQuery':
        return _libraryQuery(params);
      default:
        throw ActressLibBridgeException('宿主不支持的方法：$method');
    }
  }

  // ---------- req ----------

  Future<Map<String, dynamic>> _req(Map<String, dynamic> params) async {
    final rawUrl = (params['url'] ?? '').toString();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      throw ActressLibBridgeException('req 缺少合法 url');
    }
    final method = (params['method'] ?? 'get').toString().toLowerCase();
    final headers = <String, String>{};
    final rawHeaders = params['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (value != null) headers[key.toString()] = value.toString();
      });
    }
    String? body;
    if (method == 'post') {
      if (params['data'] != null) {
        body = params['data'].toString();
        final postType = (params['postType'] ?? 'form').toString();
        final hasContentType = headers.keys.any(
          (k) => k.toLowerCase() == 'content-type',
        );
        if (!hasContentType) {
          headers['Content-Type'] = postType == 'json'
              ? 'application/json; charset=utf-8'
              : 'application/x-www-form-urlencoded; charset=utf-8';
        }
      } else if (params['body'] != null) {
        body = params['body'].toString();
      }
    }
    final timeoutSec = int.tryParse('${params['timeout'] ?? 25}') ?? 25;
    try {
      final result = await _send(
        ActressLibHttpRequest(
          url: uri,
          method: method,
          headers: headers,
          body: body,
          timeout: Duration(seconds: timeoutSec.clamp(1, 90)),
        ),
      );
      return {
        'ok': result.status >= 200 && result.status < 400,
        'status': result.status,
        'headers': result.headers,
        'body': result.body,
        'url': result.finalUrl,
      };
    } catch (error) {
      // 网络层失败回页面约定的 {ok:false,...} 形态（页面据此抛
      // HTTP 0 并走它自己的重试/兜底），不走桥异常通道。
      return {
        'ok': false,
        'status': 0,
        'headers': const <String, String>{},
        'body': '',
        'url': rawUrl,
        'error': error.toString(),
      };
    }
  }

  /// 发一次请求并维护 Cookie 罐（发送前并入、响应后回收）。
  Future<ActressLibHttpResult> _send(ActressLibHttpRequest request) async {
    final headers = {...request.headers};
    final host = request.url.host;
    final jar = _cookies[host];
    final hasCookie = headers.keys.any((k) => k.toLowerCase() == 'cookie');
    if (!hasCookie && jar != null && jar.isNotEmpty) {
      headers['Cookie'] = jar.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    final result = await _httpExecutor(
      ActressLibHttpRequest(
        url: request.url,
        method: request.method,
        headers: headers,
        body: request.body,
        timeout: request.timeout,
      ),
    );
    final setCookie = result.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      final jar = _cookies.putIfAbsent(host, () => {});
      for (final part in _splitSetCookie(setCookie)) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        final name = part.substring(0, eq).trim();
        final rest = part.substring(eq + 1);
        final semi = rest.indexOf(';');
        final value = (semi >= 0 ? rest.substring(0, semi) : rest).trim();
        if (name.isNotEmpty) jar[name] = value;
      }
    }
    return result;
  }

  /// set-cookie 合并头拆条：逗号后跟 token= 才算新条（日期里的
  /// 逗号不拆）。
  static List<String> _splitSetCookie(String header) {
    final parts = <String>[];
    var start = 0;
    for (var i = 0; i < header.length; i++) {
      if (header[i] == ',' &&
          RegExp(r'^\s*[^=;\s]+=').hasMatch(header.substring(i + 1))) {
        parts.add(header.substring(start, i));
        start = i + 1;
      }
    }
    parts.add(header.substring(start));
    return parts;
  }

  static Future<ActressLibHttpResult> _defaultHttpExecutor(
    ActressLibHttpRequest request,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request(request.method.toUpperCase(), request.url);
      req.headers.addAll(request.headers);
      if (request.body != null) req.body = request.body!;
      req.followRedirects = true;
      req.maxRedirects = 5;
      final streamed = await client.send(req).timeout(request.timeout);
      final bytes = await streamed.stream.toBytes().timeout(
        request.timeout,
      );
      return ActressLibHttpResult(
        status: streamed.statusCode,
        headers: streamed.headers,
        body: utf8.decode(bytes, allowMalformed: true),
        finalUrl: streamed.request?.url.toString() ?? request.url.toString(),
      );
    } finally {
      client.close();
    }
  }

  // ---------- cache ----------

  Future<Object?> _cache(Map<String, dynamic> params) async {
    final op = (params['op'] ?? 'get').toString();
    final key = (params['key'] ?? '').toString();
    if (key.isEmpty) throw ActressLibBridgeException('cache 缺少 key');
    final ns = (params['ns'] ?? '').toString();
    final storeKey = '$_cachePrefix:$ns:$key';
    final prefs = await _preferences();
    switch (op) {
      case 'get':
        return prefs.getString(storeKey);
      case 'set':
        final value = params['value'];
        await prefs.setString(storeKey, value?.toString() ?? '');
        return true;
      case 'remove':
      case 'del':
        await prefs.remove(storeKey);
        return true;
      default:
        throw ActressLibBridgeException('cache 未知 op：$op');
    }
  }

  // ---------- play ----------

  Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (value != null) out[key.toString()] = value.toString();
    });
    return out;
  }

  Future<void> _play(Map<String, dynamic> params) async {
    final url = (params['url'] ?? '').toString();
    if (url.isEmpty) throw ActressLibBridgeException('play 缺少 url');
    await playHandler(
      ActressLibPlayRequest(
        title: (params['title'] ?? '').toString(),
        pic: (params['pic'] ?? '').toString(),
        wallPic: (params['wallPic'] ?? '').toString(),
        headers: _stringMap(params['headers']),
        episodes: [(name: '正片', url: url)],
      ),
    );
  }

  Future<void> _vodInline(Map<String, dynamic> params) async {
    final rawEpisodes = params['episodes'];
    final episodes = <({String name, String url})>[];
    if (rawEpisodes is List) {
      for (final raw in rawEpisodes) {
        if (raw is! Map) continue;
        final url = (raw['url'] ?? '').toString();
        if (url.isEmpty) continue;
        episodes.add((
          name: (raw['name'] ?? '正片').toString(),
          url: url,
        ));
      }
    }
    if (episodes.isEmpty) {
      throw ActressLibBridgeException('vodInline 没有可播集');
    }
    await playHandler(
      ActressLibPlayRequest(
        title: (params['vod_name'] ?? '').toString(),
        pic: (params['vod_pic'] ?? '').toString(),
        wallPic: (params['wallPic'] ?? '').toString(),
        headers: _stringMap(params['headers']),
        vodId: (params['vod_id'] ?? '').toString(),
        episodes: episodes,
      ),
    );
  }

  /// 嗅探兜底：拉目标页正文，正则提首个 m3u8/mp4 直链再播；
  /// 提不到抛错——网页收到失败会自己落回 fm.play(原页地址)。
  Future<void> _panPlay(Map<String, dynamic> params) async {
    final url = (params['url'] ?? '').toString();
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw ActressLibBridgeException('panPlay 缺少合法 url');
    }
    final result = await _send(
      ActressLibHttpRequest(
        url: uri,
        method: 'get',
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/122.0.0.0 Safari/537.36',
        },
        timeout: const Duration(seconds: 20),
      ),
    );
    final stream = _extractStreamUrl(result.body);
    if (stream == null) {
      throw ActressLibBridgeException('嗅探未找到播放地址');
    }
    await playHandler(
      ActressLibPlayRequest(
        title: (params['title'] ?? '').toString(),
        pic: (params['pic'] ?? '').toString(),
        wallPic: (params['wallPic'] ?? '').toString(),
        episodes: [(name: '正片', url: stream)],
      ),
    );
  }

  static final RegExp _streamPattern = RegExp(
    r'''https?://[^\s"'<>]+?\.(?:m3u8|mp4)(?:\?[^\s"'<>]*)?''',
    caseSensitive: false,
  );

  static String? _extractStreamUrl(String body) {
    final match = _streamPattern.firstMatch(body);
    if (match == null) return null;
    return match.group(0)?.replaceAll(r'\/', '/');
  }
}

/// 注入网页的 fm 垫片（修仙版自家实现）：只定义页面真用到的
/// 方法面（req / res / play / vodInline / cache / pan.play /
/// nvku），调用约定与页面一致——位置参数与对象形态双收、归一
/// 成对象后经 `XiuxianActressHost` 通道发给 [ActressLibraryBridge]；
/// fm.res 同步直通原地址（本宿主无回环网关）；装好后派发
/// `fmsdk` 事件并置 window.fm，页面 isNative() 据此判原生环境。
/// 重复注入由 __xiuxianActressHostInstalled 标记挡住。
const String kActressLibraryShim = r'''
(function () {
  if (window.__xiuxianActressHostInstalled) return;
  window.__xiuxianActressHostInstalled = true;
  var pending = {};
  var seq = 0;
  function post(method, params) {
    return new Promise(function (resolve, reject) {
      var id = 'xh' + (++seq) + '_' + Date.now() + '_' + Math.floor(Math.random() * 100000);
      pending[id] = { resolve: resolve, reject: reject };
      try {
        XiuxianActressHost.postMessage(JSON.stringify({ id: id, method: method, params: params || {} }));
      } catch (e) {
        delete pending[id];
        reject(e);
      }
    });
  }
  window.__xiuxianActressResolve = function (id, text) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    var data;
    try { data = JSON.parse(text); } catch (e) { entry.reject(new Error('bad bridge response')); return; }
    if (data && data.ok) {
      entry.resolve(data.result === undefined ? null : data.result);
    } else {
      entry.reject(new Error((data && data.error) || 'bridge error'));
    }
  };
  function isObj(v) { return v !== null && typeof v === 'object' && !Array.isArray(v); }
  function assign(target, source) {
    if (!isObj(source)) return target;
    var keys = Object.keys(source);
    for (var i = 0; i < keys.length; i++) target[keys[i]] = source[keys[i]];
    return target;
  }
  var fm = {};
  fm.req = function (urlOrOptions, options) {
    if (typeof urlOrOptions === 'string') return post('req', assign({ url: urlOrOptions }, options));
    return post('req', urlOrOptions || {});
  };
  fm.res = function (urlOrOptions) {
    if (typeof urlOrOptions === 'string') return urlOrOptions;
    if (isObj(urlOrOptions) && urlOrOptions.url) return String(urlOrOptions.url);
    return '';
  };
  fm.play = function (urlOrPayload, titleOrOptions, options) {
    if (typeof urlOrPayload === 'string') {
      var params = { url: urlOrPayload };
      if (typeof titleOrOptions === 'string') { params.title = titleOrOptions; assign(params, options); }
      else if (isObj(titleOrOptions)) assign(params, titleOrOptions);
      return post('play', params);
    }
    return post('play', urlOrPayload || {});
  };
  fm.vodInline = function (payload) { return post('vodInline', payload || {}); };
  fm.cache = {
    get: function (key, ns) { return post('cache', { op: 'get', key: String(key), ns: String(ns || '') }); },
    set: function (key, value, ns) { return post('cache', { op: 'set', key: String(key), value: value, ns: String(ns || '') }); },
    remove: function (key, ns) { return post('cache', { op: 'remove', key: String(key), ns: String(ns || '') }); }
  };
  fm.pan = {
    play: function (payload) { return post('panPlay', payload || {}); }
  };
  fm.nvku = function (payload) { return post('libraryQuery', payload || {}); };
  window.fm = fm;
  try { document.dispatchEvent(new CustomEvent('fmsdk', { detail: { version: 1, host: 'xiuxian' } })); } catch (e) {}
})();
''';
