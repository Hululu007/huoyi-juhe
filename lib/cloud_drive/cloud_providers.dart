/// 五家网盘的登录 + 文件列表 + 直链客户端。
///
/// 协议来源：115/夸克/百度三家的 QR 流程与接口地址是从 TVBox_Web
/// 的 index.js 混淆包里抽出的协议事实（本文件按协议自己实现，不抄
/// 它的代码）；阿里云盘在 TVBox_Web 里没有扫码登录，按公开的阿里云盘
/// OpenAPI 协议实现；移动云盘（139 云盘）走手机号 + 短信验证码登录，
/// 实现在 cloud_provider_139.dart 里（同源头的 new139 协议）。2026-11-14 已实测四家的二维码参数接口均可匿名
/// 调通（见 ~/workspace/moyi_tvboxweb_port/DESIGN.md）；轮询、登录、
/// 列表、直链四步需真账号，均未实测，列为手机待验。
///
/// 所有请求都走注入的 [http.Client]，便于单测用假客户端替换。
/// 凭证只存在 [CloudCredentialStore] 里，不进日志、不出本机。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'cloud_115_upload.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_types.dart';
import 'cloud_m115_crypto.dart';
import 'cloud_provider_139.dart';

/// 网盘侧的错误（面向用户的中文消息，由引擎转成 AppFailure）。
class CloudDriveException implements Exception {
  CloudDriveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 二维码登录会话（一次扫码流程的状态）。
class QrLoginSession {
  const QrLoginSession({
    required this.qrContent,
    required this.qrImageUrl,
    required this.message,
    required this.state,
    required this.expiresAt,
  });

  /// 二维码内容（URL 字符串，应用内用二维码编码器画成图）。
  /// 走图片地址的网盘（百度）这里为空。
  final String qrContent;

  /// 二维码图片地址（百度直接给图）；不用图片的网盘这里为空。
  final String qrImageUrl;

  /// 提示文案（“请用 XX App 扫码确认”）。
  final String message;

  /// 轮询用的不透明状态（各家自己解释，引擎不解析）。
  final Map<String, String> state;

  /// 会话过期时间（界面据此停轮询、显示“二维码已过期”）。
  final DateTime expiresAt;
}

enum QrPollStatus {
  /// 等待扫码。
  waiting,

  /// 已扫码、等待在 App 内确认。
  scanned,

  /// 登录成功（带凭证）。
  success,

  /// 二维码已过期。
  expired,

  /// 流程失败（带原因）。
  failed,
}

class QrPollResult {
  const QrPollResult({
    required this.status,
    this.credentials,
    this.message = '',
  });

  final QrPollStatus status;
  final CloudCredentials? credentials;
  final String message;
}

/// 文件夹一页的列表结果。
class CloudFolderPage {
  const CloudFolderPage({
    required this.files,
    required this.hasMore,
    this.total = -1,
  });

  final List<CloudDriveFile> files;
  final bool hasMore;

  /// 总数；网盘没给时为 -1（未知）。
  final int total;
}

/// 直链结果：播放器直接用的地址 + 请求头。
class CloudDirectLink {
  const CloudDirectLink({
    required this.url,
    this.headers = const {},
    this.isTranscoded = false,
    this.downloadCookie,
    this.expiresAtMs = 0,
    this.linkF,
    this.fetchUserAgent,
  });

  final String url;
  final Map<String, String> headers;

  /// 是否转码流（夸克 v2/play 兜底）；仍是直链数据，不嵌网页播放器。
  final bool isTranscoded;

  /// 115：取链响应 Set-Cookie 里那对下载会话 Cookie（单对
  /// `32 位 hex=32 位 hex`），直链 f=3 时取文件必须带它。
  /// 不是账号 Cookie，账号 Cookie 绝不发给 CDN。
  final String? downloadCookie;

  /// 115：直链过期时间（URL 里 `t` 参数换算的毫秒时间戳）；0 = 未知。
  final int expiresAtMs;

  /// 115：直链 URL 里 `f` 参数（取文件时的请求头要求）：null = 没给，
  /// 0 = 无要求，1 = UA 必须与取链时一致，3 = UA 一致 + 带
  /// [downloadCookie]。[headers] 已按这个契约组装好，这里留作记录。
  final int? linkF;

  /// 取链时用的 UA；null = 不适用。115 取链 UA 置空，所以这里的
  /// 空串是有效值：播放器侧必须同样发空 UA（发不出空 UA 的播放器核
  /// 需要各自的字面量兜底，见 REPORT 的问题 6 清单）。
  final String? fetchUserAgent;
}

/// 115 账号信息（provider 层读取；网盘页账号信息位展示）。
class Pan115AccountInfo {
  const Pan115AccountInfo({
    required this.userId,
    this.nickname = '',
    this.avatarUrl = '',
    this.vipExpireSeconds = 0,
    this.vipForever = false,
  });

  /// 账号数字 id（转码安卓路的请求体必须带它）。
  final String userId;
  final String nickname;
  final String avatarUrl;

  /// VIP 到期时间（epoch 秒）；0 = 没拿到/不是 VIP。
  final int vipExpireSeconds;

  /// 是否永久 VIP。
  final bool vipForever;
}

/// 是不是在期会员（纯判定，夹具可测）：永久 VIP 恒真；
/// 否则看到期时间——到期为 0 是「没拿到/不是 VIP」的
/// 口径（见 [Pan115AccountInfo.vipExpireSeconds]），算非
/// 会员，不臆造。会员权益（下载速度/离线秒下）是 115 服
/// 务端按账号执行的，取链请求本身没有会员分流（见
/// [Pan115Provider.directLink]，全账号同一条），本判定
/// 只用于如实展示，不驱动任何假开关。
bool pan115IsVip(Pan115AccountInfo info, {int? nowSeconds}) {
  if (info.vipForever) return true;
  final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return info.vipExpireSeconds > now;
}

/// 115 容量信息（字节）。
class Pan115SpaceInfo {
  const Pan115SpaceInfo({
    required this.totalBytes,
    required this.usedBytes,
    required this.remainBytes,
  });

  final int totalBytes;
  final int usedBytes;
  final int remainBytes;
}

/// 115 上传信息（files/uploadinfo）：userkey 是 initupload 签名的
/// 必需品；sizeLimit 是单文件上限（字节），0 = 接口没给。
class Pan115UploadInfo {
  const Pan115UploadInfo({
    required this.userId,
    required this.userKey,
    this.sizeLimit = 0,
    this.uploadAllowed = true,
    this.uploadAllowedMsg = '',
  });

  final String userId;
  final String userKey;
  final int sizeLimit;
  final bool uploadAllowed;
  final String uploadAllowedMsg;
}

/// initupload 的结果（响应是扁平 JSON，没有 data 包裹）。
/// status：1 需要上传（走 OSS），2 秒传成功，7 需要二次校验
/// （带 signKey/signCheck 再 init 一次）。
class Pan115UploadInit {
  const Pan115UploadInit({
    required this.status,
    this.signKey = '',
    this.signCheck = '',
    this.bucket = '',
    this.objectKey = '',
    this.callback = '',
    this.callbackVar = '',
  });

  final int status;
  final String signKey;
  final String signCheck;
  final String bucket;
  final String objectKey;
  final String callback;
  final String callbackVar;
}

/// 转码安卓路取地址与播放共用的 UA：m3u8 里的链接绑取它时的 UA，
/// 两边不一致会被拒（f=1/3 校验）。
const pan115TranscodeUserAgent = 'Mozilla/5.0';

/// 转码响应 data 解密后的明文 → 直链（纯函数，单测直接覆盖：
/// RSA 剥壳的正确性由 cloud_m115_crypto 的交叉向量背书，服务端
/// 密文要私钥才能造、单测里造不出来）。video_url 按 height 取
/// 最高档，拼 &id={fid}；没有可用地址时按 queue_url 区分
/// 「正在转码 / 没有转码版本」如实报错。
CloudDirectLink buildPan115TranscodeLink(
  Map<String, dynamic> dataObj, {
  required String fileId,
  String? downloadCookie,
}) {
  String? bestUrl;
  var bestHeight = -1;
  final variants = dataObj['video_url'];
  if (variants is List) {
    for (final variant in variants) {
      if (variant is! Map<String, dynamic>) continue;
      final url = _asString(variant['url']);
      final height = _asInt(variant['height']);
      if (url.isNotEmpty && height > bestHeight) {
        bestHeight = height;
        bestUrl = url;
      }
    }
  }
  if (bestUrl == null) {
    if (_asString(dataObj['queue_url']).isNotEmpty) {
      throw CloudDriveException('视频正在转码，请稍后再试');
    }
    throw CloudDriveException('这个视频没有转码版本');
  }
  var url = bestUrl;
  if (fileId.isNotEmpty) {
    url = url.contains('?') ? '$url&id=$fileId' : '$url?id=$fileId';
  }
  final query = Uri.tryParse(url)?.queryParameters ?? const {};
  final linkF = int.tryParse(query['f'] ?? '');
  final expiresAtMs = (int.tryParse(query['t'] ?? '') ?? 0) * 1000;
  final headers = <String, String>{'User-Agent': pan115TranscodeUserAgent};
  if ((linkF == null || linkF == 3) && downloadCookie != null) {
    headers['Cookie'] = downloadCookie;
  }
  return CloudDirectLink(
    url: url,
    headers: headers,
    isTranscoded: true,
    downloadCookie: downloadCookie,
    expiresAtMs: expiresAtMs,
    linkF: linkF,
    fetchUserAgent: pan115TranscodeUserAgent,
  );
}

/// 网盘客户端的统一接口。
abstract class CloudDriveProvider {
  /// 网盘 id：pan115 / quark / aliyun / baidu / yun139。
  String get id;

  /// 显示名：115网盘 / 夸克网盘 / 阿里云盘 / 百度网盘 / 移动云盘。
  String get displayName;

  /// 扫码用的 App 名（提示文案用）。
  String get appName;

  /// 根文件夹 id（115/夸克=0，阿里=root，百度=/）。
  String get rootFolderId;

  /// 开始扫码登录：取二维码参数。
  Future<QrLoginSession> startQrLogin(http.Client client);

  /// 轮询一次扫码状态。
  Future<QrPollResult> pollQrLogin(http.Client client, QrLoginSession session);

  /// 列文件夹一页（page 从 1 起）。
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  );

  /// 在指定文件夹内搜索。没有站方搜索接口的网盘抛
  /// [UnsupportedError]，引擎改用“取列表后按名过滤”兜底。
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  );

  /// 取文件的直链（视频/音频/图片都走直链，不嵌网页播放器）。
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  );

  /// 凭证被刷新时的回调（阿里 access_token 续期用，引擎负责落盘）。
  void Function(String providerId, CloudCredentials credentials)?
  get onCredentialsRefreshed;
  set onCredentialsRefreshed(
    void Function(String providerId, CloudCredentials credentials)? value,
  );

  /// 凭证被判定过期失效时的回调（115 用，引擎负责清掉存下的凭证）。
  /// 带上失效时用的 cookie：引擎只在存着的 cookie 与它一致时才清，
  /// 防止在途旧请求的过期报错清掉刚重新登录的新凭证（世代保护在
  /// provider 内部另有一层，见 Pan115Provider._sessionGeneration）。
  void Function(String providerId, String expiredCookie)?
  get onSessionExpired;
  set onSessionExpired(
    void Function(String providerId, String expiredCookie)? value,
  );
}

// ---------------------------------------------------------------------------
// 通用小工具
// ---------------------------------------------------------------------------

const _requestTimeout = Duration(seconds: 20);

String _uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, dynamic> _jsonObject(String body, String what) {
  final decoded = jsonDecode(body);
  if (decoded is Map<String, dynamic>) return decoded;
  throw CloudDriveException('$what：返回的不是 JSON 对象');
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

/// 从 set-cookie 头里抽 name=value（跳过 Expires 里的逗号干扰）。
Map<String, String> parseSetCookies(String? setCookieHeader) {
  final result = <String, String>{};
  if (setCookieHeader == null || setCookieHeader.isEmpty) return result;
  // 按“逗号 + 名字=”切分（Expires=Wed, 21 Oct ... 里的逗号后跟的不是 名字=）。
  final parts = setCookieHeader.split(
    RegExp(r",\s*(?=[A-Za-z0-9_!#\$%&'*+\-.^`|~]+=[^;,]*)"),
  );
  for (final part in parts) {
    final first = part.split(';').first.trim();
    final eq = first.indexOf('=');
    if (eq <= 0) continue;
    final name = first.substring(0, eq).trim();
    final value = first.substring(eq + 1).trim();
    if (name.isEmpty || name.toLowerCase() == 'expires') continue;
    result[name] = value;
  }
  return result;
}

/// 把 set-cookie 合并进已有的 Cookie 头（同名覆盖）。
String mergeCookieHeader(String existing, String? setCookieHeader) {
  final jar = <String, String>{};
  for (final part in existing.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq > 0) jar[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
  }
  jar.addAll(parseSetCookies(setCookieHeader));
  return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// 手动跟随重定向（不下载正文），返回最终地址与沿途 set-cookie。
/// [maxHops] 跳后仍是重定向则返回最后一次的 Location（调用方决定）。
Future<({String url, String setCookie})> resolveRedirects(
  http.Client client,
  http.Request request, {
  int maxHops = 5,
}) async {
  var current = request;
  var cookies = '';
  for (var hop = 0; hop <= maxHops; hop++) {
    current.followRedirects = false;
    final response = await client.send(current).timeout(_requestTimeout);
    final location = response.headers['location'];
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      cookies = mergeCookieHeader(cookies, setCookie);
    }
    final status = response.statusCode;
    if (status >= 300 && status < 400 && location != null && location.isNotEmpty) {
      // 302 正文极小，直接取消流，不下载。
      await response.stream.listen(null).cancel().catchError((_) {});
      final next = current.url.resolve(location);
      final follow = http.Request('GET', next);
      follow.headers.addAll(current.headers);
      current = follow;
      continue;
    }
    await response.stream.listen(null).cancel().catchError((_) {});
    return (url: current.url.toString(), setCookie: cookies);
  }
  return (url: current.url.toString(), setCookie: cookies);
}

Future<http.Response> _get(
  http.Client client,
  Uri uri, {
  Map<String, String> headers = const {},
}) async {
  final response = await client.get(uri, headers: headers).timeout(_requestTimeout);
  return response;
}

Future<http.Response> _postJson(
  http.Client client,
  Uri uri,
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
}) async {
  return client
      .post(
        uri,
        headers: {'Content-Type': 'application/json', ...headers},
        body: jsonEncode(body),
      )
      .timeout(_requestTimeout);
}

Future<http.Response> _postForm(
  http.Client client,
  Uri uri,
  Map<String, String> fields, {
  Map<String, String> headers = const {},
}) async {
  return client
      .post(
        uri,
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          ...headers,
        },
        body: fields.entries
            .map(
              (e) =>
                  '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
            )
            .join('&'),
      )
      .timeout(_requestTimeout);
}

// ---------------------------------------------------------------------------
// 115 网盘
// ---------------------------------------------------------------------------

/// 115 Cookie 验活结论。
enum Pan115CookieVerdict {
  /// 凭证有效。
  valid,

  /// 凭证失效（过期三码或服务端明确拒绝）。
  expired,

  /// 网络/限频/服务端问题，Cookie 可能没事。
  networkError,
}

/// 解析 "a=1; b=2" 形式的 Cookie 文本（键名统一大写；浏览器复制时
/// 常带整行 "Cookie: " 前缀，先去掉）。
Map<String, String> parsePan115CookieString(String raw) {
  final result = <String, String>{};
  var text = raw.trim();
  if (text.toLowerCase().startsWith('cookie:')) {
    text = text.substring('cookie:'.length).trim();
  }
  for (final part in text.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final key = trimmed.substring(0, eq).trim().toUpperCase();
    final value = trimmed.substring(eq + 1).trim();
    if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
  }
  return result;
}

/// 115 登录三件套里缺的键（UID/CID/SEID）；齐全时为空列表。
List<String> missingPan115CookieKeys(String cookie) {
  final parsed = parsePan115CookieString(cookie);
  return [
    for (final key in ['UID', 'CID', 'SEID'])
      if ((parsed[key] ?? '').isEmpty) key,
  ];
}

/// 规范化 115 Cookie：UID/CID/SEID 缺一返回 null；齐全时只保留
/// UID/CID/SEID/KID 并按固定键序拼回。
String? normalizePan115Cookie(String cookie) {
  final parsed = parsePan115CookieString(cookie);
  if (missingPan115CookieKeys(cookie).isNotEmpty) return null;
  return [
    for (final key in ['UID', 'CID', 'SEID', 'KID'])
      if ((parsed[key] ?? '').isNotEmpty) '$key=${parsed[key]}',
  ].join('; ');
}

class Pan115Provider implements CloudDriveProvider {
  @override
  String get id => 'pan115';
  @override
  String get displayName => '115网盘';
  @override
  String get appName => '115 App';
  @override
  String get rootFolderId => '0';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36 115Browser/26.0.7.2';
  static const _referer = 'https://cdnassets.115.com/';
  // 扫码绑 qandroid（安卓端）：115 的视频接口按会话绑定的设备认人，
  // 绑错设备会被接口拒绝（公开实现 p115client 的实测结论）；旧实现绑
  // alipaymini 不在公开实现支持的绑定集合里。取凭证走 qrcodeapi 的
  // qandroid 路径、UA 固定 Mozilla/5.0、凭证在响应体 data.cookie。
  static const _qrTokenUrl =
      'https://qrcodeapi.115.com/api/1.0/web/1.0/token/';
  static const _qrStatusUrl = 'https://qrcodeapi.115.com/get/status/';
  static const _qrLoginUrl =
      'https://qrcodeapi.115.com/app/1.0/qandroid/1.0/login/qrcode/';
  static const _qrBindUa = 'Mozilla/5.0';
  static const _filesUrl = 'https://webapi.115.com/files';
  static const _categoryUrl = 'https://webapi.115.com/category/get';
  static const _downloadUrl = 'https://webapi.115.com/files/download';
  static const _indexInfoUrl = 'https://webapi.115.com/files/index_info';
  static const _userInfoUrl = 'https://webapi.115.com/user/info';
  static const _navUrl = 'https://my.115.com/';
  static const _uploadInfoUrl = 'https://webapi.115.com/files/uploadinfo';
  static const _initUploadUrl = 'https://uplb.115.com/4.0/initupload.php';
  static const _ossTokenUrl = 'https://uplb.115.com/3.0/gettoken.php';
  // 转码安卓路：官方安卓 App 的视频接口，只认安卓绑定的会话——扫码
  // 已改绑 qandroid（一期），配套成立。web 路要 web 绑会话、我们没有，
  // 不做。取地址与播放必须用同一个 UA（Mozilla/5.0）。
  static const _videoPlayUrl = 'https://proapi.115.com/android/2.0/video/play';
  // 分页大小（2026-11-27 问题 6）：40 条/页时大文件夹要拉很多
  // 页才出齐，改 200 条/页（网页口实测可承受的量级，开源实现
  // 常用 200-1000）；hasMore/offset 都按本常量推导，自动跟随。
  static const _pageSize = 200;

  /// 登录过期三码：凭证无效 / 已退出 / 会话已退出。命中才算凭证失效；
  /// HTTP 405 是限频信号，不当凭证失效。
  static const _expiredErrnos = {40101032, 40101035, 40101037};

  /// 下载会话 Cookie 的形状：32 位 hex 名 = 32 位 hex 值。
  static final _downloadCookiePattern = RegExp(r'[0-9a-f]{32}=[0-9a-f]{32}');

  /// 登录世代：登录成功、判定过期各 +1。请求发出时记下世代，回来时
  /// 若世代已变，说明登录已经换过，旧请求的过期报错不许清掉新登录。
  int _sessionGeneration = 0;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final response = await _get(
      client,
      Uri.parse(_qrTokenUrl),
      headers: {'User-Agent': _ua, 'Referer': _referer},
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('115 二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final data = _jsonObject(response.body, '115 二维码参数')['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('115 二维码参数获取失败：返回格式不对');
    }
    final uid = _asString(data['uid']);
    if (uid.isEmpty) {
      throw CloudDriveException('115 二维码参数获取失败：缺少 uid');
    }
    // 二维码由 115 直接出图（web 通道的 qrcode 字段就是图片地址）；
    // 字段是 /scan/ 内容时才当二维码内容本地绘制，没有字段时用
    // qrcodeapi 的出图地址兜底。
    final qrcode = _asString(data['qrcode']);
    var qrContent = '';
    var qrImageUrl = '';
    if (qrcode.contains('/scan/')) {
      qrContent = qrcode;
    } else if (qrcode.isNotEmpty) {
      qrImageUrl = qrcode;
    } else {
      qrImageUrl = 'https://qrcodeapi.115.com/api/1.0/web/1.0/qrcode?uid=$uid';
    }
    return QrLoginSession(
      qrContent: qrContent,
      qrImageUrl: qrImageUrl,
      message: '请用 115 App 扫码确认',
      state: {
        'uid': uid,
        'time': _asString(data['time']),
        'sign': _asString(data['sign']),
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uid = session.state['uid'] ?? '';
    final time = session.state['time'] ?? '';
    final sign = session.state['sign'] ?? '';
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(_qrStatusUrl).replace(
      queryParameters: {
        'uid': uid,
        'time': time,
        'sign': sign,
        '_': '$seconds.112',
      },
    );
    final response = await _get(
      client,
      uri,
      headers: {'User-Agent': _ua, 'Referer': _referer},
    );
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待 115 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '115 扫码状态');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待 115 App 扫码确认',
      );
    }
    // 按 data.status 数值判读：0 等待、1 已扫、2 已确认、-1 过期、
    // -2 取消。status 缺失时保留旧启发式（有 version 且没有 msg 视为
    // 已确认）兜底，避免个别返回形状没有 status 时卡死在等待态。
    final msg = _asString(data['msg']);
    final statusValue = data['status'];
    final status = statusValue == null ? null : _asInt(statusValue, 0);
    if (status == 2 || (status == null && data['version'] != null && msg.isEmpty)) {
      return _finishLogin(client, uid);
    }
    if (status == -1) {
      return const QrPollResult(
        status: QrPollStatus.expired,
        message: '二维码已过期，请重新获取',
      );
    }
    if (status == -2) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '扫码已取消，请重新获取二维码',
      );
    }
    return QrPollResult(
      status: status == 1 ? QrPollStatus.scanned : QrPollStatus.waiting,
      message: msg.isEmpty ? '等待 115 App 扫码确认' : msg,
    );
  }

  Future<QrPollResult> _finishLogin(http.Client client, String uid) async {
    final response = await _postForm(
      client,
      Uri.parse(_qrLoginUrl),
      {'account': uid},
      headers: {'User-Agent': _qrBindUa},
    );
    // 凭证在响应体 data.cookie（字符串或键值对象两种形状都认）；
    // 响应体没有时才退回 set-cookie 拼装兜底。
    var cookie = '';
    try {
      final root = _jsonObject(response.body, '115 扫码登录');
      final data = root['data'];
      if (data is Map<String, dynamic>) {
        final raw = data['cookie'];
        if (raw is String) {
          cookie = raw;
        } else if (raw is Map) {
          cookie = raw.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; ');
        }
      }
    } catch (_) {
      // 响应体不是 JSON 时走 set-cookie 兜底。
    }
    if (cookie.isEmpty) {
      cookie = mergeCookieHeader('', response.headers['set-cookie']);
    }
    if (cookie.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '115 登录失败：服务器没有返回凭证',
      );
    }
    // 三件套校验：UID/CID/SEID 缺一不算登录成功（残缺 Cookie 存下来
    // 只会让后续接口全挂且报不出原因）。通过后规范化成固定键序。
    final normalized = normalizePan115Cookie(cookie);
    if (normalized == null) {
      final missing = missingPan115CookieKeys(cookie);
      return QrPollResult(
        status: QrPollStatus.failed,
        message: '115 登录失败：凭证不完整（缺少 ${missing.join('、')}），请重新扫码',
      );
    }
    // 落盘前验活：凭证被服务端判过期就不报成功；网络类失败（含限频
    // 405）不拦登录——Cookie 可能没事，后续请求会再判。
    final verdict = await _validateCookie(client, normalized);
    if (verdict == Pan115CookieVerdict.expired) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '115 登录失败：凭证已失效，请重新扫码',
      );
    }
    // 新登录成立：世代 +1，在途旧请求的过期报错从此清不掉这份登录。
    _sessionGeneration++;
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': normalized},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '115网盘登录成功',
    );
  }

  /// Cookie 验活（调 files/index_info）：结构化分类，不靠文案匹配。
  /// 传输层失败 / HTTP 405（限频）/ 408 / 429 / 5xx 归网络问题，
  /// Cookie 可能没事；过期三码与服务端明确拒绝才归凭证失效。
  /// 本方法只判读不清登录态（清不清由统一响应处理按世代决定）。
  Future<Pan115CookieVerdict> validateCookies(
    http.Client client,
    CloudCredentials credentials,
  ) => _validateCookie(client, credentials.fields['cookie'] ?? '');

  Future<Pan115CookieVerdict> _validateCookie(
    http.Client client,
    String cookie,
  ) async {
    if (cookie.isEmpty) return Pan115CookieVerdict.expired;
    http.Response response;
    try {
      response = await _get(
        client,
        Uri.parse(_indexInfoUrl),
        headers: {
          'User-Agent': _ua,
          'Referer': _referer,
          'Cookie': cookie,
        },
      );
    } catch (_) {
      return Pan115CookieVerdict.networkError;
    }
    final code = response.statusCode;
    if (code == 405 || code == 408 || code == 429 || code >= 500) {
      return Pan115CookieVerdict.networkError;
    }
    if (code != 200) return Pan115CookieVerdict.expired;
    try {
      final root = _jsonObject(response.body, '115 凭证校验');
      if (_stateOk(root)) return Pan115CookieVerdict.valid;
      return Pan115CookieVerdict.expired;
    } catch (_) {
      return Pan115CookieVerdict.networkError;
    }
  }

  bool _stateOk(Map<String, dynamic> root) {
    final state = root['state'];
    return state == true || state == 1 || state == '1' || state == 'true';
  }

  int? _errnoOf(Map<String, dynamic> root) {
    for (final key in ['errno', 'errNo', 'errcode']) {
      final value = root[key];
      if (value != null) return _asInt(value, -1);
    }
    return null;
  }

  /// 统一响应判读：state 为假时先分过期 / 限频 / 一般错误，再让调用方
  /// 解析 data。命中过期三码时按世代清登录态（世代已变则不清）。
  void _checkState(
    Map<String, dynamic> root, {
    required String cookieUsed,
    required int generation,
    required String what,
  }) {
    if (!root.containsKey('state') || _stateOk(root)) return;
    final errno = _errnoOf(root);
    if (errno != null && _expiredErrnos.contains(errno)) {
      _expireSession(cookieUsed, generation);
      throw CloudDriveException('115 登录已过期，请重新登录');
    }
    final message = _asString(
      root['error_msg'] ?? root['error'] ?? root['message'],
      errno == null ? '接口报错' : '接口报错（错误码 $errno）',
    );
    throw CloudDriveException('$what：$message');
  }

  void _expireSession(String cookieUsed, int generation) {
    // 世代对不上：登录已经换过，旧请求的过期报错不许清新登录。
    if (generation != _sessionGeneration) return;
    _sessionGeneration++;
    onSessionExpired?.call(id, cookieUsed);
  }

  void _throwIfRateLimited(http.Response response, String what) {
    if (response.statusCode == 405) {
      throw CloudDriveException('$what：请求太频繁，请稍后再试');
    }
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Referer': _referer,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final offset = (page - 1) * _pageSize;
    final uri = Uri.parse(_filesUrl).replace(
      queryParameters: {
        'aid': '1',
        'cid': folderId,
        'o': 'file_name',
        'asc': '1',
        'offset': '$offset',
        'show_dir': '1',
        'limit': '$_pageSize',
        'format': 'json',
        'natsort': '1',
      },
    );
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    _throwIfRateLimited(response, '115 文件列表获取失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 文件列表');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 文件列表获取失败',
    );
    final data = root['data'];
    if (data is! List) {
      throw CloudDriveException('115 文件列表获取失败：返回格式不对');
    }
    final files = <CloudDriveFile>[];
    for (final item in data) {
      if (item is! Map<String, dynamic>) continue;
      files.add(_parseItem(item));
    }
    final total = _asInt(root['count'], -1);
    final hasMore = total >= 0
        ? offset + files.length < total
        : files.length >= _pageSize;
    return CloudFolderPage(files: files, hasMore: hasMore, total: total);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final fid = _asString(item['fid']);
    final cid = _asString(item['cid']);
    final isFolder = fid.isEmpty;
    final name = _asString(item['n']).replaceAll('|', ' ');
    final size = _asInt(item['s']);
    final pickcode = _asString(item['pc']);
    final duration = item['play_long'] is num
        ? (item['play_long'] as num).toInt()
        : (item['duration'] is num ? (item['duration'] as num).toInt() : null);
    final thumb = _asString(item['thumb']);
    final kind = classifyCloudFile(name: name, isFolder: isFolder);
    return CloudDriveFile(
      id: isFolder ? cid : fid,
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: size,
      modifiedMs: _asInt(item['t']) * 1000,
      durationSeconds: duration,
      thumbnailUrl: thumb,
      extra: {if (pickcode.isNotEmpty) 'pickcode': pickcode},
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    final uri = Uri.parse('https://webapi.115.com/files/search').replace(
      queryParameters: {
        'search_value': keyword,
        'aid': '1',
        'cid': folderId,
        'o': 'file_name',
        'asc': '1',
        'offset': '0',
        'limit': '$_pageSize',
        'format': 'json',
      },
    );
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    _throwIfRateLimited(response, '115 搜索失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 搜索失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 搜索');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 搜索失败',
    );
    final data = root['data'];
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map<String, dynamic>) _parseItem(item),
    ];
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    var pickcode = file.extra['pickcode'] ?? '';
    if (pickcode.isEmpty) {
      pickcode = await _fetchPickcode(client, credentials, file.id);
    }
    if (pickcode.isEmpty) {
      throw CloudDriveException('115 取直链失败：没有拿到文件提取码');
    }
    // 现行取链路（p115client 的 download_url_web）：POST files/download，
    // 请求体 {"pickcode": ...} 经 m115 加密作 data 字段（不传 dl——
    // dl≠0 返回的是一次性 302 地址），取链 UA 置空。响应三层剥壳：
    // 外层 AES-128-CBC + LZ4、data 字段 RSA 解密、取扁平结构 file_url
    // （{fid:{url:{url}}} 嵌套结构是 App 接口的形状，只作兜底）。
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final encrypted = m115RsaEncrypt(
      utf8.encode(jsonEncode({'pickcode': pickcode})),
    );
    final response = await _postForm(
      client,
      Uri.parse(_downloadUrl),
      {'data': encrypted},
      headers: {'User-Agent': '', 'Cookie': cookieUsed},
    );
    _throwIfRateLimited(response, '115 取直链失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 取直链失败（HTTP ${response.statusCode}）');
    }
    // 下载会话 Cookie：Set-Cookie 里 32 位 hex=32 位 hex 的那一对，
    // 有多个取最后一个；只取这一对，不带账号 Cookie。
    String? downloadCookie;
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      for (final match in _downloadCookiePattern.allMatches(setCookie)) {
        downloadCookie = match.group(0);
      }
    }
    final Uint8List plainBytes;
    try {
      plainBytes = m115ContentMaybeDecrypt(response.bodyBytes);
    } catch (_) {
      throw CloudDriveException('115 取直链失败：响应解密失败');
    }
    final root = _jsonObject(utf8.decode(plainBytes), '115 取直链');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 取直链失败',
    );
    final rawData = root['data'];
    Map<String, dynamic> dataObj;
    if (rawData is String) {
      try {
        final decoded = jsonDecode(utf8.decode(m115RsaDecrypt(rawData)));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('data 不是对象');
        }
        dataObj = decoded;
      } catch (_) {
        throw CloudDriveException('115 取直链失败：下载链接解析失败');
      }
    } else if (rawData is Map<String, dynamic>) {
      dataObj = rawData;
    } else {
      throw CloudDriveException('115 取直链失败：返回格式不对');
    }
    // 扁平结构优先，嵌套结构（App 接口形状）兜底。
    Map<String, dynamic>? entry;
    for (final value in dataObj.values) {
      if (value is Map<String, dynamic>) {
        entry = value;
        break;
      }
    }
    var url = _asString(dataObj['file_url']);
    if (url.isEmpty) {
      final nested = entry?['url'];
      if (nested is Map<String, dynamic>) url = _asString(nested['url']);
    }
    if (url.isEmpty) {
      throw CloudDriveException('115 取直链失败：服务器没有返回下载链接');
    }
    // 直链请求头契约（按 URL 的 f 参数）：取链 UA 是空，播放器必须
    // 同样发空 UA；f=3（或没给 f 时保守起见）才带下载会话 Cookie，
    // 且只带那一对——账号 Cookie 绝不发给 CDN。
    final query = Uri.tryParse(url)?.queryParameters ?? const {};
    final linkF = int.tryParse(query['f'] ?? '');
    final expiresAtMs = (int.tryParse(query['t'] ?? '') ?? 0) * 1000;
    final headers = <String, String>{'User-Agent': ''};
    if ((linkF == null || linkF == 3) && downloadCookie != null) {
      headers['Cookie'] = downloadCookie;
    }
    return CloudDirectLink(
      url: url,
      headers: headers,
      downloadCookie: downloadCookie,
      expiresAtMs: expiresAtMs,
      linkF: linkF,
      fetchUserAgent: '',
    );
  }

  Future<String> _fetchPickcode(
    http.Client client,
    CloudCredentials credentials,
    String fid,
  ) async {
    final uri = Uri.parse(_categoryUrl).replace(
      queryParameters: {'cid': fid},
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) return '';
    final root = _jsonObject(response.body, '115 文件信息');
    final pickcode = _asString(root['pick_code']);
    if (pickcode.isNotEmpty) return pickcode;
    // 文件夹 id 误传时返回的是夹内列表，取第一条的文件 id 再取一次。
    final data = root['data'];
    if (data is List && data.isNotEmpty) {
      final first = data.first;
      if (first is Map<String, dynamic>) {
        final innerFid = _asString(first['fid']);
        if (innerFid.isNotEmpty && innerFid != fid) {
          return _fetchPickcode(client, credentials, innerFid);
        }
      }
    }
    return '';
  }

  /// 账号信息：先走 my.115.com 的 nav 接口（115 网页版自己用的，
  /// user_id/昵称/头像/VIP 到期都在 data 里），解析不出再走
  /// webapi 的 user/info 备路。两路都拿不到才报错。
  Future<Pan115AccountInfo> accountInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    try {
      final response = await _get(
        client,
        Uri.parse(_navUrl).replace(
          queryParameters: {'ct': 'ajax', 'ac': 'nav'},
        ),
        headers: _authHeaders(credentials),
      );
      if (response.statusCode == 200) {
        final info = _parseAccountInfo(
          _jsonObject(response.body, '115 账号信息'),
        );
        if (info != null) return info;
      }
    } catch (_) {
      // 主路任何失败（网络/限频/返回不是 JSON/字段缺失）都往下试备路；
      // 凭证真过期的话备路的统一判读会给出过期报错并清登录态。
    }
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _get(
      client,
      Uri.parse(_userInfoUrl),
      headers: _authHeaders(credentials),
    );
    _throwIfRateLimited(response, '115 账号信息获取失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 账号信息获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 账号信息');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 账号信息获取失败',
    );
    final info = _parseAccountInfo(root);
    if (info == null) {
      throw CloudDriveException('115 账号信息获取失败：未获取到用户信息');
    }
    return info;
  }

  /// 从用户信息返回里宽容解析：data 下和顶层都找，字段名多候选。
  /// 昵称/头像/user_id 三者全空才算没拿到（转码只需要 user_id，
  /// 只有 user_id 也认）。
  Pan115AccountInfo? _parseAccountInfo(Map<String, dynamic> root) {
    final data = root['data'];
    final map = data is Map<String, dynamic> ? data : root;
    String pick(List<String> keys) {
      for (final key in keys) {
        final value = _asString(map[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final nickname = pick(['user_name', 'nick_name', 'username', 'user_nick_name']);
    var avatar = pick(['face', 'avatar', 'userface']);
    if (avatar.startsWith('//')) avatar = 'https:$avatar';
    final userId = pick(['user_id', 'uid']);
    if (nickname.isEmpty && avatar.isEmpty && userId.isEmpty) return null;
    final forever = map['forever'];
    return Pan115AccountInfo(
      userId: userId,
      nickname: nickname,
      avatarUrl: avatar,
      vipExpireSeconds: _asInt(map['expire']),
      vipForever: forever == true || forever == 1 || forever == '1',
    );
  }

  /// 容量信息（files/index_info 的 space_info）。
  Future<Pan115SpaceInfo> spaceInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _get(
      client,
      Uri.parse(_indexInfoUrl),
      headers: _authHeaders(credentials),
    );
    _throwIfRateLimited(response, '115 容量信息获取失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 容量信息获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 容量信息');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 容量信息获取失败',
    );
    final data = root['data'];
    final space = data is Map<String, dynamic> ? data['space_info'] : null;
    int sizeOf(Object? node) =>
        node is Map<String, dynamic> ? _asInt(node['size']) : 0;
    final spaceMap = space is Map<String, dynamic> ? space : null;
    final total = sizeOf(spaceMap?['all_total']);
    if (total <= 0) {
      throw CloudDriveException('115 容量信息获取失败：服务器没有返回容量');
    }
    return Pan115SpaceInfo(
      totalBytes: total,
      usedBytes: sizeOf(spaceMap?['all_use']),
      remainBytes: sizeOf(spaceMap?['all_remain']),
    );
  }

  /// 转码播放地址（安卓路，兜底用）：POST proapi 的
  /// android/2.0/video/play，请求体 {pickcode, user_id} 经 m115 加密
  /// 作 data 字段（与取直链同套加密）；响应同套剥壳，data 是 RSA
  /// 密文字符串，解开后 video_url 按 height 取最高档，再拼 &id={fid}。
  /// state 为假时只有 errno 409 也要解 data（服务端在 409 时仍给
  /// 地址）；video_url 为空时：有 queue_url 是正在转码、没有就是
  /// 没有转码版本，两种都如实报错，不假装能播。
  /// 播放契约与直链同规矩：播放 UA 必须与取地址 UA 一致
  /// （Mozilla/5.0）；f=3 时带响应 Set-Cookie 里那对下载会话 Cookie。
  Future<CloudDirectLink> transcodeLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    var pickcode = file.extra['pickcode'] ?? '';
    if (pickcode.isEmpty) {
      pickcode = await _fetchPickcode(client, credentials, file.id);
    }
    if (pickcode.isEmpty) {
      throw CloudDriveException('115 取转码地址失败：没有拿到文件提取码');
    }
    final info = await accountInfo(client, credentials);
    if (info.userId.isEmpty) {
      throw CloudDriveException('115 取转码地址失败：没能拿到账号信息，请重试');
    }
    final userIdNumber = int.tryParse(info.userId);
    final encrypted = m115RsaEncrypt(
      utf8.encode(
        jsonEncode({
          'pickcode': pickcode,
          'user_id': userIdNumber ?? info.userId,
        }),
      ),
    );
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _postForm(
      client,
      Uri.parse(_videoPlayUrl),
      {'data': encrypted},
      headers: {'User-Agent': pan115TranscodeUserAgent, 'Cookie': cookieUsed},
    );
    _throwIfRateLimited(response, '115 取转码地址失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 取转码地址失败（HTTP ${response.statusCode}）');
    }
    String? downloadCookie;
    final setCookie = response.headers['set-cookie'];
    if (setCookie != null) {
      for (final match in _downloadCookiePattern.allMatches(setCookie)) {
        downloadCookie = match.group(0);
      }
    }
    final Uint8List plainBytes;
    try {
      plainBytes = m115ContentMaybeDecrypt(response.bodyBytes);
    } catch (_) {
      throw CloudDriveException('115 取转码地址失败：响应解密失败');
    }
    final root = _jsonObject(utf8.decode(plainBytes), '115 取转码地址');
    if (!_stateOk(root) && _errnoOf(root) != 409) {
      // 过期三码在这里面会被判成过期并清登录态，其余按接口报错抛。
      _checkState(
        root,
        cookieUsed: cookieUsed,
        generation: generation,
        what: '115 取转码地址失败',
      );
      throw CloudDriveException('115 取转码地址失败：接口报错');
    }
    final rawData = root['data'];
    if (rawData is! String) {
      throw CloudDriveException('115 取转码地址失败：服务器没有返回转码地址');
    }
    Map<String, dynamic> dataObj;
    try {
      final decoded = jsonDecode(utf8.decode(m115RsaDecrypt(rawData)));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('data 不是对象');
      }
      dataObj = decoded;
    } catch (_) {
      throw CloudDriveException('115 取转码地址失败：转码地址解析失败');
    }
    return buildPan115TranscodeLink(
      dataObj,
      fileId: file.id,
      downloadCookie: downloadCookie,
    );
  }

  /// 上传信息：user_id/userkey 是 initupload 签名的必需品。
  /// 返回可能是 data 包裹也可能是扁平的，两种都认；
  /// upload_allowed 字段缺失时当允许（服务端真不让传时 init 会报错）。
  Future<Pan115UploadInfo> uploadInfo(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    final generation = _sessionGeneration;
    final cookieUsed = credentials.fields['cookie'] ?? '';
    final response = await _get(
      client,
      Uri.parse(_uploadInfoUrl),
      headers: _authHeaders(credentials),
    );
    _throwIfRateLimited(response, '115 上传信息获取失败');
    if (response.statusCode != 200) {
      throw CloudDriveException('115 上传信息获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 上传信息');
    _checkState(
      root,
      cookieUsed: cookieUsed,
      generation: generation,
      what: '115 上传信息获取失败',
    );
    final data = root['data'];
    final map = data is Map<String, dynamic> ? data : root;
    final userId = _asString(map['user_id']);
    final userKey = _asString(map['userkey']);
    if (userId.isEmpty || userKey.isEmpty) {
      throw CloudDriveException('115 上传信息获取失败：服务器返回异常');
    }
    var allowed = true;
    if (map.containsKey('upload_allowed')) {
      final raw = map['upload_allowed'];
      allowed = raw == true || raw == 1 || raw == '1' || raw == 'true';
    }
    return Pan115UploadInfo(
      userId: userId,
      userKey: userKey,
      sizeLimit: _asInt(map['size_limit']),
      uploadAllowed: allowed,
      uploadAllowedMsg: _asString(map['upload_allowed_msg']),
    );
  }

  /// 秒传初始化：POST uplb 的 initupload，body 是 AES 加密后的表单
  /// （cloud_115_upload 的 buildPan115UploadPayload），k_ec 必须 URL
  /// 编码后拼进查询串（Base64 里的 + 裸拼会被当空格）。偶尔回
  /// HTTP 401，重试一次。statuscode 0 或 701 都算成功。
  Future<Pan115UploadInit> uploadInit(
    http.Client client,
    CloudCredentials credentials, {
    required Pan115UploadInfo info,
    required String fileId,
    required String fileName,
    required int fileSize,
    required String target,
    String signKey = '',
    String signVal = '',
    int? timestampSeconds,
  }) async {
    final payload = buildPan115UploadPayload(
      userId: info.userId,
      userKey: info.userKey,
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      target: target,
      signKey: signKey,
      signVal: signVal,
      appVersion: pan115UploadAppVersion,
      timestampSeconds:
          timestampSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final uri = Uri.parse(
      '$_initUploadUrl?k_ec=${Uri.encodeQueryComponent(payload.kEc)}',
    );
    final headers = {
      'User-Agent': pan115UploadUserAgent,
      'Content-Type': 'application/x-www-form-urlencoded',
      'Cookie': credentials.fields['cookie'] ?? '',
    };
    var response = await client
        .post(uri, headers: headers, body: payload.body)
        .timeout(_requestTimeout);
    if (response.statusCode == 401) {
      response = await client
          .post(uri, headers: headers, body: payload.body)
          .timeout(_requestTimeout);
    }
    if (response.statusCode != 200) {
      throw CloudDriveException('115 上传初始化失败（HTTP ${response.statusCode}）');
    }
    final Uint8List plainBytes;
    try {
      plainBytes = m115ContentMaybeDecrypt(response.bodyBytes);
    } catch (_) {
      throw CloudDriveException('115 上传初始化失败：响应解密失败');
    }
    final root = _jsonObject(utf8.decode(plainBytes), '115 上传初始化');
    final statusCode = _asInt(root['statuscode']);
    if (statusCode != 0 && statusCode != 701) {
      final msg = _asString(root['statusmsg']);
      throw CloudDriveException(
        msg.isNotEmpty
            ? '115 上传初始化失败：$msg'
            : '115 上传初始化失败（错误码 $statusCode）',
      );
    }
    final callback = root['callback'];
    final callbackMap = callback is Map<String, dynamic> ? callback : null;
    return Pan115UploadInit(
      status: _asInt(root['status']),
      signKey: _asString(root['sign_key']),
      signCheck: _asString(root['sign_check']),
      bucket: _asString(root['bucket']),
      objectKey: _asString(root['object']),
      callback: _asString(callbackMap?['callback']),
      callbackVar: _asString(callbackMap?['callback_var']),
    );
  }

  /// OSS 临时凭证：不带任何鉴权头取（带了反而可能被拒），
  /// 有效期约 1 小时，上传会话里现取现用、403 时刷新。
  Future<Pan115OssToken> fetchOssToken(http.Client client) async {
    final response = await client
        .get(Uri.parse(_ossTokenUrl))
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw CloudDriveException('115 上传凭证获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '115 上传凭证');
    if (_asString(root['StatusCode']) != '200') {
      throw CloudDriveException('115 上传凭证获取失败');
    }
    final token = Pan115OssToken(
      accessKeyId: _asString(root['AccessKeyId']),
      accessKeySecret: _asString(root['AccessKeySecret']),
      securityToken: _asString(root['SecurityToken']),
    );
    if (token.accessKeyId.isEmpty ||
        token.accessKeySecret.isEmpty ||
        token.securityToken.isEmpty) {
      throw CloudDriveException('115 上传凭证获取失败：服务器返回异常');
    }
    return token;
  }

  /// 上传一份内存字节到指定文件夹（小内容与单测用；界面层走
  /// [uploadLocalFile] 流式读本地文件）。编排与流式版共用
  /// [_uploadFromSource]。
  Future<void> uploadFile(
    http.Client client,
    CloudCredentials credentials, {
    required String fileName,
    required List<int> bytes,
    required String targetFolderId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) {
    return _uploadFromSource(
      client,
      credentials,
      fileName: fileName,
      source: MemoryPan115UploadSource(bytes),
      targetFolderId: targetFolderId,
      onProgress: onProgress,
    );
  }

  /// 上传本地文件到指定文件夹（界面层入口）：全程流式读——全文件
  /// SHA1 边读边算、二次校验只读校验区间、OSS 分片按片读，整文件
  /// 不进内存，几个 GB 的文件也能传。[fileName] 不给时用文件
  /// 本身的名字。文件读不到时抛干净的中文错，不带文件路径原文。
  Future<void> uploadLocalFile(
    http.Client client,
    CloudCredentials credentials, {
    required File file,
    String? fileName,
    required String targetFolderId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    final int length;
    try {
      length = await file.length();
    } on FileSystemException {
      throw CloudDriveException('读取所选文件失败，请重新选择文件');
    }
    try {
      await _uploadFromSource(
        client,
        credentials,
        fileName: fileName ?? file.uri.pathSegments.last,
        source: FilePan115UploadSource(file, length),
        targetFolderId: targetFolderId,
        onProgress: onProgress,
      );
    } on FileSystemException {
      throw CloudDriveException('读取所选文件失败，请重新选择文件');
    }
  }

  /// 上传编排（内存/流式共用）：全文件 SHA1 → uploadinfo（不允许/
  /// 超限先拦）→ initupload（status 7 带 sign_check 区间 SHA1 再
  /// init 一次；status 2 秒传完成）→ OSS 分片（10MB 串行、单片
  /// 重试 3 次、403 刷新凭证）→ complete 带回调登记。任何一步
  /// 失败都如实抛错，不假成功；OSS 阶段失败会尽力 abort 已开的
  /// 分片会话。
  Future<void> _uploadFromSource(
    http.Client client,
    CloudCredentials credentials, {
    required String fileName,
    required Pan115UploadSource source,
    required String targetFolderId,
    void Function(int sentBytes, int totalBytes)? onProgress,
  }) async {
    if (source.length == 0) {
      throw CloudDriveException('文件为空，无法上传');
    }
    final fileId = await source.sha1All();
    final info = await uploadInfo(client, credentials);
    if (!info.uploadAllowed) {
      throw CloudDriveException(
        info.uploadAllowedMsg.isNotEmpty
            ? info.uploadAllowedMsg
            : '当前账号不允许上传',
      );
    }
    if (info.sizeLimit > 0 && source.length > info.sizeLimit) {
      throw CloudDriveException('文件超过大小限制（上限 ${info.sizeLimit} 字节）');
    }
    final target = 'U_1_$targetFolderId';
    var init = await uploadInit(
      client,
      credentials,
      info: info,
      fileId: fileId,
      fileName: fileName,
      fileSize: source.length,
      target: target,
    );
    if (init.status == 7) {
      final range = _parseSignCheck(init.signCheck);
      if (range == null || range.$1 >= source.length) {
        throw CloudDriveException('115 上传初始化失败：服务器返回的校验区间无法解析');
      }
      final end = range.$2 >= source.length ? source.length - 1 : range.$2;
      final signVal = await source.sha1Range(range.$1, end);
      init = await uploadInit(
        client,
        credentials,
        info: info,
        fileId: fileId,
        fileName: fileName,
        fileSize: source.length,
        target: target,
        signKey: init.signKey,
        signVal: signVal,
      );
    }
    if (init.status == 2) return; // 秒传成功，文件已经在网盘里了。
    if (init.status != 1) {
      throw CloudDriveException('115 上传初始化失败：服务器返回了未知状态（${init.status}）');
    }
    if (init.bucket.isEmpty || init.objectKey.isEmpty) {
      throw CloudDriveException('115 上传初始化失败：服务器没有返回存储位置');
    }
    // 回调为空就算分片传完文件也不会登记进网盘，那种「成功」是假的。
    if (init.callback.isEmpty || init.callbackVar.isEmpty) {
      throw CloudDriveException('115 上传初始化失败：服务器没有返回上传回调');
    }
    final totalParts =
        (source.length + pan115OssPartSize - 1) ~/ pan115OssPartSize;
    if (totalParts > 10000) {
      throw CloudDriveException('文件太大，单次上传最多 10000 个分片');
    }
    final oss = Pan115OssClient(client);
    var token = await fetchOssToken(client);
    String? uploadId;
    try {
      uploadId = await oss.initMultipart(token, init.bucket, init.objectKey);
      final parts = <Pan115OssPart>[];
      for (var i = 0; i < totalParts; i++) {
        final start = i * pan115OssPartSize;
        final end = start + pan115OssPartSize > source.length
            ? source.length
            : start + pan115OssPartSize;
        final partBytes = await source.readRange(start, end);
        String? etag;
        Pan115OssException? lastError;
        var refreshed = false;
        for (var attempt = 0; attempt < 3 && etag == null; attempt++) {
          try {
            etag = await oss.uploadPart(
              token,
              init.bucket,
              init.objectKey,
              uploadId,
              i + 1,
              partBytes,
            );
          } on Pan115OssException catch (e) {
            lastError = e;
            if (e.httpCode == 403 && !refreshed) {
              refreshed = true;
              token = await fetchOssToken(client);
            }
          }
        }
        if (etag == null) {
          throw CloudDriveException(
            '115 上传分片 ${i + 1} 失败：${lastError?.message ?? '未知错误'}',
          );
        }
        parts.add(Pan115OssPart(partNumber: i + 1, etag: etag));
        onProgress?.call(end, source.length);
      }
      try {
        await oss.completeMultipart(
          token,
          init.bucket,
          init.objectKey,
          uploadId,
          parts,
          init.callback,
          init.callbackVar,
        );
      } on Pan115OssException catch (e) {
        if (e.httpCode != 403) rethrow;
        // 凭证可能刚好在 complete 前过期：刷新一次再试。
        token = await fetchOssToken(client);
        await oss.completeMultipart(
          token,
          init.bucket,
          init.objectKey,
          uploadId,
          parts,
          init.callback,
          init.callbackVar,
        );
      }
    } on Pan115OssException catch (e) {
      if (uploadId != null) {
        await oss.abortMultipart(token, init.bucket, init.objectKey, uploadId);
      }
      throw CloudDriveException(e.message);
    } catch (_) {
      if (uploadId != null) {
        await oss.abortMultipart(token, init.bucket, init.objectKey, uploadId);
      }
      rethrow;
    }
  }

  /// sign_check 的 "start-end"（闭区间）解析；解析不了返回 null。
  (int, int)? _parseSignCheck(String text) {
    final parts = text.split('-');
    if (parts.length != 2) return null;
    final start = int.tryParse(parts[0].trim());
    final end = int.tryParse(parts[1].trim());
    if (start == null || end == null || start < 0 || end < start) return null;
    return (start, end);
  }
}

// ---------------------------------------------------------------------------
// 夸克网盘
// ---------------------------------------------------------------------------

class QuarkProvider implements CloudDriveProvider {
  @override
  String get id => 'quark';
  @override
  String get displayName => '夸克网盘';
  @override
  String get appName => '夸克 App';
  @override
  String get rootFolderId => '0';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';
  static const _tokenUrl =
      'https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin';
  static const _ticketUrl =
      'https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken';
  static const _loginUrl = 'https://pan.quark.cn/desktop/account/login';
  static const _fileListUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/sort';
  static const _downloadUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/download';
  static const _playUrl =
      'https://drive-pc.quark.cn/1/clouddrive/file/v2/play';
  static const _pageSize = 50;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final requestId = _uuidV4();
    final uri = Uri.parse(_tokenUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'client_id': '386',
        'v': '1.2',
        'request_id': requestId,
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('夸克二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '夸克二维码参数');
    final token = _asString(
      ((root['data'] as Map?)?['members'] as Map?)?['token'],
    );
    if (token.isEmpty) {
      throw CloudDriveException('夸克二维码参数获取失败：缺少 token');
    }
    final qrUrl =
        'https://su.quark.cn/4_eMHBJ?token=$token&client_id=386'
        '&sch=pckk@other_ch&sve=3.1.8&ssb=weblogin&uc_param_str='
        '&uc_biz_str=S:custom|OPT:SAREA@0|OPT:IMMERSIVE@1|OPT:BACK_BTN_STYLE@0';
    return QrLoginSession(
      qrContent: qrUrl,
      qrImageUrl: '',
      message: '请用夸克 App 扫码确认',
      state: {'requestId': requestId, 'token': token},
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uri = Uri.parse(_ticketUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'client_id': '386',
        'v': '1.2',
        'request_id': session.state['requestId'] ?? '',
        'token': session.state['token'] ?? '',
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待夸克 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '夸克扫码状态');
    final message = _asString(root['message']);
    final ticket = _asString(
      ((root['data'] as Map?)?['members'] as Map?)?['service_ticket'],
    );
    if (!message.contains('ok') || ticket.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待夸克 App 扫码确认',
      );
    }
    final loginUri = Uri.parse(_loginUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'sys': 'win32',
        'st': ticket,
      },
    );
    final loginResponse = await _get(
      client,
      loginUri,
      headers: {'User-Agent': _ua},
    );
    final cookie = mergeCookieHeader('', loginResponse.headers['set-cookie']);
    if (cookie.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '夸克登录失败：没有拿到登录凭证',
      );
    }
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': cookie},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '夸克网盘登录成功',
    );
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final uri = Uri.parse(_fileListUrl).replace(
      queryParameters: {
        'pr': 'ucpro',
        'fr': 'pc',
        'uc_param_str': '',
        'pdir_fid': folderId,
        '_page': '$page',
        '_size': '$_pageSize',
        '_fetch_total': '1',
        '_fetch_sub_dirs': '0',
        '_sort': 'file_type:asc,updated_at:desc',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('夸克文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '夸克文件列表');
    final data = root['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('夸克文件列表获取失败：返回格式不对');
    }
    final list = data['list'];
    final files = <CloudDriveFile>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    final total = _asInt(data['total'], -1);
    final hasMore = total >= 0
        ? (page - 1) * _pageSize + files.length < total
        : files.length >= _pageSize;
    return CloudFolderPage(files: files, hasMore: hasMore, total: total);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = item['file'] == false;
    final name = _asString(item['file_name']);
    final duration = item['duration'] is num
        ? (item['duration'] as num).toInt()
        : null;
    final kind = classifyCloudFile(name: name, isFolder: isFolder);
    return CloudDriveFile(
      id: _asString(item['fid']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: _asInt(item['updated_at']) * 1000,
      durationSeconds: duration,
      thumbnailUrl: _asString(item['thumbnail']),
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    // 夸克没有公开的站内搜索接口，走引擎的“取列表后按名过滤”兜底。
    throw UnsupportedError('夸克网盘没有站方搜索接口');
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final headers = _authHeaders(credentials);
    // 先取原文件直链。
    final downloadUri = Uri.parse(_downloadUrl).replace(
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
    );
    try {
      final response = await _postJson(
        client,
        downloadUri,
        {
          'fids': [file.id],
        },
        headers: headers,
      );
      if (response.statusCode == 200) {
        final root = _jsonObject(response.body, '夸克直链');
        final data = root['data'];
        if (data is List && data.isNotEmpty) {
          final first = data.first;
          if (first is Map<String, dynamic>) {
            final url = _asString(first['download_url']);
            if (url.isNotEmpty) {
              return CloudDirectLink(url: url, headers: headers);
            }
          }
        }
      }
    } catch (_) {
      // 直链接口失败时落到转码流兜底。
    }
    // 兜底：转码播放接口（仍是直链数据，不嵌网页播放器）。
    final playUri = Uri.parse(_playUrl).replace(
      queryParameters: {'pr': 'ucpro', 'fr': 'pc'},
    );
    final playResponse = await _postJson(
      client,
      playUri,
      {
        'fid': file.id,
      },
      headers: headers,
    );
    if (playResponse.statusCode != 200) {
      throw CloudDriveException('夸克取直链失败（HTTP ${playResponse.statusCode}）');
    }
    final root = _jsonObject(playResponse.body, '夸克转码播放');
    final videoList = (root['data'] as Map?)?['video_list'];
    if (videoList is List) {
      for (final entry in videoList) {
        if (entry is Map<String, dynamic>) {
          final info = entry['video_info'];
          if (info is Map<String, dynamic>) {
            final url = _asString(info['url']);
            if (url.isNotEmpty) {
              return CloudDirectLink(
                url: url,
                headers: headers,
                isTranscoded: true,
              );
            }
          }
        }
      }
    }
    throw CloudDriveException('夸克取直链失败：没有返回可播地址');
  }
}

// ---------------------------------------------------------------------------
// 百度网盘
// ---------------------------------------------------------------------------

class BaiduProvider implements CloudDriveProvider {
  @override
  String get id => 'baidu';
  @override
  String get displayName => '百度网盘';
  @override
  String get appName => '百度网盘 App';
  @override
  String get rootFolderId => '/';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';
  static const _qrCodeUrl = 'https://passport.baidu.com/v2/api/getqrcode';
  static const _channelUrl = 'https://passport.baidu.com/channel/unicast';
  static const _qrLoginUrl =
      'https://passport.baidu.com/v3/login/main/qrbdusslogin';
  static const _xpanUrl = 'https://pan.baidu.com/rest/2.0/xpan/file';
  static const _pcsUrl = 'https://pcs.baidu.com/rest/2.0/pcs/file';
  static const _pageSize = 100;

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final gid = _uuidV4().toUpperCase();
    final tangramGuid = DateTime.now().millisecondsSinceEpoch.toString();
    final tt = DateTime.now().millisecondsSinceEpoch.toString();
    final uri = Uri.parse(_qrCodeUrl).replace(
      queryParameters: {
        'lp': 'pc',
        'qrloginfrom': 'pc',
        'gid': gid,
        'callback': 'tangram_guid_$tangramGuid',
        'apiver': 'v3',
        'tt': tt,
        'tpl': 'netdisk',
        'logPage': '',
      },
    );
    final response = await _get(client, uri, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('百度二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    // 返回是 JSONP：tangram_guid_xxx({...})，取括号里的 JSON。
    final body = response.body;
    final start = body.indexOf('{');
    final end = body.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw CloudDriveException('百度二维码参数获取失败：返回格式不对');
    }
    final root = _jsonObject(body.substring(start, end + 1), '百度二维码参数');
    final sign = _asString(root['sign']);
    final imgurl = _asString(root['imgurl']);
    if (sign.isEmpty || imgurl.isEmpty) {
      throw CloudDriveException('百度二维码参数获取失败：缺少 sign 或二维码图');
    }
    final cookie = mergeCookieHeader('', response.headers['set-cookie']);
    return QrLoginSession(
      qrContent: '',
      qrImageUrl: imgurl.startsWith('http') ? imgurl : 'https://$imgurl',
      message: '请用百度网盘 App 扫码确认',
      state: {
        'gid': gid,
        'sign': sign,
        'tangramGuid': tangramGuid,
        'cookie': cookie,
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final nonce = (DateTime.now().millisecondsSinceEpoch * 1000 + 3000).toString();
    final uri = Uri.parse(_channelUrl).replace(
      queryParameters: {
        'channel_id': session.state['sign'] ?? '',
        'gid': session.state['gid'] ?? '',
        'tpl': 'netdisk',
        '_sdkFrom': '1',
        'callback': 'tangram_guid_${session.state['tangramGuid'] ?? ''}',
        'apiver': 'v3',
        'tt': nonce,
        '_': nonce,
      },
    );
    final cookie = session.state['cookie'] ?? '';
    final response = await _get(
      client,
      uri,
      headers: {'User-Agent': _ua, if (cookie.isNotEmpty) 'Cookie': cookie},
    );
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待百度网盘 App 扫码确认',
      );
    }
    final match = RegExp(r'\\"v\\":\\"([a-f0-9]{32})\\"').firstMatch(response.body);
    final bdussValue = match?.group(1) ?? '';
    if (bdussValue.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待百度网盘 App 扫码确认',
      );
    }
    return _finishLogin(client, session, bdussValue, nonce);
  }

  Future<QrPollResult> _finishLogin(
    http.Client client,
    QrLoginSession session,
    String bdussValue,
    String nonce,
  ) async {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final uri = Uri.parse(_qrLoginUrl).replace(
      queryParameters: {
        'v': nonce,
        'bduss': bdussValue,
        'u':
            'https%3A%2F%2Fpan.baidu.com%2Fdisk%2Fmain%23%2Findex%3Fcategory%3Dall',
        'loginVersion': 'v5',
        'qrcode': '1',
        'tpl': 'netdisk',
        'maskId': '',
        'fileId': '',
        'apiver': 'v3',
        'tt': nonce,
        'traceid': '',
        'time': '$seconds',
        'alg': 'v3',
        'elapsed': '1',
        'callback': 'bd__cbs__tro4ll',
      },
    );
    final cookie = session.state['cookie'] ?? '';
    final request = http.Request('GET', uri)
      ..headers.addAll({
        'User-Agent': _ua,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      })
      ..followRedirects = false;
    final streamed = await client.send(request).timeout(_requestTimeout);
    var body = '';
    if (streamed.statusCode == 302) {
      final location = streamed.headers['location'];
      await streamed.stream.listen(null).cancel().catchError((_) {});
      if (location != null && location.isNotEmpty) {
        final follow = await _get(
          client,
          uri.resolve(location),
          headers: {'User-Agent': _ua, if (cookie.isNotEmpty) 'Cookie': cookie},
        );
        body = follow.body;
      }
    } else {
      body = await streamed.stream.bytesToString().timeout(_requestTimeout);
    }
    final match = RegExp(r'bd__cbs__tro4ll\((.*?)\)').firstMatch(body);
    if (match == null) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：没有拿到会话信息',
      );
    }
    final root = _jsonObject(match.group(1)!, '百度登录会话');
    final data = root['data'];
    final sessionMap = data is Map<String, dynamic> ? data['session'] : null;
    if (sessionMap is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：会话格式不对',
      );
    }
    final ubi = _asString(sessionMap['ubi']);
    final stoken = _asString(sessionMap['stoken']);
    final bduss = _asString(sessionMap['bduss']);
    final ptoken = _asString(sessionMap['ptoken']);
    if (bduss.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '百度登录失败：缺少 BDUSS',
      );
    }
    final jar = <String, String>{};
    for (final part in cookie.split(';')) {
      final trimmed = part.trim();
      final eq = trimmed.indexOf('=');
      if (eq > 0) jar[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
    }
    jar.addAll({
      'newlogin': '1',
      'UBI': ubi,
      'STOKEN': stoken,
      'BDUSS': bduss,
      'PTOKEN': ptoken,
      'BDUSS_BFESS': bduss,
      'STOKEN_BFESS': stoken,
      'PTOKEN_BFESS': ptoken,
      'UBI_BFESS': ubi,
    });
    final fullCookie = jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: CloudCredentials(
        fields: {'cookie': fullCookie},
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
      message: '百度网盘登录成功',
    );
  }

  Map<String, String> _authHeaders(CloudCredentials credentials) => {
    'User-Agent': _ua,
    'Cookie': credentials.fields['cookie'] ?? '',
  };

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final uri = Uri.parse(_xpanUrl).replace(
      queryParameters: {
        'method': 'list',
        'dir': folderId,
        'order': 'name',
        'desc': '0',
        'showempty': '0',
        'web': '1',
        'page': '$page',
        'num': '$_pageSize',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('百度文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '百度文件列表');
    if (_asInt(root['errno'], 0) != 0) {
      throw CloudDriveException('百度文件列表获取失败：${_asString(root['errmsg'], '接口报错')}');
    }
    final list = root['list'];
    final files = <CloudDriveFile>[];
    if (list is List) {
      for (final item in list) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    return CloudFolderPage(files: files, hasMore: files.length >= _pageSize);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = _asInt(item['isdir']) == 1;
    final name = _asString(item['server_filename']);
    // 百度 category：1 视频 / 2 音频 / 3 图片（最佳推测，扩展名兜底）。
    CloudFileKind? hint;
    switch (_asInt(item['category'])) {
      case 1:
        hint = CloudFileKind.video;
      case 2:
        hint = CloudFileKind.audio;
      case 3:
        hint = CloudFileKind.image;
    }
    final kind = classifyCloudFile(name: name, isFolder: isFolder, providerHint: hint);
    var thumb = '';
    final thumbs = item['thumbs'];
    if (thumbs is Map<String, dynamic>) {
      thumb = _asString(thumbs['url3']);
      if (thumb.isEmpty) thumb = _asString(thumbs['url2']);
      if (thumb.isEmpty) thumb = _asString(thumbs['url1']);
    }
    return CloudDriveFile(
      id: _asString(item['fs_id']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: _asInt(item['server_mtime']) * 1000,
      thumbnailUrl: thumb,
      extra: {'path': _asString(item['path'])},
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    final uri = Uri.parse(_xpanUrl).replace(
      queryParameters: {
        'method': 'search',
        'key': keyword,
        'dir': folderId,
        'recursion': '1',
        'web': '1',
        'page': '1',
        'num': '$_pageSize',
      },
    );
    final response = await _get(client, uri, headers: _authHeaders(credentials));
    if (response.statusCode != 200) {
      throw CloudDriveException('百度搜索失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '百度搜索');
    final list = root['list'];
    if (list is! List) return const [];
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) _parseItem(item),
    ];
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final path = file.extra['path'] ?? '';
    if (path.isEmpty) {
      throw CloudDriveException('百度取直链失败：缺少文件路径');
    }
    final uri = Uri.parse(_pcsUrl).replace(
      queryParameters: {
        'method': 'download',
        'app_id': '250528',
        'path': path,
      },
    );
    final request = http.Request('GET', uri)..headers.addAll(_authHeaders(credentials));
    final resolved = await resolveRedirects(client, request);
    return CloudDirectLink(url: resolved.url, headers: _authHeaders(credentials));
  }
}

// ---------------------------------------------------------------------------
// 阿里云盘（公开 OpenAPI 协议；TVBox_Web 里没有这家，全程标注未实测）
// ---------------------------------------------------------------------------

class AliyunProvider implements CloudDriveProvider {
  @override
  String get id => 'aliyun';
  @override
  String get displayName => '阿里云盘';
  @override
  String get appName => '阿里云盘 App';
  @override
  String get rootFolderId => 'root';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;

  static const _generateUrl =
      'https://passport.aliyundrive.com/newlogin/qrcode/generate.do';
  static const _queryUrl =
      'https://passport.aliyundrive.com/newlogin/qrcode/query.do';
  static const _tokenUrl = 'https://auth.aliyundrive.com/v2/account/token';
  static const _listUrl =
      'https://open.aliyundrive.com/adrive/v1.0/openFile/list';
  static const _downloadUrl =
      'https://open.aliyundrive.com/adrive/v1.0/openFile/getDownloadUrl';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36';

  /// 分页 marker 缓存：folderId -> 按页存的 marker（第 N 页用第 N-1 个）。
  final Map<String, List<String>> _markers = {};

  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    final uri = Uri.parse(_generateUrl).replace(
      queryParameters: {
        'appName': 'aliyun_drive',
        'fromSite': '52',
        'appEntrance': 'web',
      },
    );
    final response = await _postJson(client, uri, {
      'appName': 'aliyun_drive',
      'appEntrance': 'web',
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里二维码参数获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里二维码参数');
    final data = (root['content'] as Map?)?['data'];
    if (data is! Map<String, dynamic>) {
      throw CloudDriveException('阿里二维码参数获取失败：返回格式不对');
    }
    final codeContent = _asString(data['codeContent']);
    if (codeContent.isEmpty) {
      throw CloudDriveException('阿里二维码参数获取失败：缺少二维码内容');
    }
    return QrLoginSession(
      qrContent: codeContent,
      qrImageUrl: '',
      message: '请用阿里云盘 App 扫码确认',
      state: {
        't': _asString(data['t']),
        'ck': _asString(data['ck']),
      },
      expiresAt: DateTime.now().add(const Duration(seconds: 120)),
    );
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    final uri = Uri.parse(_queryUrl).replace(
      queryParameters: {
        'appName': 'aliyun_drive',
        'fromSite': '52',
      },
    );
    final response = await _postJson(client, uri, {
      't': session.state['t'] ?? '',
      'ck': session.state['ck'] ?? '',
      'appName': 'aliyun_drive',
      'appEntrance': 'web',
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待阿里云盘 App 扫码确认',
      );
    }
    final root = _jsonObject(response.body, '阿里扫码状态');
    final data = (root['content'] as Map?)?['data'];
    if (data is! Map<String, dynamic>) {
      return const QrPollResult(
        status: QrPollStatus.waiting,
        message: '等待阿里云盘 App 扫码确认',
      );
    }
    final status = _asString(data['status']);
    switch (status) {
      case 'LOGINED':
        return _finishLogin(client, data);
      case 'EXPIRED':
        return const QrPollResult(
          status: QrPollStatus.expired,
          message: '二维码已过期，请重新获取',
        );
      case 'SCANED':
        return const QrPollResult(
          status: QrPollStatus.scanned,
          message: '已扫码，请在阿里云盘 App 内确认登录',
        );
      default:
        return const QrPollResult(
          status: QrPollStatus.waiting,
          message: '等待阿里云盘 App 扫码确认',
        );
    }
  }

  Future<QrPollResult> _finishLogin(
    http.Client client,
    Map<String, dynamic> data,
  ) async {
    final bizExt = data['bizExt'];
    final loginResultRaw = bizExt is Map<String, dynamic>
        ? bizExt['pds_login_result']
        : null;
    Map<String, dynamic>? loginResult;
    if (loginResultRaw is String) {
      final decoded = jsonDecode(loginResultRaw);
      if (decoded is Map<String, dynamic>) loginResult = decoded;
    } else if (loginResultRaw is Map<String, dynamic>) {
      loginResult = loginResultRaw;
    }
    final refreshToken = _asString(loginResult?['refreshToken']);
    if (refreshToken.isEmpty) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '阿里登录失败：没有拿到刷新凭证',
      );
    }
    final credentials = await _exchangeToken(client, refreshToken);
    if (credentials == null) {
      return const QrPollResult(
        status: QrPollStatus.failed,
        message: '阿里登录失败：换取访问凭证失败',
      );
    }
    return QrPollResult(
      status: QrPollStatus.success,
      credentials: credentials,
      message: '阿里云盘登录成功',
    );
  }

  /// 手动粘贴 refresh_token 登录（单手机用户扫不了自己屏幕时的兜底）：
  /// 用 refresh_token 换 access_token + drive_id，失败返回 null。
  Future<CloudCredentials?> credentialsFromRefreshToken(
    http.Client client,
    String refreshToken,
  ) =>
      _exchangeToken(client, refreshToken.trim());

  Future<CloudCredentials?> _exchangeToken(
    http.Client client,
    String refreshToken,
  ) async {
    final response = await _postJson(client, Uri.parse(_tokenUrl), {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
    }, headers: {'User-Agent': _ua});
    if (response.statusCode != 200) return null;
    final root = _jsonObject(response.body, '阿里换取凭证');
    final accessToken = _asString(root['access_token']);
    final newRefresh = _asString(root['refresh_token']);
    final driveId = _asString(root['default_drive_id']);
    if (accessToken.isEmpty || newRefresh.isEmpty || driveId.isEmpty) {
      return null;
    }
    return CloudCredentials(
      fields: {
        'refresh_token': newRefresh,
        'access_token': accessToken,
        'drive_id': driveId,
      },
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 带一次 401 续期重试的请求：续期成功后通知引擎落盘新凭证。
  Future<http.Response> _withAuth(
    http.Client client,
    CloudCredentials credentials,
    Future<http.Response> Function(String accessToken) run,
  ) async {
    var accessToken = credentials.fields['access_token'] ?? '';
    var response = await run(accessToken);
    if (response.statusCode == 401) {
      final refreshed = await _exchangeToken(
        client,
        credentials.fields['refresh_token'] ?? '',
      );
      if (refreshed != null) {
        onCredentialsRefreshed?.call(id, refreshed);
        accessToken = refreshed.fields['access_token'] ?? '';
        response = await run(accessToken);
      }
    }
    return response;
  }

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final driveId = credentials.fields['drive_id'] ?? '';
    final markers = _markers.putIfAbsent(folderId, () => []);
    final marker = page > 1 && markers.length >= page - 1
        ? markers[page - 2]
        : '';
    final body = <String, dynamic>{
      'drive_id': driveId,
      'parent_file_id': folderId,
      'limit': 100,
      'order_by': 'name',
      'order_direction': 'ASC',
      if (marker.isNotEmpty) 'marker': marker,
    };
    final response = await _withAuth(
      client,
      credentials,
      (token) => _postJson(
        client,
        Uri.parse(_listUrl),
        body,
        headers: {'Authorization': 'Bearer $token', 'User-Agent': _ua},
      ),
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里文件列表获取失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里文件列表');
    final items = root['items'];
    final files = <CloudDriveFile>[];
    if (items is List) {
      for (final item in items) {
        if (item is Map<String, dynamic>) files.add(_parseItem(item));
      }
    }
    final nextMarker = _asString(root['next_marker']);
    if (nextMarker.isNotEmpty) {
      while (markers.length < page) {
        markers.add('');
      }
      markers[page - 1] = nextMarker;
    }
    return CloudFolderPage(files: files, hasMore: nextMarker.isNotEmpty);
  }

  CloudDriveFile _parseItem(Map<String, dynamic> item) {
    final isFolder = _asString(item['type']) == 'folder';
    final name = _asString(item['name']);
    CloudFileKind? hint;
    switch (_asString(item['category'])) {
      case 'video':
        hint = CloudFileKind.video;
      case 'audio':
        hint = CloudFileKind.audio;
      case 'image':
        hint = CloudFileKind.image;
    }
    final kind = classifyCloudFile(name: name, isFolder: isFolder, providerHint: hint);
    int? duration;
    final meta = item['video_media_metadata'];
    if (meta is Map<String, dynamic> && meta['duration'] is num) {
      duration = (meta['duration'] as num).toInt();
    }
    var modifiedMs = 0;
    final updated = _asString(item['updated_at']);
    if (updated.isNotEmpty) {
      modifiedMs = DateTime.tryParse(updated)?.millisecondsSinceEpoch ?? 0;
    }
    return CloudDriveFile(
      id: _asString(item['file_id']),
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: _asInt(item['size']),
      modifiedMs: modifiedMs,
      durationSeconds: duration,
      thumbnailUrl: _asString(item['thumbnail']),
    );
  }

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    // 阿里 OpenAPI 没有搜索接口，走引擎的“取列表后按名过滤”兜底。
    throw UnsupportedError('阿里云盘没有站方搜索接口');
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final driveId = credentials.fields['drive_id'] ?? '';
    final response = await _withAuth(
      client,
      credentials,
      (token) => _postJson(
        client,
        Uri.parse(_downloadUrl),
        {'drive_id': driveId, 'file_id': file.id},
        headers: {'Authorization': 'Bearer $token', 'User-Agent': _ua},
      ),
    );
    if (response.statusCode != 200) {
      throw CloudDriveException('阿里取直链失败（HTTP ${response.statusCode}）');
    }
    final root = _jsonObject(response.body, '阿里直链');
    final url = _asString(root['url']);
    if (url.isEmpty) {
      throw CloudDriveException('阿里取直链失败：没有返回下载地址');
    }
    return CloudDirectLink(url: url);
  }
}

// ---------------------------------------------------------------------------
// 注册表
// ---------------------------------------------------------------------------

/// 五家网盘客户端（每次调用新建实例；阿里实例带分页 marker 缓存，
/// 移动云盘实例带短信通道记忆与分页游标缓存，引擎内只建一次、复用到底）。
List<CloudDriveProvider> createCloudDriveProviders() => [
  Pan115Provider(),
  QuarkProvider(),
  AliyunProvider(),
  BaiduProvider(),
  Yun139Provider(),
];

/// 网盘 id → 显示名（界面与站点注册共用）。
const cloudDriveDisplayNames = <String, String>{
  'pan115': '115网盘',
  'quark': '夸克网盘',
  'aliyun': '阿里云盘',
  'baidu': '百度网盘',
  'yun139': '移动云盘',
};
