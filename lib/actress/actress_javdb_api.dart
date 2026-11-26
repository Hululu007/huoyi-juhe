import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'actress_adapter_http.dart' show ContentHttp;
import 'actress_adapter_models.dart' show AppFailure;
import 'actress_online_sources.dart' show actressCodeKey;

/// JavDB 接口（信息源）：2026-11-27 照魔蚁侧修正版（提交
/// b0e196d，jar 版 ZakaJavdbAmns 原文 + AvPlay 反编译实证）
/// 移植，只取作品详情页要用的两条：按番号搜索、作品详情补
/// 充（剧照/评分/系列/演员）。接口形状以修正版为准，不自写
/// 不猜写：
/// - 基址 https://jdforrepam.com，签名头 jdSignature =
///   {秒}.lpw6vgqzsp.{MD5(秒+写死盐)}，每请求现算，不带令牌；
/// - 搜索 api/v2/search?q=（参数名 q 照 jar 版实证，旧写
///   keyword 是推定、已改）；详情 api/v1/movies/{id}；
/// - 成功门：success 为真，或没给 success 时以 data 在场
///   为准（jar 版 api() 同口径）。
///
/// 定位：JavDB 本身不给播放入口，只喂详情页数据（剧照补
/// 图、评分、系列、演员头像）；播放走本地库 + who's /
/// 123AV / PH 线路。本机出口连不上该域名，整条源未验，
/// 补数失败一律静默回空、不挡开页。

const javdbApiBase = 'https://jdforrepam.com';

/// 写死盐（JavDbApiSignature，API_MAP 逐字实证）。
const _javdbSalt =
    '71cf27bb3c0bcdf207b64abecddc970098c7421ee7203b9cdae54478478a199e7d5a6e1a57691123c1a931c057842fb73ba3b3c83bcd69c17ccf174081e3d8aa';

/// jdSignature = {秒}.{固定串}.{MD5(秒 + 盐)}。
String javdbSignature(int timestampSeconds) {
  final digest = md5
      .convert(utf8.encode('$timestampSeconds$_javdbSalt'))
      .toString();
  return '$timestampSeconds.lpw6vgqzsp.$digest';
}

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

/// 是不是 JavDB 图床的图（实证图床域名 jdbstatic.com）：
/// 这类图字节带 XOR 加密，显示必须走解密路径（见
/// actress_javdb_image.dart），普通网络图组件解不出。
bool javdbIsImageUrl(String url) {
  final host = Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  return host == 'jdbstatic.com' || host.endsWith('.jdbstatic.com');
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

/// 一部作品（JavDbApiMovie 字段名逐字实证，解析宽容）。
class JavdbMovie {
  const JavdbMovie({
    required this.id,
    required this.number,
    required this.title,
    this.thumbUrl = '',
    this.coverUrl = '',
    this.durationSeconds = 0,
    this.releaseDate = '',
    this.score = '',
  });

  final String id;
  final String number;
  final String title;
  final String thumbUrl;
  final String coverUrl;
  final int durationSeconds;
  final String releaseDate;

  /// 评分原值（接口没给就是空，不编）。
  final String score;

  String get poster => coverUrl.isNotEmpty ? coverUrl : thumbUrl;

  factory JavdbMovie.fromJson(Map<String, dynamic> json) {
    return JavdbMovie(
      id: _javdbStr(json['id']),
      number: _javdbStr(json['number']),
      title: _javdbStr(json['title']),
      thumbUrl: _javdbStr(json['thumb_url']),
      coverUrl: _javdbStr(json['cover_url']),
      durationSeconds: _javdbInt(json['duration']),
      releaseDate: _javdbStr(json['release_date']),
      score: _javdbStr(json['score']),
    );
  }
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
    return JavdbActor(
      id: _javdbStr(json['id']),
      name: name,
      avatarUrl: _javdbStr(json['avatar_url']),
      gender: _javdbInt(json['gender'], fallback: -1),
    );
  }
}

/// 作品详情补充（JavDbApiMovieDetail）：演员、剧照、信息行、
/// 评分——只带接口真返回的。
class JavdbMovieExtra {
  const JavdbMovieExtra({
    this.actors = const [],
    this.stills = const [],
    this.extraInfo = const [],
    this.score = '',
    this.scoreCount = 0,
  });

  final List<JavdbActor> actors;

  /// 预览图（preview_images 的 large_url）——剧照真数据。
  final List<String> stills;

  /// (标签, 值)：导演/制作商/发行商/系列。
  final List<(String, String)> extraInfo;

  /// 评分原值；接口没给就是空，详情页不显示、不编。
  final String score;

  /// 评分人数：score_count → score_users → reviews_count
  /// 依次兜底（修正版口径）；0 = 没给。
  final int scoreCount;
}

String _javdbStr(Object? value) {
  if (value == null) return '';
  return value.toString().trim();
}

int _javdbInt(Object? value, {int fallback = 0}) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

/// 可注入取数（测试用）：给 URL 回响应文本。
typedef JavdbFetch = Future<String> Function(String url);

/// JavDB API 客户端：每请求现算签名头；不带令牌（无账号）。
class JavdbApiClient {
  JavdbApiClient({JavdbFetch? fetch, ContentHttp? http})
    : _fetch = fetch,
      _http = http ?? ContentHttp();

  final JavdbFetch? _fetch;
  final ContentHttp _http;

  Map<String, String> _headers() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return {
      'jdSignature': javdbSignature(ts),
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/122.0 Mobile Safari/537.36',
      'Accept': 'application/json',
    };
  }

  Future<dynamic> _getJson(String path) async {
    final url = '$javdbApiBase/$path';
    final String text;
    if (_fetch != null) {
      text = await _fetch(url);
    } else {
      text = await _http
          .get(url, headers: _headers())
          .timeout(const Duration(seconds: 25));
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw AppFailure('JavDB 接口返回异常，请稍后再试');
    }
    final success = decoded['success'];
    // 成功门：success 明确为真最稳；没给 success 字段时以
    // data 在场为准（jar 版 api() 同口径）；明确为假拒绝。
    final ok =
        success == true ||
        success == 1 ||
        success?.toString().toLowerCase() == 'true' ||
        (success == null && decoded.containsKey('data'));
    if (!ok) {
      final message = _javdbStr(decoded['message']);
      throw AppFailure(message.isNotEmpty ? message : 'JavDB 接口拒绝了请求');
    }
    return decoded['data'];
  }

  /// 搜索作品（api/v2/search，参数名 q 照 jar 版实证）。
  Future<List<JavdbMovie>> searchMovies(String keyword, {int page = 1}) async {
    final q = Uri.encodeQueryComponent(keyword.trim());
    final data = await _getJson('api/v2/search?q=$q&page=$page');
    final list = _listOf(data, const ['movies', 'list', 'items']);
    return [
      for (final item in list)
        if (item is Map<String, dynamic>) JavdbMovie.fromJson(item),
    ];
  }

  /// 作品详情补充（api/v1/movies/{id}）：演员、剧照（预览
  /// 图）、导演/制作商/发行商/系列、评分——只取真返回的。
  Future<JavdbMovieExtra> movieExtra(String movieId) async {
    final data = await _getJson('api/v1/movies/$movieId');
    if (data is! Map<String, dynamic>) return const JavdbMovieExtra();
    final actors = <JavdbActor>[];
    final rawActors = data['actors'];
    if (rawActors is List) {
      for (final item in rawActors) {
        if (item is Map<String, dynamic>) {
          actors.add(JavdbActor.fromJson(item));
        }
      }
    }
    final stills = <String>[];
    final rawImages = data['preview_images'];
    if (rawImages is List) {
      for (final item in rawImages) {
        if (item is Map<String, dynamic>) {
          final url = _javdbStr(item['large_url']);
          if (url.isNotEmpty) stills.add(url);
        } else if (item is String && item.isNotEmpty) {
          stills.add(item);
        }
      }
    }
    final extra = <(String, String)>[
      if (_javdbStr(data['director_name']).isNotEmpty)
        ('导演', _javdbStr(data['director_name'])),
      if (_javdbStr(data['maker_name']).isNotEmpty)
        ('制作商', _javdbStr(data['maker_name'])),
      if (_javdbStr(data['publisher_name']).isNotEmpty)
        ('发行商', _javdbStr(data['publisher_name'])),
      if (_javdbStr(data['series_name']).isNotEmpty)
        ('系列', _javdbStr(data['series_name'])),
    ];
    var scoreCount = _javdbInt(data['score_count']);
    if (scoreCount <= 0) scoreCount = _javdbInt(data['score_users']);
    if (scoreCount <= 0) scoreCount = _javdbInt(data['reviews_count']);
    return JavdbMovieExtra(
      actors: actors,
      stills: stills,
      extraInfo: extra,
      score: _javdbStr(data['score']),
      scoreCount: scoreCount,
    );
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
/// 补充。搜索与详情各 6 秒超时；任何失败/超时回 null，不
/// 抛错——补数永远不挡开页（照魔蚁侧补图口径）。
Future<({JavdbMovie movie, JavdbMovieExtra extra})?> actressJavdbSupplement({
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
    final extra = await client.movieExtra(hit.id).timeout(timeout);
    return (movie: hit, extra: extra);
  } catch (_) {
    return null;
  }
}
