/// 红果账号云端同步服务：账号命名空间存储、HTTP 传输与登录状态机。
///
/// 分层说明：
/// - [HongguoAccountCloudStore]：账号数据专用 Hive 箱，与本机历史
///   （LibraryStore `history` 箱）与本机书架（ShelfStore `shelf` 箱）
///   完全分开。键按 `<账号 id>:<剧 id>` 命名空间，换号不串号；
///   退出登录只清本账号的箱，本机记录原样保留。
/// - [HongguoAccountHttpTransport]：官方登录/账号接口的请求形状与
///   返回解析。**签名已接线**：默认用树里已有的红果签名能力
///   （hongguo_sign.dart，取流同款）给请求补签名头，设备表用取流
///   同款取值；[HongguoAccountRequestSigner] 仍是注入点，可换实现。
///   本文件不含任何设备指纹、签名常量与密钥材料。短信验证码与扫码
///   流程仍须在用户手机上实测验证。
/// - [HongguoAccountService]：登录状态机 + 同步 + 退出，供页面与
///   播放器组调用。播放器续播只认 [HongguoAccountService.resumeForSeries] /
///   [HongguoAccountService.resumeForEpisode] 两个方法。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import 'encrypted_hive.dart';
import 'hongguo_account.dart';
import 'hongguo_sign.dart';
import 'secure_key_provider.dart';

// ── 账号命名空间存储 ────────────────────────────────────────────────

/// 账号数据专用存储。Hive 箱名与本机箱不同，键带账号 id 前缀。
class HongguoAccountCloudStore {
  HongguoAccountCloudStore() : _memory = false;

  /// 测试/无平台通道时用的内存后端，与 Hive 后端同一套键规则。
  HongguoAccountCloudStore.memory() : _memory = true;

  final bool _memory;
  Box<dynamic>? _favBox;
  Box<dynamic>? _histBox;
  Box<dynamic>? _resBox;
  final Map<String, Map<String, dynamic>> _memFav = {};
  final Map<String, Map<String, dynamic>> _memHist = {};
  final Map<String, Map<String, dynamic>> _memRes = {};

  static const favoritesBoxName = 'hongguo_account_favorites';
  static const historyBoxName = 'hongguo_account_history';
  static const reservationsBoxName = 'hongguo_account_reservations';

  static String keyFor(String userId, String seriesId) => '$userId:$seriesId';

  bool get isReady => _memory || (_favBox?.isOpen == true);

  Future<void> init() async {
    if (_memory || isReady) return;
    _favBox = await EncryptedHive.openBox(Hive, favoritesBoxName);
    _histBox = await EncryptedHive.openBox(Hive, historyBoxName);
    _resBox = await EncryptedHive.openBox(Hive, reservationsBoxName);
  }

  Map<String, dynamic>? _get(
    Box<dynamic>? box,
    Map<String, Map<String, dynamic>> mem,
    String key,
  ) {
    if (_memory) return mem[key];
    final raw = box?.get(key);
    return raw is Map
        ? {for (final e in raw.entries) '${e.key}': e.value}
        : null;
  }

  Future<void> _put(
    Box<dynamic>? box,
    Map<String, Map<String, dynamic>> mem,
    String key,
    Map<String, dynamic> value,
  ) async {
    if (_memory) {
      mem[key] = value;
      return;
    }
    await box?.put(key, value);
  }

  Future<void> _deleteKeys(
    Box<dynamic>? box,
    Map<String, Map<String, dynamic>> mem,
    String userId,
  ) async {
    final prefix = '$userId:';
    if (_memory) {
      mem.removeWhere((key, _) => key.startsWith(prefix));
      return;
    }
    final doomed = [
      for (final key in box?.keys ?? const [])
        if (key.toString().startsWith(prefix)) key,
    ];
    await box?.deleteAll(doomed);
  }

  List<T> _listFor<T>(
    Box<dynamic>? box,
    Map<String, Map<String, dynamic>> mem,
    String userId,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final prefix = '$userId:';
    final rows = <Map<String, dynamic>>[];
    if (_memory) {
      for (final entry in mem.entries) {
        if (entry.key.startsWith(prefix)) rows.add(entry.value);
      }
    } else {
      for (final key in box?.keys ?? const []) {
        if (!key.toString().startsWith(prefix)) continue;
        final raw = box?.get(key);
        if (raw is Map) {
          rows.add({for (final e in raw.entries) '${e.key}': e.value});
        }
      }
    }
    return rows.map(fromJson).toList();
  }

  // 收藏：按收藏时间倒序。
  List<HongguoCloudFavorite> favorites(String userId) {
    final rows = _listFor(
      _favBox,
      _memFav,
      userId,
      HongguoCloudFavorite.fromJson,
    );
    rows.sort((a, b) => b.collectedAtMs.compareTo(a.collectedAtMs));
    return rows;
  }

  Future<void> putFavorites(
    String userId,
    List<HongguoCloudFavorite> rows,
  ) async {
    await _deleteKeys(_favBox, _memFav, userId);
    for (final row in rows) {
      await _put(
        _favBox,
        _memFav,
        keyFor(userId, row.seriesId),
        row.toJson(),
      );
    }
  }

  // 云端历史：按更新时间倒序。
  List<HongguoCloudProgress> history(String userId) {
    final rows = _listFor(
      _histBox,
      _memHist,
      userId,
      HongguoCloudProgress.fromJson,
    );
    rows.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return rows;
  }

  Future<void> putHistory(
    String userId,
    List<HongguoCloudProgress> rows,
  ) async {
    await _deleteKeys(_histBox, _memHist, userId);
    for (final row in rows) {
      await _put(
        _histBox,
        _memHist,
        keyFor(userId, row.seriesId),
        row.toJson(),
      );
    }
  }

  Future<void> upsertProgress(
    String userId,
    HongguoCloudProgress row,
  ) async {
    await _put(
      _histBox,
      _memHist,
      keyFor(userId, row.seriesId),
      row.toJson(),
    );
  }

  HongguoCloudProgress? progressFor(String userId, String seriesId) =>
      _get(_histBox, _memHist, keyFor(userId, seriesId)) == null
      ? null
      : HongguoCloudProgress.fromJson(
          _get(_histBox, _memHist, keyFor(userId, seriesId))!,
        );

  // 预约：已上线/待上线分开取。
  List<HongguoCloudReservation> reservations(String userId, bool online) {
    final rows = _listFor(
      _resBox,
      _memRes,
      userId,
      HongguoCloudReservation.fromJson,
    );
    final kept = rows.where((row) => row.online == online).toList();
    kept.sort((a, b) => b.publishAtMs.compareTo(a.publishAtMs));
    return kept;
  }

  Future<void> putReservations(
    String userId,
    bool online,
    List<HongguoCloudReservation> rows,
  ) async {
    final prefix = '$userId:';
    if (_memory) {
      _memRes.removeWhere(
        (key, value) =>
            key.startsWith(prefix) && value['online'] == online,
      );
    } else {
      final doomed = <dynamic>[];
      for (final key in _resBox?.keys ?? const []) {
        if (!key.toString().startsWith(prefix)) continue;
        final raw = _resBox?.get(key);
        if (raw is Map && raw['online'] == online) doomed.add(key);
      }
      await _resBox?.deleteAll(doomed);
    }
    for (final row in rows) {
      await _put(
        _resBox,
        _memRes,
        keyFor(userId, row.seriesId),
        row.toJson(),
      );
    }
  }

  /// 只清本账号的三个箱。登出后本机历史/书架不受影响。
  Future<void> clearAccount(String userId) async {
    await _deleteKeys(_favBox, _memFav, userId);
    await _deleteKeys(_histBox, _memHist, userId);
    await _deleteKeys(_resBox, _memRes, userId);
  }
}

// ── HTTP 传输 ───────────────────────────────────────────────────────

/// 请求签名注入点：由调用方把树里已有的红果签名能力接进来，
/// 返回补齐签名后的请求头。默认实现是 [_hongguoAccountSigner]
/// （hongguo_sign.dart，取流同款），不传即用默认；传了就覆盖。
typedef HongguoAccountRequestSigner =
    Future<Map<String, String>> Function({
      required Uri url,
      required Map<String, String> params,
      List<int>? body,
    });

/// 账号请求默认签名：用树里已有的红果签名栈（hongguo_sign.dart，
/// 取流同款）给请求补签名头；外加取流同款的两个静态头。
/// query 已在 URL 里，params 不再重复使用。
Future<Map<String, String>> _hongguoAccountSigner({
  required Uri url,
  required Map<String, String> params,
  List<int>? body,
}) async {
  final headers = hongguoPlayerHeaders(
    url: url.toString(),
    body: body,
    now: DateTime.now(),
    rawQuery: url.query,
  );
  headers['Sdk-Version'] = '2';
  headers['X-XS-From-Web'] = '0';
  return headers;
}

/// 官方登录/账号接口的请求形状与返回解析。
///
/// 端点路径与返回字段名取自对照仓库的流程结构；本文件不含设备
/// 指纹、签名常量与密钥材料，也不保存验证码与任何明文凭据。
/// 签名默认已接线（[_hongguoAccountSigner]，hongguo_sign 栈）；
/// 错误会原样抛给页面显示，不得谎称已通，错误码 7 另见 [_describe]。
class HongguoAccountHttpTransport implements HongguoAccountTransport {
  HongguoAccountHttpTransport({http.Client? client, HongguoAccountRequestSigner? signer})
    : _client = client ?? http.Client(),
      _signer = signer ?? _hongguoAccountSigner;

  static const _webBase = 'https://hongguoduanju.com';
  static const _passportBase = 'https://security.snssdk.com';
  static const _apiBase = 'https://api5-normal-sinfonlinea.fqnovel.com';

  /// passport 请求的设备表：取流同款取值（hgtv_content 的 _appQuery），
  /// 不含 device_id/iid——对照仓库实测，passport 的 query 里带
  /// device_id 会被判 2046；设备靠签名识别，不靠 query。
  /// 取值是树里已有的那套，不是从对照仓库新拷的常量。
  /// 版本已对齐 7.4.3.32：签名栈（hongguo_sign.dart 字段 7）与取流
  /// 路（hgtv_content._appQuery、Rust params_74332）都是 74332，
  /// 这里再留 73532 会让签名与 query 各说一个版本。
  static const _passportDeviceParams = <String, String>{
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '74332',
    'version_name': '7.4.3.32',
    'manifest_version_code': '74332',
    'update_version_code': '74332',
    'channel': 'update_64',
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'resolution': '1280*2772',
    'dpi': '520',
    'ac': 'wifi',
  };

  /// passport 请求参数：设备表 + 本次请求参数 + 现取的 _rticket。
  /// 请求参数后合并，同名以本次请求为准。
  static Map<String, String> _passportParams(Map<String, String> params) {
    return {
      ..._passportDeviceParams,
      ...params,
      '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
    };
  }

  static const _webUa =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36';

  final http.Client _client;
  final HongguoAccountRequestSigner? _signer;

  bool get signingWired => _signer != null;

  // 本次登录尝试的设备身份：本机随机生成、仅本次尝试有效，
  // 不复用任何固定设备指纹；签名接线时再与设备表对齐。
  final String _deviceId = _randomDigits(19);
  final String _installId = _randomDigits(19);
  String _ticket = '';
  String _mobile = '';
  String _qrToken = '';
  final Map<String, String> _cookies = {};

  static String _randomDigits(int length) {
    final random = Random.secure();
    return List.generate(
      length,
      (i) => i == 0
          ? (random.nextInt(9) + 1).toString()
          : random.nextInt(10).toString(),
    ).join();
  }

  void _absorbCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null) return;
    for (final part in setCookie.split(',')) {
      final pair = part.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) _cookies[name] = value;
    }
    // 多个 Set-Cookie 可能被 http 库合并进一条，上面按逗号切会误伤
    // Expires 里的逗号；sessionid 本身不含逗号，切分结果仍可用。
  }

  String get _cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Future<Map<String, String>> _signedHeaders(
    Uri url,
    Map<String, String> params, [
    List<int>? body,
  ]) async {
    final signer = _signer;
    if (signer == null) return {};
    return signer(url: url, params: params, body: body);
  }

  Future<http.Response> _postForm(
    String base,
    String path,
    Map<String, String> params, {
    bool formBody = false,
    Map<String, String>? extraHeaders,
    String? cookie,
  }) async {
    final query = Map<String, String>.from(params);
    final url = Uri.parse('$base$path').replace(queryParameters: query);
    // 先算 body 再签名：签名要覆盖实际发出的 body，之前先签名后算
    // body，表单请求的签名里 body 是空的。
    final body = formBody
        ? utf8.encode(
            query.entries
                .map(
                  (e) =>
                      '${Uri.encodeQueryComponent(e.key)}='
                      '${Uri.encodeQueryComponent(e.value)}',
                )
                .join('&'),
          )
        : null;
    final headers = <String, String>{
      'User-Agent': _webUa,
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
      ...?extraHeaders,
      ...await _signedHeaders(url, query, body),
    };
    if (body != null) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    final response = await _guard(
      () => _client.post(url, headers: headers, body: body).timeout(
        const Duration(seconds: 30),
      ),
    );
    _checkStatus(response);
    _absorbCookies(response);
    return response;
  }

  Future<http.Response> _getJson(
    String base,
    String path,
    Map<String, String> params, {
    String? cookie,
  }) async {
    final url = Uri.parse('$base$path').replace(queryParameters: params);
    final headers = <String, String>{
      'User-Agent': _webUa,
      'Accept': 'application/json',
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
      ...await _signedHeaders(url, params),
    };
    final response = await _guard(
      () => _client.get(url, headers: headers).timeout(
        const Duration(seconds: 30),
      ),
    );
    _checkStatus(response);
    _absorbCookies(response);
    return response;
  }

  /// 网络层异常一律转成 [HongguoAccountError]：服务层与页面只认这
  /// 一种异常。未转的 Timeout/ClientException/FormatException 会
  /// 穿过 sendCode/verifyCode 的 catch，让页面卡在“正在发送/登录…”
  /// 且无任何提示——用户只看到登入不了。
  static Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on HongguoAccountError {
      rethrow;
    } on TimeoutException {
      throw HongguoAccountError('请求超时，请检查网络后重试');
    } on http.ClientException {
      throw HongguoAccountError('网络连接失败，请检查网络后重试');
    } on SocketException {
      throw HongguoAccountError('网络连接失败，请检查网络后重试');
    } on FormatException {
      throw HongguoAccountError('账号接口返回格式异常，请稍后重试');
    }
  }

  /// 非 200 先报 HTTP 码：否则 _decode 会对着错误页（如限流/盾页
  /// 的 HTML）抛 FormatException，用户看到的只是“格式异常”。
  static void _checkStatus(http.Response response) {
    if (response.statusCode != 200) {
      throw HongguoAccountError(
        '账号接口返回 HTTP ${response.statusCode}，请稍后重试',
      );
    }
  }

  static Map<String, dynamic> _decode(http.Response response) {
    if (response.body.isEmpty) {
      throw HongguoAccountError('账号接口返回空响应，请稍后重试');
    }
    final Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw HongguoAccountError('账号接口返回格式异常');
      }
      decoded = parsed;
    } on FormatException {
      throw HongguoAccountError('账号接口返回格式异常，请稍后重试');
    }
    return decoded;
  }

  static String _describe(Map<String, dynamic> data) {
    final desc = '${data['description'] ?? ''}';
    final code = data['error_code'];
    // 错误码 7 是平台限流（发码太频繁）：只转述平台原文，用户既不
    // 知道等多久，也分不清是平台在限流还是本机问题，这里写清。
    if (code is num && code.toInt() == 7) {
      return '平台限流：请求太频繁，请等 60 秒后再试（错误码 7）';
    }
    if (desc.isEmpty) return '';
    return code is num ? '$desc（错误码 $code）' : desc;
  }

  // ── 手机号登录 ──

  @override
  Future<HongguoCodeSent> sendPhoneCode(String mobile) async {
    _mobile = mobile;
    _ticket = '';
    _cookies.clear();
    final reply = _decode(
      await _postForm(
        _passportBase,
        '/passport/mobile/send_code/v1/',
        _passportParams({'mobile': mobile, 'type': '24'}),
      ),
    );
    if ('${reply['message'] ?? ''}' != 'success') {
      final data = reply['data'] is Map<String, dynamic>
          ? reply['data'] as Map<String, dynamic>
          : <String, dynamic>{};
      if (data.containsKey('verify_center_decision_conf')) {
        throw HongguoAccountError('平台要求先完成滑块验证，当前登录流程不支持，尚未完成登录。');
      }
      // 把平台错误码带上：调用方靠它决定要不要限流冷却（错误码 7）。
      // 错误码也可能放顶层不在 data 里，顶层也看一眼。
      final errorCode = data['error_code'] is num
          ? (data['error_code'] as num).toInt()
          : reply['error_code'] is num
          ? (reply['error_code'] as num).toInt()
          : 0;
      final described = _describe(data).isEmpty
          ? _describe(reply)
          : _describe(data);
      throw HongguoAccountError(
        described.isEmpty ? '验证码没发出去' : described,
        code: errorCode == 0 ? null : errorCode,
      );
    }
    final data = reply['data'] is Map<String, dynamic>
        ? reply['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    _ticket = '${data['mobile_ticket'] ?? ''}';
    return HongguoCodeSent(
      maskedMobile: '${data['mobile'] ?? ''}'.isEmpty
          ? HongguoPhoneNumber.mask(mobile)
          : '${data['mobile']}',
      retrySeconds: data['retry_time'] is num
          ? (data['retry_time'] as num).toInt()
          : 60,
    );
  }

  @override
  Future<HongguoAccountSession> verifyPhoneCode(String code) async {
    if (_mobile.isEmpty) {
      throw HongguoAccountError('请先发送验证码');
    }
    HongguoAccountError? lastFailure;
    // 5 个端点都没下发 sessionid 时，别只剩一句含糊话：把最后一个
    // 有内容的平台原话带上，方便定位到底是哪个端点、哪句拒绝。
    String lastNote = '';
    // 主端点在前，已登录校验入口在最后兜底：未登录会话调它固定
    // 回会话过期，见对照仓库的实测记录。
    const attempts = [
      ('/passport/mobile/sms_login/', true),
      ('/passport/mobile/sms_login_only/', true),
      ('/passport/mobile/sms_login_continue/', true),
      ('/passport/mobile/validate_code/v1/', false),
      ('/passport/mobile/validate_code/v1/', true),
    ];
    for (final (path, form) in attempts) {
      final params = {
        'mobile': _mobile,
        'code': code,
        'type': '24',
        'mobile_ticket': _ticket,
      };
      final reply = _decode(
        await _postForm(
          _passportBase,
          path,
          _passportParams(params),
          formBody: form,
        ),
      );
      if (_cookies.containsKey('sessionid')) break;
      final data = reply['data'] is Map<String, dynamic>
          ? reply['data'] as Map<String, dynamic>
          : <String, dynamic>{};
      final freshTicket = '${data['mobile_ticket'] ?? ''}';
      if (freshTicket.isNotEmpty) _ticket = freshTicket;
      final errorCode = data['error_code'] is num
          ? (data['error_code'] as num).toInt()
          : 0;
      final note = _describe(data).isEmpty
          ? '${reply['message'] ?? ''}'
          : _describe(data);
      if (note.isNotEmpty && note != 'success') lastNote = note;
      if (errorCode == 0 || errorCode == 1) {
        if (errorCode == 1) {
          lastFailure = HongguoAccountError('会话过期，请重新登录（错误码 1）', code: 1);
        }
        continue;
      }
      if (errorCode == 1203) {
        _ticket = '';
        _cookies.clear();
        throw HongguoAccountError(
          _describe(data).isEmpty
              ? '错误次数过多或验证码过期，请重新获取验证码（错误码 1203）'
              : _describe(data),
          code: 1203,
        );
      }
      throw HongguoAccountError(
        _describe(data).isEmpty ? '验证码校验失败（错误码 $errorCode）' : _describe(data),
        code: errorCode,
        canRetryCode: errorCode == 1102,
      );
    }
    if (!_cookies.containsKey('sessionid')) {
      throw lastFailure ??
          HongguoAccountError(
            lastNote.isEmpty
                ? '登录没有成功，平台没有下发登录态'
                : '登录没有成功，平台没有下发登录态（$lastNote）',
          );
    }
    return HongguoAccountSession(
      cookie: _cookieHeader,
      deviceId: _deviceId,
      installId: _installId,
      userId: '',
      nickname: '',
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ── 扫码登录 ──

  @override
  Future<HongguoQrCode> fetchQrCode() async {
    final reply = _decode(
      await _getJson(_webBase, '/passport/web/get_qrcode/', {
        'aid': '513755',
        'passport_jssdk_version': '3.4.10',
        'passport_jssdk_type': 'normal',
        'account_sdk_source': 'web',
        'is_from_ttaccountsdk': '1',
        'language': 'zh',
        'next': '$_webBase/',
      }),
    );
    if ('${reply['message'] ?? ''}' != 'success') {
      throw HongguoAccountError('取登录二维码失败，请重试');
    }
    final data = reply['data'] is Map<String, dynamic>
        ? reply['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    _qrToken = '${data['token'] ?? ''}';
    final qrcode = '${data['qrcode'] ?? ''}';
    final base64Part = qrcode.contains('base64,')
        ? qrcode.substring(qrcode.indexOf('base64,') + 7)
        : qrcode;
    if (_qrToken.isEmpty || base64Part.isEmpty) {
      throw HongguoAccountError('取登录二维码失败，请重试');
    }
    final expire = data['expire_time'];
    final seconds = expire is num
        ? expire > 1000000000
              ? ((expire - DateTime.now().millisecondsSinceEpoch ~/ 1000)
                      .clamp(0, 600))
                  .toInt()
              : expire.clamp(0, 600).toInt()
        : 180;
    return HongguoQrCode(
      imageBytes: base64Decode(base64Part),
      expiresInSeconds: seconds,
    );
  }

  @override
  Future<HongguoQrPoll> pollQrCode() async {
    if (_qrToken.isEmpty) throw HongguoAccountError('请先获取二维码');
    final reply = _decode(
      await _getJson(_webBase, '/passport/web/check_qrconnect/', {
        'aid': '513755',
        'passport_jssdk_version': '3.4.10',
        'passport_jssdk_type': 'normal',
        'account_sdk_source': 'web',
        'is_from_ttaccountsdk': '1',
        'language': 'zh',
        'next': '$_webBase/',
        'token': _qrToken,
      }),
    );
    final data = reply['data'] is Map<String, dynamic>
        ? reply['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    final status = '${data['status'] ?? ''}';
    if (status == '5' || status == 'expired') return HongguoQrPoll.expired;
    if (status == '3' || status == 'confirmed') {
      final redirect = '${data['redirect_url'] ?? ''}';
      if (redirect.isNotEmpty) await _followConfirmRedirect(redirect);
      return _hasWebSession() ? HongguoQrPoll.confirmed : HongguoQrPoll.waiting;
    }
    return HongguoQrPoll.waiting;
  }

  /// 只跟官方站内的确认跳转（https + hongguoduanju.com），最多 5 跳。
  Future<void> _followConfirmRedirect(String value) async {
    var url = Uri.parse(_webBase).resolve(value);
    for (var i = 0; i < 5; i++) {
      if (url.scheme != 'https' || url.host != 'hongguoduanju.com') {
        throw HongguoAccountError('登录确认跳转到不支持的站点');
      }
      final request = http.Request('GET', url);
      request.headers['User-Agent'] = _webUa;
      request.headers['Referer'] = '$_webBase/';
      if (_cookieHeader.isNotEmpty) {
        request.headers['Cookie'] = _cookieHeader;
      }
      final streamed = await _guard(
        () => _client.send(request).timeout(
          const Duration(seconds: 30),
        ),
      );
      final response = await http.Response.fromStream(streamed);
      _absorbCookies(response);
      final location = response.headers['location'];
      if (response.statusCode >= 300 &&
          response.statusCode < 400 &&
          location != null) {
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HongguoAccountError('登录确认失败（HTTP ${response.statusCode}）');
      }
      return;
    }
    throw HongguoAccountError('登录确认跳转次数过多');
  }

  bool _hasWebSession() =>
      (_cookies.containsKey('sessionid') ||
          _cookies.containsKey('sessionid_ss')) &&
      _cookies.entries.any((e) => e.value.isNotEmpty);

  @override
  Future<HongguoAccountSession> finishQrLogin() async {
    if (!_hasWebSession()) {
      throw HongguoAccountError('官网尚未下发登录态，请先在手机确认登录');
    }
    // 调一次账号信息确认会话有效，再交会话。
    await _getJson(_webBase, '/passport/account/info/v2/', {
      'aid': '513755',
      'passport_jssdk_version': '3.4.10',
      'passport_jssdk_type': 'normal',
      'account_sdk_source': 'web',
      'is_from_ttaccountsdk': '1',
      'language': 'zh',
    }, cookie: _cookieHeader);
    return HongguoAccountSession(
      cookie: _cookieHeader,
      deviceId: _deviceId,
      installId: _installId,
      userId: '',
      nickname: '',
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  // ── 账号数据 ──

  /// 账号接口通用 query：官方 App 接口的固定应用/设备表，与取流
  /// 路（hgtv_content._appQuery、Rust params_74332）同款。
  ///
  /// 根因：之前 _accountJson 一个参数都不带，/reading/user/info/v1/
  /// 这类接口直接回 100103（api5 体系的“参数无效”码，公开资料里
  /// bookshelf/check 不带参数就是这个码）。设备身份取 session 里
  /// 持久化的那份（本次登录换到的），刷新沿用同一份，不用每次新建
  /// 传输的随机号。passport 的 2046 忌讳只针对 passport 域名，
  /// fqnovel 的 api5 接口取流路本来就带 device_id/iid。
  static Map<String, String> _accountParams(
    HongguoAccountSession session,
  ) {
    return {
      ..._passportDeviceParams,
      'device_id': session.deviceId,
      'iid': session.installId,
      'cdid': session.deviceId,
      'host_abi': 'arm64-v8a',
      'dragon_device_type': 'phone',
      'pv_player': '74332',
      'compliance_status': '0',
      'need_personal_recommend': '1',
      'player_so_load': '1',
      'is_android_pad_screen': '0',
      '_rticket': DateTime.now().millisecondsSinceEpoch.toString(),
    };
  }

  Future<Map<String, dynamic>> _accountJson(
    HongguoAccountSession session,
    String path, {
    Map<String, String> params = const {},
    Map<String, dynamic>? body,
    bool gzip = false,
  }) async {
    // 调用方参数在后，同名以调用方为准。
    final queryParams = {..._accountParams(session), ...params};
    final url = Uri.parse('$_apiBase$path').replace(
      queryParameters: queryParams,
    );
    // 先算最终要发的 body 再签名：签名要覆盖实际发出的字节
    // （gzip 后），之前签名的请求里 body 是空的。
    final bodyBytes = body == null ? null : utf8.encode(jsonEncode(body));
    final List<int>? wireBody = (gzip && bodyBytes != null)
        ? gzipEncode(bodyBytes)
        : bodyBytes;
    final headers = <String, String>{
      'User-Agent': _webUa,
      'Accept': 'application/json',
      'Cookie': session.cookie,
      ...await _signedHeaders(url, queryParams, wireBody),
    };
    if (gzip && bodyBytes != null) {
      headers['Content-Encoding'] = 'gzip';
    }
    if (wireBody != null) {
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    final response = await _guard(
      () => (wireBody == null
              ? _client.get(url, headers: headers)
              : _client.post(url, headers: headers, body: wireBody))
          .timeout(const Duration(seconds: 30)),
    );
    _checkStatus(response);
    final json = _decode(response);
    if (json['code'] is num && (json['code'] as num) != 0) {
      final code = (json['code'] as num).toInt();
      // 服务端原话别丢：之前只取 code 自己拼“账号接口不可用”，
      // 平台真正的拒绝原因（比如参数名）用户永远看不到。
      final serverMessage = _pick(json, ['message', 'msg', 'description']);
      throw HongguoAccountError(
        serverMessage.isEmpty
            ? '账号接口不可用（错误码 $code），请重新登录或稍后重试'
            : '$serverMessage（错误码 $code）',
        code: code,
      );
    }
    return json;
  }

  static List<int> gzipEncode(List<int> input) => gzip.encode(input);

  /// 按顺序取第一个非空字符串字段。
  static String _pick(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final value = '${row[key] ?? ''}';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  @override
  Future<HongguoAccountProfile> fetchProfile(
    HongguoAccountSession session,
  ) async {
    final json = await _accountJson(session, '/reading/user/info/v1/');
    return parseProfileJson(json);
  }

  /// 账号资料解析：biz_user_id 为空 = 该手机号还没有红果账号资料，
  /// 与登录链路无关，须提示用户先去官方 App 登录一次。
  static HongguoAccountProfile parseProfileJson(Map<String, dynamic> json) {
    final data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : <String, dynamic>{};
    final id = '${data['biz_user_id'] ?? ''}';
    if (id.isEmpty) {
      throw HongguoAccountError(
        '该手机号还没有红果账号资料，请先用官方红果 App 登录一次再回来试（或改用扫码）',
      );
    }
    final name = '${data['user_name'] ?? ''}';
    return HongguoAccountProfile(
      userId: id,
      nickname: name.isEmpty ? '红果用户' : name,
    );
  }

  @override
  Future<List<HongguoCloudFavorite>> fetchFavorites(
    HongguoAccountSession session,
  ) async {
    final json = await _accountJson(
      session,
      '/reading/bookapi/bookshelf/video/info/v1/',
    );
    return parseFavoritesJson(json);
  }

  static List<HongguoCloudFavorite> parseFavoritesJson(
    Map<String, dynamic> json,
  ) {
    final data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : null;
    if (data == null || !data.containsKey('video_shelf_info')) {
      throw HongguoAccountError('账户收藏列表格式已变化');
    }
    final rows = data['video_shelf_info'];
    if (rows == null) return const [];
    if (rows is! List) throw HongguoAccountError('账户收藏列表格式已变化');
    final out = <HongguoCloudFavorite>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final video = row['video_data'] is Map<String, dynamic>
          ? row['video_data'] as Map<String, dynamic>
          : row;
      final id = _pick(video, ['series_id']).isEmpty
          ? _pick(row, ['series_id', 'book_id'])
          : _pick(video, ['series_id']);
      final title = _pick(row, ['series_title']).isEmpty
          ? _pick(video, ['title']).isEmpty
                ? _pick(row, ['book_name'])
                : _pick(video, ['title'])
          : _pick(row, ['series_title']);
      if (!RegExp(r'^[0-9]{1,30}$').hasMatch(id) || title.isEmpty) continue;
      final cover = _pick(row, ['series_cover_url']).isEmpty
          ? _pick(video, ['cover', 'cover_url', 'thumb_url']).isEmpty
                ? _pick(row, ['thumb_url'])
                : _pick(video, ['cover', 'cover_url', 'thumb_url'])
          : _pick(row, ['series_cover_url']);
      final count = video['episode_cnt'] is num
          ? (video['episode_cnt'] as num).toInt()
          : video['episode_count'] is num
          ? (video['episode_count'] as num).toInt()
          : row['episode_cnt'] is num
          ? (row['episode_cnt'] as num).toInt()
          : 0;
      final stampRaw = row['collect_time'];
      final stamp = stampRaw is num ? stampRaw.toInt() : 0;
      out.add(
        HongguoCloudFavorite(
          seriesId: id,
          title: title,
          cover: cover,
          intro: _pick(row, ['series_intro']).isEmpty
              ? _pick(video, ['video_desc']).isEmpty
                    ? _pick(row, ['abstract'])
                    : _pick(video, ['video_desc'])
              : _pick(row, ['series_intro']),
          badge: count > 0 ? '全 $count 集' : '',
          collectedAtMs: stamp > 0 && stamp < 10000000000 ? stamp * 1000 : stamp,
        ),
      );
    }
    if (rows.isNotEmpty && out.isEmpty) {
      throw HongguoAccountError('账户收藏条目格式已变化');
    }
    final seen = <String>{};
    final deduped = out.where((e) => seen.add(e.seriesId)).toList();
    deduped.sort((a, b) => b.collectedAtMs.compareTo(a.collectedAtMs));
    return deduped;
  }

  @override
  Future<void> setFavorite(
    HongguoAccountSession session,
    String seriesId,
    bool add,
  ) async {
    if (!RegExp(r'^[0-9]{1,30}$').hasMatch(seriesId)) {
      throw HongguoAccountError('剧集编号无效');
    }
    final entry = <String, dynamic>{
      'book_id': seriesId,
      'book_type': 2,
      'modify_time': DateTime.now().millisecondsSinceEpoch,
      'video_shelf_operate_type': add ? 0 : 1,
      if (!add) 'group_name': '',
    };
    final body = <String, dynamic>{
      'is_cancelled': false,
      'update_bookshelf_video_list': [entry],
      if (add)
        'shark_extra': {
          'enter_from': 'MainFragmentActivity',
          'previous_page': '',
          'page_list': 'MainFragmentActivity',
          'is_active_behavior': 'true',
          'inactive_type': '0',
        },
    };
    await _accountJson(
      session,
      '/reading/bookapi/bookshelf/video/update/v1/',
      body: body,
    );
  }

  @override
  Future<List<HongguoCloudProgress>> fetchHistory(
    HongguoAccountSession session,
  ) async {
    final json = await _accountJson(
      session,
      '/reading/bookapi/read_progress/list/v1/',
      params: {'book_types': '2', 'limit': '50'},
    );
    final rows = json['video_data'] is List
        ? json['video_data'] as List
        : (json['data'] is Map<String, dynamic> &&
                (json['data'] as Map<String, dynamic>)['video_data'] is List
            ? (json['data'] as Map<String, dynamic>)['video_data'] as List
            : null);
    if (rows == null) throw HongguoAccountError('云端历史数据格式已变化');
    final progress = parseProgressRows(rows);
    if (progress.isEmpty) return const [];
    // 补剧名与封面：失败不掩盖已拿到的进度列表。
    try {
      final detail = await _accountJson(
        session,
        '/reading/bookapi/multi-detail/v1/',
        params: {
          'book_id': progress.map((e) => e.seriesId).join(','),
          'book_type': '2',
        },
      );
      final details = detail['data'];
      if (details is List) {
        final byId = <String, Map<String, dynamic>>{};
        for (final row in details) {
          if (row is Map<String, dynamic>) {
            byId['${row['book_id'] ?? ''}'] = row;
          }
        }
        return progress
            .map(
              (p) => byId.containsKey(p.seriesId)
                  ? HongguoCloudProgress(
                      seriesId: p.seriesId,
                      episodeId: p.episodeId,
                      episodeIndex: p.episodeIndex,
                      positionMs: p.positionMs,
                      durationMs: p.durationMs,
                      updatedAtMs: p.updatedAtMs,
                      title: '${byId[p.seriesId]!['book_name'] ?? ''}',
                      cover: '${byId[p.seriesId]!['thumb_url'] ?? ''}',
                      episodeCount: p.episodeCount,
                    )
                  : p,
            )
            .toList();
      }
    } catch (_) {
      // 剧集资料补不全时仍返回进度本身，标题用剧集 id 占位。
    }
    return progress
        .map(
          (p) => p.title.isEmpty
              ? HongguoCloudProgress(
                  seriesId: p.seriesId,
                  episodeId: p.episodeId,
                  episodeIndex: p.episodeIndex,
                  positionMs: p.positionMs,
                  durationMs: p.durationMs,
                  updatedAtMs: p.updatedAtMs,
                  title: '剧集 ${p.seriesId}',
                  cover: p.cover,
                  episodeCount: p.episodeCount,
                )
              : p,
        )
        .toList();
  }

  static List<HongguoCloudProgress> parseProgressRows(List<dynamic> rows) {
    final out = <HongguoCloudProgress>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final id = '${row['series_id'] ?? ''}'.isEmpty
          ? '${row['book_id'] ?? ''}'
          : '${row['series_id']}';
      final episode = '${row['vid'] ?? ''}';
      if (!RegExp(r'^[0-9]{1,30}$').hasMatch(id) ||
          !RegExp(r'^[0-9]{1,30}$').hasMatch(episode)) {
        continue;
      }
      int stamp = row['last_watch_time'] is num
          ? (row['last_watch_time'] as num).toInt()
          : 0;
      if (stamp > 0 && stamp < 10000000000) stamp *= 1000;
      out.add(
        HongguoCloudProgress(
          seriesId: id,
          episodeId: episode,
          episodeIndex: ((row['vid_index'] is num
                          ? (row['vid_index'] as num).toInt()
                          : 1) -
                      1)
                  .clamp(0, 1 << 30),
          positionMs: (row['current_play_time'] is num
                  ? (row['current_play_time'] as num).toInt()
                  : 0)
              .clamp(0, 1 << 62),
          durationMs: (row['current_total_time'] is num
                  ? (row['current_total_time'] as num).toInt()
                  : 0)
              .clamp(0, 1 << 62),
          updatedAtMs: stamp,
          episodeCount: row['episode_count'] is num
              ? (row['episode_count'] as num).toInt()
              : 0,
        ),
      );
    }
    final seen = <String>{};
    final deduped = out.where((e) => seen.add(e.seriesId)).toList();
    deduped.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return deduped;
  }

  @override
  Future<void> uploadProgress(
    HongguoAccountSession session,
    HongguoCloudProgress progress,
  ) async {
    if (!RegExp(r'^[0-9]{1,30}$').hasMatch(progress.seriesId) ||
        !RegExp(r'^[0-9]{1,30}$').hasMatch(progress.episodeId)) {
      throw HongguoAccountError('剧集编号无效');
    }
    final rate = progress.durationMs > 0
        ? (progress.positionMs / progress.durationMs).clamp(0.0, 1.0).toString()
        : '0';
    await _accountJson(
      session,
      '/reading/bookapi/read_progress/upload/v1/',
      body: {
        'books': [
          {
            'book_id': progress.seriesId,
            'item_id': progress.episodeId,
            'vid_index': progress.episodeIndex + 1,
            'current_play_time': progress.positionMs.clamp(0, 1 << 62),
            'current_total_time': progress.durationMs.clamp(0, 1 << 62),
            'episode_count': progress.episodeCount,
            'read_timestamp_ms': progress.updatedAtMs,
            'book_type': 2,
            'progress_rate': rate,
            'player_cumulative_total_duration': progress.positionMs.clamp(
              0,
              1 << 62,
            ),
          },
        ],
        'write_mode': 1,
      },
    );
  }

  @override
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountSession session,
    bool online,
  ) async {
    final json = await _accountJson(
      session,
      '/reading/user/subscribe/list/v0/',
      params: {
        'offset': '0',
        'limit': '20',
        'is_online': online.toString(),
        'tab_type': '13',
        'subscribe_order_type': '0',
        'swipe_type': '0',
        'need_calendar_schema': 'false',
        'subscribe_offset': '0',
      },
    );
    return parseReservationsJson(json, online);
  }

  static List<HongguoCloudReservation> parseReservationsJson(
    Map<String, dynamic> json,
    bool online,
  ) {
    final data = json['data'] is Map<String, dynamic>
        ? json['data'] as Map<String, dynamic>
        : null;
    if (data == null || !data.containsKey('subscribe_items')) {
      throw HongguoAccountError('预约列表格式已变化，请稍后重试');
    }
    final rows = data['subscribe_items'];
    if (rows == null) return const [];
    if (rows is! List) throw HongguoAccountError('预约列表格式已变化，请稍后重试');
    final out = <HongguoCloudReservation>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final video = row['subscribe_data'] is Map<String, dynamic>
          ? row['subscribe_data'] as Map<String, dynamic>
          : row['video_data'] is Map<String, dynamic>
          ? row['video_data'] as Map<String, dynamic>
          : row;
      var seriesId = _pick(video, ['series_id']);
      if (seriesId.isEmpty) seriesId = _pick(row, ['series_id', 'book_id']);
      // 未上线条目没有可播剧集 id：用 reservation: 前缀命名空间，
      // 绝不能当成播放 id。
      String id;
      if (RegExp(r'^[0-9]{1,30}$').hasMatch(seriesId)) {
        id = seriesId;
      } else if (!online &&
          identical(video, row) &&
          RegExp(r'^[0-9]{1,30}$').hasMatch('${row['item_id'] ?? ''}')) {
        id = 'reservation:${row['item_id']}';
      } else {
        continue;
      }
      final title = _pick(row, ['series_title']).isEmpty
          ? _pick(video, ['title']).isEmpty
                ? _pick(video, ['book_name']).isEmpty
                      ? _pick(row, ['name'])
                      : _pick(video, ['book_name'])
                : _pick(video, ['title'])
          : _pick(row, ['series_title']);
      if (title.isEmpty) continue;
      if (row.containsKey('is_online') &&
          row['is_online'] is bool &&
          (row['is_online'] as bool) != online) {
        continue;
      }
      int stamp = row['schedule_publish_time'] is num
          ? (row['schedule_publish_time'] as num).toInt()
          : 0;
      if (stamp > 0 && stamp < 10000000000) stamp *= 1000;
      out.add(
        HongguoCloudReservation(
          seriesId: id,
          title: title,
          online: online,
          cover: _pick(row, ['series_cover_url']).isEmpty
              ? _pick(video, ['cover', 'cover_url', 'thumb_url'])
              : _pick(row, ['series_cover_url']),
          intro: _pick(video, ['video_desc']).isEmpty
              ? _pick(row, ['abstract']).isEmpty
                    ? _pick(row, ['item_desc'])
                    : _pick(row, ['abstract'])
              : _pick(video, ['video_desc']),
          publishAtMs: stamp,
          publishText: '${row['expected_rec_text'] ?? ''}',
        ),
      );
    }
    if (rows.isNotEmpty && out.isEmpty) {
      throw HongguoAccountError('预约条目格式已变化，请稍后重试');
    }
    final seen = <String>{};
    return out.where((e) => seen.add(e.seriesId)).toList();
  }

  @override
  Future<void> reserve(
    HongguoAccountSession session,
    String seriesId, {
    required bool upcoming,
  }) async {
    if (!upcoming || !RegExp(r'^[0-9]{1,19}$').hasMatch(seriesId)) {
      throw HongguoAccountError('预约编号无效');
    }
    final id = int.tryParse(seriesId);
    if (id == null) throw HongguoAccountError('预约编号无效');
    await _accountJson(
      session,
      '/reading/bookapi/search/uncover_subscribe/v1/',
      body: {
        'item_id': id,
        'item_type': 3,
        'op_type': 1,
        'subscribe_source': 0,
      },
      gzip: true,
    );
  }
}

// ── 登录状态机与同步服务 ──────────────────────────────────────────────

enum HongguoLoginState {
  signedOut,
  sendingCode,
  codeSent,
  verifying,
  fetchingQr,
  waitingScan,
  signedIn,
}

/// 红果账号服务：登录两路、账号收藏/历史/预约同步、退出。
///
/// - 登录态只存安全存储（键 hongguo_account_session_v1），不进 Hive；
/// - 账号数据只进 [HongguoAccountCloudStore] 的三个账号箱，
///   本机历史（LibraryStore）与本机书架（ShelfStore）一字不动；
/// - 退出登录只清会话 + 本账号的云端箱，本机记录原样保留。
/// - 真机短信登录须用户手机配合验证，本文件不虚构“已通”。
class HongguoAccountService extends ChangeNotifier {
  HongguoAccountService({
    HongguoAccountTransport Function()? transportFactory,
    HongguoAccountCloudStore? cloudStore,
    SecureKeyStorage? sessionStorage,
  }) : _transportFactory =
           transportFactory ?? HongguoAccountHttpTransport.new,
       _cloudStore = cloudStore ?? HongguoAccountCloudStore(),
       _sessionStorage = sessionStorage ?? const FlutterSecureKeyStorage();

  static final HongguoAccountService instance = HongguoAccountService();

  /// 安全存储里的会话键。
  static const sessionStorageKey = 'hongguo_account_session_v1';

  final HongguoAccountTransport Function() _transportFactory;
  final HongguoAccountCloudStore _cloudStore;
  final SecureKeyStorage _sessionStorage;

  HongguoAccountTransport? _attempt;
  HongguoAccountSession? _session;
  HongguoAccountProfile? _profile;

  /// 验码已换到、但资料核对还没过的会话：验码成功后 fetchProfile
  /// 失败（如 100103）时留着它，点登录可直接重试核对，不用重发
  /// 短信、重输新码。发码/扫码/退出会清掉它（换了新的尝试）。
  HongguoAccountSession? _pendingVerifiedSession;

  HongguoLoginState _loginState = HongguoLoginState.signedOut;
  bool _busy = false;
  String _statusMessage = '未登录';
  HongguoQrCode? _qr;
  DateTime? _qrExpiresAt;
  DateTime? _codeCooldownUntil;
  Timer? _qrPollTimer;
  Timer? _codeCooldownTimer;
  int _lastUploadMs = 0;
  String _lastUploadEpisodeId = '';
  bool _initialized = false;

  HongguoLoginState get loginState => _loginState;
  bool get busy => _busy;
  String get statusMessage => _statusMessage;
  HongguoAccountProfile? get profile => _profile;
  bool get signedIn => _session != null && _session!.isUsable;
  HongguoQrCode? get qr => _qr;
  DateTime? get qrExpiresAt => _qrExpiresAt;

  /// 验证码重发倒计时（秒），0=可重发。
  int get codeCooldownSeconds {
    final until = _codeCooldownUntil;
    if (until == null) return 0;
    final left = until.difference(DateTime.now()).inSeconds;
    return left > 0 ? left : 0;
  }

  /// 当前传输是否接了请求签名。默认 HTTP 传输已接线（hongguo_sign
  /// 栈），还没发过请求时也是 true；只有测试注入的假传输才 false。
  bool get signingWired {
    final attempt = _attempt;
    if (attempt == null) return true;
    if (attempt is HongguoAccountHttpTransport) return attempt.signingWired;
    return false;
  }

  String? get _userId => _session?.userId.isNotEmpty == true
      ? _session!.userId
      : null;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _cloudStore.init();
    await _restoreSession();
  }

  Future<void> _restoreSession() async {
    try {
      final raw = await _sessionStorage.read(sessionStorageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final session = HongguoAccountSession.fromJson(decoded);
      if (!session.isUsable) return;
      _session = session;
      _profile = HongguoAccountProfile(
        userId: session.userId,
        nickname: session.nickname,
      );
      _loginState = HongguoLoginState.signedIn;
      _statusMessage = '登录态已恢复，正在读取云端记录';
      notifyListeners();
      unawaited(refresh());
    } catch (_) {
      _statusMessage = '登录态无法读取，请重新登录';
      notifyListeners();
    }
  }

  Future<void> _saveSession(HongguoAccountSession session) async {
    // 先写盘再赋值：写盘失败时内存里不留一个“已登录但下次启动
    // 就丢”的会话，调用方才能按未登录重试。
    await _sessionStorage.write(
      sessionStorageKey,
      jsonEncode(session.toJson()),
    );
    _session = session;
  }

  /// 非账号异常的通用提示（落盘/存储等）：不把异常原文（含路径、
  /// 平台细节）直接甩给用户，只给一句能看懂的话。
  static String _genericMessage(Object e) {
    if (e is TimeoutException) return '请求超时，请检查网络后重试';
    if (e is http.ClientException || e is SocketException) {
      return '网络连接失败，请检查网络后重试';
    }
    return '登录失败，请稍后重试';
  }

  Future<void> _acceptSession(
    HongguoAccountSession session,
    HongguoAccountTransport attempt,
  ) async {
    // 手机号还没有红果账号资料时平台返回空账号：先核对再落盘，
    // 绝不把空账号当成“已登录”。
    final profile = await attempt.fetchProfile(session);
    final usable = HongguoAccountSession(
      cookie: session.cookie,
      deviceId: session.deviceId,
      installId: session.installId,
      userId: profile.userId,
      nickname: profile.nickname,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveSession(usable);
    _profile = profile;
    _attempt = null;
    _qr = null;
    _qrExpiresAt = null;
    _qrPollTimer?.cancel();
    _loginState = HongguoLoginState.signedIn;
    _statusMessage = '已登录 ${profile.nickname}，正在读取云端记录';
    notifyListeners();
    await refresh(force: true);
  }

  // ── 手机号登录（主路） ──

  /// 启动验证码重发倒计时（秒）。成功发码用平台回的 retry_time，
  /// 限流失败用 60 秒；冷却内按钮禁用、倒计时显示，不再发请求。
  void _startCodeCooldown(int seconds) {
    _codeCooldownUntil = DateTime.now().add(
      Duration(seconds: seconds.clamp(1, 600)),
    );
    _codeCooldownTimer?.cancel();
    _codeCooldownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (codeCooldownSeconds <= 0) _codeCooldownTimer?.cancel();
        notifyListeners();
      },
    );
  }

  /// 发短信验证码。countryCode 默认 86；号码归一化失败直接抛
  /// [HongguoAccountError]，页面显示其 message 即可。
  Future<HongguoCodeSent> sendCode({
    String countryCode = '86',
    required String number,
  }) async {
    final mobile = HongguoPhoneNumber.format(countryCode, number);
    if (_busy) throw HongguoAccountError('账号操作进行中，请稍候');
    if (codeCooldownSeconds > 0) {
      throw HongguoAccountError('请等 $codeCooldownSeconds 秒后再重发');
    }
    _busy = true;
    _loginState = HongguoLoginState.sendingCode;
    _statusMessage = '正在发送验证码…';
    notifyListeners();
    final attempt = _transportFactory();
    try {
      final sent = await attempt.sendPhoneCode(mobile);
      _attempt = attempt;
      _pendingVerifiedSession = null;
      _loginState = HongguoLoginState.codeSent;
      _statusMessage = '验证码已发送至 ${sent.maskedMobile}';
      _startCodeCooldown(sent.retrySeconds);
      return sent;
    } on HongguoAccountError catch (e) {
      // 平台限流（错误码 7）：发码失败也不让立刻重发，否则每次重
      // 点都再打一次已被限流的接口，只会延长限流。
      if (e.code == 7) _startCodeCooldown(60);
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = e.message;
      rethrow;
    } catch (e) {
      // 传输层之外的异常（如构造传输失败）：同样落一句可显示的话，
      // 不让页面卡在“正在发送验证码…”且无提示。
      final message = _genericMessage(e);
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = message;
      throw HongguoAccountError(message);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 验码登录：4–8 位数字验证码。
  Future<void> verifyCode(String code) async {
    final attempt = _attempt;
    if (attempt == null) {
      throw HongguoAccountError('请先点「获取验证码」');
    }
    if (!RegExp(r'^[0-9]{4,8}$').hasMatch(code.trim())) {
      throw HongguoAccountError('请输入 4—8 位验证码');
    }
    if (_busy) throw HongguoAccountError('账号操作进行中，请稍候');
    _busy = true;
    _loginState = HongguoLoginState.verifying;
    _statusMessage = '正在登录…';
    notifyListeners();
    HongguoAccountSession? verified;
    try {
      // 已验过的会话直接重试资料核对，不再重打验码接口：上次失败
      // 在 fetchProfile（100103 那类），验证码本身已经用过了，
      // 再打一次验码接口只会报码已用/码错误。
      verified = _pendingVerifiedSession ??
          await attempt.verifyPhoneCode(code.trim());
      await _acceptSession(verified, attempt);
      _pendingVerifiedSession = null;
    } on HongguoAccountError catch (e) {
      _statusMessage = e.message;
      if (verified != null) {
        // 验码已换到会话，失败在后面的资料核对/落盘：保留本次尝试，
        // 点登录可直接重试核对，不用重新发码。
        _pendingVerifiedSession = verified;
        _loginState = HongguoLoginState.codeSent;
      } else if (!e.canRetryCode) {
        // 验证码作废（次数过多/过期）：本次尝试丢弃，须重新发码。
        _attempt = null;
        _pendingVerifiedSession = null;
        _loginState = HongguoLoginState.signedOut;
      } else {
        _loginState = HongguoLoginState.codeSent;
      }
      rethrow;
    } catch (e) {
      // 非账号异常（落盘/存储等）：同样别卡在“正在登录…”。
      final message = _genericMessage(e);
      _statusMessage = message;
      if (verified != null) {
        _pendingVerifiedSession = verified;
        _loginState = HongguoLoginState.codeSent;
      } else {
        _attempt = null;
        _pendingVerifiedSession = null;
        _loginState = HongguoLoginState.signedOut;
      }
      throw HongguoAccountError(message);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── 扫码登录（备用） ──
  //
  // 定法：本机展示二维码，供另一台设备上的红果 App 扫码确认。
  // 用户只有一台手机时，本机扫不了自己的屏幕，扫码走不通——
  // 页面会明说这一点，并引导走手机号登录。绝不在本机放一个
  // “扫一扫”入口假装能用。

  Future<HongguoQrCode> fetchQr() async {
    if (_busy) throw HongguoAccountError('账号操作进行中，请稍候');
    _busy = true;
    _loginState = HongguoLoginState.fetchingQr;
    _statusMessage = '正在取登录二维码…';
    notifyListeners();
    final attempt = _transportFactory();
    try {
      final qr = await attempt.fetchQrCode();
      _attempt = attempt;
      _pendingVerifiedSession = null;
      _qr = qr;
      _qrExpiresAt = DateTime.now().add(
        Duration(seconds: qr.expiresInSeconds.clamp(1, 600)),
      );
      _loginState = HongguoLoginState.waitingScan;
      _statusMessage = '等待手机确认扫码登录';
      _qrPollTimer?.cancel();
      _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_pollQrOnce());
      });
      return qr;
    } on HongguoAccountError catch (e) {
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = e.message;
      rethrow;
    } catch (e) {
      final message = _genericMessage(e);
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = message;
      throw HongguoAccountError(message);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _pollQrOnce() async {
    final attempt = _attempt;
    if (attempt == null ||
        _loginState != HongguoLoginState.waitingScan ||
        _busy) {
      return;
    }
    final expiresAt = _qrExpiresAt;
    if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
      _qrPollTimer?.cancel();
      _attempt = null;
      _qr = null;
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = '二维码已过期，请重新扫码';
      notifyListeners();
      return;
    }
    try {
      final poll = await attempt.pollQrCode();
      if (poll == HongguoQrPoll.expired) {
        _qrPollTimer?.cancel();
        _attempt = null;
        _qr = null;
        _loginState = HongguoLoginState.signedOut;
        _statusMessage = '二维码已过期，请重新扫码';
        notifyListeners();
        return;
      }
      if (poll == HongguoQrPoll.confirmed) {
        _qrPollTimer?.cancel();
        _busy = true;
        _statusMessage = '扫码已确认，正在保存登录状态';
        notifyListeners();
        try {
          final session = await attempt.finishQrLogin();
          await _acceptSession(session, attempt);
        } finally {
          _busy = false;
          notifyListeners();
        }
      }
    } catch (e) {
      _qrPollTimer?.cancel();
      _attempt = null;
      _qr = null;
      _loginState = HongguoLoginState.signedOut;
      _statusMessage = e is HongguoAccountError ? e.message : '扫码登录未完成';
      notifyListeners();
    }
  }

  void cancelQr() {
    _qrPollTimer?.cancel();
    _attempt = null;
    _pendingVerifiedSession = null;
    _qr = null;
    if (_loginState == HongguoLoginState.waitingScan ||
        _loginState == HongguoLoginState.fetchingQr) {
      _loginState = _session != null
          ? HongguoLoginState.signedIn
          : HongguoLoginState.signedOut;
      _statusMessage = '已取消扫码登录';
      notifyListeners();
    }
  }

  // ── 云端同步 ──

  /// 重读账号资料 + 云端历史 + 收藏 + 预约，写进账号箱。
  /// 某一类失败不伪装成空列表：失败那类保持旧数据并报信。
  /// [force]：登录刚成功时 _acceptSession 调的那次——verifyCode
  /// 全程占着 _busy，不带 force 的话这里开头就 return，登录后
  /// 云端记录永远不会自动拉取，页面上“正在读取云端记录”是假话，
  /// 得用户手动点刷新才有数据。
  Future<void> refresh({bool force = false}) async {
    final session = _session;
    if (session == null) return;
    if (_busy && !force) return;
    _busy = true;
    _statusMessage = '正在读取账号观看历史…';
    notifyListeners();
    final attempt = _transportFactory();
    try {
      final profile = await attempt.fetchProfile(session);
      _profile = profile;
      _session = session.copyWith(nickname: profile.nickname);
      await _saveSession(_session!);
      final history = await attempt.fetchHistory(session);
      await _cloudStore.putHistory(profile.userId, history);
      try {
        final favorites = await attempt.fetchFavorites(session);
        await _cloudStore.putFavorites(profile.userId, favorites);
      } catch (e) {
        _statusMessage =
            '云端历史已读取，收藏读取失败：${e is HongguoAccountError ? e.message : '请稍后重试'}';
      }
      for (final online in [true, false]) {
        try {
          final rows = await attempt.fetchReservations(session, online);
          await _cloudStore.putReservations(profile.userId, online, rows);
        } catch (_) {
          // 预约某一类失败不掩盖已读到的另一类。
        }
      }
      _statusMessage = '已读取 ${history.length} 部云端观看记录';
    } on HongguoAccountError catch (e) {
      _statusMessage = e.message;
    } catch (_) {
      // 登录已成的刷新失败不能把已登录态掀翻：只报一句，不抛错，
      // 否则 _acceptSession 里 refresh 一抛，验码成功也显示失败。
      _statusMessage = '云端记录读取失败，请稍后重试';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── 收藏（进账号） ──

  List<HongguoCloudFavorite> get accountFavorites {
    final userId = _userId;
    if (userId == null) return const [];
    return _cloudStore.favorites(userId);
  }

  bool isAccountFavorite(String seriesId) =>
      accountFavorites.any((e) => e.seriesId == seriesId);

  /// 收藏/取消收藏：写后重读核对，核对不上如实报“未确认”，
  /// 不报假成功。返回给页面显示的一句话。
  Future<String> toggleAccountFavorite({
    required String seriesId,
    required String title,
    String cover = '',
    String intro = '',
    String badge = '',
  }) async {
    final session = _session;
    if (session == null) return '请先登录红果账号';
    if (_busy) return '账户收藏正在处理，请稍候';
    final add = !isAccountFavorite(seriesId);
    _busy = true;
    _statusMessage = '正在核对并更新账户收藏…';
    notifyListeners();
    final attempt = _transportFactory();
    try {
      final before = await attempt.fetchFavorites(session);
      final already = before.any((e) => e.seriesId == seriesId);
      if (already == add) {
        await _cloudStore.putFavorites(session.userId, before);
        return add ? '这部剧已在账户收藏中，无需重复添加' : '本次读取的账户列表中已没有这部剧，无需重复取消';
      }
      await attempt.setFavorite(session, seriesId, add);
      final after = await attempt.fetchFavorites(session);
      await _cloudStore.putFavorites(session.userId, after);
      final confirmed = after.any((e) => e.seriesId == seriesId) == add;
      if (!confirmed) {
        return '请求已提交，但账户列表尚未确认生效。请刷新或在手机红果核对，不要连续重复提交。';
      }
      return add ? '已加入账户收藏，并已在账户列表确认' : '已取消账户收藏，并已从本次读取的列表移除';
    } on HongguoAccountError catch (e) {
      return '收藏操作未确认：${e.message}。请先刷新或在手机核对。';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── 云端历史 / 续播（给播放器组） ──

  List<HongguoCloudProgress> get cloudHistory {
    final userId = _userId;
    if (userId == null) return const [];
    return _cloudStore.history(userId);
  }

  /// 播放器续播入口①：按剧查云端续播点。未登录返回 null。
  /// 返回的是云端记录；与本机记录的合并策略见 mergeCloudProgress，
  /// 播放器组接的时候按“更新时间新者赢”取用。
  Future<HongguoCloudResume?> resumeForSeries(String seriesId) async {
    final userId = _userId;
    if (userId == null || seriesId.isEmpty) return null;
    return _cloudStore.progressFor(userId, seriesId);
  }

  /// 播放器续播入口②：按剧 + 集查云端续播点。集 id 对不上返回 null，
  /// 调用方此时应走本机记录或从头播。
  Future<HongguoCloudResume?> resumeForEpisode(
    String seriesId,
    String episodeId,
  ) async {
    final resume = await resumeForSeries(seriesId);
    if (resume == null || resume.episodeId != episodeId) return null;
    return resume;
  }

  /// 同步读缓存里的云端续播点（不发请求，供列表页直接用）。
  HongguoCloudResume? cachedResumeForSeries(String seriesId) {
    final userId = _userId;
    if (userId == null || seriesId.isEmpty) return null;
    return _cloudStore.progressFor(userId, seriesId);
  }

  /// 播放器上报进度：同一集 30 秒内只传一次；先写账号箱，
  /// 再后台上传。未登录时静默丢弃，不写本机历史（本机历史
  /// 由播放器自己经 LibraryStore 写，两边不串）。
  Future<void> reportProgress({
    required String seriesId,
    required String episodeId,
    required int episodeIndex,
    required int positionMs,
    required int durationMs,
    required int episodeCount,
    String title = '',
    String cover = '',
  }) async {
    final session = _session;
    final userId = _userId;
    if (session == null || userId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (episodeId == _lastUploadEpisodeId &&
        now - _lastUploadMs < 30000) {
      return;
    }
    _lastUploadMs = now;
    _lastUploadEpisodeId = episodeId;
    final progress = HongguoCloudProgress(
      seriesId: seriesId,
      episodeId: episodeId,
      episodeIndex: episodeIndex,
      positionMs: positionMs.clamp(0, 1 << 62),
      durationMs: durationMs.clamp(0, 1 << 62),
      updatedAtMs: now,
      title: title,
      cover: cover,
      episodeCount: episodeCount,
    );
    await _cloudStore.upsertProgress(userId, progress);
    notifyListeners();
    final attempt = _transportFactory();
    try {
      await attempt.uploadProgress(session, progress);
      _statusMessage = '播放进度已上传（请在手机端核对续播）';
    } catch (e) {
      _statusMessage =
          '进度上传失败：${e is HongguoAccountError ? e.message : '请稍后重试'}';
    }
    notifyListeners();
  }

  // ── 预约（进账号） ──

  List<HongguoCloudReservation> reservations({required bool online}) {
    final userId = _userId;
    if (userId == null) return const [];
    return _cloudStore.reservations(userId, online);
  }

  bool isReserved(String seriesId) =>
      reservations(online: true).any((e) => e.seriesId == seriesId) ||
      reservations(online: false).any((e) => e.seriesId == seriesId);

  /// 预约一部待上线作品（upcoming=true 才允许）。写后重读核对，
  /// 核对不上如实报“未确认”，返回给页面显示的一句话。
  Future<String> reserveSeries(String seriesId, {required bool upcoming}) async {
    final session = _session;
    if (session == null) return '请先登录红果账号';
    if (!upcoming) return '只有待上线的作品可以预约';
    if (_busy) return '账号操作进行中，请稍候';
    if (isReserved(seriesId)) return '该作品已在当前账号的预约列表中';
    _busy = true;
    notifyListeners();
    final attempt = _transportFactory();
    try {
      await attempt.reserve(session, seriesId, upcoming: true);
      final rows = await attempt.fetchReservations(session, false);
      await _cloudStore.putReservations(session.userId, false, rows);
      final confirmed = rows.any(
        (e) => e.seriesId == seriesId || e.seriesId == 'reservation:$seriesId',
      );
      return confirmed
          ? '已加入账号预约'
          : '红果已接受预约请求，尚未在账号列表确认。请刷新预约状态，或在手机红果核对是否新增。';
    } on HongguoAccountError catch (e) {
      return '预约未完成：${e.message}';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── 退出 ──

  /// 退出登录：清会话 + 本账号的云端箱。本机历史与书架不动，
  /// 下次登录同一账号会重新拉云端记录。
  Future<void> logout() async {
    final userId = _userId;
    _qrPollTimer?.cancel();
    _codeCooldownTimer?.cancel();
    _attempt = null;
    _pendingVerifiedSession = null;
    _qr = null;
    _session = null;
    _profile = null;
    _lastUploadMs = 0;
    _lastUploadEpisodeId = '';
    _loginState = HongguoLoginState.signedOut;
    _statusMessage = '已退出账号，自动同步已停止';
    notifyListeners();
    await _sessionStorage.write(sessionStorageKey, '');
    if (userId != null) await _cloudStore.clearAccount(userId);
    notifyListeners();
  }

  @override
  void dispose() {
    _qrPollTimer?.cancel();
    _codeCooldownTimer?.cancel();
    super.dispose();
  }
}
