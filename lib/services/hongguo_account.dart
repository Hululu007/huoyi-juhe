/// 红果账号：模型、手机号校验、云端/本机续播合并策略与传输接口。
///
/// 本文件是纯 Dart，不含任何网络实现与密钥材料：登录态只以
/// [HongguoAccountSession] 的形式出现，调用方不得打印它
/// （[HongguoAccountSession.toString] 已脱敏）。
///
/// 对照仓库结构说明（只取流程结构，未拷对方的品牌、设备指纹、
/// 签名常量与服务端逻辑）：
/// - 手机号登录：发码 → 验码换会话 → 读账号资料确认；
/// - 扫码登录：取二维码 → 轮询等手机确认 → 换会话；
/// - 账号数据：收藏、播放历史、预约三类，全部走账号命名空间，
///   与本机历史/书架分开存（见 hongguo_account_sync.dart）。
library;

/// 红果账号资料。
class HongguoAccountProfile {
  const HongguoAccountProfile({
    required this.userId,
    required this.nickname,
    this.maskedMobile = '',
  });

  final String userId;
  final String nickname;

  /// 平台回显的打码号码（如 +86******23），可能为空。
  final String maskedMobile;

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'nickname': nickname,
    'maskedMobile': maskedMobile,
  };

  factory HongguoAccountProfile.fromJson(Map<String, dynamic> json) =>
      HongguoAccountProfile(
        userId: '${json['userId'] ?? ''}',
        nickname: '${json['nickname'] ?? ''}',
        maskedMobile: '${json['maskedMobile'] ?? ''}',
      );
}

/// 登录会话：只存安全存储（flutter_secure_storage），绝不进 Hive、
/// 日志与任何回报。deviceId/installId 是本次登录换到的设备身份，
/// 之后账号请求须沿用同一份，换号/重登即作废。
class HongguoAccountSession {
  const HongguoAccountSession({
    required this.cookie,
    required this.deviceId,
    required this.installId,
    required this.userId,
    required this.nickname,
    required this.savedAtMs,
  });

  /// Cookie 头原文（含 sessionid）。调用方只透传，不解析、不打印。
  final String cookie;
  final String deviceId;
  final String installId;
  final String userId;
  final String nickname;
  final int savedAtMs;

  bool get isUsable => cookie.isNotEmpty && userId.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'cookie': cookie,
    'deviceId': deviceId,
    'installId': installId,
    'userId': userId,
    'nickname': nickname,
    'savedAtMs': savedAtMs,
  };

  factory HongguoAccountSession.fromJson(Map<String, dynamic> json) =>
      HongguoAccountSession(
        cookie: '${json['cookie'] ?? ''}',
        deviceId: '${json['deviceId'] ?? ''}',
        installId: '${json['installId'] ?? ''}',
        userId: '${json['userId'] ?? ''}',
        nickname: '${json['nickname'] ?? ''}',
        savedAtMs: json['savedAtMs'] is num
            ? (json['savedAtMs'] as num).toInt()
            : 0,
      );

  HongguoAccountSession copyWith({String? nickname}) => HongguoAccountSession(
    cookie: cookie,
    deviceId: deviceId,
    installId: installId,
    userId: userId,
    nickname: nickname ?? this.nickname,
    savedAtMs: savedAtMs,
  );

  /// 绝不输出 cookie 与设备身份。
  @override
  String toString() => 'HongguoAccountSession(userId=$userId, [redacted])';
}

/// 云端收藏的一部剧。
class HongguoCloudFavorite {
  const HongguoCloudFavorite({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.intro = '',
    this.badge = '',
    this.collectedAtMs = 0,
  });

  final String seriesId;
  final String title;
  final String cover;
  final String intro;
  final String badge;
  final int collectedAtMs;

  Map<String, dynamic> toJson() => {
    'seriesId': seriesId,
    'title': title,
    'cover': cover,
    'intro': intro,
    'badge': badge,
    'collectedAtMs': collectedAtMs,
  };

  factory HongguoCloudFavorite.fromJson(Map<String, dynamic> json) =>
      HongguoCloudFavorite(
        seriesId: '${json['seriesId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        cover: '${json['cover'] ?? ''}',
        intro: '${json['intro'] ?? ''}',
        badge: '${json['badge'] ?? ''}',
        collectedAtMs: json['collectedAtMs'] is num
            ? (json['collectedAtMs'] as num).toInt()
            : 0,
      );
}

/// 云端播放进度：只记剧/集/秒数，不存临时播放地址。
class HongguoCloudProgress {
  const HongguoCloudProgress({
    required this.seriesId,
    required this.episodeId,
    required this.episodeIndex,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
    this.title = '',
    this.cover = '',
    this.episodeCount = 0,
  });

  final String seriesId;
  final String episodeId;

  /// 0 起的集下标。
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;
  final String title;
  final String cover;
  final int episodeCount;

  double get rate =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;

  /// 是否已看完（剩不到 5 秒算看完）。
  bool get finished => durationMs > 0 && durationMs - positionMs <= 5000;

  Map<String, dynamic> toJson() => {
    'seriesId': seriesId,
    'episodeId': episodeId,
    'episodeIndex': episodeIndex,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAtMs': updatedAtMs,
    'title': title,
    'cover': cover,
    'episodeCount': episodeCount,
  };

  factory HongguoCloudProgress.fromJson(Map<String, dynamic> json) =>
      HongguoCloudProgress(
        seriesId: '${json['seriesId'] ?? ''}',
        episodeId: '${json['episodeId'] ?? ''}',
        episodeIndex: json['episodeIndex'] is num
            ? (json['episodeIndex'] as num).toInt()
            : 0,
        positionMs: json['positionMs'] is num
            ? (json['positionMs'] as num).toInt()
            : 0,
        durationMs: json['durationMs'] is num
            ? (json['durationMs'] as num).toInt()
            : 0,
        updatedAtMs: json['updatedAtMs'] is num
            ? (json['updatedAtMs'] as num).toInt()
            : 0,
        title: '${json['title'] ?? ''}',
        cover: '${json['cover'] ?? ''}',
        episodeCount: json['episodeCount'] is num
            ? (json['episodeCount'] as num).toInt()
            : 0,
      );
}

/// 播放器组用的云端续播点：与 [HongguoCloudProgress] 同义，名字按
/// 播放器语义取，免得播放器组去猜字段。
typedef HongguoCloudResume = HongguoCloudProgress;

/// 一条预约记录。未上线的剧没有可播剧集 id，键用 `reservation:<id>`
/// 命名空间，绝不能当成播放 id 传给播放器。
class HongguoCloudReservation {
  const HongguoCloudReservation({
    required this.seriesId,
    required this.title,
    required this.online,
    this.cover = '',
    this.intro = '',
    this.publishAtMs = 0,
    this.publishText = '',
  });

  final String seriesId;
  final String title;

  /// true=已上线，false=待上线。
  final bool online;
  final String cover;
  final String intro;
  final int publishAtMs;
  final String publishText;

  /// 是否可播：只有已上线且 id 为纯数字剧集 id 的才可播。
  bool get playable =>
      online && RegExp(r'^[0-9]{1,30}$').hasMatch(seriesId);

  Map<String, dynamic> toJson() => {
    'seriesId': seriesId,
    'title': title,
    'online': online,
    'cover': cover,
    'intro': intro,
    'publishAtMs': publishAtMs,
    'publishText': publishText,
  };

  factory HongguoCloudReservation.fromJson(Map<String, dynamic> json) =>
      HongguoCloudReservation(
        seriesId: '${json['seriesId'] ?? ''}',
        title: '${json['title'] ?? ''}',
        online: json['online'] == true,
        cover: '${json['cover'] ?? ''}',
        intro: '${json['intro'] ?? ''}',
        publishAtMs: json['publishAtMs'] is num
            ? (json['publishAtMs'] as num).toInt()
            : 0,
        publishText: '${json['publishText'] ?? ''}',
      );
}

/// 发码回执：打码号码与重发倒计时。
class HongguoCodeSent {
  const HongguoCodeSent({required this.maskedMobile, required this.retrySeconds});

  final String maskedMobile;
  final int retrySeconds;
}

/// 扫码登录的二维码：图片字节 + 有效秒数。
class HongguoQrCode {
  const HongguoQrCode({required this.imageBytes, required this.expiresInSeconds});

  final List<int> imageBytes;
  final int expiresInSeconds;
}

enum HongguoQrPoll { waiting, confirmed, expired }

/// 账号操作失败：message 可直接显示给用户，不得含地址、Cookie、
/// 手机号明文与任何密钥材料。
class HongguoAccountError implements Exception {
  HongguoAccountError(this.message, {this.code, this.canRetryCode = false});

  final String message;
  final int? code;

  /// true=本次验证码已作废，须重新发码（不是换号重登）。
  final bool canRetryCode;

  @override
  String toString() => message;
}

/// 手机号归一化：只做格式校验，不发任何请求。
///
/// - 大陆（86）：1 开头的 11 位数字，原样发；
/// - 境外：`+区号 号码`，区号 1–3 位，区号 + 号码合计不超过 15 位
///   （E.164），号码至少 4 位，本地开头的 0 去掉；
/// - 号码里的空格、横线等非数字字符一律忽略。
class HongguoPhoneNumber {
  HongguoPhoneNumber._();

  static String format(String countryCode, String number) {
    final cc = countryCode.replaceAll(RegExp(r'\D'), '');
    final digits = number
        .replaceAll(RegExp(r'\D'), '')
        .replaceFirst(RegExp(r'^0'), '');
    if (cc == '86') {
      if (!RegExp(r'^1\d{10}$').hasMatch(digits)) {
        throw HongguoAccountError('大陆手机号是 1 开头的 11 位数字');
      }
      return digits;
    }
    if (!RegExp(r'^[1-9]\d{0,2}$').hasMatch(cc)) {
      throw HongguoAccountError('区号是 1–3 位数字');
    }
    if (digits.length < 4 || cc.length + digits.length > 15) {
      throw HongguoAccountError('号码长度不对：区号加号码最多 15 位');
    }
    return '+$cc $digits';
  }

  /// 一整串写法：`13800138000`（大陆），或 `+区号-号码` /
  /// `+区号 号码`（如 `+886 0912345678`）。
  static String parse(String raw) {
    final text = raw.trim();
    if (!text.startsWith('+')) return format('86', text);
    final cc = text.substring(1).split(RegExp(r'\D')).first;
    final rest = text.substring(1 + cc.length);
    if (rest.isEmpty || (rest[0] != '-' && rest[0] != ' ')) {
      throw HongguoAccountError('境外号码写成 +区号 号码，如 +886 0912345678');
    }
    return format(cc, rest);
  }

  /// 显示用打码：只留首尾，其余打星，绝不回显完整号码。
  static String mask(String mobile) {
    final digits = mobile.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 4) return '****';
    return '${digits.substring(0, 2)}******${digits.substring(digits.length - 2)}';
  }
}

/// 云端/本机续播合并策略：按更新时间判，不简单取最大集数——
/// 用户回看较早集时，较早集的云端记录不得覆盖较新的本机意图。
///
/// - 只有一方有记录：用有的一方；
/// - 两方都有：更新时间新的一方赢；时间相同取本机（刚看过的本机
///   记录优先，避免一次同步把正在看的进度顶掉）。
HongguoCloudProgress? mergeCloudProgress({
  required HongguoCloudProgress? local,
  required HongguoCloudProgress? cloud,
}) {
  if (local == null) return cloud;
  if (cloud == null) return local;
  if (cloud.updatedAtMs > local.updatedAtMs) return cloud;
  return local;
}

/// 账号传输接口：一次登录尝试用一个实例（发码与验码须是同一台
/// 设备身份，重新发码会换身份、旧验证码随之作废）。
///
/// 实现见 hongguo_account_sync.dart 的 HongguoAccountHttpTransport；
/// 测试用内存假实现即可覆盖全部状态机。
abstract interface class HongguoAccountTransport {
  /// 发短信验证码。返回打码号码与重发倒计时秒数。
  Future<HongguoCodeSent> sendPhoneCode(String mobile);

  /// 用短信验证码换会话。成功后调用方须立即用 [fetchProfile] 核对
  /// 账号资料（手机号还没有红果账号资料时，平台会返回空账号，
  /// 此时应提示用户先去官方红果 App 登录一次）。
  Future<HongguoAccountSession> verifyPhoneCode(String code);

  /// 取登录二维码（图片字节 + 有效秒数）。
  Future<HongguoQrCode> fetchQrCode();

  /// 轮询扫码状态：waiting=等手机确认，confirmed=已确认，
  /// expired=二维码过期。
  Future<HongguoQrPoll> pollQrCode();

  /// 扫码确认后换会话。
  Future<HongguoAccountSession> finishQrLogin();

  /// 读账号资料（昵称与账号 id）。
  Future<HongguoAccountProfile> fetchProfile(HongguoAccountSession session);

  /// 读账号收藏（最近一次全量）。
  Future<List<HongguoCloudFavorite>> fetchFavorites(
    HongguoAccountSession session,
  );

  /// 写账号收藏。只认 code=0 的回执，不自动重试：调用方写后须
  /// 重读列表核对，核对不上不得报“已收藏”。
  Future<void> setFavorite(
    HongguoAccountSession session,
    String seriesId,
    bool add,
  );

  /// 读云端观看历史（最近 50 部）。
  Future<List<HongguoCloudProgress>> fetchHistory(
    HongguoAccountSession session,
  );

  /// 上传一条播放进度。
  Future<void> uploadProgress(
    HongguoAccountSession session,
    HongguoCloudProgress progress,
  );

  /// 读预约列表。online=true 读已上线，false 读待上线，两类分开。
  Future<List<HongguoCloudReservation>> fetchReservations(
    HongguoAccountSession session,
    bool online,
  );

  /// 预约一部待上线作品。只认 code=0 的回执，调用方须重读列表
  /// 核对，核对不上不得报“已预约”。
  Future<void> reserve(
    HongguoAccountSession session,
    String seriesId, {
    required bool upcoming,
  });
}
