import '../actress/actress_crosssite_probe.dart' show extractAvId;
import '../actress/actress_javdb_api.dart';
import '../actress/actress_library_db.dart';
import '../actress/actress_models.dart' show actressNameKey;
import '../actress/jav_code_meta.dart';

/// 片库详情页自动补全（JAV 路）：一名演员条目（名字 + 头像，
/// 头像没有就是空，页面回落首字占位，不编造）。
class FilmFillCast {
  const FilmFillCast({required this.name, this.avatar = ''});

  final String name;
  final String avatar;
}

/// 片库详情页自动补全结果：三路（JavDB 接口 / 本地库同番号 /
/// 本地库按番号反查详情）+ 番号元数据兜底合成的一份数据。
/// 只带各路真返回的值，补不到就是空——页面负责与自身字段
/// 判空合并，本服务不编造任何内容。
class FilmDetailFill {
  const FilmDetailFill({
    this.code = '',
    this.cover = '',
    this.synopsis = '',
    this.cast = const <FilmFillCast>[],
    this.director = '',
    this.maker = '',
    this.series = '',
    this.releaseDate = '',
    this.durationText = '',
    this.score = '',
    this.scoreCount = 0,
    this.originTitle = '',
    this.tags = const <String>[],
    this.stills = const <String>[],
  });

  /// 番号（调用方传入的原样回填）。
  final String code;

  /// 封面地址。
  final String cover;

  /// 简介。
  final String synopsis;

  /// 演员（名字 + 头像）。
  final List<FilmFillCast> cast;

  /// 导演。
  final String director;

  /// 制作商。
  final String maker;

  /// 系列。
  final String series;

  /// 发行日期（或仅年份，来自番号元数据兜底时形如 `2023`）。
  final String releaseDate;

  /// 时长文本（如 `120 分钟`）。
  final String durationText;

  /// 评分原值（接口没给就是空，不编）。
  final String score;

  /// 评分人数（0 = 没给）。
  final int scoreCount;

  /// 原标题（页面负责与自身标题比对，不同才展示）。
  final String originTitle;

  /// 标签名列表。
  final List<String> tags;

  /// 剧照地址列表（去重，上限 24）。
  final List<String> stills;

  /// 补来的数据字段全空 = 三路都没补到东西（code 是入参番号、
  /// 不是补来的数据，不计在内，否则回填番号的 fill 永不为空）。
  bool get isEmpty =>
      cover.isEmpty &&
      synopsis.isEmpty &&
      cast.isEmpty &&
      director.isEmpty &&
      maker.isEmpty &&
      series.isEmpty &&
      releaseDate.isEmpty &&
      durationText.isEmpty &&
      score.isEmpty &&
      scoreCount == 0 &&
      originTitle.isEmpty &&
      tags.isEmpty &&
      stills.isEmpty;
}

/// 从页面已有信息里抠番号：先 id+title 走 [JavCodeMeta.resolveCode]，
/// 空了再拿 remark 当标题走一遍，再空对 remark 用 [extractAvId]
/// 兜底提取。都抠不到回空字符串。
String resolveFilmCode({
  required String id,
  required String title,
  String remark = '',
}) {
  var code = JavCodeMeta.resolveCode(id: id, title: title);
  if (code.isNotEmpty) return code;
  if (remark.isNotEmpty) {
    code = JavCodeMeta.resolveCode(id: '', title: remark);
    if (code.isNotEmpty) return code;
    code = extractAvId(title: remark, id: '', sourceId: '') ?? '';
    if (code.isNotEmpty) return code;
  }
  return '';
}

/// 按番号三路并行补全详情数据，合成一份 [FilmDetailFill]：
///
/// - (a) JavDB 接口补充（评分/封面/日期/时长/原标题/标签/
///   剧照/演员/系列/制作商/导演）；
/// - (b) 本地库同番号（sameCode）：简介候选 + 演员头像表；
/// - (c) 本地库按番号反查（search 精确命中 → detail）：简介
///   候选（与 (b) 取更长者）、封面/标签/日期兜底候选。
///
/// [codeMeta] 只作导演/制作商空位与年份兜底、演员追加。
/// 单路失败吞错留空、永不抛错：补数永远不挡开页。
Future<FilmDetailFill> fillFilmDetailByCode({
  required String code,
  JavdbApiClient? javdbClient,
  Future<Map<String, dynamic>> Function(Map<String, dynamic> request)?
      dbHandle,
  CodeMeta? codeMeta,
}) async {
  final trimmedCode = code.trim();
  if (trimmedCode.isEmpty) return const FilmDetailFill();
  final handle = dbHandle ?? ActressLibraryDbFallback.shared.handle;

  // (a) JavDB 路：补充函数本身失败回 null，这里再兜一层。
  final javdbFuture = () async {
    try {
      return await actressJavdbSupplement(
        code: trimmedCode,
        client: javdbClient ?? JavdbApiClient(),
      );
    } catch (_) {
      return null;
    }
  }();

  // (b) 本地库同番号路：简介候选 + 归一化名→头像表。
  final sameCodeFuture = () async {
    var content = '';
    final avatarByKey = <String, String>{};
    try {
      final res = await handle({
        'op': 'sameCode',
        'vodId': '',
        'code': trimmedCode,
      });
      if (res['ok'] == true) {
        content = (res['content'] ?? '').toString().trim();
        final avatars = res['avatars'];
        if (avatars is List) {
          for (final row in avatars) {
            if (row is! Map) continue;
            final name = (row['name'] ?? '').toString().trim();
            final avatar = (row['avatar'] ?? '').toString().trim();
            if (name.isEmpty || avatar.isEmpty) continue;
            avatarByKey.putIfAbsent(actressNameKey(name), () => avatar);
          }
        }
      }
    } catch (_) {
      // 本路失败留空，不拖垮其余两路。
    }
    return (content: content, avatarByKey: avatarByKey);
  }();

  // (c) 本地库反查路：search 里番号全等命中一行，再取 detail。
  final dbDetailFuture = () async {
    var content = '';
    var pic = '';
    var date = '';
    var tags = const <String>[];
    try {
      final search = await handle({'op': 'search', 'q': trimmedCode, 'page': 1});
      if (search['ok'] == true) {
        final items = search['items'];
        String? hitId;
        if (items is List) {
          for (final row in items) {
            if (row is! Map) continue;
            final vodId = (row['vodId'] ?? '').toString().trim();
            if (vodId.toLowerCase() == trimmedCode.toLowerCase()) {
              hitId = vodId;
              break;
            }
          }
        }
        if (hitId != null) {
          final detail = await handle({'op': 'detail', 'vodId': hitId});
          if (detail['ok'] == true) {
            final item = detail['item'];
            if (item is Map) {
              content = (item['content'] ?? '').toString().trim();
              pic = (item['pic'] ?? '').toString().trim();
              date = (item['date'] ?? '').toString().trim();
              final rawTags = item['tags'];
              if (rawTags is List) {
                tags = [
                  for (final tag in rawTags)
                    if (tag.toString().trim().isNotEmpty) tag.toString().trim(),
                ];
              }
            }
          }
        }
      }
    } catch (_) {
      // 本路失败留空，不拖垮其余两路。
    }
    return (content: content, pic: pic, date: date, tags: tags);
  }();

  final javdb = await javdbFuture;
  final sameCode = await sameCodeFuture;
  final dbDetail = await dbDetailFuture;

  // ---- (a) JavDB 字段（优先级最高的一路） ----
  var score = '';
  var scoreCount = 0;
  var cover = '';
  var releaseDate = '';
  var durationText = '';
  var originTitle = '';
  var tags = const <String>[];
  var stills = const <String>[];
  var series = '';
  var maker = '';
  var director = '';
  final javdbCast = <FilmFillCast>[];
  final movie = javdb?.movie;
  final extra = javdb?.extra;
  if (extra != null) {
    score = extra.score;
    scoreCount = extra.scoreCount;
    cover = extra.poster;
    originTitle = extra.originTitle;
    tags = extra.tags;
    for (final (label, value) in extra.extraInfo) {
      if (label == '系列' && series.isEmpty) series = value;
      if (label == '制作商' && maker.isEmpty) maker = value;
      if (label == '导演' && director.isEmpty) director = value;
    }
    for (final actor in extra.actors) {
      if (actor.name.isEmpty) continue;
      javdbCast.add(FilmFillCast(name: actor.name, avatar: actor.avatarUrl));
    }
  }
  if (movie != null) {
    if (score.isEmpty) score = movie.score;
    if (cover.isEmpty) cover = movie.poster;
    releaseDate = movie.releaseDate;
    if (movie.durationMinutes > 0) {
      durationText = '${movie.durationMinutes} 分钟';
    }
  }
  {
    final seen = <String>{};
    final merged = <String>[];
    for (final url in [
      ...?extra?.stills,
      ...?movie?.previewImages,
    ]) {
      final text = url.trim();
      if (text.isEmpty || !seen.add(text)) continue;
      merged.add(text);
      if (merged.length >= 24) break;
    }
    stills = merged;
  }

  // ---- (c) 本地库反查兜底（封面/日期/标签只填空位） ----
  if (cover.isEmpty) cover = dbDetail.pic;
  if (releaseDate.isEmpty) releaseDate = dbDetail.date;
  if (tags.isEmpty) tags = dbDetail.tags;

  // ---- 简介：(b) 与 (c) 取更长的一份 ----
  final synopsis = dbDetail.content.length > sameCode.content.length
      ? dbDetail.content
      : sameCode.content;

  // ---- 番号元数据兜底：导演/制作商空位、年份、演员追加 ----
  if (codeMeta != null) {
    if (director.isEmpty) director = codeMeta.director;
    if (maker.isEmpty) maker = codeMeta.maker;
    if (releaseDate.isEmpty && codeMeta.year != null) {
      releaseDate = '${codeMeta.year}';
    }
  }

  // ---- 演员合成：JavDB 为主，空头像用 (b) 头像表补；
  // 番号元数据里有而 JavDB 没有的人追加在后；按归一名去重 ----
  final cast = <FilmFillCast>[];
  final castKeys = <String>{};
  for (final person in javdbCast) {
    final key = actressNameKey(person.name);
    if (key.isEmpty || !castKeys.add(key)) continue;
    var avatar = person.avatar;
    if (avatar.isEmpty) avatar = sameCode.avatarByKey[key] ?? '';
    cast.add(FilmFillCast(name: person.name, avatar: avatar));
  }
  if (codeMeta != null) {
    for (final person in codeMeta.castWithAvatars) {
      final key = actressNameKey(person.name);
      if (key.isEmpty || !castKeys.add(key)) continue;
      var avatar = person.avatarUrl;
      if (avatar.isEmpty) avatar = sameCode.avatarByKey[key] ?? '';
      cast.add(FilmFillCast(name: person.name, avatar: avatar));
    }
  }

  return FilmDetailFill(
    code: trimmedCode,
    cover: cover,
    synopsis: synopsis,
    cast: cast,
    director: director,
    maker: maker,
    series: series,
    releaseDate: releaseDate,
    durationText: durationText,
    score: score,
    scoreCount: scoreCount,
    originTitle: originTitle,
    tags: tags,
    stills: stills,
  );
}
