import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 演员库在线源（123AV / PH）的纯解析层：只吃网页文本、吐结构，
/// 不碰网络与界面。2026-11-27 照魔蚁侧修正版逐条移植（123AV 取址
/// 改内联 player JSON + /stream 接口、嵌入域名现读不写死；PH 走
/// flashvars mediaDefinitions），魔蚁侧 AV01 / Jable 两源不在
/// 修仙版范围，未搬。
///
/// 本文件只依赖 dart:convert 与 package:html，方便离线拿真页面
/// 样本直接验解析。

/// 在线源的一个可点选项（排序页签 / 分类页签通用）：
/// [value] 的含义随源而定——PH 排序与分类都是查询串片段
/// （o=ht / c=111），123AV 页签是路径（/cn/recent）。
class OnlineTabOption {
  const OnlineTabOption({
    required this.id,
    required this.name,
    required this.value,
  });

  final String id;
  final String name;
  final String value;
}

/// 在线源列表里的一张视频卡。
class OnlineVideoCard {
  const OnlineVideoCard({
    required this.pageUrl,
    required this.title,
    this.cover = '',
    this.duration = '',
  });

  /// 详情页地址（取流要再打开它）。
  final String pageUrl;
  final String title;
  final String cover;

  /// 时长文案（如 12:34），站上没有就不带。
  final String duration;
}

/// 在线源详情页解析结果（标题/海报/演员/标签 + 剧照与信息
/// 字段）。剧照只认详情页里专设的剧照区（保守选择器），取不
/// 到就是空——不拿封面或推荐位图片冒充；日期/时长/厂商同理，
/// 页里有才带（2026-11-26 用户令：没有真数据不许编）。
class OnlineDetailInfo {
  const OnlineDetailInfo({
    required this.title,
    this.poster = '',
    this.actresses = const [],
    this.tags = const [],
    this.stills = const [],
    this.date = '',
    this.duration = '',
    this.maker = '',
  });

  final String title;
  final String poster;
  final List<String> actresses;
  final List<String> tags;

  /// 剧照（详情页剧照区的图），没有就是空。
  final List<String> stills;

  /// 发行/上传日期（页里有才带）。
  final String date;

  /// 时长文案（页里有才带）。
  final String duration;

  /// 制作商/片商（页里有才带；PH 无此概念，恒空）。
  final String maker;
}

String _txt(dom.Element? el) {
  if (el == null) return '';
  return el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _absolutize(String site, String href) {
  if (href.startsWith('http')) return href;
  return '$site${href.startsWith('/') ? '' : '/'}$href';
}

/// 图片地址取值（与合并页 pickImg 同序）：懒加载属性优先，
/// data: 占位图跳过。
String _pickImg(dom.Element? img) {
  if (img == null) return '';
  for (final key in const [
    'data-src',
    'data-original',
    'data-lazy-src',
    'data-echo',
    'data-path',
    'src',
  ]) {
    final value = img.attributes[key] ?? '';
    if (value.isNotEmpty && !value.startsWith('data:')) return value;
  }
  return '';
}

// ---------------------------------------------------------------------------
// PH（cn.pornhub.com）
// ---------------------------------------------------------------------------

const phSite = 'https://cn.pornhub.com';

/// PH 一级页签 = 排序（value 是查询串片段 o=xx）。
const kPhSortTabs = <OnlineTabOption>[
  OnlineTabOption(id: 'hot', name: '热门', value: 'o=ht'),
  OnlineTabOption(id: 'new', name: '最新', value: 'o=mr'),
  OnlineTabOption(id: 'views', name: '最多观看', value: 'o=mv'),
  OnlineTabOption(id: 'rate', name: '最高评分', value: 'o=tr'),
  OnlineTabOption(id: 'week', name: '本周', value: 'o=mv&t=w'),
  OnlineTabOption(id: 'month', name: '本月', value: 'o=mv&t=m'),
  OnlineTabOption(id: 'long', name: '最长', value: 'o=lg'),
];

/// PH 二级页签 = 分类（value 是查询串片段 c=NN，ID 取自站内菜单）。
const kPhGenreCats = <OnlineTabOption>[
  OnlineTabOption(id: 'all', name: '全部', value: ''),
  OnlineTabOption(id: 'jp', name: '日本人', value: 'c=111'),
  OnlineTabOption(id: 'milf', name: '熟女', value: 'c=28'),
  OnlineTabOption(id: 'mom', name: '辣妈', value: 'c=29'),
  OnlineTabOption(id: 'les', name: '女同', value: 'c=27'),
  OnlineTabOption(id: 'anal', name: '爆菊', value: 'c=35'),
  OnlineTabOption(id: '3p', name: '3P', value: 'c=65'),
  OnlineTabOption(id: 'ebony', name: '黑人女', value: 'c=17'),
];

/// PH 列表地址：浏览走 /video（分类 + 排序 + 页码拼查询串），
/// 搜索走 /video/search?search=。
String phListUrl({
  required String sortValue,
  required String catValue,
  required String query,
  required int page,
}) {
  final kw = query.trim();
  if (kw.isNotEmpty) {
    final base = '$phSite/video/search?search=${Uri.encodeQueryComponent(kw)}';
    return page > 1 ? '$base&page=$page' : base;
  }
  final qs = <String>[
    if (catValue.isNotEmpty) catValue,
    if (sortValue.isNotEmpty) sortValue,
    if (page > 1) 'page=$page',
  ];
  return '$phSite/video${qs.isEmpty ? '' : '?${qs.join('&')}'}';
}

bool _isPhVideoUrl(String href) => href.contains('view_video.php?viewkey=');

/// PH 列表卡片：带 viewkey 的链接里有缩略图的才算卡（与合并页
/// parseCards 同口径），按详情地址去重。
List<OnlineVideoCard> parsePhCards(String htmlText) {
  final doc = html_parser.parse(htmlText);
  final out = <OnlineVideoCard>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href*="view_video.php?viewkey="]')) {
    var href = a.attributes['href'] ?? '';
    if (!_isPhVideoUrl(href)) continue;
    href = _absolutize(phSite, href);
    if (!seen.add(href)) continue;
    final img = a.querySelector('img');
    if (img == null) continue; // 只要带缩略图的卡片链接
    var pic = a.attributes['data-poster'] ?? img.attributes['src'] ?? '';
    if (pic.isEmpty || pic.startsWith('data:')) {
      pic = img.attributes['data-path'] ?? '';
    }
    var duration = '';
    final box = a.parent;
    if (box != null) {
      duration = _txt(box.querySelector('.duration .time, .duration'));
    }
    final title = img.attributes['alt'] ?? a.attributes['title'] ?? '';
    out.add(
      OnlineVideoCard(pageUrl: href, title: title, cover: pic, duration: duration),
    );
  }
  return out;
}

/// PH 详情：og 标题/海报 + 演员（pornstar/model 链接）+ 标签链接。
OnlineDetailInfo parsePhDetail(String htmlText) {
  final doc = html_parser.parse(htmlText);
  String og(String property) =>
      doc.querySelector('meta[property="$property"]')?.attributes['content'] ??
      '';
  var title = og('og:title').replaceAll(
    RegExp(r'\s*-\s*Pornhub[^-]*$', caseSensitive: false),
    '',
  );
  if (title.isEmpty) title = _txt(doc.querySelector('h1'));
  final poster = og('og:image');
  final models = <String>[];
  for (final a in doc.querySelectorAll(
    'a[href*="/pornstar/"], a[href*="/model/"]',
  )) {
    final name = _txt(a);
    if (name.isEmpty || name.length > 24) continue;
    if (!models.contains(name)) models.add(name);
  }
  final tags = <String>[];
  for (final a in doc.querySelectorAll(
    'a[href*="/video?c="], a[href*="/video/search?search="]',
  )) {
    final name = _txt(a);
    if (name.isEmpty || name.length > 16) continue;
    if (!tags.contains(name)) tags.add(name);
  }
  // 剧照：只认专设的剧照容器（.screenshots / #screenshots），
  // 没有这个区就空——推荐位与封面不冒充剧照（2026-11-26 令）。
  final stills = <String>[];
  for (final img in doc.querySelectorAll(
    '.screenshots img, #screenshots img',
  )) {
    final pic = _pickImg(img);
    if (pic.isEmpty || pic == poster) continue;
    if (!stills.contains(pic)) stills.add(pic);
  }
  // 日期：JSON-LD 的 datePublished 优先（页里有才带）。
  var date = '';
  final dm = RegExp(
    r'"datePublished"\s*:\s*"([0-9]{4}-[0-9]{2}-[0-9]{2})',
  ).firstMatch(htmlText);
  if (dm != null) date = dm.group(1)!;
  // 时长：flashvars 的 video_duration（秒）→ 分钟文案。
  var duration = '';
  final vm = RegExp(r'"video_duration"\s*:\s*"?(\d+)').firstMatch(htmlText);
  if (vm != null) {
    final seconds = int.tryParse(vm.group(1)!) ?? 0;
    if (seconds >= 60) {
      duration = '${(seconds / 60).round()} 分钟';
    } else if (seconds > 0) {
      duration = '$seconds 秒';
    }
  }
  return OnlineDetailInfo(
    title: title,
    poster: poster,
    actresses: models.take(6).toList(),
    tags: tags.take(20).toList(),
    stills: stills.take(24).toList(),
    date: date,
    duration: duration,
  );
}

/// PH 取流：详情页 flashvars 里的 mediaDefinitions——quality 是
/// 数组的那条是 master 播放列表，其次取最高画质 m3u8，再退 mp4；
/// flashvars 解不出时全文找 m3u8（与合并页 extractStream 同序）。
String extractPhStream(String raw) {
  if (raw.isEmpty) return '';
  String clean(String u) => u.replaceAll('\\/', '/').replaceAll('&amp;', '&');
  final fvMatch =
      RegExp(
        r'var\s+flashvars_\d+\s*=\s*(\{[\s\S]*?\});\s*\n',
      ).firstMatch(raw) ??
      RegExp(r'var\s+flashvars_\d+\s*=\s*(\{[\s\S]*?\});').firstMatch(raw);
  if (fvMatch != null) {
    try {
      final fv = jsonDecode(fvMatch.group(1)!);
      if (fv is Map) {
        final defs = fv['mediaDefinitions'];
        if (defs is List) {
          var master = '';
          var best = '';
          var bestQ = -1;
          var mp4 = '';
          var mp4Q = -1;
          for (final row in defs) {
            if (row is! Map) continue;
            final urlRaw = row['videoUrl']?.toString() ?? '';
            if (urlRaw.isEmpty) continue;
            final u = clean(urlRaw);
            final quality = row['quality'];
            if (u.contains('.m3u8')) {
              if (quality is List) {
                if (master.isEmpty) master = u;
              } else {
                final q = int.tryParse(quality?.toString() ?? '') ?? 0;
                if (q > bestQ) {
                  bestQ = q;
                  best = u;
                }
              }
            } else if (u.contains('.mp4')) {
              final q = int.tryParse(quality?.toString() ?? '') ?? 0;
              if (q > mp4Q) {
                mp4Q = q;
                mp4 = u;
              }
            }
          }
          if (master.isNotEmpty) return master;
          if (best.isNotEmpty) return best;
          if (mp4.isNotEmpty) return mp4;
        }
      }
    } catch (_) {
      // flashvars 不是规整 JSON 时走下面的全文兜底。
    }
  }
  final un = raw.replaceAll(RegExp(r'\\+/'), '/');
  final m =
      RegExp(
        'https?://[^"\'\\s]+?/master\\.m3u8[^"\'\\s]*',
        caseSensitive: false,
      ).firstMatch(un) ??
      RegExp(
        'https?://[^"\'\\s]+?\\.m3u8[^"\'\\s]*',
        caseSensitive: false,
      ).firstMatch(un);
  return m?.group(0) ?? '';
}

// ---------------------------------------------------------------------------
// 123AV（123av.com）
// ---------------------------------------------------------------------------

const av123Site = 'https://123av.com';

/// 123AV 页签 = 站内栏目路径。
const kAv123Tabs = <OnlineTabOption>[
  OnlineTabOption(id: 'recent', name: '最新', value: '/cn/recent'),
  OnlineTabOption(id: 'hot', name: '热门', value: '/cn/hot'),
  OnlineTabOption(id: 'new', name: '新片', value: '/cn/new'),
  OnlineTabOption(id: 'cen', name: '有码', value: '/cn/censored'),
  OnlineTabOption(id: 'uncen', name: '无码', value: '/cn/uncensored'),
  OnlineTabOption(id: 'leak', name: '无码流出', value: '/cn/uncensored-leaked'),
];

/// 123AV 列表地址：浏览走栏目路径 + page 参数，搜索走 /cn/search?q=。
String av123ListUrl({
  required String path,
  required String query,
  required int page,
}) {
  final kw = query.trim();
  if (kw.isNotEmpty) {
    final base = '$av123Site/cn/search?q=${Uri.encodeQueryComponent(kw)}';
    return page > 1 ? '$base&page=$page' : base;
  }
  var url = '$av123Site$path';
  if (page > 1) url += '${url.contains('?') ? '&' : '?'}page=$page';
  return url;
}

final _av123VideoPath = RegExp(r'/v/[a-z0-9-]+', caseSensitive: false);

/// 123AV 番号：/v/{slug} 的 slug 规整成 ABC-123 形（取不出就回
/// slug 大写），与合并页 codeOf 同口径。
String av123CodeOf(String url) {
  final m = RegExp(
    r'/v/([a-z0-9-]+)',
    caseSensitive: false,
  ).firstMatch(url);
  final slug = m?.group(1) ?? '';
  final mm = RegExp(r'^([a-z]+)-?(\d+)', caseSensitive: false).firstMatch(slug);
  if (mm != null) return '${mm.group(1)}-${mm.group(2)}'.toUpperCase();
  return slug.toUpperCase();
}

/// 123AV 列表卡片：.card/.featured 盒子里的 /v/ 链接（与合并页
/// parseCards 同口径），按详情地址去重；标题取不出时用番号顶。
List<OnlineVideoCard> parseAv123Cards(String htmlText) {
  final doc = html_parser.parse(htmlText);
  final out = <OnlineVideoCard>[];
  final seen = <String>{};
  for (final box in doc.querySelectorAll('.card, .featured')) {
    final a = box.querySelector(
      'a.card__cover[href], a.featured__link[href], a[href*="/v/"]',
    );
    if (a == null) continue;
    var href = (a.attributes['href'] ?? '').split('#').first;
    if (!_av123VideoPath.hasMatch(href)) continue;
    href = _absolutize(av123Site, href);
    if (!seen.add(href)) continue;
    final img = box.querySelector('img.card__img, img.featured__img, img');
    final pic = _pickImg(img);
    final label = box.querySelector('.card__dur, .featured__dur');
    final titleEl = box.querySelector('.featured__title, .card__title, h2, h3');
    var title = _txt(titleEl);
    if (title.isEmpty) title = a.attributes['title'] ?? '';
    if (title.isEmpty) title = img?.attributes['alt'] ?? '';
    if (title.isEmpty) title = av123CodeOf(href);
    out.add(
      OnlineVideoCard(
        pageUrl: href,
        title: title,
        cover: pic,
        duration: _txt(label),
      ),
    );
  }
  return out;
}

/// 123AV 详情：h1 标题、海报（播放器 poster 参数优先，其次站内
/// 图床图片）、演员（/actresses/ 链接）、标签（/genres/、/tag/）。
OnlineDetailInfo parseAv123Detail(String htmlText) {
  final doc = html_parser.parse(htmlText);
  var title = _txt(doc.querySelector('h1'));
  if (title.isEmpty) title = _txt(doc.querySelector('.watch__title'));
  var poster = '';
  final pm = RegExp(r'poster=([^"&\\]+)').firstMatch(htmlText);
  if (pm != null) {
    final rawPoster = pm.group(1)!;
    try {
      poster = Uri.decodeComponent(rawPoster);
    } catch (_) {
      poster = rawPoster;
    }
  }
  if (poster.isEmpty) {
    poster =
        doc.querySelector('img[src*="icdn.123av"]')?.attributes['src'] ?? '';
  }
  final models = <String>[];
  for (final a in doc.querySelectorAll('a[href*="/actresses/"]')) {
    final href = a.attributes['href'] ?? '';
    if (!RegExp(r'/actresses/[^/]').hasMatch(href)) continue;
    final name = _txt(a);
    if (name.isEmpty) continue;
    if (!models.contains(name)) models.add(name);
  }
  final tags = <String>[];
  for (final a in doc.querySelectorAll(
    'a[href*="/genres/"], a[href*="/tag/"]',
  )) {
    final href = a.attributes['href'] ?? '';
    if (!RegExp(r'/(genres|tag)/[^/]').hasMatch(href)) continue;
    final name = _txt(a);
    if (name.isEmpty || name.length > 16) continue;
    if (!tags.contains(name)) tags.add(name);
  }
  // 剧照：只认预览图区（preview-images / sample-images 等专设
  // 容器），没有就空——封面不冒充剧照（2026-11-26 令）。本机
  // 出口未恢复、未经真页验证；取不到时详情页整区不显示。
  final stills = <String>[];
  for (final img in doc.querySelectorAll(
    '.preview-images img, .sample-images img, .previews img, .preview img',
  )) {
    final pic = _pickImg(img);
    if (pic.isEmpty || pic == poster) continue;
    if (!stills.contains(pic)) stills.add(pic);
  }
  // 信息字段：详情页正文里的标签行（中英标签都认），
  // 页里没有就空、不编。
  final bodyText = _txt(doc.querySelector('body'));
  String after(List<String> labels, String pattern) {
    for (final label in labels) {
      final m = RegExp('$label\\s*[:：]\\s*($pattern)').firstMatch(bodyText);
      if (m != null) return m.group(1)!.trim();
    }
    return '';
  }

  final date = after(
    ['发布日期', '发行日期', 'Release Date', 'Released'],
    r'[0-9]{4}-[0-9]{2}-[0-9]{2}',
  );
  final duration = after(
    ['长度', '时长', 'Duration'],
    r'[0-9]+\s*分钟|[0-9]+\s*min',
  );
  final maker = after(
    ['制作商', '片商', 'Maker', 'Studio'],
    r'[^\s，,、]{2,30}',
  );
  return OnlineDetailInfo(
    title: title,
    poster: poster,
    actresses: models.take(8).toList(),
    tags: tags.take(20).toList(),
    stills: stills.take(24).toList(),
    date: date,
    duration: duration,
    maker: maker,
  );
}

/// JS 单引号字符串解转义（123AV 内联 player 数据用）：反
/// 斜杠 + 任意字符 → 该字符本身，\uXXXX → 对应码点。解完
/// 的文本是标准 JSON，再走 jsonDecode（2026-11-26 出口补
/// 验批实拉样本验证过此解法）。
String av123JsUnescape(String input) {
  final out = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '\\' && i + 1 < input.length) {
      final next = input[i + 1];
      if (next == 'u' && i + 5 < input.length) {
        final hex = input.substring(i + 2, i + 6);
        final code = int.tryParse(hex, radix: 16);
        if (code != null &&
            RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
          out.writeCharCode(code);
          i += 6;
          continue;
        }
      }
      out.write(next);
      i += 2;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// 123AV 集数列表：集数/取址数据不在 iframe 里，在详情页
/// 内联脚本 `player(JSON.parse('…转义JSON…'), 标题id, 番号,
/// …)` 的第一个参数里（2026-11-26 出口补验批全链实证：
/// 主列表 200 → 变体 4819 分片约 4.0 小时全长 → 首分片
/// Range 206、首字节 0x47）。先解转义再解析 JSON；数组本
/// 体或 {episodes:[...]} 都认。每集带 number/name/url，
/// url 是嵌入页地址（域名会轮换——实证时已由 javplayer
/// 轮换成 sadie-shop.site——绝不写死、从这里现读）。
List<({int number, String name, String url})> av123EpisodesOf(String raw) {
  if (raw.isEmpty) return const [];
  const marker = "player(JSON.parse('";
  final start = raw.indexOf(marker);
  if (start < 0) return const [];
  final contentStart = start + marker.length;
  var end = raw.indexOf("'),", contentStart);
  if (end < 0) end = raw.indexOf("')", contentStart);
  if (end < 0) return const [];
  try {
    final decoded = jsonDecode(
      av123JsUnescape(raw.substring(contentStart, end)),
    );
    final List<dynamic> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map && decoded['episodes'] is List) {
      rows = decoded['episodes'] as List;
    } else {
      return const [];
    }
    final episodes = <({int number, String name, String url})>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final url = (row['url'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      episodes.add((
        number: row['number'] is num
            ? (row['number'] as num).toInt()
            : int.tryParse((row['number'] ?? '').toString()) ??
                  episodes.length + 1,
        name: (row['name'] ?? '').toString(),
        url: url.replaceAll('&amp;', '&'),
      ));
    }
    return episodes;
  } catch (_) {
    return const [];
  }
}

/// 123AV 播放器嵌入地址：内联 player JSON 第一集的 url
/// （主路，域名现读不写死）；抠不到再退任意域名的 /e/{id}
/// 地址正则（容忍反斜杠转义、连同查询串一起取——取流接口
/// 要原样转发这些参数）。
String av123EmbedOf(String raw) {
  if (raw.isEmpty) return '';
  final episodes = av123EpisodesOf(raw);
  if (episodes.isNotEmpty) return episodes.first.url;
  final m = RegExp(
    r'https?:[\\/]+[a-z0-9.-]+[\\/]+e[\\/]+[A-Za-z0-9_-]+(?:\?[^"'
    r"'\s\\<>]*)?",
    caseSensitive: false,
  ).firstMatch(raw);
  if (m != null) {
    return m.group(0)!.replaceAll('\\', '').replaceAll('&amp;', '&');
  }
  return '';
}

/// 嵌入取流接口：id 取自 /e/{id}，接口 = 嵌入源 +
/// '/stream?' + 原查询串 + '&id=' + id（嵌入页 JS 包写明
/// 的取流方式，补验批实证回 JSON 取 media.stream）。不要
/// 再找播放器 iframe。嵌入地址不是 /e/ 形时回 null。
({String apiUrl, String origin})? av123StreamRequest(String embed) {
  final m = RegExp(
    r'^(https?://[^/]+)/e/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  ).firstMatch(embed);
  if (m == null) return null;
  final origin = m.group(1)!;
  final id = m.group(2)!;
  var qs = '';
  final qi = embed.indexOf('?');
  if (qi >= 0) qs = embed.substring(qi + 1);
  final api =
      '$origin/stream?${qs.isNotEmpty ? '$qs&' : ''}id=${Uri.encodeQueryComponent(id)}';
  return (apiUrl: api, origin: origin);
}

/// 页面是不是人机校验/盾页（CF 挑战页特征词）：是盾页时按
/// 「查询失败」如实回状态，不按「未找到」糊弄（AvPlay 对
/// MissAV/Jable 撞盾也是转挑战页处理，我们纯 HTTP 拿不到
/// 就如实标失败，播放层另有壳级嗅探兜底）。
bool actressPageLooksChallenged(String html) {
  if (html.isEmpty) return false;
  final lower = html.toLowerCase();
  return lower.contains('just a moment') ||
      lower.contains('challenges.cloudflare.com') ||
      lower.contains('cf-challenge') ||
      lower.contains('attention required') ||
      lower.contains('checking your browser');
}

String extractAv123Stream(String text) {
  if (text.isEmpty) return '';
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      final media = decoded['media'];
      if (media is Map) {
        final stream = (media['stream'] ?? '').toString();
        if (stream.isNotEmpty) return stream;
      }
      for (final key in const ['stream', 'file']) {
        final value = (decoded[key] ?? '').toString();
        if (value.isNotEmpty) return value;
      }
      return '';
    }
  } catch (_) {
    // 非 JSON 回包走下面的正则兜底。
  }
  final un = text.replaceAll(RegExp(r'\\+/'), '/');
  final m =
      RegExp(r'"stream"\s*:\s*"(https?:[^"]+)"', caseSensitive: false)
          .firstMatch(un) ??
      RegExp(
        r'"(?:file|url|src|hls)"\s*:\s*"(https?:[^"]+)"',
        caseSensitive: false,
      ).firstMatch(un) ??
      RegExp(
        'https?://[^"\'\\s]+\\.m3u8[^"\'\\s]*',
        caseSensitive: false,
      ).firstMatch(un);
  if (m == null) return '';
  return m.groupCount >= 1 && m.group(1) != null ? m.group(1)! : m.group(0)!;
}
