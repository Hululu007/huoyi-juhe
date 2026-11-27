import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'actress_adapter_http.dart' show ContentHttp;
import 'actress_adapter_models.dart' show AppFailure;
import 'actress_online_sources.dart' show actressCodeKey;

/// JavDB 接口（信息源）：2026-11-27 对齐 jar 版蜘蛛
/// ZakaJavdbAmns 的已验证路线（魔蚁侧同日转写 Dart 并实证，
/// 本文件照其修正版移植、适配修仙版接口面），只取作品详情
/// 页要用的三条：按番号搜索定位、作品详情补充、磁力列表。
/// 五项通道口径（逐项照 jar 版，不自写不猜写）：
/// - 域名：主域名 apidd.spthgb.com（jar 版 BASE_URL），
///   jdforrepam.com（AvPlay 的接口域名）作网络失败兜底，
///   主域名连不上/超时自动切换、切换即清令牌；
/// - 开会话：POST api/v1/sessions 换令牌（字段照 jar 版
///   常量，base85 编码存放、运行时解码）——照 jar 版 api()
///   源码实证（2026-11-27 回读）：这是**机会性尝试**，调
///   了不看成败，失败/超时照样发数据请求；请求头仅在令
///   牌非空时才加 Authorization，没令牌只带签名头照样取
///   数。只有个别分类真需要令牌，那类拿不到令牌时只在
///   该处失败、不拖垮其它数据。令牌只存内存、不落盘不
///   打日志；开会话尝试有 4 秒上限，绝不吃掉数据请求的
///   时间预算；
/// - 签名：头名全小写 jdsignature = {秒}.lpw6vgqzsp.
///   {MD5(秒+写死盐)}，每请求现算；UA 照 jar 版 Dart/3.5；
/// - 详情：走 api/v4/movies/{id} 取 data.movie（旧 v1 详情
///   魔蚁侧实测 404，是详情页补不到数据的根因之一）；
///   搜索 api/v2/search 参数名 q（jar 版实证）；
/// - 图片：tp.spfcas.com 与 c0.jdbstatic.com 两家图床的字节
///   同为 XOR 加密，取图要解密 + 带 Referer（见
///   actress_javdb_image.dart）。
///
/// 定位：JavDB 本身不给播放入口，只喂详情页数据（剧照/评
/// 分/评分人数/系列/制作商/演员头像/译名/磁力）；播放走本
/// 地库 + 123AV / PH 线路。本机出口连不上该域名，整条源
/// 真拉未验；补数失败一律静默回空、不挡开页、不上英文原文。

/// API 主域名：jar 版 ZakaJavdbAmns 的 BASE_URL（已验证路线）。
const javdbApiBase = 'https://apidd.spthgb.com';

/// API 兜底域名：AvPlay 的接口域名，主域名网络层失败时切换。
const javdbApiBaseFallback = 'https://jdforrepam.com';

/// 写死盐（JavDbApiSignature，API_MAP 逐字实证）。
const _javdbSalt =
    '71cf27bb3c0bcdf207b64abecddc970098c7421ee7203b9cdae54478478a199e7d5a6e1a57691123c1a931c057842fb73ba3b3c83bcd69c17ccf174081e3d8aa';

/// jdsignature = {秒}.{固定串}.{MD5(秒 + 盐)}。
String javdbSignature(int timestampSeconds) {
  final digest = md5
      .convert(utf8.encode('$timestampSeconds$_javdbSalt'))
      .toString();
  return '$timestampSeconds.lpw6vgqzsp.$digest';
}

/// base85 解码（jar 版 b85decode 逐字移植：不在表里的字符
/// 跳过；每 5 字符还原 4 字节，尾组 n 字符还原 n-1 字节、
/// 缺位按 84 补）。
const _javdbB85Alphabet =
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
    '!#\$%&()*+-;<=>?@^_`{|}~';

String javdbB85Decode(String encoded) {
  final values = <int>[];
  for (final unit in encoded.codeUnits) {
    if (unit >= 128) continue;
    final index = _javdbB85Alphabet.indexOf(String.fromCharCode(unit));
    if (index >= 0) values.add(index);
  }
  final bytes = <int>[];
  for (var i = 0; i < values.length; i += 5) {
    final take = values.length - i >= 5 ? 5 : values.length - i;
    var value = 0;
    for (var j = 0; j < 5; j++) {
      value = value * 85 + (j < take ? values[i + j] : 84);
    }
    final group = [
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
    bytes.addAll(take == 5 ? group : group.sublist(0, take - 1));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// 开会话字段（jar 版 LOGIN_FIELDS_B85 原文照抄，值是
/// base85 编码、运行时才解码；明文不落任何文件/日志）。
const _javdbLoginFieldsB85 = <(String, String)>[
  ('username', 'Y;1XTW@T<?HZVCrXKi6=Y%XJOZ2'),
  ('password', 'ad%~MG&3?W'),
  ('device_uuid', 'H#lQuFgY<aEjKYRWi2&0GBhn=FfuePHDWn2VmLNsIWRJ2'),
  ('device_name', 'N;WVyMg'),
  ('device_model', 'Ol59wc5g3CWo~bFZy;1cElM^pHbw'),
];

/// 开会话固定字段（jar 版开会话实现原文）。
const _javdbLoginFixedFields = <(String, String)>[
  ('platform', 'android'),
  ('system_version', '11'),
  ('app_channel', 'official'),
  ('app_version', 'official'),
  ('app_version_number', '1.9.35'),
];

/// 封面/头像/剧照 XOR 解密（JavDbImageDecryptor 逐字实证）：
/// 字节不以 JPEG/PNG/GIF/WEBP 魔数开头即判定加密——首字
/// 节是钥匙，其余每字节与它异或，输出丢弃首字节。
Uint8List javdbDecryptImageBytes(Uint8List bytes) {
  if (bytes.length < 2) return bytes;
  if (_hasImageMagic(bytes)) return bytes;
  final key = bytes[0];
  final out = Uint8List(bytes.length - 1);
  for (var i = 1; i < bytes.length; i++) {
    out[i - 1] = bytes[i] ^ key;
  }
  return out;
}

/// 是不是 JavDB 图床的图：封面/头像/剧照走 c0.jdbstatic.com
/// 与 tp.spfcas.com 两家，字节同带 XOR 加密，显示必须走
/// actress_javdb_image.dart 的解密路径，普通网络图组件解不出。
bool javdbIsImageUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'jdbstatic.com' ||
      host.endsWith('.jdbstatic.com') ||
      host == 'spfcas.com' ||
      host.endsWith('.spfcas.com');
}

bool _hasImageMagic(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return true; // JPEG
  }
  if (b.length >= 4 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return true; // PNG
  }
  if (b.length >= 4 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x38) {
    return true; // GIF
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return true; // WEBP (RIFF....WEBP)
  }
  return false;
}

/// 一部作品（JavDbApiMovie 字段名逐字实证，解析宽容：数值/
/// 字符串混型都收）。
class JavdbMovie {
  const JavdbMovie({
    required this.id,
    required this.number,
    required this.title,
    this.thumbUrl = '',
    this.coverUrl = '',
    this.durationMinutes = 0,
    this.releaseDate = '',
    this.score = '',
    this.previewImages = const [],
  });

  final String id;
  final String number;
  final String title;
  final String thumbUrl;
  final String coverUrl;

  /// 时长（分钟）：接口 duration 字段就是分钟（魔蚁侧实测
  /// 互证：latest 列表 ADN-821 回 150；旧实现误当秒再除以
  /// 60 显示，正片只剩「3 分钟」——用户实报的错误形态）。
  final int durationMinutes;
  final String releaseDate;

  /// 评分原值（接口没给就是空，不编）。
  final String score;

  /// 剧照（列表/搜索信封自带的 preview_images，large 优先、
  /// thumb 兜底）。
  final List<String> previewImages;

  String get poster => coverUrl.isNotEmpty ? coverUrl : thumbUrl;

  factory JavdbMovie.fromJson(Map<String, dynamic> json) {
    return JavdbMovie(
      id: _javdbStr(json['id']),
      number: _javdbStr(json['number']),
      title: _javdbStr(json['title']),
      thumbUrl: _javdbStr(json['thumb_url']),
      coverUrl: _javdbStr(json['cover_url']),
      durationMinutes: _javdbInt(json['duration']),
      releaseDate: _javdbStr(json['release_date']),
      score: _javdbStr(json['score']),
      previewImages: _javdbPreviewUrls(json['preview_images']),
    );
  }
}

/// preview_images 数组 → 剧照地址表（元素是 {large_url,
/// thumb_url} 对象或纯字符串，两种都认；large 优先）。
List<String> _javdbPreviewUrls(Object? raw) {
  if (raw is! List) return const [];
  final urls = <String>[];
  for (final item in raw) {
    if (item is Map) {
      var url = _javdbStr(item['large_url']);
      if (url.isEmpty) url = _javdbStr(item['thumb_url']);
      if (url.isNotEmpty) urls.add(url);
    } else if (item is String && item.isNotEmpty) {
      urls.add(item);
    }
  }
  return urls;
}

/// 一名演员（JavDbApiActor：id / name / avatar_url / gender）。
class JavdbActor {
  const JavdbActor({
    required this.id,
    required this.name,
    this.avatarUrl = '',
    this.gender = -1,
  });

  final String id;
  final String name;
  final String avatarUrl;

  /// 性别原值（映射口径未证实，只存不译）。
  final int gender;

  factory JavdbActor.fromJson(Map<String, dynamic> json) {
    // 名字取值顺序照 jar 版 actorOptions 实证：name 优先、
    // 空了落 name_zht（繁中名）。
    var name = _javdbStr(json['name']);
    if (name.isEmpty) name = _javdbStr(json['name_zht']);
    // 头像取值照 jar 版：avatar_url 优先、cover_url 兜底。
    var avatar = _javdbStr(json['avatar_url']);
    if (avatar.isEmpty) avatar = _javdbStr(json['cover_url']);
    return JavdbActor(
      id: _javdbStr(json['id']),
      name: name,
      avatarUrl: avatar,
      gender: _javdbInt(json['gender'], fallback: -1),
    );
  }
}

/// 作品详情补充（api/v4/movies/{id} 的 data.movie）：演员、
/// 剧照、信息行、评分、原标题、标签、相关推荐——只带接口
/// 真返回的，没返回就是空、页面整块不出、不编造。
class JavdbMovieExtra {
  const JavdbMovieExtra({
    this.actors = const [],
    this.stills = const [],
    this.extraInfo = const [],
    this.score = '',
    this.scoreCount = 0,
    this.poster = '',
    this.originTitle = '',
    this.tags = const [],
    this.relativeMovies = const [],
    this.actorMovies = const [],
  });

  final List<JavdbActor> actors;

  /// 预览图（preview_images 的 large_url）——剧照真数据。
  final List<String> stills;

  /// (标签, 值)：导演/制作商/发行商/系列。
  final List<(String, String)> extraInfo;

  /// 评分原值；接口没给就是空，详情页不显示、不编。
  final String score;

  /// 评分人数：score_count → score_users → reviews_count
  /// 依次兜底（魔蚁侧口径）；0 = 没给。
  final int scoreCount;

  /// 详情自带的封面（cover_url 优先、thumb_url 兜底）。
  final String poster;

  /// 原标题（origin_title）：与页面标题不同时，详情页大标
  /// 题旁出「翻译」切换；接口没给/相同就是空/同值，不显示。
  final String originTitle;

  /// 相关分类名（tags[].name）：详情页标签行用。
  final List<String> tags;

  /// 相关推荐（relative_movies）：详情页「你可能也喜欢」
  /// 真数据；没返回就是空、整区不出。
  final List<JavdbMovie> relativeMovies;

  /// 本片演员的其他作品（actor_movies）：详情页「她们还
  /// 演出过」真数据；没返回就是空、整区不出。
  final List<JavdbMovie> actorMovies;
}

/// 磁力一条（详情页「下载链接」区用）：只带接口真返回的
/// 字段——名称/链接/体积文本/高清/日期/中文字幕，有啥摆啥。
class JavdbMagnet {
  const JavdbMagnet({
    required this.name,
    required this.url,
    this.sizeLabel = '',
    this.dateLabel = '',
    this.hd = false,
    this.cnsub = false,
  });

  final String name;

  /// 完整磁力链接（点按复制用）。
  final String url;
  final String sizeLabel;

  /// 日期（YYYY-MM-DD 形态）；接口没给/不像日期就是空。
  final String dateLabel;
  final bool hd;
  final bool cnsub;
}

/// hash 归一（照 jar 版 normHash）：磁力链接里抽 btih，只认
/// 40 位十六进制、转小写；认不出回空（这类条目排序时丢弃）。
String javdbNormHashOf(String raw) {
  var text = raw.trim();
  if (text.toLowerCase().startsWith('magnet:')) {
    final match = RegExp(
      r'xt=urn:btih:([0-9a-fA-F]{40})',
      caseSensitive: false,
    ).firstMatch(text);
    text = match?.group(1) ?? '';
  }
  return RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(text) ? text.toLowerCase() : '';
}

double _javdbNumOf(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return 0;
}

/// 磁力打分（照 jar 版 score() 逐项对照）：做种数 ×1e9 主
/// 导；中文字幕 +1e7；高清 +1e6；大小在 500–8000 MB 区间
/// +1e5；日期 ×0.001；最后减 |大小MB-2500|×1e-6 微调。
/// size 数字按 MB 读（与 jar 的 num(size) 同口径）。
double javdbMagnetScoreOf(Map<String, dynamic> json) {
  final seeders = _javdbNumOf(json, const [
    'seeders',
    'seeds',
    'heat',
    'popularity',
  ]);
  final name = _javdbStr(json['name']).toLowerCase();
  final cnsub =
      _javdbBool(json['cnsub']) ||
      name.contains('中文字幕') ||
      name.contains('中字') ||
      name.contains('中文') ||
      name.contains('chinese') ||
      name.contains('chs') ||
      name.contains('cht');
  final hd =
      _javdbBool(json['hd']) ||
      name.contains('2160p') ||
      name.contains('4k') ||
      name.contains('1080p') ||
      name.contains('高清') ||
      name.contains('hd');
  final sizeMb = _javdbNumOf(json, const ['size']);
  final sizeInRange = sizeMb >= 500 && sizeMb <= 8000;
  var dateValue = 0.0;
  final dateText = _javdbStr(json['created_at']).isNotEmpty
      ? _javdbStr(json['created_at'])
      : _javdbStr(json['release_date']);
  final dateMatch = RegExp(
    r'(20\d{2})[-/]?(\d{2})?[-/]?(\d{2})?',
  ).firstMatch(dateText);
  if (dateMatch != null) {
    dateValue =
        (int.parse(dateMatch.group(1)!) * 10000 +
                int.parse(dateMatch.group(2) ?? '0') * 100 +
                int.parse(dateMatch.group(3) ?? '0'))
            .toDouble();
  }
  return seeders * 1e9 +
      (cnsub ? 1e7 : 0) +
      (hd ? 1e6 : 0) +
      (sizeInRange ? 1e5 : 0) +
      dateValue * 0.001 -
      (sizeMb - 2500).abs() * 1e-6;
}

/// 磁力排序（照 jar 版 rankMagnets）：按 normHash 去重（同
/// hash 只留分高的一条，hash 认不出的条目丢弃），按分降序。
List<Map<String, dynamic>> javdbRankMagnetJsons(
  List<Map<String, dynamic>> items,
) {
  final byHash = <String, (Map<String, dynamic>, double)>{};
  for (final item in items) {
    var candidate = '';
    for (final key in const ['hash', 'magnet', 'magnet_url', 'url', 'link']) {
      final value = _javdbStr(item[key]);
      if (value.isNotEmpty) {
        candidate = value;
        break;
      }
    }
    final hash = javdbNormHashOf(candidate);
    if (hash.isEmpty) continue;
    final score = javdbMagnetScoreOf(item);
    final existing = byHash[hash];
    if (existing == null || score > existing.$2) {
      byHash[hash] = (item, score);
    }
  }
  final ranked = byHash.values.toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return [for (final entry in ranked) entry.$1];
}

/// 磁力一条 → JavdbMagnet（字段照 jar 版 magnets 实证：
/// hash/name/size（MB）/created_at/hd/cnsub；链接拼法照
/// jar 版 magnetUri：magnet:?xt=urn:btih:{hash}，有名时带
/// &dn={编码后的「[javdb.com]」+名}；url 字段已是现成磁力
/// 链接时照原样）。hash 与现成链接都拿不到回 null（不编）。
JavdbMagnet? javdbMagnetLinkOf(Map<String, dynamic> json) {
  var url = '';
  for (final key in const ['magnet', 'magnet_url', 'url', 'link']) {
    final value = _javdbStr(json[key]);
    if (value.startsWith('magnet:')) {
      url = value;
      break;
    }
  }
  final hash = _javdbStr(json['hash']);
  if (url.isEmpty) {
    if (hash.isEmpty) return null;
    url = 'magnet:?xt=urn:btih:$hash';
    final rawName = _javdbStr(json['name']);
    if (rawName.isNotEmpty) {
      final dn = rawName.startsWith('[javdb.com]')
          ? rawName
          : '[javdb.com]$rawName';
      url = '$url&dn=${Uri.encodeComponent(dn)}';
    }
  }
  var name = _javdbStr(json['name']);
  if (name.isEmpty) name = _javdbStr(json['title']);
  if (name.isEmpty) name = hash;
  final dateDigits = javdbDateDigitsOf(
    _javdbStr(json['created_at']).isNotEmpty
        ? _javdbStr(json['created_at'])
        : _javdbStr(json['date']),
  );
  return JavdbMagnet(
    name: name,
    url: url,
    sizeLabel: javdbSizeLabelOf(json['size']),
    dateLabel: dateDigits.isEmpty
        ? ''
        : '${dateDigits.substring(0, 4)}-${dateDigits.substring(4, 6)}-'
              '${dateDigits.substring(6, 8)}',
    hd: _javdbBool(json['hd']),
    cnsub: _javdbBool(json['cnsub']),
  );
}

/// size 字段转显示文本：数字按 MB（>=1024 换 GB，两位小数
/// 去尾零）；字符串照原样；其余回空。
String javdbSizeLabelOf(Object? size) {
  if (size is num) {
    final mb = size.toDouble();
    if (mb <= 0) return '';
    if (mb >= 1024) {
      var text = (mb / 1024).toStringAsFixed(2);
      if (text.contains('.')) {
        text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(
          RegExp(r'\.$'),
          '',
        );
      }
      return '$text GB';
    }
    return mb == mb.roundToDouble() ? '${mb.toInt()} MB' : '$mb MB';
  }
  return _javdbStr(size);
}

/// 日期文本归一成 YYYYMMDD：取开头的年月日数字，不像日期
/// （不以 19/20 开头或不足 8 位）回空，不硬凑。
String javdbDateDigitsOf(String raw) {
  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length < 8) return '';
  final head = digits.substring(0, 8);
  if (!head.startsWith('19') && !head.startsWith('20')) return '';
  return head;
}

String _javdbStr(Object? value) {
  if (value == null) return '';
  return value.toString().trim();
}

int _javdbInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

bool _javdbBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().toLowerCase() ?? '';
  return text == 'true' || text == '1';
}

/// 响应体不是 JSON 信封（空体/HTML 错误页等）：属解析失败，
/// 不是网络层失败，域名兜底不重试（见 _requestEnvelope）。
class _JavdbBadBody implements Exception {
  const _JavdbBadBody();
}

/// 可注入取数（测试用）：给 URL 回响应文本。
typedef JavdbFetch = Future<String> Function(String url);

/// 可注入 POST（测试用）：URL + 正文 + Content-Type 回响应文本。
typedef JavdbPostFetch =
    Future<String> Function(String url, String body, String contentType);

/// JavDB API 客户端（对齐 jar 版已验证路线）：开会话换令
/// 牌是机会性尝试（不看成败、失败不挡数据请求，无令牌只
/// 带签名头照常取数）、每请求现算签名头（全小写
/// jdsignature）；主域名网络层失败自动切兜底域名。令牌
/// 只存内存、不落盘不打日志。
class JavdbApiClient {
  JavdbApiClient({
    JavdbFetch? fetch,
    JavdbPostFetch? post,
    ContentHttp? http,
    void Function(Map<String, String> headers)? onHeaders,
    this.sessionTimeout = const Duration(seconds: 4),
  }) : _fetch = fetch,
       _postFetch = post,
       _http = http ?? ContentHttp(),
       _onHeaders = onHeaders;

  final JavdbFetch? _fetch;
  final JavdbPostFetch? _postFetch;
  final ContentHttp _http;

  /// 开会话尝试的时长上限：会话端点慢/挂时到点就放弃、
  /// 照常发数据请求（只带签名头），不许吃掉调用方给数据
  /// 请求的时间预算。测试可调短。
  final Duration sessionTimeout;

  /// 请求头观察口（测试断言签名头名/Authorization 用，生产不传）。
  final void Function(Map<String, String> headers)? _onHeaders;

  String _base = javdbApiBase;
  String _token = '';

  Map<String, String> _headers() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final headers = {
      // 头名照 jar 版 appHeaders 全小写 jdsignature（旧写
      // jdSignature 大小写混排，服务端可能不认）。
      'jdsignature': javdbSignature(ts),
      // UA 照 jar 版 APP_UA 原文。
      'User-Agent': 'Dart/3.5 (dart:io)',
      'Accept-Language': 'zh-TW',
      'Accept': 'application/json',
      if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
    };
    _onHeaders?.call(headers);
    return headers;
  }

  /// 开会话换令牌（jar 版开会话实现逐字移植）：POST
  /// api/v1/sessions，multipart 表单 = base85 字段解码值 +
  /// 五个固定字段；success=1 且 data.token 长度 ≥8 才算成。
  /// 失败回 false、不抛错——照 jar 版 api() 实证，这是机
  /// 会性尝试：成败都不拦后续数据请求，没令牌时数据请求
  /// 只带签名头照常发。整段尝试受 [sessionTimeout] 上限
  /// 约束，会话端点挂住也不会拖住数据请求。
  Future<bool> _openSession() async {
    // 测试只注入了 GET 取数时不假装开会话（夹具按 URL 分
    // 发，也不该被开会话请求消耗）。
    if (_fetch != null && _postFetch == null) return false;
    final boundary =
        '----javdb-tvbox-'
        '${md5.convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}')).toString().substring(0, 24)}';
    final body = StringBuffer();
    void field(String name, String value) {
      body.write(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="$name"\r\n\r\n'
        '$value\r\n',
      );
    }

    for (final (name, encoded) in _javdbLoginFieldsB85) {
      field(name, javdbB85Decode(encoded));
    }
    for (final (name, value) in _javdbLoginFixedFields) {
      field(name, value);
    }
    body.write('--$boundary--\r\n');
    final contentType = 'multipart/form-data; boundary=$boundary';
    try {
      final String text;
      if (_postFetch != null) {
        text = await _postFetch(
          '$_base/api/v1/sessions',
          body.toString(),
          contentType,
        ).timeout(sessionTimeout);
      } else {
        text = await _http
            .postRaw(
              '$_base/api/v1/sessions',
              body.toString(),
              headers: {
                'User-Agent': 'Dart/3.5 (dart:io)',
                'Accept-Language': 'zh-TW',
                'Accept': 'application/json',
                'Content-Type': contentType,
                'jdsignature': javdbSignature(
                  DateTime.now().millisecondsSinceEpoch ~/ 1000,
                ),
              },
            )
            .timeout(sessionTimeout);
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> &&
          (decoded['success'] == 1 || decoded['success'] == true)) {
        final data = decoded['data'];
        final token = data is Map ? _javdbStr(data['token']) : '';
        if (token.length >= 8) {
          _token = token;
          return true;
        }
      }
    } catch (_) {
      // 开会话失败/超时不挡数据接口，调用方只带签名头照常
      // 发请求（jar 版 api() 同口径：不看开会话成败）。
    }
    return false;
  }

  bool _envelopeOk(Map<String, dynamic> envelope) {
    final success = envelope['success'];
    // 成功门：success 明确为真最稳；没给 success 字段时以
    // data 在场为准；success 明确为假就是假。
    return success == true ||
        success == 1 ||
        success?.toString().toLowerCase() == 'true' ||
        (success == null && envelope.containsKey('data'));
  }

  Future<Map<String, dynamic>> _requestEnvelopeOnce(String path) async {
    if (_token.isEmpty) await _openSession();
    final url = '$_base/$path';
    final String text;
    if (_fetch != null) {
      text = await _fetch(url);
    } else {
      text = await _http
          .get(url, headers: _headers())
          .timeout(const Duration(seconds: 25));
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const _JavdbBadBody();
    }
    if (decoded is! Map<String, dynamic>) {
      throw const _JavdbBadBody();
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _requestEnvelope(String path) async {
    try {
      return await _requestEnvelopeOnce(path);
    } catch (error) {
      // 只对网络层失败（连不上/超时/传输异常）切兜底域名、
      // 清令牌后重试一次（魔蚁侧口径）；响应体解析失败
      // 不是网络问题，换域名也一样，不重试。测试注入模式
      // 保持单域名语义、不重试。
      if (error is _JavdbBadBody ||
          _fetch != null ||
          _base == javdbApiBaseFallback) {
        rethrow;
      }
      _base = javdbApiBaseFallback;
      _token = '';
      return _requestEnvelopeOnce(path);
    }
  }

  Future<dynamic> _getJson(String path) async {
    var envelope = await _requestEnvelope(path);
    if (!_envelopeOk(envelope)) {
      // 信封 success 不是 1：清掉现令牌、再试一次开会话并
      // 重试一次（令牌过期时详情、磁力靠这一步）；仍失败
      // 只让本接口失败，不拖垮同页其它数据。
      _token = '';
      await _openSession();
      envelope = await _requestEnvelope(path);
    }
    if (!_envelopeOk(envelope)) {
      // 服务端信封原文（外文/授权提示）不往上抛：只在本接
      // 口给固定中文说明。拿不到令牌多半是本接口真需要授
      // 权，如实区分；其它数据路由不受影响。
      throw AppFailure(
        _token.isEmpty
            ? '此内容需要接口授权，当前拿不到授权'
            : 'JavDB 接口拒绝了请求',
      );
    }
    return envelope['data'];
  }

  /// 搜索作品（api/v2/search，参数名 q 照 jar 版实证——旧
  /// 写 keyword 是推定、已改）。
  Future<List<JavdbMovie>> searchMovies(String keyword, {int page = 1}) async {
    final q = Uri.encodeQueryComponent(keyword.trim());
    final data = await _getJson('api/v2/search?q=$q&page=$page');
    final list = _listOf(data, const ['movies', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbMovie.fromJson(item),
    ];
  }

  /// 演员列表（api/v1/actors?type=0&page=N，路径与必传参数
  /// type 由 jar 版原文实证：漏传 type 服务端回「参数不能
  /// 为空: type」；信封 data.actors、字段 id/name/name_zht/
  /// avatar_url/videos_count 同其实证）。头像补全链按名查
  /// 人用（见 actress_avatar.dart）。
  Future<List<JavdbActor>> actors({int page = 1}) async {
    final data = await _getJson('api/v1/actors?type=0&page=$page');
    final list = _listOf(data, const ['actors', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbActor.fromJson(item),
    ];
  }

  /// 按演员名查 JavDB 演员（头像补全链第二级）：演员列表没
  /// 有按名搜索端点（两个参照客户端都没有），只能逐页翻列
  /// 表按归一化名精确相等认人——最多翻 [maxPages] 页，翻不
  /// 到回 null（不拿近似名冒充）。归一口径：去全部空白、
  /// 小写（与库层 actressNameKey 同口径）。
  Future<JavdbActor?> actorByName(
    String name, {
    int maxPages = 3,
  }) async {
    final target = name.replaceAll(RegExp(r'[\s\u3000\u00A0]+'), '').toLowerCase();
    if (target.isEmpty) return null;
    for (var page = 1; page <= maxPages; page++) {
      final rows = await actors(page: page);
      if (rows.isEmpty) return null;
      for (final actor in rows) {
        final key = actor.name
            .replaceAll(RegExp(r'[\s\u3000\u00A0]+'), '')
            .toLowerCase();
        if (key == target && actor.avatarUrl.isNotEmpty) return actor;
      }
    }
    return null;
  }

  /// 作品详情补充（api/v4/movies/{id}，jar 版 detailContent
  /// 实证：取 data.movie、没有就 data 本体）：演员、剧照
  /// （预览图）、封面、原标题、标签、相关推荐、导演/制作
  /// 商/发行商/系列、评分——只取接口真返回的。旧走 v1 详
  /// 情：魔蚁侧实测 v1 回 404，两头都拿不到，详情页补充全空。
  Future<JavdbMovieExtra> movieExtra(String movieId) async {
    final data = await _getJson('api/v4/movies/$movieId');
    if (data is! Map<String, dynamic>) return const JavdbMovieExtra();
    final rawMovie = data['movie'];
    final map = rawMovie is Map<String, dynamic> ? rawMovie : data;
    final actors = <JavdbActor>[];
    final rawActors = map['actors'];
    if (rawActors is List) {
      for (final item in rawActors) {
        if (item is Map<String, dynamic>) {
          actors.add(JavdbActor.fromJson(item));
        }
      }
    }
    final extra = <(String, String)>[
      if (_javdbStr(map['director_name']).isNotEmpty)
        ('导演', _javdbStr(map['director_name'])),
      if (_javdbStr(map['maker_name']).isNotEmpty)
        ('制作商', _javdbStr(map['maker_name'])),
      if (_javdbStr(map['publisher_name']).isNotEmpty)
        ('发行商', _javdbStr(map['publisher_name'])),
      if (_javdbStr(map['series_name']).isNotEmpty)
        ('系列', _javdbStr(map['series_name'])),
    ];
    var scoreCount = _javdbInt(map['score_count']);
    if (scoreCount <= 0) scoreCount = _javdbInt(map['score_users']);
    if (scoreCount <= 0) scoreCount = _javdbInt(map['reviews_count']);
    var poster = _javdbStr(map['cover_url']);
    if (poster.isEmpty) poster = _javdbStr(map['thumb_url']);
    final tags = <String>[];
    final rawTags = map['tags'];
    if (rawTags is List) {
      for (final item in rawTags) {
        if (item is Map<String, dynamic>) {
          final name = _javdbStr(item['name']);
          if (name.isNotEmpty && !tags.contains(name)) tags.add(name);
        } else if (item is String && item.isNotEmpty) {
          if (!tags.contains(item)) tags.add(item);
        }
      }
    }
    List<JavdbMovie> moviesOf(String key) {
      final out = <JavdbMovie>[];
      final raw = map[key];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map<String, dynamic>) {
            out.add(JavdbMovie.fromJson(item));
          }
        }
      }
      return out;
    }

    return JavdbMovieExtra(
      actors: actors,
      stills: _javdbPreviewUrls(map['preview_images']),
      extraInfo: extra,
      score: _javdbStr(map['score']),
      scoreCount: scoreCount,
      poster: poster,
      originTitle: _javdbStr(map['origin_title']),
      tags: tags,
      relativeMovies: moviesOf('relative_movies'),
      actorMovies: moviesOf('actor_movies'),
    );
  }

  /// 磁力列表（GET api/v1/movies/{id}/magnets，路径与信封
  /// data.magnets 由 jar 版原文实证；另宽容 list / items /
  /// 列表本体）。返回前照 jar 版 rankMagnets 排序去重。坏
  /// 行跳过、拿不到回空表。这是磁力的真来源：v4 详情本身
  /// 不带磁力条目（详情模型只有 magnets_count 计数）。
  Future<List<JavdbMagnet>> movieMagnets(String movieId) async {
    final data = await _getJson('api/v1/movies/$movieId/magnets');
    final list = _listOf(data, const ['magnets', 'list', 'items']);
    final raw = [
      for (final item in list)
        if (item is Map<String, dynamic>) item,
    ];
    return [
      for (final item in javdbRankMagnetJsons(raw))
        ?javdbMagnetLinkOf(item),
    ];
  }

  /// data 可能是列表本体，或 {movies:[...]} 等信封——都认，
  /// 取不到回空表（不编数据）。
  List<dynamic> _listOf(dynamic data, List<String> keys) {
    if (data is List) return data;
    if (data is Map<String, dynamic>) {
      for (final key in keys) {
        final value = data[key];
        if (value is List) return value;
      }
    }
    return const [];
  }
}

/// 详情页 JavDB 补充（按番号）：搜索结果里番号归一后**精确
/// 相等**才认（近似不认、不拿别片数据冒充），命中再取详情
/// 补充与磁力。各路 6 秒超时；任何失败/超时回 null，不抛
/// 错——补数永远不挡开页。
Future<
  ({JavdbMovie movie, JavdbMovieExtra extra, List<JavdbMagnet> magnets})?
>
actressJavdbSupplement({
  required String code,
  required JavdbApiClient client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final target = actressCodeKey(code);
  if (target.isEmpty) return null;
  try {
    final hits = await client.searchMovies(code).timeout(timeout);
    JavdbMovie? hit;
    for (final movie in hits) {
      if (actressCodeKey(movie.number) == target) {
        hit = movie;
        break;
      }
    }
    if (hit == null) return null;
    var extra = const JavdbMovieExtra();
    try {
      extra = await client.movieExtra(hit.id).timeout(timeout);
    } catch (_) {
      // 详情补充单独失败（例如该接口真需要授权、当前拿不
      // 到）只让补充缺席：搜索命中与磁力照常回，不拖垮整
      // 页补充（与磁力单独失败同口径）。
    }
    var magnets = const <JavdbMagnet>[];
    try {
      magnets = await client.movieMagnets(hit.id).timeout(timeout);
    } catch (_) {
      // 磁力单独失败只让下载区不出，不拖垮其余补充。
    }
    return (movie: hit, extra: extra, magnets: magnets);
  } catch (_) {
    return null;
  }
}
