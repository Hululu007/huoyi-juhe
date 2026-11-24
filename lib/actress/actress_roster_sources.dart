import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'actress_models.dart';
import 'actress_adapter_http.dart';

/// 抓取器 HTTP 响应：状态码 + 已解码正文。非 200 不抛错，由各源自行
/// 判定（盾/空页/末页的语义不同）。
class ActressHttpResponse {
  const ActressHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// 抓取器 HTTP 层：默认走 [ContentHttp.getRaw]（智能代理出口），
/// 测试注入假函数。
typedef ActressHttpFetch =
    Future<ActressHttpResponse> Function(
      String url, {
      Map<String, String> headers,
      Duration timeout,
    });

ActressHttpFetch actressDefaultFetch(ContentHttp http) =>
    (
      String url, {
      Map<String, String> headers = const {},
      Duration timeout = contentTimeout,
    }) async {
      final raw = await http.getRaw(url, headers: headers, timeout: timeout);
      return ActressHttpResponse(
        statusCode: raw.statusCode,
        body: decodeContentBytes(
          raw.bodyBytes,
          contentType: raw.headers['content-type'],
        ),
      );
    };

/// 名册一页：人物 + 是否还有下一页。
class ActressRosterPage {
  const ActressRosterPage({required this.persons, required this.hasMore});

  final List<RosterPerson> persons;
  final bool hasMore;
}

/// 名册源接口：三家各自实现。所有解析函数都是纯函数（可单测），
/// 抓取器只负责拼 URL、发请求、判状态码。
abstract class ActressRosterSource {
  ActressRosterSourceId get id;

  /// 名册第 [page] 页（1 起）。
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  });

  /// 某人的全部作品清单：内部自行翻页直到空页。
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  });

  /// 排行第 [page] 页（1 起，顺序即名次序）：MissAV 默认提供；
  /// whos 须开 [WhosRosterSource.enableRanking]（未验通前默认关闭），
  /// 其余源返回空页。
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async => const ActressRosterPage(persons: [], hasMore: false);
}

/// 标题打头的番号提取（启发式，只认标题开头的番号形 token）：
/// - `SSIS-123`、`ABW-123`、`1PONDO-102726`、`FC2-PPV-1234567`；
/// - 无连字符的 `SSIS123` 亦认；
/// - 前缀必须含字母（`2024-123456` 这种纯数字不认）。
/// 标题中间出现的番号不认（误报太多），那部分靠跨站补全对番号。
String extractLeadingAvCode(String title) {
  final hyphenated = RegExp(
    r'^\s*([A-Za-z0-9]+(?:-[A-Za-z0-9]+)?)-(\d{3,7})\b',
  ).firstMatch(title);
  if (hyphenated != null) {
    final prefix = hyphenated.group(1)!;
    if (RegExp(r'[A-Za-z]').hasMatch(prefix)) {
      return hyphenated.group(0)!.trim();
    }
  }
  final glued = RegExp(r'^\s*([A-Za-z]{2,8})(\d{3,6})\b').firstMatch(title);
  if (glued != null) return glued.group(0)!.trim();
  return '';
}

/// 潮流名册：`chaoliu.py` 的同源 JSON（名册接口不走 feed 签名，
/// 普通 GET + UA 即可，与 py `_http_json` 一致）。
/// 域名与版本常量与 py 同步：域名或版本变了，两处一起改。
class ChaoliuRosterSource extends ActressRosterSource {
  static const webBase = 'https://chaoliu-av-tk8m.web.zaka.live';
  static const jpVersion = '20261005c';
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  @override
  ActressRosterSourceId get id => ActressRosterSourceId.chaoliu;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    if (page != 1) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final response = await fetch(
      '$webBase/jp220/actors.json?v=$jpVersion',
      headers: const {'Accept': 'application/json', 'User-Agent': _userAgent},
      timeout: const Duration(seconds: 45),
    );
    if (response.statusCode != 200) {
      throw StateError('chaoliu roster http ${response.statusCode}');
    }
    return ActressRosterPage(
      persons: parseChaoliuRoster(response.body),
      hasMore: false,
    );
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    final encoded = Uri.encodeComponent(sourceId);
    final response = await fetch(
      '$webBase/jp220/f/$encoded.json?v=$jpVersion',
      headers: const {'Accept': 'application/json', 'User-Agent': _userAgent},
      timeout: const Duration(seconds: 45),
    );
    if (response.statusCode != 200) {
      throw StateError('chaoliu films http ${response.statusCode}');
    }
    return parseChaoliuFilms(response.body);
  }
}

/// 解析潮流 actors.json：`{"actors":[{id,n,s,t,e,c,a}]}`。
/// c 为逗号分隔标签，含“推荐”计编辑推荐；a 缺失时回落
/// `$webBase/jp/av/<id>.jpg`（与 py `_detail_jp` 同一回落）。
List<RosterPerson> parseChaoliuRoster(String body) {
  final decoded = jsonDecode(body);
  final actors = decoded is Map<String, dynamic> ? decoded['actors'] : decoded;
  if (actors is! List) return const [];
  final out = <RosterPerson>[];
  for (final item in actors) {
    if (item is! Map) continue;
    final id = (item['id'] ?? '').toString();
    final name = (item['n'] ?? '').toString();
    if (id.isEmpty || name.trim().isEmpty) continue;
    final tags = (item['c'] ?? '')
        .toString()
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList();
    var avatar = (item['a'] ?? '').toString();
    if (avatar.isEmpty) {
      avatar = '${ChaoliuRosterSource.webBase}/jp/av/$id.jpg';
    }
    out.add(
      RosterPerson(
        source: ActressRosterSourceId.chaoliu,
        sourceId: id,
        name: name,
        sex: (item['s'] ?? '').toString(),
        avatarUrl: avatar,
        tags: tags,
        worksHint: (item['t'] as num?)?.toInt() ?? 0,
        recommended: tags.contains('推荐'),
      ),
    );
  }
  return out;
}

/// 解析潮流 `f/<id>.json`：数组每项 `[mid, 番号, 日期]`，全量取回
/// （py 只取前 200 部作选集显示，同步要全量）。
/// 解出不是数组时抛错（不要静默回空：空结果曾被同步记成成功，
/// 中毒状态永久化）；空数组照常返回，由同步层记失败重取。
List<RosterFilm> parseChaoliuFilms(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw StateError('chaoliu films: expected a JSON array');
  }
  final out = <RosterFilm>[];
  for (final item in decoded) {
    if (item is! List || item.length < 2) continue;
    final code = (item[1] ?? '').toString().trim();
    if (code.isEmpty) continue;
    final date = item.length > 2 ? (item[2] ?? '').toString().trim() : '';
    out.add(RosterFilm(code: code, date: date));
  }
  return out;
}

/// whos.tv 女优库：结构取自已发布 spider `ZakaWhosAmns` 的解析逻辑
/// （`/actresses` 列表 + `/actresses/<slug>` 人物页，每页 12 人）。
///
/// 兜底开关（默认全关，手机验通一项开一项，见 ACTRESS_FALLBACK_SPEC）：
/// - [enableRanking]：`/ranking/actress` 日榜作名气分后备信号；
/// - [enableNameSearch]：`?name=` 搜索作 enrichPerson 的追加输入；
/// - [enableXorCover]：data-cover-src XOR 解码直取封面（默认走跨站补全）。
/// 卡片评分/作品数/别名解析是防御性的（只读已拉回的列表页），
/// 始终开启，解析不到即空值，不影响既有字段。
class WhosRosterSource extends ActressRosterSource {
  WhosRosterSource({
    this.enableRanking = false,
    this.enableNameSearch = false,
    this.enableXorCover = false,
    this.rankingPeriod = '24h',
  });

  static const base = 'https://whos.tv';
  static const maxPages = 5000;

  final bool enableRanking;
  final bool enableNameSearch;
  final bool enableXorCover;

  /// 排行榜周期（24h/7d/30d/total），默认 24h 日榜。
  final String rankingPeriod;

  @override
  ActressRosterSourceId get id => ActressRosterSourceId.whos;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    if (page > maxPages) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final url = page <= 1 ? '$base/actresses' : '$base/actresses/page-$page';
    final response = await fetch(url);
    if (response.statusCode != 200) {
      throw StateError('whos roster http ${response.statusCode}');
    }
    final persons = parseWhosRoster(response.body);
    return ActressRosterPage(persons: persons, hasMore: persons.isNotEmpty);
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    final films = <RosterFilm>[];
    for (var page = 1; page <= maxPages; page++) {
      final url = page <= 1
          ? '$base/actresses/$sourceId'
          : '$base/actresses/$sourceId/page-$page';
      final response = await fetch(url);
      if (response.statusCode != 200) {
        throw StateError('whos films http ${response.statusCode}');
      }
      final pageFilms = parseWhosFilms(
        response.body,
        decodeCover: enableXorCover,
      );
      if (pageFilms.isEmpty) break;
      films.addAll(pageFilms);
    }
    return films;
  }

  @override
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    if (!enableRanking || page != 1) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final response = await fetch('$base/ranking/actress?period=$rankingPeriod');
    if (response.statusCode != 200) {
      throw StateError('whos ranking http ${response.statusCode}');
    }
    final persons = parseWhosRoster(response.body);
    return ActressRosterPage(persons: persons, hasMore: false);
  }

  /// 按名搜索（`?name=`）：仅开关打开时拉取，否则返回空页。
  Future<ActressRosterPage> fetchSearchByName(
    String name, {
    required ActressHttpFetch fetch,
  }) async {
    if (!enableNameSearch) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final encoded = Uri.encodeQueryComponent(name);
    final response = await fetch('$base/actresses?name=$encoded');
    if (response.statusCode != 200) {
      throw StateError('whos search http ${response.statusCode}');
    }
    final persons = parseWhosRoster(response.body);
    return ActressRosterPage(persons: persons, hasMore: false);
  }

  /// 人物页简介键值对：与 [fetchFilms] 同一端点（首页）；是否写库
  /// 由调用方（enrichPerson 的开关）决定，本方法只取不写。
  Future<Map<String, String>> fetchPersonAbout(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    final response = await fetch('$base/actresses/$sourceId');
    if (response.statusCode != 200) {
      throw StateError('whos person http ${response.statusCode}');
    }
    return parseWhosPersonAbout(response.body);
  }
}

/// 解析 whos 列表页：按 `<a href="/actresses/<slug>">` 切块（排除
/// `page-` 开头的分页链接），名取 `<img alt>`，回落为 slug 解码，
/// 头像取 `<img src>`（优先 hersav 演员图）。性别未知，记空（不臆断）。
/// 卡片另取评分/作品数/别名（防御性解析，取不到即空值）；“素人”
/// 不排除——2026-11-21 用户纠正：素人是有番号的正常演员，界面上
/// 不要把素人过滤掉（旧口径称其为分类伪演员，已废）。
List<RosterPerson> parseWhosRoster(String body) {
  final document = html_parser.parse(body);
  final out = <RosterPerson>[];
  final seen = <String>{};
  for (final anchor in document.querySelectorAll('a[href^="/actresses/"]')) {
    final href = anchor.attributes['href'] ?? '';
    final slug = href.replaceFirst('/actresses/', '').split('/').first;
    if (slug.isEmpty || slug.startsWith('page-')) continue;
    if (!seen.add(slug)) continue;
    final scope = _whosCardScope(anchor);
    Element? avatarImg;
    for (final img in scope.querySelectorAll('img')) {
      if ((img.attributes['src'] ?? '').contains('v.hersav.me/actress')) {
        avatarImg = img;
        break;
      }
    }
    avatarImg ??= anchor.querySelector('img');
    var name = '';
    for (final img in anchor.querySelectorAll('img')) {
      final alt = img.attributes['alt']?.trim() ?? '';
      if (alt.isNotEmpty) {
        name = alt;
        break;
      }
    }
    if (name.isEmpty) {
      name = Uri.decodeComponent(slug).replaceAll(RegExp(r'[-_]'), ' ').trim();
    }
    if (name.isEmpty) continue;
    final avatar = _resolveUrl(WhosRosterSource.base, avatarImg?.attributes['src']);
    out.add(
      RosterPerson(
        source: ActressRosterSourceId.whos,
        sourceId: slug,
        name: name,
        avatarUrl: avatar,
        rating: _whosCardRating(scope),
        exactWorks: _whosCardWorks(scope),
        aliases: _whosCardAlias(scope, name),
      ),
    );
  }
  return out;
}

/// 卡片作用域：父元素恰好只含一条女优链接时取父元素（评分/作品数
/// 等元数据在链接外时也能取到），否则只取链接自身，避免串卡。
Element _whosCardScope(Element anchor) {
  final parent = anchor.parent;
  if (parent != null) {
    final anchors = parent.querySelectorAll('a[href^="/actresses/"]');
    if (anchors.length == 1) return parent;
  }
  return anchor;
}

/// 卡片评分：先认 `aria-label="评分 X"`，再认 amber/yellow 评分数值；
/// 0–10 之外的值视为误取，返回 null。
double? _whosCardRating(Element scope) {
  final candidates = <Element>[scope, ...scope.querySelectorAll('*')];
  for (final element in candidates) {
    final label = element.attributes['aria-label'];
    if (label == null) continue;
    final match = RegExp(r'评分\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(label);
    if (match != null) {
      final value = double.tryParse(match.group(1)!);
      if (value != null && value >= 0 && value <= 10) return value;
    }
  }
  for (final element in scope.querySelectorAll('*')) {
    final classes = element.attributes['class'] ?? '';
    if (!classes.contains('text-amber') && !classes.contains('text-yellow')) {
      continue;
    }
    final match = RegExp(
      r'^\s*([0-9]+(?:\.[0-9]+)?)',
    ).firstMatch(element.text);
    if (match != null) {
      final value = double.tryParse(match.group(1)!);
      if (value != null && value >= 0 && value <= 10) return value;
    }
  }
  return null;
}

/// 卡片作品数：`N 部作品` 文本，去逗号转整数；异常值返回 0。
int _whosCardWorks(Element scope) {
  final match = RegExp(r'([\d,]+)\s*部作品').firstMatch(scope.text);
  if (match == null) return 0;
  final value = int.tryParse(match.group(1)!.replaceAll(',', ''));
  if (value == null || value < 0 || value > 999999) return 0;
  return value;
}

/// 卡片别名：`mt-0.5` 元数据行的首个合规文本（≤40 字、不是名字
/// 本身、不含作品数/评分/星号）；取不到返回空。
List<String> _whosCardAlias(Element scope, String name) {
  for (final element in scope.querySelectorAll('*')) {
    final classes = element.attributes['class'] ?? '';
    if (!classes.contains('mt-0.5')) continue;
    final text = element.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty || text.length > 40) continue;
    if (text == name) continue;
    if (text.contains('部作品') ||
        text.contains('评分') ||
        text.contains('★') ||
        text.contains('☆')) {
      continue;
    }
    return [text];
  }
  return const [];
}

/// whos 封面 XOR 解码：decCover 的逐字移植——hex 串末字节为密钥，
/// 其余字节逐个异或，解出文本须以 http(s):// 开头，否则返回 null。
String? decodeWhosCover(String? hex) {
  if (hex == null) return null;
  final cleaned = hex.trim();
  if (cleaned.length < 6 || cleaned.length.isOdd) return null;
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(cleaned)) return null;
  final bytes = <int>[];
  for (var i = 0; i < cleaned.length; i += 2) {
    bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
  }
  if (bytes.isEmpty) return null;
  final key = bytes.last;
  final decoded = [
    for (var i = 0; i < bytes.length - 1; i++) bytes[i] ^ key,
  ];
  final text = utf8.decode(decoded, allowMalformed: true);
  if (text.startsWith('http://') || text.startsWith('https://')) return text;
  return null;
}

/// 解析 whos 人物页简介键值对：`<p class="text-sm
/// text-muted-foreground">键</p>` 紧跟 `<p class="font-medium
/// text-white">值</p>`；键超过 8 字、值超过 200 字视为错配，跳过。
Map<String, String> parseWhosPersonAbout(String body) {
  final document = html_parser.parse(body);
  final about = <String, String>{};
  for (final paragraph in document.querySelectorAll('p')) {
    final classes = paragraph.attributes['class'] ?? '';
    if (!classes.contains('text-sm') ||
        !classes.contains('text-muted-foreground')) {
      continue;
    }
    final parent = paragraph.parent;
    if (parent == null) continue;
    final siblings = parent.children;
    final index = siblings.indexOf(paragraph);
    if (index < 0 || index + 1 >= siblings.length) continue;
    final next = siblings[index + 1];
    if (next.localName != 'p') continue;
    final nextClasses = next.attributes['class'] ?? '';
    if (!nextClasses.contains('font-medium') ||
        !nextClasses.contains('text-white')) {
      continue;
    }
    final key = paragraph.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final value = next.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (key.isEmpty || key.length > 8 || value.isEmpty || value.length > 200) {
      continue;
    }
    about[key] = value;
    if (about.length >= 20) break;
  }
  return about;
}

/// 解析 whos 人物页：按 `<a href="/videos/<id>">` 切块，标题取
/// `<h3>`/alt/`<p>` 的首个非空，番号只认标题打头的番号形 token。
/// [decodeCover] 打开时另取封面（data-cover-src XOR 解码，解不出
/// 回落 img src）与详情地址；关闭时两字段恒为空。
List<RosterFilm> parseWhosFilms(String body, {bool decodeCover = false}) {
  final document = html_parser.parse(body);
  final out = <RosterFilm>[];
  final seen = <String>{};
  for (final anchor in document.querySelectorAll('a[href^="/videos/"]')) {
    final href = anchor.attributes['href'] ?? '';
    if (!seen.add(href)) continue;
    final title = _firstNonEmpty([
      anchor.querySelector('h3')?.text,
      anchor.querySelector('img')?.attributes['alt'],
      anchor.querySelector('p')?.text,
    ]);
    if (title.isEmpty) continue;
    final code = extractLeadingAvCode(title);
    var coverUrl = '';
    if (decodeCover) {
      final img = anchor.querySelector('img');
      final encoded = img?.attributes['data-cover-src'];
      coverUrl = decodeWhosCover(encoded) ?? '';
      if (coverUrl.isEmpty) {
        coverUrl = _resolveUrl(WhosRosterSource.base, img?.attributes['src']);
      }
    }
    out.add(
      RosterFilm(
        code: code,
        title: code.isNotEmpty && title == code ? '' : title,
        coverUrl: coverUrl,
        detailUrl: decodeCover ? href : '',
      ),
    );
  }
  return out;
}

/// MissAV 女优库：结构取自树内海阔内置规则 🔞MissAV（手机已验可播）
/// 的女优列表与排行选择器，基址与 UA 与规则一致。
/// 人物页即视频列表，封面直接取 `.lozad` 图的 data-src（无则 src，
/// 再无则 data-srcset 首个地址），封面加载走 `repository.cover()`
/// 的 HTTP 客户端（可带 UA），不再走跨站补全；详情地址取条目链接
/// 的相对路径，封面直取的站源记 MissAV 视频站。
class MissavRosterSource extends ActressRosterSource {
  static const base = 'https://missav.live/dm16/cn/';
  static const maxPages = 5000;
  static const _userAgent = 'Mozilla/5.0 (Windows NT 10.0)';

  @override
  ActressRosterSourceId get id => ActressRosterSourceId.missav;

  Map<String, String> get _headers => const {'User-Agent': _userAgent};

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    if (page > maxPages) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final response = await fetch(
      '${base}actresses?page=$page',
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw StateError('missav roster http ${response.statusCode}');
    }
    final persons = parseMissavRoster(response.body);
    return ActressRosterPage(persons: persons, hasMore: persons.isNotEmpty);
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    final films = <RosterFilm>[];
    final personUrl = _resolveUrl(base, sourceId);
    for (var page = 1; page <= maxPages; page++) {
      final separator = personUrl.contains('?') ? '&' : '?';
      final response = await fetch(
        '$personUrl${separator}page=$page',
        headers: _headers,
      );
      if (response.statusCode != 200) {
        throw StateError('missav films http ${response.statusCode}');
      }
      final pageFilms = parseMissavFilms(response.body);
      if (pageFilms.isEmpty) break;
      films.addAll(pageFilms);
    }
    return films;
  }

  @override
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    if (page > maxPages) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    final response = await fetch(
      '${base}actresses/ranking?page=$page',
      headers: _headers,
    );
    if (response.statusCode != 200) {
      throw StateError('missav ranking http ${response.statusCode}');
    }
    final persons = parseMissavRoster(response.body);
    return ActressRosterPage(persons: persons, hasMore: persons.isNotEmpty);
  }
}

/// 解析 MissAV 女优列表/排行页：项选择器 `.max-w-full ul li`，
/// 名取 `h4` 文本、链接取 `a href`、头像取 `img src`。
/// 性别未知，记空（不臆断）。
List<RosterPerson> parseMissavRoster(String body) {
  final document = html_parser.parse(body);
  final out = <RosterPerson>[];
  final seen = <String>{};
  for (final item in document.querySelectorAll('.max-w-full ul li')) {
    final name = item.querySelector('h4')?.text.trim() ?? '';
    final href = item.querySelector('a')?.attributes['href'] ?? '';
    if (name.isEmpty || href.isEmpty) continue;
    final path = _relativePath(href);
    if (path.isEmpty || !seen.add(path)) continue;
    final avatar = _resolveUrl(
      MissavRosterSource.base,
      item.querySelector('img')?.attributes['src'],
    );
    out.add(
      RosterPerson(
        source: ActressRosterSourceId.missav,
        sourceId: path,
        name: name,
        avatarUrl: avatar,
      ),
    );
  }
  return out;
}

/// 解析 MissAV 人物页（视频列表）：项选择器 `.grid.relative`，
/// 标题取 `.lozad` 的 alt、番号只认标题打头的番号形 token；
/// 封面取同一张 `.lozad` 图的 data-src（无则 src，再无则
/// data-srcset 首个地址），详情地址取条目链接的相对路径。
List<RosterFilm> parseMissavFilms(String body) {
  final document = html_parser.parse(body);
  final out = <RosterFilm>[];
  final seen = <String>{};
  for (final item in document.querySelectorAll('.grid.relative')) {
    final href = item.querySelector('a')?.attributes['href'] ?? '';
    if (href.isNotEmpty && !seen.add(href)) continue;
    final img = item.querySelector('.lozad');
    final title = img?.attributes['alt']?.trim() ?? '';
    if (title.isEmpty) continue;
    final code = extractLeadingAvCode(title);
    out.add(
      RosterFilm(
        code: code,
        title: code.isNotEmpty && title == code ? '' : title,
        coverUrl: _resolveUrl(
          MissavRosterSource.base,
          _missavCoverSrc(img),
        ),
        detailUrl: _relativePath(href),
      ),
    );
  }
  return out;
}

/// MissAV 封面图地址：data-src 优先，其次 src，最后 data-srcset
/// 的首个地址（`url 100w, url 200w` 只取第一个 url）。
String _missavCoverSrc(Element? img) {
  if (img == null) return '';
  final dataSrc = img.attributes['data-src']?.trim() ?? '';
  if (dataSrc.isNotEmpty) return dataSrc;
  final src = img.attributes['src']?.trim() ?? '';
  if (src.isNotEmpty) return src;
  final srcset = img.attributes['data-srcset'] ?? '';
  for (final candidate in srcset.split(',')) {
    final parts = candidate.trim().split(RegExp(r'\s+'));
    final url = parts.isEmpty ? '' : parts.first;
    if (url.isNotEmpty) return url;
  }
  return '';
}

String _firstNonEmpty(List<String?> values) {
  for (final value in values) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

String _resolveUrl(String base, String? raw) {
  final trimmed = (raw ?? '').trim();
  if (trimmed.isEmpty) return '';
  final resolved = Uri.tryParse(base)?.resolve(trimmed);
  return resolved?.toString() ?? trimmed;
}

/// 取相对路径（去域名、去查询串）：作 MissAV 人物在库内的源身份。
String _relativePath(String href) {
  final trimmed = href.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return trimmed;
  final path = uri.path;
  return path.isEmpty ? trimmed : path;
}

/// 供测试注入的假源：返回写死的名册/作品/排行。
class FakeRosterSource implements ActressRosterSource {
  FakeRosterSource({
    required this.sourceId,
    this.rosterPages = const [],
    this.filmsBySourceId = const {},
    this.rankingPages = const [],
    this.failRosterPages = const {},
    this.failFilmsFor = const {},
  });

  final ActressRosterSourceId sourceId;
  final List<List<RosterPerson>> rosterPages;
  final Map<String, List<RosterFilm>> filmsBySourceId;
  final List<List<RosterPerson>> rankingPages;
  final Set<int> failRosterPages;
  final Set<String> failFilmsFor;

  /// 记录实际拉过的名册页（断点续跑测试用）。
  final fetchedRosterPages = <int>[];

  /// 记录实际拉过作品清单的源身份（断点续跑测试用）。
  final fetchedFilmsFor = <String>[];

  @override
  ActressRosterSourceId get id => sourceId;

  @override
  Future<ActressRosterPage> fetchRosterPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    fetchedRosterPages.add(page);
    if (failRosterPages.contains(page)) {
      throw StateError('fake roster failure page $page');
    }
    final index = page - 1;
    if (index < 0 || index >= rosterPages.length) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    return ActressRosterPage(
      persons: rosterPages[index],
      hasMore: index + 1 < rosterPages.length,
    );
  }

  @override
  Future<List<RosterFilm>> fetchFilms(
    String sourceId, {
    required ActressHttpFetch fetch,
  }) async {
    fetchedFilmsFor.add(sourceId);
    if (failFilmsFor.contains(sourceId)) {
      throw StateError('fake films failure $sourceId');
    }
    return filmsBySourceId[sourceId] ?? const [];
  }

  @override
  Future<ActressRosterPage> fetchRankingPage(
    int page, {
    required ActressHttpFetch fetch,
  }) async {
    final index = page - 1;
    if (index < 0 || index >= rankingPages.length) {
      return const ActressRosterPage(persons: [], hasMore: false);
    }
    return ActressRosterPage(
      persons: rankingPages[index],
      hasMore: index + 1 < rankingPages.length,
    );
  }
}
