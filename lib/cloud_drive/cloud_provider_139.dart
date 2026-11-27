/// 移动云盘（139 云盘）的短信登录 + 文件列表 + 直链客户端。
///
/// 协议来源：TVBox_Web 的 index.js 里 new139 实现的协议事实（接口地址、
/// 请求字段、请求头、AES 信封格式、滑块页地址），本文件按协议自己实现，
/// 不抄它的代码。登录走手机号 + 短信验证码，没有扫码登录，所以
/// [CloudDriveProvider] 的扫码方法抛 [UnsupportedError]，登录中心改走
/// 本文件的短信方法（与阿里手动粘贴凭证走具体类方法的口径一致）。
///
/// 登录有两条通道，与源头一致：先走免滑块通道（AES 加密信封 + 拼图
/// 校验），触发风控/协议对不上时落到普通通道（明文 JSON，风控时弹
/// 滑块页，滑块在内嵌页里完成）。两条通道的登录响应都是 AES-128-ECB
/// 加密的十六进制字符串，各用各的密钥与格式，见信封函数注释。
///
/// 设备信息：登录时随机一台国产安卓机型（品牌/型号/系统/分辨率取自
/// 源头同一张设备表），登录成功后把设备信息随凭证一起存进
/// [CloudCredentialStore]，列表/直链/刷新都用凭证里的同一套设备信息，
/// 不每次重随机。设备信息只在登录前存在实例内存里，登录中心一次登录
/// 流程内复用同一个 provider 实例，设备不会中途换。
///
/// 未实测：短信、滑块、列表、直链、刷新五步都需真账号，均未实测，
/// 列为手机待验。列表里的缩略图与时长字段源头映射里没取（它只取了
/// id/名/大小/时间/类型），这里按它请求的 fields（thumbnailUrls、
/// mediaMetaInfo）尽力解析，形状对不上时按“没有”处理，不猜。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'cloud_aes.dart';
import 'cloud_credential_store.dart';
import 'cloud_drive_types.dart';
import 'cloud_providers.dart';

// ---------------------------------------------------------------------------
// 常量：接口地址与协议参数（源头 new139 配置的事实值）
// ---------------------------------------------------------------------------

const _appVersion = '13.1.0';
const _loginVersion = '30131040';
const _appChannel = '10000023';
const _smsUrl = 'https://user-njs.yun.139.com/user/sms/getSmsCode';
const _verifyUrl = 'https://user-njs.yun.139.com/user/verfycode';
const _loginUrl = 'https://user-njs.yun.139.com/user/thirdlogin';
const _refreshUrl = 'https://user-njs.yun.139.com/user/auth/refreshToken';
const _mineListUrl = 'https://personal-kd-njs.yun.139.com/hcy/file/list';
const _mineDownloadUrl =
    'https://personal-kd-njs.yun.139.com/hcy/file/getDownloadUrl';
const _captchaPageBase = 'https://yun.139.com/fe/captcha/?data=';
const _mineListFields =
    'thumbnailUrls,addressDetail,mediaMetaInfo,metadataAuditInfo,userTags,'
    'contentAuditInfo,starredAt,starred,localCreatedAt,localUpdatedAt';
const _minePageSize = 100;

/// 滑块通道登录响应的解密密钥（AES-128-ECB，十六进制密文，无旋转）。
const _sliderLoginKey = 'qPqDw263XgFgL3u8';

/// 免滑块通道接口信封的密钥（24 字节，走 AES-192-CBC，IV 前置）。
const _apiEnvelopeKey = '2olBaQGYnEKoStYomsd1n7ax';

/// 免滑块拼图校验数据的密钥（AES-128-CBC，IV 前置）。
const _puzzleKey = 'CREATPUZZLE03F9A';

/// 免滑块通道登录请求/响应的密钥（AES-128-ECB，密文旋转 5 字节后转 hex）。
const _noSliderLoginKey = 'gB^gGdQHX1l+XteY';

const _playUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36 115Browser/26.0.7.2';
const _playReferer = 'https://yun.139.com/';

const _authTimeout = Duration(seconds: 25);
const _dataTimeout = Duration(seconds: 15);

/// 短信通道记忆的有效期（源头 login_attempt 30 分钟过期）。
const _smsModeTtl = Duration(minutes: 30);

/// token 提前多久刷新（源头 5 分钟窗口）。
const _refreshEarlyWindow = Duration(minutes: 5);

// ---------------------------------------------------------------------------
// 设备信息
// ---------------------------------------------------------------------------

/// 一台虚拟安卓设备（品牌/型号/系统/分辨率 + 派生的两个请求头值）。
class Yun139DeviceInfo {
  const Yun139DeviceInfo({
    required this.brand,
    required this.model,
    required this.os,
    required this.screen,
    required this.deviceId,
    required this.deviceInfo,
    required this.userAgent,
  });

  final String brand;
  final String model;
  final String os;
  final String screen;
  final String deviceId;

  /// `x-DeviceInfo` / `x-yun-client-info` 头的值（`|` 分隔的设备串）。
  final String deviceInfo;

  /// `x-yun-user-agent` 头的值。
  final String userAgent;

  /// 从已存凭证里还原（只认两个头值，其余字段为空，不影响请求）。
  factory Yun139DeviceInfo.fromStored({
    required String deviceInfo,
    required String userAgent,
  }) =>
      Yun139DeviceInfo(
        brand: '',
        model: '',
        os: '',
        screen: '',
        deviceId: '',
        deviceInfo: deviceInfo,
        userAgent: userAgent,
      );

  /// 随机一台设备（源头同一张设备表 + 16 字节随机设备 id）。
  factory Yun139DeviceInfo.generate([Random? random]) {
    final rng = random ?? Random.secure();
    final entry = _deviceTable[rng.nextInt(_deviceTable.length)];
    final deviceId = [
      for (var i = 0; i < 16; i++) rng.nextInt(256),
    ].map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
    final deviceInfo = [
      '1',
      '127.0.0.1',
      '1',
      _appVersion,
      entry.$1,
      entry.$2,
      deviceId,
      '02-00-00-00-00-00',
      entry.$3,
      entry.$4,
      'zh',
      '',
      '',
      '',
      '000',
      '0',
      '',
    ].join('|');
    return Yun139DeviceInfo(
      brand: entry.$1,
      model: entry.$2,
      os: entry.$3,
      screen: entry.$4,
      deviceId: deviceId,
      deviceInfo: deviceInfo,
      userAgent: 'android|${entry.$2}|${entry.$3}|mCloud$_appVersion-000',
    );
  }
}

/// 设备表：（品牌，型号，系统，分辨率），与源头 new139 的表一致。
const _deviceTable = <(String, String, String, String)>[
  ('OPPO', 'PMT110', 'android 16', '1080X2252'),
  ('OPPO', 'PKH110', 'android 15', '1240X2772'),
  ('OPPO', 'PHZ110', 'android 14', '1080X2412'),
  ('OPPO', 'PGEM10', 'android 13', '1440X3216'),
  ('OPPO', 'CPH2521', 'android 14', '1080X2400'),
  ('vivo', 'V2303A', 'android 15', '1260X2800'),
  ('vivo', 'V2324A', 'android 14', '1260X2800'),
  ('vivo', 'V2241A', 'android 13', '1080X2400'),
  ('vivo', 'V2405A', 'android 15', '1260X2800'),
  ('vivo', 'V2338A', 'android 14', '1080X2400'),
  ('iQOO', 'V2304A', 'android 14', '1260X2800'),
  ('iQOO', 'V2329A', 'android 15', '1440X3200'),
  ('iQOO', 'V2232A', 'android 13', '1080X2400'),
  ('Xiaomi', '2211133C', 'android 14', '1220X2712'),
  ('Xiaomi', '23116PN5BC', 'android 15', '1440X3200'),
  ('Xiaomi', '24031PN0DC', 'android 14', '1200X2670'),
  ('Xiaomi', '2304FPN6DC', 'android 13', '1080X2400'),
  ('Xiaomi', '2210132C', 'android 13', '1080X2400'),
  ('Redmi', '23078RKD5C', 'android 14', '1220X2712'),
  ('Redmi', '2311DRK48C', 'android 14', '1080X2400'),
  ('Redmi', '22041216C', 'android 13', '1080X2400'),
  ('Redmi', '24069RA21C', 'android 15', '1220X2712'),
  ('HONOR', 'PGT-AN10', 'android 14', '1312X2848'),
  ('HONOR', 'BVL-AN16', 'android 15', '1280X2800'),
  ('HONOR', 'MAG-AN00', 'android 13', '1200X2664'),
  ('HONOR', 'REA-AN00', 'android 14', '1224X2700'),
  ('HONOR', 'CLK-AN00', 'android 13', '1080X2400'),
  ('HUAWEI', 'BRA-AL00', 'android 12', '1260X2800'),
  ('HUAWEI', 'ALN-AL00', 'android 12', '1212X2616'),
  ('HUAWEI', 'ADY-AL00', 'android 12', '1080X2388'),
  ('HUAWEI', 'MNA-AL00', 'android 12', '1200X2652'),
  ('OnePlus', 'PJD110', 'android 15', '1240X2772'),
  ('OnePlus', 'PHB110', 'android 14', '1240X2772'),
  ('OnePlus', 'CPH2449', 'android 13', '1440X3216'),
  ('realme', 'RMX3708', 'android 14', '1240X2772'),
  ('realme', 'RMX3820', 'android 13', '1080X2412'),
  ('realme', 'RMX3852', 'android 14', '1080X2400'),
  ('Meizu', 'M2392', 'android 14', '1080X2400'),
  ('Meizu', 'M381Q', 'android 13', '1080X2400'),
  ('ZTE', 'A2024P', 'android 13', '1116X2480'),
];

// ---------------------------------------------------------------------------
// 线上格式：AES 信封（源头 pa0/ma0/oRt/sRt/gRt 的行为，代码自己写）
// ---------------------------------------------------------------------------

/// 接口信封加密：AES-CBC（密钥长度定 128/192/256），随机 IV 前置，整体
/// base64。免滑块短信/验证接口与拼图校验数据都用这个格式。
String yun139ApiEnvelopeEncrypt(
  String plaintext,
  String key, {
  Uint8List? ivBytes,
}) {
  final iv = ivBytes ??
      Uint8List.fromList(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
  final cipher = aesCbcEncrypt(
    Uint8List.fromList(utf8.encode(key)),
    iv,
    Uint8List.fromList(utf8.encode(plaintext)),
  );
  final combined = Uint8List(iv.length + cipher.length)
    ..setAll(0, iv)
    ..setAll(iv.length, cipher);
  return base64Encode(combined);
}

/// 接口信封解密：去引号/空白后 base64 解码，前 16 字节是 IV，余下解密。
/// 密文过短或填充不对抛 [FormatException]。
String yun139ApiEnvelopeDecrypt(String envelope, String key) {
  final cleaned = envelope.trim().replaceAll('"', '');
  final bytes = base64Decode(_padBase64(cleaned));
  if (bytes.length <= 16) {
    throw const FormatException('移动云盘信封密文长度无效');
  }
  final plain = aesCbcDecrypt(
    Uint8List.fromList(utf8.encode(key)),
    Uint8List.sublistView(bytes, 0, 16),
    Uint8List.sublistView(bytes, 16),
  );
  return utf8.decode(plain);
}

/// 免滑块登录载荷加密：AES-128-ECB 加密后，把最后 5 个字节挪到最前面，
/// 再转十六进制。请求体与响应里的 `data` 字段都用这个格式。
String yun139LoginPayloadEncrypt(String plaintext, String key) {
  final cipher = aesEcbEncrypt(
    Uint8List.fromList(utf8.encode(key)),
    Uint8List.fromList(utf8.encode(plaintext)),
  );
  return _bytesToHex(_rotateTailToFront(cipher));
}

/// 免滑块登录载荷解密：十六进制解码后，把最前 5 个字节挪回最后，再
/// AES-128-ECB 解密。
String yun139LoginPayloadDecrypt(String hexText, String key) {
  final plain = aesEcbDecrypt(
    Uint8List.fromList(utf8.encode(key)),
    _rotateFrontToTail(_hexToBytes(hexText.trim())),
  );
  return utf8.decode(plain);
}

/// 滑块通道登录响应解密：十六进制解码后直接 AES-128-ECB 解密（不旋转）。
String yun139SliderLoginDecrypt(String hexText, String key) {
  final plain = aesEcbDecrypt(
    Uint8List.fromList(utf8.encode(key)),
    _hexToBytes(hexText.trim()),
  );
  return utf8.decode(plain);
}

Uint8List _rotateTailToFront(Uint8List bytes) {
  if (bytes.length < 5) return bytes;
  final out = Uint8List(bytes.length)
    ..setAll(0, bytes.sublist(bytes.length - 5))
    ..setAll(5, bytes.sublist(0, bytes.length - 5));
  return out;
}

Uint8List _rotateFrontToTail(Uint8List bytes) {
  if (bytes.length < 5) return bytes;
  final out = Uint8List(bytes.length)
    ..setAll(0, bytes.sublist(5))
    ..setAll(bytes.length - 5, bytes.sublist(0, 5));
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexToBytes(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'\s'), '');
  if (cleaned.length.isOdd) {
    throw const FormatException('十六进制字符串长度必须是偶数');
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _padBase64(String value) {
  final stripped = value.replaceAll(RegExp(r'\s'), '');
  return stripped + '=' * (-stripped.length % 4);
}

// ---------------------------------------------------------------------------
// 滑块页地址与滑块登录头（源头 ta0/ra0 的行为）
// ---------------------------------------------------------------------------

/// 滑块验证页地址：`data` 参数是标准 base64 的 JSON（captchaType 2 +
/// 手机号参数 + 渠道/设备头），与源头 iframe 用的地址一致。
String yun139CaptchaUrl(String phone, Yun139DeviceInfo device) {
  final payload = {
    'captchaType': 2,
    'params': {
      'clientType': '414',
      'nationCode': '+86',
      'phoneNumber': phone,
      'reqType': '3',
    },
    'headers': {
      'x-yun-app-channel': _appChannel,
      'x-yun-client-info': device.deviceInfo,
    },
  };
  final encoded = base64Encode(utf8.encode(jsonEncode(payload)));
  return '$_captchaPageBase$encoded';
}

/// 滑块通道登录时附带的 H5 设备头（源头按固定桌面 UA 派生，与设备表
/// 无关）：`x-DeviceInfo` / `x-yun-client-info` / `x-NationCode`。
Map<String, String> yun139SliderLoginHeaders() {
  const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  const platform = 'Win32';
  const screen = '1920X1080';
  final digest = md5.convert(utf8.encode('$userAgent|$platform|$screen|mcloud-h5')).toString();
  final encodedPlatform = base64Encode(utf8.encode(platform));
  final deviceInfo = [
    '',
    '',
    '3',
    '7.17.7',
    platform,
    platform,
    digest,
    '',
    'Chrome 126.0.0.0',
    screen,
    '',
    '',
    '',
    encodedPlatform,
    '',
  ].join('|');
  return {
    'x-DeviceInfo': deviceInfo,
    'x-yun-client-info': deviceInfo,
    'x-NationCode': '+86',
  };
}

// ---------------------------------------------------------------------------
// 短信发送结果
// ---------------------------------------------------------------------------

/// 短信走的通道（登录时按同一通道提交验证码，源头 login_attempt 语义）。
enum Yun139SmsMode {
  /// 免滑块通道（加密信封）。
  noSlider,

  /// 普通通道（明文 JSON，风控时走滑块）。
  slider,
}

/// 发短信的结果：已发送 / 需要滑块验证（二选一）。
class Yun139SmsResult {
  const Yun139SmsResult({
    required this.phone,
    required this.mode,
    required this.message,
    this.requiresCaptcha = false,
    this.captchaUrl = '',
    this.sliderHeaders = const {},
  });

  final String phone;
  final Yun139SmsMode mode;
  final String message;

  /// 需要滑块验证时为真：界面打开 [captchaUrl] 内嵌页，用户完成滑块
  /// 后等短信，登录时带上 [sliderHeaders]。
  final bool requiresCaptcha;
  final String captchaUrl;
  final Map<String, String> sliderHeaders;
}

// ---------------------------------------------------------------------------
// 内部控制流异常
// ---------------------------------------------------------------------------

/// 风控信号：免滑块通道被要求滑块验证，调用方落到普通通道。
class _NeedsSlider implements Exception {
  const _NeedsSlider();
}

/// 协议对不上（信封解不开、字段缺失）：短信流程里落到普通通道重试；
/// 登录流程里直接作为失败报给用户。
class _ProtocolError extends CloudDriveException {
  _ProtocolError(super.message);
}

// ---------------------------------------------------------------------------
// 小工具（本文件自带，与 cloud_providers.dart 里的同名私有函数同行为）
// ---------------------------------------------------------------------------

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  return value.toString();
}

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

Map<String, dynamic> _jsonObject(String body, String what) {
  final decoded = jsonDecode(body);
  if (decoded is Map<String, dynamic>) return decoded;
  throw CloudDriveException('$what：返回的不是 JSON 对象');
}

String _randomLetters(int length, [Random? random]) {
  final rng = random ?? Random.secure();
  const letters = 'abcdefghijklmnopqrstuvwxyz';
  return String.fromCharCodes(
    List<int>.generate(length, (_) => letters.codeUnitAt(rng.nextInt(26))),
  );
}

/// 加密通道的成功判定：success 为真，或 code/resultCode 为 '0'。
bool _isSuccess(Map<String, dynamic> json) =>
    json['success'] == true ||
    json['code']?.toString() == '0' ||
    json['resultCode']?.toString() == '0';

String _messageOf(Map<String, dynamic> json, String fallback) {
  final message = json['message'] ?? json['desc'];
  if (message is String && message.isNotEmpty) return message;
  final code = json['code'];
  return code == null ? fallback : '$fallback：$code';
}

bool _hasMessage(Map<String, dynamic> json) =>
    json['message'] != null || json['desc'] != null || json['code'] != null;

/// 风控判定：错误码 200059554、captchaType 2、或文案含滑块/验证/风控词。
bool _isRisk(Map<String, dynamic> json) {
  if (json['code']?.toString() == '200059554') return true;
  final data = json['data'];
  if (data is Map && _asInt(data['captchaType']) == 2) return true;
  final message = _messageOf(json, '');
  return message.contains('滑块') ||
      message.contains('图形验证') ||
      message.contains('安全验证') ||
      message.contains('风控');
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

class Yun139Provider implements CloudDriveProvider {
  Yun139Provider({Yun139DeviceInfo? fixedDevice})
    : _fixedDevice = fixedDevice;

  /// 测试用固定设备（不随机，请求头可断言）。
  final Yun139DeviceInfo? _fixedDevice;

  Yun139DeviceInfo? _deviceCache;

  Yun139DeviceInfo get _device =>
      _deviceCache ??= _fixedDevice ?? Yun139DeviceInfo.generate();

  @override
  String get id => 'yun139';
  @override
  String get displayName => '移动云盘';
  @override
  String get appName => '移动云盘 App';
  @override
  String get rootFolderId => '/';

  @override
  void Function(String providerId, CloudCredentials credentials)?
  onCredentialsRefreshed;

  @override
  void Function(String providerId, String expiredCookie)? onSessionExpired;

  /// 短信通道记忆（登录按发短信时的通道提交，30 分钟过期）。
  String _smsPhone = '';
  Yun139SmsMode _smsMode = Yun139SmsMode.noSlider;
  DateTime? _smsAt;

  /// 分页游标缓存：`<Authorization>|<文件夹>` → 每页的游标（源头 gWt 语义）。
  final Map<String, List<String>> _pageCursors = {};

  void _rememberSms(String phone, Yun139SmsMode mode) {
    _smsPhone = phone;
    _smsMode = mode;
    _smsAt = DateTime.now();
  }

  void _clearSmsMemory() {
    _smsPhone = '';
    _smsAt = null;
  }

  Yun139SmsMode _smsModeFor(String phone) {
    final at = _smsAt;
    if (_smsPhone != phone || at == null) return Yun139SmsMode.noSlider;
    if (DateTime.now().difference(at) > _smsModeTtl) {
      return Yun139SmsMode.noSlider;
    }
    return _smsMode;
  }

  // -------------------------------------------------------------------------
  // 扫码登录：移动云盘没有，诚实抛错（登录中心走短信方法）。
  // 异步接口必须异步失败：同步抛错会在调用方 await 之前炸开，
  // expectLater/then 链都接不住。
  @override
  Future<QrLoginSession> startQrLogin(http.Client client) async {
    throw UnsupportedError('移动云盘没有扫码登录，请用手机号+短信验证码登录');
  }

  @override
  Future<QrPollResult> pollQrLogin(
    http.Client client,
    QrLoginSession session,
  ) async {
    throw UnsupportedError('移动云盘没有扫码登录，请用手机号+短信验证码登录');
  }

  // -------------------------------------------------------------------------
  // 请求头（四组，端点各异，照源头逐项写）
  // -------------------------------------------------------------------------

  Map<String, String> _plainHeaders(Yun139DeviceInfo device) => {
    'x-NationCode': '+86',
    'x-yun-net-type': '1',
    'x-yun-user-agent': device.userAgent,
    'Connection': 'keep-alive',
    'x-NetType': '1',
    'x-DeviceInfo': device.deviceInfo,
    'x-yun-client-info': device.deviceInfo,
    'x-yun-app-channel': _appChannel,
    'x-huawei-channelSrc': _appChannel,
    'Content-Type': 'application/json; charset=utf-8',
    'x-MM-Source': '000',
    'Accept-Language': 'zh-CN',
    'x-SvcType': '1',
  };

  /// 免滑块通道头：设备串里的 `|000|0|` 改 `|032|0|`，UA 里的 `-000`
  /// 改 `-032`，加 `hcy-cool-flag` 与 okhttp UA。
  Map<String, String> _noSliderHeaders(Yun139DeviceInfo device) {
    final deviceInfo = device.deviceInfo.replaceAll('|000|0|', '|032|0|');
    final userAgent = device.userAgent.replaceAll('-000', '-032');
    return {
      ..._plainHeaders(device),
      'x-DeviceInfo': deviceInfo,
      'x-yun-client-info': deviceInfo,
      'x-yun-user-agent': userAgent,
      'x-MM-Source': '032',
      'hcy-cool-flag': '1',
      'User-Agent': 'okhttp/4.12.0',
    };
  }

  Map<String, String> _refreshHeaders(
    CloudCredentials credentials,
    Yun139DeviceInfo device,
  ) => {
    'Content-Type': 'application/json; charset=UTF-8',
    'x-yun-api-version': 'v1',
    'x-yun-net-type': '1',
    'x-yun-client-info': device.deviceInfo,
    'x-yun-svc-type': '1',
    'x-yun-module-type': '100',
    'x-yun-device-id': device.deviceInfo,
    'x-yun-user-agent': device.userAgent,
    'x-yun-app-channel': _appChannel,
    'Accept-Language': 'zh-CN',
    'x-yun-uni': credentials.fields['x-yun-uni'] ?? '',
    'Authorization': credentials.fields['authorization'] ?? '',
  };

  Map<String, String> _listHeaders(
    CloudCredentials credentials,
    Yun139DeviceInfo device,
  ) => {
    'Content-Type': 'application/json; charset=UTF-8',
    'x-yun-api-version': 'v2',
    'Connection': 'keep-alive',
    'x-yun-net-type': '1',
    'x-yun-client-info': device.deviceInfo,
    'x-yun-svc-type': '1',
    'x-yun-module-type': '100',
    'x-yun-device-id': device.deviceInfo,
    'x-yun-user-agent': device.userAgent,
    'x-yun-app-channel': _appChannel,
    'Accept-Language': 'zh-CN',
    'x-yun-uni': credentials.fields['x-yun-uni'] ?? '',
    'Authorization': credentials.fields['authorization'] ?? '',
  };

  Map<String, String> _downloadHeaders(
    CloudCredentials credentials,
    Yun139DeviceInfo device,
  ) => {
    'Content-Type': 'application/json; charset=UTF-8',
    'x-yun-url-type': '1',
    'x-yun-api-version': 'v1',
    'x-yun-net-type': '1',
    'x-yun-user-agent': device.userAgent,
    'x-yun-client-info': device.deviceInfo,
    'x-yun-app-channel': _appChannel,
    'x-huawei-channelSrc': _appChannel,
    'Accept-Language': 'zh-CN',
    'x-yun-uni': credentials.fields['x-yun-uni'] ?? '',
    'Authorization': credentials.fields['authorization'] ?? '',
  };

  // -------------------------------------------------------------------------
  // 请求小件
  // -------------------------------------------------------------------------

  /// 明文 JSON POST：非 2xx 或非 JSON 对象时抛 [CloudDriveException]。
  Future<Map<String, dynamic>> _postJsonMap(
    http.Client client,
    String url,
    Map<String, dynamic> body,
    Map<String, String> headers,
    String what, {
    Duration timeout = _authTimeout,
  }) async {
    final response = await client
        .post(
          Uri.parse(url),
          headers: headers,
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudDriveException('$what请求失败：${response.statusCode}');
    }
    return _jsonObject(response.body, what);
  }

  /// 加密信封 POST：请求体是信封密文字符串，响应体解密后再解析 JSON。
  /// HTTP 失败抛 [CloudDriveException]（不回落）；解密/解析失败抛
  /// [_ProtocolError]（短信流程里回落普通通道）。
  Future<Map<String, dynamic>> _postEncrypted(
    http.Client client,
    String url,
    Map<String, dynamic> body,
    Map<String, String> headers,
    String what,
  ) async {
    final payload = yun139ApiEnvelopeEncrypt(jsonEncode(body), _apiEnvelopeKey);
    final response = await client
        .post(Uri.parse(url), headers: headers, body: payload)
        .timeout(_authTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudDriveException('$what请求失败：${response.statusCode}');
    }
    try {
      final plain = yun139ApiEnvelopeDecrypt(response.body, _apiEnvelopeKey);
      return _jsonObject(plain, what);
    } on FormatException catch (e) {
      throw _ProtocolError('$what响应无法解密：$e');
    } on CloudDriveException {
      throw _ProtocolError('$what响应格式异常');
    }
  }

  // -------------------------------------------------------------------------
  // 短信验证码
  // -------------------------------------------------------------------------

  String _validatePhone(String rawPhone) {
    final phone = rawPhone.trim();
    if (!RegExp(r'^1\d{10}$').hasMatch(phone)) {
      throw CloudDriveException('请输入正确的移动手机号');
    }
    return phone;
  }

  /// 发短信：先免滑块通道，风控/协议对不上时落普通通道；普通通道
  /// 触发风控时返回滑块页地址，不抛错（界面打开内嵌页完成滑块）。
  Future<Yun139SmsResult> sendSms(http.Client client, String rawPhone) async {
    final phone = _validatePhone(rawPhone);
    final device = _device;
    try {
      final result = await _sendSmsNoSlider(client, phone, device);
      _rememberSms(phone, Yun139SmsMode.noSlider);
      return result;
    } on _NeedsSlider {
      // 落普通通道。
    } on _ProtocolError {
      // 协议对不上，落普通通道。
    }
    final result = await _sendSmsSlider(client, phone, device);
    _rememberSms(phone, Yun139SmsMode.slider);
    return result;
  }

  Future<Yun139SmsResult> _sendSmsNoSlider(
    http.Client client,
    String phone,
    Yun139DeviceInfo device,
  ) async {
    final headers = _noSliderHeaders(device);
    // 预验证：结果不用，只确认通道通畅。
    await _postEncrypted(client, _smsUrl, {
      'clientType': '414',
      'mode': '0',
      'phoneNumber': phone,
      'random': _randomLetters(6),
      'reqType': '3',
    }, headers, '移动云盘免滑块预验证');
    final verify = await _postEncrypted(client, _verifyUrl, {
      'account': phone,
      'type': '2',
    }, headers, '移动云盘免滑块验证');
    if (_isRisk(verify)) throw const _NeedsSlider();
    final data = verify['data'];
    final puzzleLeft = data is Map ? _asString(data['puzzleLeft']) : '';
    if (puzzleLeft.isEmpty) {
      if (!_isSuccess(verify) && _hasMessage(verify)) {
        throw CloudDriveException(_messageOf(verify, '移动云盘免滑块验证失败'));
      }
      throw _ProtocolError('移动云盘免滑块接口未返回 puzzleLeft');
    }
    String puzzlePlain;
    try {
      puzzlePlain = yun139ApiEnvelopeDecrypt(puzzleLeft, _puzzleKey);
    } catch (e) {
      throw _ProtocolError('移动云盘免滑块校验数据无法解密：$e');
    }
    final puzzleCode = yun139ApiEnvelopeEncrypt(puzzlePlain, _puzzleKey);
    final sent = await _postEncrypted(client, _smsUrl, {
      'clientType': '414',
      'mode': '0',
      'phoneNumber': phone,
      'puzzleVerfycode': puzzleCode,
      'random': _randomLetters(6),
      'reqType': '3',
    }, headers, '移动云盘免滑块验证码发送');
    if (_isSuccess(sent)) {
      return Yun139SmsResult(
        phone: phone,
        mode: Yun139SmsMode.noSlider,
        message: _messageOf(sent, '验证码已发送'),
      );
    }
    if (_isRisk(sent)) throw const _NeedsSlider();
    throw CloudDriveException(_messageOf(sent, '移动云盘验证码发送失败'));
  }

  Future<Yun139SmsResult> _sendSmsSlider(
    http.Client client,
    String phone,
    Yun139DeviceInfo device,
  ) async {
    final result = await _postJsonMap(client, _smsUrl, {
      'clientType': '414',
      'mode': '0',
      'phoneNumber': phone,
      'random': 'pcpuzh',
      'reqType': '3',
    }, _plainHeaders(device), '移动云盘验证码发送');
    if (result['success'] == true) {
      return Yun139SmsResult(
        phone: phone,
        mode: Yun139SmsMode.slider,
        message: _messageOf(result, '验证码已发送'),
      );
    }
    final data = result['data'];
    final captchaType = data is Map ? _asInt(data['captchaType']) : 0;
    if (result['code']?.toString() == '200059554' || captchaType == 2) {
      return Yun139SmsResult(
        phone: phone,
        mode: Yun139SmsMode.slider,
        message: _messageOf(result, '需要完成滑块验证，完成后等待短信验证码'),
        requiresCaptcha: true,
        captchaUrl: yun139CaptchaUrl(phone, device),
        sliderHeaders: yun139SliderLoginHeaders(),
      );
    }
    throw CloudDriveException(_messageOf(result, '移动云盘验证码发送失败'));
  }

  // -------------------------------------------------------------------------
  // 短信验证码登录
  // -------------------------------------------------------------------------

  /// 只取滑块头里的三个键（其余键不透传，与源头 bRt 一致）。
  Map<String, String> _filterSliderHeaders(Map<String, String> headers) {
    const wanted = ['x-DeviceInfo', 'x-yun-client-info', 'x-NationCode'];
    final result = <String, String>{};
    for (final key in wanted) {
      final value = headers[key] ?? headers[key.toLowerCase()] ?? '';
      if (value.trim().isNotEmpty) result[key] = value.trim();
    }
    return result;
  }

  /// 用短信验证码登录。带滑块头、或发短信时走的是普通通道时，走
  /// 滑块通道登录；否则走免滑块通道。成功返回可直接存入
  /// [CloudCredentialStore] 的凭证。
  Future<CloudCredentials> loginWithSms(
    http.Client client,
    String rawPhone,
    String rawCode, {
    Map<String, String> sliderHeaders = const {},
  }) async {
    final phone = _validatePhone(rawPhone);
    final code = rawCode.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw CloudDriveException('请输入 6 位短信验证码');
    }
    final device = _device;
    final filtered = _filterSliderHeaders(sliderHeaders);
    final useSlider =
        filtered.isNotEmpty || _smsModeFor(phone) == Yun139SmsMode.slider;
    final Map<String, dynamic> loginData;
    if (useSlider) {
      loginData = await _loginSlider(client, phone, code, device, filtered);
    } else {
      loginData = await _loginNoSlider(client, phone, code, device);
    }
    final token = _asString(loginData['token']).isNotEmpty
        ? _asString(loginData['token'])
        : _asString(loginData['authToken']);
    final userDomainId = _asString(loginData['userDomainId']);
    final account = _asString(loginData['account']).isNotEmpty
        ? _asString(loginData['account'])
        : phone;
    if (token.isEmpty || userDomainId.isEmpty) {
      throw CloudDriveException('移动云盘登录成功但缺少 token 或 userDomainId');
    }
    _clearSmsMemory();
    final authorization =
        'Basic ${base64Encode(utf8.encode('mobile:$phone:$token'))}';
    final expireTime = _asString(loginData['expireTime']);
    return CloudCredentials(
      fields: {
        'authorization': authorization,
        'x-yun-uni': userDomainId,
        'user_domain_id': userDomainId,
        'token': token,
        'phone': phone,
        'account': account,
        'device_info': device.deviceInfo,
        'device_user_agent': device.userAgent,
        'token_expire_time': expireTime,
      },
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      label: _maskPhone(phone),
    );
  }

  Map<String, dynamic> _loginBody(String phone, String code) => {
    'clienttype': '414',
    'cpid': '58',
    'dycpwd': code,
    'extInfo': {'ifOpenAccount': '1'},
    'loginMode': '1',
    'msisdn': phone,
    'pintype': '8',
    'version': _loginVersion,
  };

  Future<Map<String, dynamic>> _loginSlider(
    http.Client client,
    String phone,
    String code,
    Yun139DeviceInfo device,
    Map<String, String> sliderHeaders,
  ) async {
    final result = await _postJsonMap(
      client,
      _loginUrl,
      _loginBody(phone, code),
      {..._plainHeaders(device), ...sliderHeaders},
      '移动云盘登录',
    );
    final data = result['data'];
    if (result['success'] != true || data is! String) {
      throw CloudDriveException(_messageOf(result, '移动云盘登录失败'));
    }
    try {
      final plain = yun139SliderLoginDecrypt(data, _sliderLoginKey);
      return _jsonObject(plain, '移动云盘登录数据');
    } catch (e) {
      throw CloudDriveException('移动云盘滑块登录数据无法解密：$e');
    }
  }

  Future<Map<String, dynamic>> _loginNoSlider(
    http.Client client,
    String phone,
    String code,
    Yun139DeviceInfo device,
  ) async {
    final headers = _noSliderHeaders(device)..remove('hcy-cool-flag');
    final payload = yun139LoginPayloadEncrypt(
      jsonEncode(_loginBody(phone, code)),
      _noSliderLoginKey,
    );
    final response = await client
        .post(Uri.parse(_loginUrl), headers: headers, body: payload)
        .timeout(_authTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudDriveException('移动云盘登录请求失败：${response.statusCode}');
    }
    final Map<String, dynamic> result;
    try {
      result = _jsonObject(response.body, '移动云盘登录');
    } catch (_) {
      throw _ProtocolError('移动云盘免滑块登录响应格式异常');
    }
    final data = result['data'];
    if (!_isSuccess(result) || data == null) {
      throw CloudDriveException(_messageOf(result, '移动云盘登录失败'));
    }
    try {
      final plain = yun139LoginPayloadDecrypt(
        _asString(data),
        _noSliderLoginKey,
      );
      return _jsonObject(plain, '移动云盘登录数据');
    } catch (e) {
      throw _ProtocolError('移动云盘免滑块登录数据无法解密：$e');
    }
  }

  String _maskPhone(String phone) {
    if (phone.length != 11) return phone;
    return '${phone.substring(0, 3)}****${phone.substring(7)}';
  }

  // -------------------------------------------------------------------------
  // 凭证刷新
  // -------------------------------------------------------------------------

  Yun139DeviceInfo _deviceFromCredentials(CloudCredentials credentials) {
    final deviceInfo = credentials.fields['device_info'] ?? '';
    final userAgent = credentials.fields['device_user_agent'] ?? '';
    if (deviceInfo.isNotEmpty && userAgent.isNotEmpty) {
      return Yun139DeviceInfo.fromStored(
        deviceInfo: deviceInfo,
        userAgent: userAgent,
      );
    }
    return _device;
  }

  /// token 过期时间（毫秒时间戳）；算不出来时返回 0（不自动刷新）。
  /// 口径与源头一致：expireTime 字段（>1e9 当时间戳，否则当相对秒数）、
  /// JWT 的 exp、竖线格式 token 的第 4 段，依次尝试。
  int _tokenExpiresAtMs(CloudCredentials credentials) {
    final raw = credentials.fields['token_expire_time'] ?? '';
    final numeric = num.tryParse(raw);
    if (numeric != null && numeric > 0) {
      final value = numeric.toInt();
      if (value > 1000000000) {
        return value < 100000000000 ? value * 1000 : value;
      }
      return credentials.savedAtMs + value * 1000;
    }
    final token = credentials.fields['token'] ?? '';
    if (token.isEmpty) return 0;
    final jwtParts = token.split('.');
    if (jwtParts.length >= 2) {
      try {
        final payload = jsonDecode(
          utf8.decode(
            base64Decode(
              _padBase64(
                jwtParts[1].replaceAll('-', '+').replaceAll('_', '/'),
              ),
            ),
          ),
        );
        if (payload is Map) {
          final exp = num.tryParse('${payload['exp']}');
          if (exp != null && exp > 0) return exp.toInt() * 1000;
        }
      } catch (_) {
        // 不是 JWT，继续试竖线格式。
      }
    }
    final pipeParts = token.split('|');
    if (pipeParts.length >= 4) {
      final value = num.tryParse(pipeParts[3]);
      if (value != null && value > 0) {
        final millis = value.toInt();
        return millis < 100000000000 ? millis * 1000 : millis;
      }
    }
    return 0;
  }

  /// 刷新登录（换新 token）。失败抛 [CloudDriveException]，调用方按
  /// “重新登录”提示，不静默当成功。
  Future<CloudCredentials> refreshCredentials(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    final device = _deviceFromCredentials(credentials);
    final result = await _postJsonMap(
      client,
      _refreshUrl,
      {'clientType': '414'},
      _refreshHeaders(credentials, device),
      '移动云盘刷新登录',
    );
    final data = result['data'];
    final token = data is Map ? _asString(data['token']) : '';
    if (result['success'] != true || token.isEmpty) {
      throw CloudDriveException(_messageOf(result, '移动云盘刷新登录失败'));
    }
    final phone =
        credentials.fields['phone'] ?? credentials.fields['account'] ?? '';
    final expireTime = data is Map ? _asString(data['expireTime']) : '';
    final authorization =
        'Basic ${base64Encode(utf8.encode('mobile:$phone:$token'))}';
    return CloudCredentials(
      fields: {
        ...credentials.fields,
        'token': token,
        'authorization': authorization,
        if (expireTime.isNotEmpty) 'token_expire_time': expireTime,
      },
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
      label: credentials.label,
    );
  }

  /// token 将在 5 分钟内过期时先刷新（失败时用旧凭证继续，服务端
  /// 拒绝时再诚实报错）；算不出过期时间时不刷新。
  Future<CloudCredentials> _ensureFresh(
    http.Client client,
    CloudCredentials credentials,
  ) async {
    final expiresAt = _tokenExpiresAtMs(credentials);
    if (expiresAt <= 0) return credentials;
    if (expiresAt > DateTime.now().millisecondsSinceEpoch +
        _refreshEarlyWindow.inMilliseconds) {
      return credentials;
    }
    try {
      final refreshed = await refreshCredentials(client, credentials);
      onCredentialsRefreshed?.call(id, refreshed);
      return refreshed;
    } catch (_) {
      return credentials;
    }
  }

  // -------------------------------------------------------------------------
  // 文件列表（游标分页，引擎按页号调，这里按源头 gWt 语义走游标）
  // -------------------------------------------------------------------------

  @override
  Future<CloudFolderPage> listFolder(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    int page,
  ) async {
    final fresh = await _ensureFresh(client, credentials);
    final folder = folderId.isEmpty || folderId == '0' ? '/' : folderId;
    final pageNumber = page < 1 ? 1 : page;
    final cacheKey = '${fresh.fields['authorization']}|$folder';
    final cursors = _pageCursors.putIfAbsent(cacheKey, () => ['']);
    // 逐页走到目标页（游标只能顺序取，与源头一致）。
    while (cursors.length < pageNumber) {
      final fetched = await _fetchListPage(
        client,
        fresh,
        folder,
        cursors.last,
      );
      if (!fetched.hasMore || cursors.contains(fetched.nextCursor)) {
        return const CloudFolderPage(files: [], hasMore: false);
      }
      cursors.add(fetched.nextCursor);
    }
    final result = await _fetchListPage(
      client,
      fresh,
      folder,
      cursors[pageNumber - 1],
    );
    while (cursors.length > pageNumber) {
      cursors.removeLast();
    }
    if (result.hasMore && !cursors.contains(result.nextCursor)) {
      cursors.add(result.nextCursor);
    }
    if (_pageCursors.length > 128) _pageCursors.clear();
    return CloudFolderPage(files: result.files, hasMore: result.hasMore);
  }

  Future<
    ({List<CloudDriveFile> files, String nextCursor, bool hasMore})
  >
  _fetchListPage(
    http.Client client,
    CloudCredentials credentials,
    String folderId,
    String cursor,
  ) async {
    final device = _deviceFromCredentials(credentials);
    final result = await _postJsonMap(
      client,
      _mineListUrl,
      {
        'fields': _mineListFields,
        'imageThumbnailStyleList': ['Small', 'Big'],
        'orderBy': 'updated_at',
        'orderDirection': 'DESC',
        'ownerId': null,
        'pageInfo': {
          'needTotalCount': 0,
          'pageCursor': cursor.isEmpty ? null : cursor,
          'pageSize': _minePageSize,
        },
        'parentFileId': folderId,
        'parentFilePath': true,
        'type': null,
        'workSpaceType': null,
      },
      _listHeaders(credentials, device),
      '移动云盘目录加载',
      timeout: _dataTimeout,
    );
    final data = result['data'];
    if (result['success'] != true || data is! Map<String, dynamic>) {
      throw CloudDriveException(_messageOf(result, '移动云盘目录加载失败'));
    }
    final rawItems = data['items'];
    final files = <CloudDriveFile>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is Map<String, dynamic>) {
          final parsed = _parseListItem(item);
          if (parsed != null) files.add(parsed);
        }
      }
    }
    var nextCursor = _asString(data['nextPageCursor']).trim();
    if (nextCursor.toLowerCase() == 'null') nextCursor = '';
    // 有没有下一页只认服务端游标：一页不足 pageSize 也可能是服务端
    // 分页切分的结果，不能用条数启发式压掉游标；只有游标重复（与
    // 本次请求游标相同）才算到底。
    if (nextCursor == cursor) {
      nextCursor = '';
    }
    return (files: files, nextCursor: nextCursor, hasMore: nextCursor.isNotEmpty);
  }

  CloudDriveFile? _parseListItem(Map<String, dynamic> item) {
    final id = _asString(item['fileId']);
    var name = _asString(item['name']);
    if (name.isEmpty) name = _asString(item['fileName']);
    if (id.isEmpty || name.isEmpty) return null;
    final type = _asString(item['type']).isNotEmpty
        ? _asString(item['type'])
        : _asString(item['contentType']);
    final isFolder =
        type.toLowerCase() != 'file' && type.toLowerCase() != 'content';
    final size = _asInt(item['size'], -1) >= 0
        ? _asInt(item['size'])
        : _asInt(item['fileSize']);
    final kind = classifyCloudFile(name: name, isFolder: isFolder);
    return CloudDriveFile(
      id: id,
      name: name,
      isFolder: isFolder,
      kind: kind,
      sizeBytes: size,
      modifiedMs: _parseTimeMs(
        item['updatedAt'] ?? item['localUpdatedAt'] ?? item['createdAt'],
      ),
      durationSeconds: _parseDuration(item),
      thumbnailUrl: _parseThumbnail(item),
    );
  }

  /// 时间字段：数字（秒/毫秒自适应）或 ISO 字符串，解析不出为 0。
  int _parseTimeMs(Object? value) {
    if (value is num) {
      final millis = value.toInt();
      if (millis <= 0) return 0;
      if (millis > 1000000000000) return millis;
      if (millis > 1000000000) return millis * 1000;
      return millis * 1000;
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return 0;
      final numeric = num.tryParse(trimmed);
      if (numeric != null) return _parseTimeMs(numeric);
      return DateTime.tryParse(trimmed)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  /// 缩略图：`thumbnailUrls` 可能是 {Small, Big} 对象、列表或字符串，
  /// 优先取 Big；源头映射里没取该字段，形状对不上时按没有处理。
  String _parseThumbnail(Map<String, dynamic> item) {
    final urls = item['thumbnailUrls'];
    if (urls is Map) {
      for (final key in ['Big', 'Small']) {
        final value = _asString(urls[key]);
        if (value.isNotEmpty) return value;
      }
      for (final value in urls.values) {
        final text = _asString(value);
        if (text.isNotEmpty) return text;
      }
    } else if (urls is List) {
      for (final value in urls) {
        final text = _asString(value);
        if (text.isNotEmpty) return text;
      }
    } else if (urls is String && urls.isNotEmpty) {
      return urls;
    }
    final fallback = _asString(item['thumbnailUrl']);
    if (fallback.isNotEmpty) return fallback;
    return _asString(item['thumbnail']);
  }

  /// 时长：`mediaMetaInfo.duration` 或顶层 `duration`；数值 ≥10000 按
  /// 毫秒算（除以 1000），否则按秒算。源头映射里没取该字段，这里是
  /// 尽力解析，拿不到时返回 null（未知，不猜）。
  int? _parseDuration(Map<String, dynamic> item) {
    Object? raw;
    final meta = item['mediaMetaInfo'];
    if (meta is Map) raw = meta['duration'];
    raw ??= item['duration'] ?? item['playLong'] ?? item['play_long'];
    num? value;
    if (raw is num) {
      value = raw;
    } else if (raw is String) {
      value = num.tryParse(raw.trim());
    }
    if (value == null || value <= 0) return null;
    final seconds = value >= 10000 ? value ~/ 1000 : value.toInt();
    return seconds > 0 ? seconds : null;
  }

  // -------------------------------------------------------------------------
  // 搜索与直链
  // -------------------------------------------------------------------------

  @override
  Future<List<CloudDriveFile>> search(
    http.Client client,
    CloudCredentials credentials,
    String keyword,
    String folderId,
  ) async {
    // 移动云盘个人盘没有站方搜索接口，走引擎的“取列表后按名过滤”兜底。
    throw UnsupportedError('移动云盘没有站方搜索接口');
  }

  @override
  Future<CloudDirectLink> directLink(
    http.Client client,
    CloudCredentials credentials,
    CloudDriveFile file,
  ) async {
    final fresh = await _ensureFresh(client, credentials);
    final device = _deviceFromCredentials(fresh);
    final result = await _postJsonMap(
      client,
      _mineDownloadUrl,
      {
        'fileId': file.id,
        'fileName': '${file.name}.mcloud.downloading',
      },
      _downloadHeaders(fresh, device),
      '移动云盘播放地址',
      timeout: _dataTimeout,
    );
    final data = result['data'];
    final url = data is Map ? _asString(data['url']) : '';
    if (result['success'] != true || url.isEmpty) {
      throw CloudDriveException(_messageOf(result, '移动云盘播放地址为空'));
    }
    return CloudDirectLink(
      url: url,
      headers: {'User-Agent': _playUserAgent, 'Referer': _playReferer},
    );
  }
}
