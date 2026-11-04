import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_channel.dart';
import 'source_registry.dart';

enum OneClickLevel { auto, assisted }

enum OneClickContent { video, novel, comic, audio }

extension OneClickContentRegistry on OneClickContent {
  ContentType get registryType => switch (this) {
    OneClickContent.video => ContentType.video,
    OneClickContent.novel => ContentType.novel,
    OneClickContent.comic => ContentType.comic,
    OneClickContent.audio => ContentType.audio,
  };

  String get label => switch (this) {
    OneClickContent.video => '影视',
    OneClickContent.novel => '小说',
    OneClickContent.comic => '漫画',
    OneClickContent.audio => '听书',
  };
}

class OneClickTemplateInfo {
  const OneClickTemplateInfo({
    required this.code,
    required this.name,
    required this.level,
    required this.content,
    required this.note,
  });

  final String code;
  final String name;
  final OneClickLevel level;
  final OneClickContent content;
  final String note;

  String get levelLabel => level == OneClickLevel.auto ? '全自动' : '模板辅助';
}

const Map<String, OneClickTemplateInfo> oneClickTemplates = {
  'T1': OneClickTemplateInfo(
    code: 'T1',
    name: 'MacCMS JSON 接口',
    level: OneClickLevel.auto,
    content: OneClickContent.video,
    note: '全自动：接口直取，分类取自接口类型表，取不到时只给全部。',
  ),
  'T2': OneClickTemplateInfo(
    code: 'T2',
    name: 'MacCMS HTML 改写族（视频）',
    level: OneClickLevel.assisted,
    content: OneClickContent.video,
    note: '模板辅助：分类与卡片按模板骨架生成，取流为直链提取，不含嗅探兜底。',
  ),
  'T3': OneClickTemplateInfo(
    code: 'T3',
    name: 'MacCMS 文章改写族',
    level: OneClickLevel.assisted,
    content: OneClickContent.novel,
    note: '模板辅助：按 /arttype/、/artdetail- 骨架生成。',
  ),
  'T4': OneClickTemplateInfo(
    code: 'T4',
    name: 'MacCMS 文章改写变体',
    level: OneClickLevel.assisted,
    content: OneClickContent.comic,
    note: '模板辅助：按 /cstype/、/cs- 骨架生成；个别视频详情未验。',
  ),
  'T5': OneClickTemplateInfo(
    code: 'T5',
    name: 'WordPress 式',
    level: OneClickLevel.assisted,
    content: OneClickContent.novel,
    note: '模板辅助：正文与图集容器各站不同，生成用通用容器启发式，可能需人工钉。',
  ),
  'T6': OneClickTemplateInfo(
    code: 'T6',
    name: '纯 HTML 正则视频站',
    level: OneClickLevel.assisted,
    content: OneClickContent.video,
    note: '模板辅助：卡片与播放选择器按通用正则生成，可能需人工钉。',
  ),
  'T8': OneClickTemplateInfo(
    code: 'T8',
    name: 'PHP 查询接口视频站',
    level: OneClickLevel.assisted,
    content: OneClickContent.video,
    note: '模板辅助：按 list.php、video.php、search.php 骨架生成。',
  ),
  'T9': OneClickTemplateInfo(
    code: 'T9',
    name: '站内 JSON API 视频站',
    level: OneClickLevel.assisted,
    content: OneClickContent.video,
    note: '模板辅助：接口路径取自首页探测，字段通用解析；涉 AES 的站取流需完整流程。',
  ),
  'T10': OneClickTemplateInfo(
    code: 'T10',
    name: 'Discuz! 论坛移动接口',
    level: OneClickLevel.assisted,
    content: OneClickContent.video,
    note: '模板辅助：按 forum.php 移动接口骨架生成。',
  ),
  'T12': OneClickTemplateInfo(
    code: 'T12',
    name: '漫画 HTML 站',
    level: OneClickLevel.assisted,
    content: OneClickContent.comic,
    note: '模板辅助：按三站章节路径骨架生成。',
  ),
  'T13': OneClickTemplateInfo(
    code: 'T13',
    name: '漫画 JSON API 站',
    level: OneClickLevel.assisted,
    content: OneClickContent.comic,
    note: '模板辅助：接口路径取自首页探测，图床分流按模板处理。',
  ),
  'T14': OneClickTemplateInfo(
    code: 'T14',
    name: '小说现代 Web 应用',
    level: OneClickLevel.assisted,
    content: OneClickContent.novel,
    note: '模板辅助：按 /discovery、/novel/series 骨架生成。',
  ),
  'T15': OneClickTemplateInfo(
    code: 'T15',
    name: '小说 PHP 内容接口',
    level: OneClickLevel.assisted,
    content: OneClickContent.novel,
    note: '模板辅助：正文接口按 /_getcontent.php 骨架生成，分类与目录以通用解析为准。',
  ),
  'T16': OneClickTemplateInfo(
    code: 'T16',
    name: '听书 JSON API 站',
    level: OneClickLevel.assisted,
    content: OneClickContent.audio,
    note: '模板辅助：按专辑与曲目接口骨架生成；VIP 集不取。',
  ),
};

class OneClickUnsupported extends StateError {
  OneClickUnsupported(this.reason, {this.needsFullFlow = false})
    : super(reason);
  final String reason;
  final bool needsFullFlow;
}

class OneClickIdentification {
  const OneClickIdentification({
    required this.template,
    required this.origin,
    required this.siteKey,
    required this.siteName,
    this.apiLinks = const [],
    this.fallbackNote,
    this.trialCandidates = const [],
    this.homeHtml = '',
    this.inputUrl = '',
  });

  final OneClickTemplateInfo template;
  final String origin;
  final String siteKey;
  final String siteName;
  final List<String> apiLinks;
  final String? fallbackNote;

  /// 试套用候选（按优先顺序）：非空即试套模式，template 只是占位，
  /// 生成前必须逐项自检，验过才换成胜出模板导入，不过则报套不上。
  final List<String> trialCandidates;

  /// 识别时抓到的首页（或输入页）HTML，试套自检直接复用，不重抓。
  final String homeHtml;

  /// 用户输入的归一化网址：试套 T9 时可把它本身当接口地址探一次
  /// （登记表仅见接口地址的站，用户往往直接贴接口地址）。
  final String inputUrl;

  bool get trialMode => trialCandidates.isNotEmpty;
}

/// 试套用优先顺序（用户定）：T1 全自动探针已在识别时跑过，试套时
/// 再跑一次不亏；其余按文章、WP、通用视频、站内接口排。
const oneClickTrialOrder = ['T1', 'T3', 'T5', 'T6', 'T9'];

String normalizeSiteUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) {
    throw StateError('网址不能为空');
  }
  if (!text.contains('://')) {
    text = 'https://$text';
  }
  final uri = Uri.tryParse(text);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    throw StateError('网址格式不对，需要是 http 或 https 地址');
  }
  var normalized = text;
  final hashIndex = normalized.indexOf('#');
  if (hashIndex >= 0) {
    normalized = normalized.substring(0, hashIndex);
  }
  if (normalized.endsWith('/') && uri.path == '/') {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String siteOriginOf(String url) {
  final uri = Uri.parse(url);
  return '${uri.scheme}://${uri.host}';
}

String siteKeyFromHost(String host) {
  var bare = host.toLowerCase();
  if (bare.startsWith('www.')) {
    bare = bare.substring(4);
  }
  final first = bare.split('.').first;
  final cleaned = first
      .replaceAll(RegExp(r'[^a-z0-9_]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? 'site' : cleaned;
}

String displayNameFromHost(String host) {
  var bare = host.toLowerCase();
  if (bare.startsWith('www.')) {
    bare = bare.substring(4);
  }
  final first = bare.split('.').first;
  return first.isEmpty ? 'site' : first;
}

class OneClickUrlMatch {
  const OneClickUrlMatch({this.templateCode, this.unsupportedKind});

  final String? templateCode;
  final String? unsupportedKind;
}

OneClickUrlMatch matchUrlPatterns(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    return const OneClickUrlMatch();
  }
  final host = uri.host.toLowerCase();
  if (host == 'youtube.com' ||
      host == 'www.youtube.com' ||
      host == 'youtu.be' ||
      host.endsWith('.youtube.com')) {
    return const OneClickUrlMatch(unsupportedKind: 'youtube');
  }
  if (host == 'hongguoduanju.com' || host.endsWith('.hongguoduanju.com')) {
    return const OneClickUrlMatch(unsupportedKind: 'hongguo');
  }
  final target = url.toLowerCase();
  if (target.contains('/arttype/') || target.contains('/artdetail-')) {
    return const OneClickUrlMatch(templateCode: 'T3');
  }
  if (target.contains('/cstype/') ||
      target.contains('/cs-') ||
      target.contains('/cssearch/')) {
    return const OneClickUrlMatch(templateCode: 'T4');
  }
  if (target.contains('forum.php')) {
    return const OneClickUrlMatch(templateCode: 'T10');
  }
  if (target.contains('list.php') ||
      target.contains('video.php') ||
      target.contains('search.php?content=')) {
    return const OneClickUrlMatch(templateCode: 'T8');
  }
  if (target.contains('/api/comic') ||
      target.contains('/api/categories') ||
      target.contains('/api/album') ||
      target.contains('/api/chapter')) {
    return const OneClickUrlMatch(templateCode: 'T13');
  }
  if (target.contains('/_getcontent.php')) {
    return const OneClickUrlMatch(templateCode: 'T15');
  }
  if (target.contains('/listening/') ||
      target.contains('/mobile/others/ca/album/track/')) {
    return const OneClickUrlMatch(templateCode: 'T16');
  }
  if (target.contains('/discovery') ||
      target.contains('/novel/series/') ||
      target.contains('/novel/show/') ||
      target.contains('/search/novels')) {
    return const OneClickUrlMatch(templateCode: 'T14');
  }
  if (target.contains('/comic/') ||
      target.contains('/album/') ||
      target.contains('/manga/')) {
    return const OneClickUrlMatch(templateCode: 'T12');
  }
  if (target.contains('/type/id/')) {
    return const OneClickUrlMatch(templateCode: 'T2');
  }
  if (target.contains('/api.php/provide/vod/')) {
    return const OneClickUrlMatch(templateCode: 'T1');
  }
  if (target.contains('/?s=') ||
      target.contains('/page/') ||
      target.contains('/post/') ||
      target.contains('/article/') ||
      target.contains('/category/')) {
    return const OneClickUrlMatch(templateCode: 'T5');
  }
  return const OneClickUrlMatch();
}

class OneClickHomepageScore {
  const OneClickHomepageScore({
    this.templateCode,
    this.shell = false,
    this.nextJs = false,
    this.videoMarkers = false,
    this.apiLinks = const [],
  });

  final String? templateCode;
  final bool shell;
  final bool nextJs;
  final bool videoMarkers;
  final List<String> apiLinks;
}

const _specificityOrder = [
  'T3',
  'T4',
  'T10',
  'T8',
  'T13',
  'T15',
  'T16',
  'T14',
  'T12',
  'T2',
  'T5',
  'T9',
];

OneClickHomepageScore scoreHomepage(String html, String origin) {
  final lower = html.toLowerCase();
  final shell =
      lower.contains('obfuscate/js/t/') || lower.contains('fu1');
  final nextJs = lower.contains('__next_f.push');
  final videoMarkers =
      lower.contains('.m3u8') ||
      lower.contains('.mp4') ||
      lower.contains('data-m3u8') ||
      lower.contains('<video');
  final scores = <String, int>{};
  void add(String code, int points, bool hit) {
    if (hit) {
      scores[code] = (scores[code] ?? 0) + points;
    }
  }

  add('T3', 3, lower.contains('/arttype/'));
  add('T3', 2, lower.contains('/artdetail-'));
  add('T4', 3, lower.contains('/cstype/'));
  add('T4', 2, lower.contains('/cs-'));
  add('T10', 3, lower.contains('forum.php'));
  add('T8', 2, lower.contains('list.php'));
  add('T8', 2, lower.contains('video.php'));
  add('T13', 3, lower.contains('/api/comic'));
  add('T13', 3, lower.contains('/api/categories'));
  add('T13', 2, lower.contains('/api/album'));
  add('T13', 2, lower.contains('/api/chapter'));
  add('T15', 3, lower.contains('/_getcontent.php'));
  add('T16', 3, lower.contains('/mobile/others/ca/album/track/'));
  add('T16', 2, lower.contains('/listening/'));
  add('T14', 3, lower.contains('/novel/series/'));
  add('T14', 3, lower.contains('/novel/show/'));
  add('T14', 2, lower.contains('/discovery'));
  add('T14', 2, lower.contains('/search/novels'));
  add('T12', 2, lower.contains('/comic/'));
  add('T12', 2, lower.contains('/album/'));
  add('T12', 2, lower.contains('/manga/'));
  add('T2', 3, lower.contains('/type/id/'));
  add('T5', 3, lower.contains('/wp-content/'));
  add('T5', 1, lower.contains('/?s='));
  add('T5', 1, lower.contains('/post/'));
  add('T5', 1, lower.contains('/article/'));
  add('T5', 1, lower.contains('/category/'));
  final apiLinks = <String>[];
  final seenLinks = <String>{};
  for (final match in RegExp(
    r'''href="([^"]*\/api\/[^"]*)"''',
  ).allMatches(html)) {
    final raw = match.group(1)!;
    final absolute = raw.startsWith('http')
        ? raw
        : origin + (raw.startsWith('/') ? raw : '/$raw');
    if (seenLinks.add(absolute)) {
      apiLinks.add(absolute);
    }
    if (apiLinks.length >= 8) {
      break;
    }
  }
  add('T9', 1, apiLinks.isNotEmpty);
  String? best;
  var bestScore = 0;
  for (final code in _specificityOrder) {
    final score = scores[code] ?? 0;
    if (score > bestScore) {
      bestScore = score;
      best = code;
    }
  }
  return OneClickHomepageScore(
    templateCode: best,
    shell: shell,
    nextJs: nextJs,
    videoMarkers: videoMarkers,
    apiLinks: apiLinks,
  );
}

bool looksLikeMaccmsJson(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return false;
    }
    final list = decoded['list'];
    if (list is List) {
      return true;
    }
    final data = decoded['data'];
    if (data is List) {
      return true;
    }
    if (data is Map && data['list'] is List) {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

const _unsupportedMessages = {
  'youtube': 'YouTube 系：机器人检查与格式演进需持续跟进，需完整流程，暂不支持一键生成。',
  'hongguo': '红果短剧：签名、spade、CENC 四层缺一不可，需完整流程，暂不支持一键生成。',
  'shell': '壳混淆站：混淆层需逐站复现，需完整流程，暂不支持一键生成。',
  'nextjs': 'Next.js RSC 视频站：对象字段分型需人工钉，不在首版范围，暂不支持一键生成。',
  'unknown':
      '无法识别该站模板：请确认输入的是站点首页或分类、详情页地址。',
};

OneClickUnsupported unsupportedFor(String kind) {
  return OneClickUnsupported(
    _unsupportedMessages[kind] ?? _unsupportedMessages['unknown']!,
    needsFullFlow: kind != 'unknown',
  );
}

Future<OneClickIdentification> identifySite(
  String rawUrl, {
  http.Client? client,
  List<OneClickHistoryEntry>? history,
}) async {
  final url = normalizeSiteUrl(rawUrl);
  final uri = Uri.parse(url);
  final origin = '${uri.scheme}://${uri.host}';
  final siteKey = siteKeyFromHost(uri.host);
  final siteName = displayNameFromHost(uri.host);
  final urlMatch = matchUrlPatterns(url);
  if (urlMatch.unsupportedKind != null) {
    throw unsupportedFor(urlMatch.unsupportedKind!);
  }
  if (urlMatch.templateCode != null) {
    final template = oneClickTemplates[urlMatch.templateCode!]!;
    final seedLinks = <String>[];
    if (urlMatch.templateCode == 'T13') {
      seedLinks.add(url);
    }
    return OneClickIdentification(
      template: template,
      origin: origin,
      siteKey: siteKey,
      siteName: siteName,
      apiLinks: seedLinks,
    );
  }
  if (history != null) {
    for (final record in history) {
      if (Uri.tryParse(record.url)?.host == uri.host &&
          oneClickTemplates.containsKey(record.templateCode)) {
        return OneClickIdentification(
          template: oneClickTemplates[record.templateCode]!,
          origin: origin,
          siteKey: siteKey,
          siteName: record.name,
          apiLinks: record.apiLinks,
        );
      }
    }
  }
  final httpClient = client ?? http.Client();
  try {
    try {
      final probe = await httpClient
          .get(
            Uri.parse('$origin/api.php/provide/vod/?ac=list'),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (probe.statusCode == 200 &&
          looksLikeMaccmsJson(utf8.decode(probe.bodyBytes))) {
        return OneClickIdentification(
          template: oneClickTemplates['T1']!,
          origin: origin,
          siteKey: siteKey,
          siteName: siteName,
        );
      }
    } catch (_) {}
    var home = '';
    try {
      final response = await httpClient
          .get(
            Uri.parse(origin),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        home = utf8.decode(response.bodyBytes, allowMalformed: true);
      }
    } catch (_) {}
    if (home.isEmpty && url != origin) {
      try {
        final response = await httpClient
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          home = utf8.decode(response.bodyBytes, allowMalformed: true);
        }
      } catch (_) {}
    }
    final scored = scoreHomepage(home, origin);
    if (scored.shell) {
      throw unsupportedFor('shell');
    }
    if (scored.nextJs) {
      throw unsupportedFor('nextjs');
    }
    if (scored.templateCode != null) {
      final template = oneClickTemplates[scored.templateCode!]!;
      final linksMissing =
          (template.code == 'T9' || template.code == 'T13') &&
          scored.apiLinks.isEmpty;
      if (!linksMissing) {
        return OneClickIdentification(
          template: template,
          origin: origin,
          siteKey: siteKey,
          siteName: siteName,
          apiLinks: scored.apiLinks,
        );
      }
      // 接口路径未探到：不直接判死，落到试套用。
    }
    if (scored.videoMarkers) {
      return OneClickIdentification(
        template: oneClickTemplates['T6']!,
        origin: origin,
        siteKey: siteKey,
        siteName: siteName,
        fallbackNote: '未命中已知模板，按通用 HTML 视频骨架试写套用，播放选择器可能需人工钉。',
      );
    }
    // 无对应模板的站不再直接判不支持：返回试套模式，生成时按
    // T1、T3、T5、T6、T9 顺序逐项自检，验过才导入，不过报套不上。
    return OneClickIdentification(
      template: oneClickTemplates['T1']!,
      origin: origin,
      siteKey: siteKey,
      siteName: siteName,
      apiLinks: scored.apiLinks,
      fallbackNote:
          '未命中已知模板，生成时按 T1、T3、T5、T6、T9 顺序试套，逐项自检，验过才导入，不过如实报套不上。',
      trialCandidates: oneClickTrialOrder,
      homeHtml: home,
      inputUrl: url,
    );
  } finally {
    if (client == null) {
      httpClient.close();
    }
  }
}

const _trialUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36';

Future<String> _trialFetch(
  http.Client client,
  String url,
  String referer,
) async {
  try {
    final response = await client
        .get(Uri.parse(url), headers: {'User-Agent': _trialUa, 'Referer': referer})
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return '';
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

List<(String, String)> _trialLinks(String html) {
  final found = <(String, String)>[];
  for (final match in RegExp(
    r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
    dotAll: true,
  ).allMatches(html)) {
    final href = match.group(1)!;
    var name = match.group(2)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (name.isEmpty) {
      final title = RegExp(r'title="([^"]+)"').firstMatch(match.group(0)!);
      if (title != null) {
        name = title.group(1)!;
      }
    }
    if (href.isNotEmpty && name.isNotEmpty) {
      found.add((href, name));
    }
  }
  return found;
}

List<(String, String)> _trialCards(String html, RegExp? pattern) {
  return [
    for (final link in _trialLinks(html))
      if (pattern == null || pattern.hasMatch(link.$1)) link,
  ];
}

String _trialAbs(String origin, String href) {
  if (href.startsWith('http')) {
    return href;
  }
  if (href.startsWith('//')) {
    return 'https:$href';
  }
  return origin + (href.startsWith('/') ? href : '/$href');
}

String _trialTitle(String html) {
  final h1 = RegExp(
    r'<h1[^>]*>(.*?)</h1>',
    dotAll: true,
  ).firstMatch(html);
  if (h1 != null) {
    final text = h1.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (text.isNotEmpty) {
      return text;
    }
  }
  final title = RegExp(
    r'<title>(.*?)</title>',
    dotAll: true,
  ).firstMatch(html);
  if (title != null) {
    return title.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
  }
  return '';
}

String _trialText(String html) {
  final texts = <String>[];
  for (final match in RegExp(
    r'<p[^>]*>(.*?)</p>',
    dotAll: true,
  ).allMatches(html)) {
    final text = match.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
    if (text.length > 10) {
      texts.add(text);
    }
  }
  if (texts.isNotEmpty) {
    return texts.join('\n');
  }
  final body = RegExp(
    r'<body[^>]*>(.*?)</body>',
    dotAll: true,
  ).firstMatch(html);
  if (body == null) {
    return '';
  }
  return body
      .group(1)!
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

List<String> _trialImages(String origin, String html) {
  final urls = <String>[];
  for (final match in RegExp(r'<img[^>]+src="([^"]+)"').allMatches(html)) {
    final url = _trialAbs(origin, match.group(1)!);
    if (!urls.contains(url)) {
      urls.add(url);
    }
  }
  return urls;
}

List<String> _trialMediaUrls(String html) {
  final urls = <String>[];
  for (final pattern in [
    r'''https?://[^"'\s<>]+\.m3u8[^"'\s<>]*''',
    r'''https?://[^"'\s<>]+\.mp4[^"'\s<>]*''',
    r'''https?://[^"'\s<>]+\.mp3[^"'\s<>]*''',
    r'''https?://[^"'\s<>]+\.webm[^"'\s<>]*''',
    r'''https?://[^"'\s<>]+\.m4a[^"'\s<>]*''',
    r'data-m3u8="([^"]+)"',
    r'<source[^>]+src="([^"]+)"',
  ]) {
    for (final match in RegExp(pattern).allMatches(html)) {
      final url = match.groupCount >= 1
          ? (match.group(1) ?? match.group(0)!)
          : match.group(0)!;
      if (url.isNotEmpty && !urls.contains(url)) {
        urls.add(url);
      }
    }
  }
  return urls;
}

List<Object?> _trialJsonList(Object? obj) {
  if (obj is List) {
    return obj;
  }
  if (obj is Map) {
    for (final key in ['list', 'data', 'rows', 'items', 'results']) {
      final value = obj[key];
      if (value is List) {
        return value;
      }
      if (value is Map) {
        final inner = _trialJsonList(value);
        if (inner.isNotEmpty) {
          return inner;
        }
      }
    }
  }
  return const [];
}

List<Map<String, dynamic>> _trialJsonRows(String body) {
  try {
    final decoded = jsonDecode(body);
    final list = _trialJsonList(decoded);
    return [
      for (final row in list)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  } catch (_) {
    return const [];
  }
}

Map<String, dynamic>? _trialJsonDetail(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final rows = _trialJsonRows(body);
      if (rows.isNotEmpty) {
        return rows.first;
      }
      return Map<String, dynamic>.from(decoded);
    }
    if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
      return Map<String, dynamic>.from(decoded.first);
    }
  } catch (_) {}
  return null;
}

String _trialRowString(Map<String, dynamic> row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value != null && '$value'.isNotEmpty) {
      return '$value';
    }
  }
  return '';
}

String _trialKeyword(String title) {
  final cleaned = title.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) {
    return '';
  }
  return cleaned.length >= 2 ? cleaned.substring(0, 2) : cleaned;
}

/// 取流实测：只读首个数据块就断流，不下载整文件；按扩展名验魔数，
/// m3u8 认 #EXTM3U，mp4 认 ftyp，mp3 认 ID3 或帧头，webm 认 EBML 头，
/// 其他扩展名只认状态 200/206 与非空首块。
Future<bool> _trialMediaOk(
  http.Client client,
  String url,
  String referer,
) async {
  try {
    final request = http.Request('GET', Uri.parse(url));
    request.headers['User-Agent'] = _trialUa;
    request.headers['Referer'] = referer;
    request.headers['Range'] = 'bytes=0-4095';
    final streamed = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (streamed.statusCode != 200 && streamed.statusCode != 206) {
      return false;
    }
    final chunk = await streamed.stream.first.timeout(
      const Duration(seconds: 15),
    );
    if (chunk.isEmpty) {
      return false;
    }
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.m3u8')) {
      return utf8.decode(chunk, allowMalformed: true).contains('#EXTM3U');
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v')) {
      return utf8.decode(chunk, allowMalformed: true).contains('ftyp');
    }
    if (lower.endsWith('.mp3')) {
      return chunk.length >= 3 &&
          (utf8.decode(chunk.sublist(0, 3), allowMalformed: true) == 'ID3' ||
              (chunk[0] == 0xFF && (chunk[1] & 0xE0) == 0xE0));
    }
    if (lower.endsWith('.webm')) {
      return chunk.length >= 4 &&
          chunk[0] == 0x1A &&
          chunk[1] == 0x45 &&
          chunk[2] == 0xDF &&
          chunk[3] == 0xA3;
    }
    return true;
  } catch (_) {
    return false;
  }
}

class OneClickTrialAttempt {
  const OneClickTrialAttempt({
    required this.code,
    required this.passed,
    required this.failedStep,
    required this.summary,
    this.effectiveApiLinks = const [],
  });

  final String code;
  final bool passed;
  final String failedStep;
  final String summary;
  final List<String> effectiveApiLinks;
}

class OneClickTrialOutcome {
  const OneClickTrialOutcome({this.winner, required this.attempts});

  final OneClickIdentification? winner;
  final List<OneClickTrialAttempt> attempts;
}

class _TrialCtx {
  _TrialCtx({
    required this.identification,
    required this.content,
    required this.client,
    required this.homeHtml,
  });

  final OneClickIdentification identification;
  final OneClickContent content;
  final http.Client client;

  /// 识别首页与输入页拼起来的待验 HTML：首页无信号的站，输入页
  ///（栏目页、接口地址页）往往才有分类与卡片，单看首页会漏掉。
  final String homeHtml;

  String get origin => identification.origin;
  String get referer => '$origin/';

  Future<String> fetch(String url) => _trialFetch(client, url, referer);
}

/// 详情完整性（按生效类型）：标题必填；小说要正文、漫画要章节
/// 链接或图片、视频与听书要可播地址。小说与漫画的取流由详情直接
/// 构造（novel://、pics://），详情通过即取流通过。
bool _trialDetailOk(String html, String origin, OneClickContent content) {
  if (_trialTitle(html).isEmpty) {
    return false;
  }
  switch (content) {
    case OneClickContent.novel:
      return _trialText(html).length >= 10;
    case OneClickContent.comic:
      final chapters = _trialCards(html, RegExp(r'(chapter|detail|/ch/)'));
      return chapters.isNotEmpty || _trialImages(origin, html).isNotEmpty;
    case OneClickContent.video:
    case OneClickContent.audio:
      return _trialMediaUrls(html).isNotEmpty;
  }
}

OneClickTrialAttempt _trialFail(String code, String step, String summary) {
  return OneClickTrialAttempt(
    code: code,
    passed: false,
    failedStep: step,
    summary: summary,
  );
}

OneClickTrialAttempt _trialPass(
  String code,
  String summary, {
  List<String> effectiveApiLinks = const [],
}) {
  return OneClickTrialAttempt(
    code: code,
    passed: true,
    failedStep: '',
    summary: summary,
    effectiveApiLinks: effectiveApiLinks,
  );
}

Future<OneClickTrialAttempt> _verifyTrialT1(_TrialCtx ctx) async {
  const code = 'T1';
  if (ctx.content != OneClickContent.video) {
    return _trialFail(code, '类型不符', '该模板只出视频流，与所选类型不符');
  }
  String api(String params) => '${ctx.origin}/api.php/provide/vod/?$params';
  final rows = _trialJsonRows(await ctx.fetch(api('ac=list')));
  if (rows.isEmpty) {
    return _trialFail(code, '分类首页无数据', '接口 ac=list 未返回列表');
  }
  final page2 = _trialJsonRows(await ctx.fetch(api('ac=list&pg=2')));
  final pageNote = page2.isNotEmpty ? '翻页通过' : '翻页未验（第二页无数据，可能单页）';
  final firstId = _trialRowString(rows.first, ['vod_id', 'id', 'vid', 'aid']);
  if (firstId.isEmpty) {
    return _trialFail(code, '详情无编号', '列表首条无编号，无法取详情');
  }
  final detail = _trialJsonDetail(
    await ctx.fetch(api('ac=detail&ids=${Uri.encodeComponent(firstId)}')),
  );
  if (detail == null) {
    return _trialFail(code, '详情无数据', '详情接口未返回数据');
  }
  final name = _trialRowString(detail, ['vod_name', 'name', 'title']);
  var playUrl = _trialRowString(detail, ['vod_play_url', 'play_url']);
  if (playUrl.contains('#')) {
    playUrl = playUrl.split('#').first;
  }
  if (playUrl.contains('\$')) {
    playUrl = playUrl.split('\$').last;
  }
  if (playUrl.isEmpty) {
    playUrl = _trialRowString(rows.first, ['vod_play_url', 'play_url']);
    if (playUrl.contains('#')) {
      playUrl = playUrl.split('#').first;
    }
    if (playUrl.contains('\$')) {
      playUrl = playUrl.split('\$').last;
    }
  }
  if (name.isEmpty ||
      (playUrl.isEmpty &&
          _trialRowString(detail, ['vod_pic', 'pic']).isEmpty)) {
    return _trialFail(code, '详情无数据', '详情接口未返回标题与播放地址');
  }
  final keyword = _trialKeyword(name);
  if (keyword.isEmpty) {
    return _trialFail(code, '搜索无关键词', '详情无标题，无法构造搜索关键词');
  }
  final searchRows = _trialJsonRows(
    await ctx.fetch(api('ac=list&wd=${Uri.encodeComponent(keyword)}&pg=1')),
  );
  if (searchRows.isEmpty) {
    return _trialFail(code, '搜索无结果', '搜索接口未返回结果');
  }
  if (playUrl.isEmpty || !playUrl.startsWith('http')) {
    return _trialFail(code, '取流无地址', '详情无 http 播放地址');
  }
  final ok = await _trialMediaOk(ctx.client, playUrl, ctx.referer);
  if (!ok) {
    return _trialFail(code, '取流首字节未通过', '播放地址首字节校验未通过');
  }
  return _trialPass(code, '分类首页通过、$pageNote、详情通过、搜索通过、取流通过');
}

Future<OneClickTrialAttempt> _verifyTrialT3(_TrialCtx ctx) async {
  const code = 'T3';
  final categories = _trialCards(
    ctx.homeHtml,
    RegExp(r'/arttype/'),
  );
  if (categories.isEmpty) {
    return _trialFail(code, '分类首页无分类', '首页无 /arttype/ 分类链接');
  }
  final catHtml = await ctx.fetch(
    _trialAbs(ctx.origin, categories.first.$1),
  );
  final cards = _trialCards(catHtml, RegExp(r'/artdetail-'));
  if (cards.isEmpty) {
    return _trialFail(code, '目录无文章', '分类页无 /artdetail- 文章卡片');
  }
  var pageNote = '翻页未验';
  final catId = RegExp(
    r'/arttype/(\d+)/',
  ).firstMatch(categories.first.$1)?.group(1);
  if (catId != null) {
    final page2 = _trialCards(
      await ctx.fetch('${ctx.origin}/arttype/$catId-2/'),
      RegExp(r'/artdetail-'),
    );
    pageNote = page2.isNotEmpty ? '翻页通过' : '翻页未验（第二页无数据，可能单页）';
  }
  final detailHtml = await ctx.fetch(
    _trialAbs(ctx.origin, cards.first.$1),
  );
  if (!_trialDetailOk(detailHtml, ctx.origin, ctx.content)) {
    return _trialFail(code, '详情不完整', '详情页标题或正文、图片、可播地址缺失');
  }
  final keyword = _trialKeyword(_trialTitle(detailHtml));
  if (keyword.isEmpty) {
    return _trialFail(code, '搜索无关键词', '详情无标题，无法构造搜索关键词');
  }
  final searchCards = _trialCards(
    await ctx.fetch(
      '${ctx.origin}/artsearch/-------/?wd=${Uri.encodeComponent(keyword)}',
    ),
    RegExp(r'/artdetail-'),
  );
  if (searchCards.isEmpty) {
    return _trialFail(code, '搜索无结果', '搜索页无 /artdetail- 结果卡片');
  }
  if (ctx.content == OneClickContent.video ||
      ctx.content == OneClickContent.audio) {
    final media = _trialMediaUrls(detailHtml);
    if (media.isEmpty) {
      return _trialFail(code, '详情无可播地址', '详情页无可播地址');
    }
    final ok = await _trialMediaOk(ctx.client, media.first, ctx.referer);
    if (!ok) {
      return _trialFail(code, '取流首字节未通过', '播放地址首字节校验未通过');
    }
    return _trialPass(code, '分类首页通过、$pageNote、详情通过、搜索通过、取流通过');
  }
  return _trialPass(code, '分类首页通过、$pageNote、详情通过、搜索通过、取流随详情通过');
}

Future<OneClickTrialAttempt> _verifyTrialT5(_TrialCtx ctx) async {
  const code = 'T5';
  final cards = _trialCards(
    ctx.homeHtml,
    RegExp(r'/(post|article)/'),
  );
  if (cards.isEmpty) {
    return _trialFail(code, '分类首页无文章卡片', '首页无 /post/、/article/ 文章卡片');
  }
  final page2 = _trialCards(
    await ctx.fetch('${ctx.origin}/page/2/'),
    RegExp(r'/(post|article)/'),
  );
  final pageNote = page2.isNotEmpty ? '翻页通过' : '翻页未验（第二页无数据，可能单页）';
  final detailHtml = await ctx.fetch(
    _trialAbs(ctx.origin, cards.first.$1),
  );
  if (!_trialDetailOk(detailHtml, ctx.origin, ctx.content)) {
    return _trialFail(code, '详情不完整', '详情页标题或正文、图片、可播地址缺失');
  }
  final keyword = _trialKeyword(_trialTitle(detailHtml));
  if (keyword.isEmpty) {
    return _trialFail(code, '搜索无关键词', '详情无标题，无法构造搜索关键词');
  }
  final searchCards = _trialCards(
    await ctx.fetch('${ctx.origin}/?s=${Uri.encodeComponent(keyword)}'),
    RegExp(r'/(post|article)/'),
  );
  if (searchCards.isEmpty) {
    return _trialFail(code, '搜索无结果', '搜索页无文章结果卡片');
  }
  if (ctx.content == OneClickContent.video ||
      ctx.content == OneClickContent.audio) {
    final media = _trialMediaUrls(detailHtml);
    if (media.isEmpty) {
      return _trialFail(code, '详情无可播地址', '详情页无可播地址');
    }
    final ok = await _trialMediaOk(ctx.client, media.first, ctx.referer);
    if (!ok) {
      return _trialFail(code, '取流首字节未通过', '播放地址首字节校验未通过');
    }
    return _trialPass(code, '分类首页通过、$pageNote、详情通过、搜索通过、取流通过');
  }
  return _trialPass(code, '分类首页通过、$pageNote、详情通过、搜索通过、取流随详情通过');
}

Future<OneClickTrialAttempt> _verifyTrialT6(_TrialCtx ctx) async {
  const code = 'T6';
  var media = _trialMediaUrls(ctx.homeHtml);
  var detailHtml = ctx.homeHtml;
  if (media.isEmpty) {
    final cards = _trialLinks(ctx.homeHtml);
    if (cards.isEmpty) {
      return _trialFail(code, '分类首页无卡片', '首页无卡片与可播地址');
    }
    detailHtml = await ctx.fetch(
      _trialAbs(ctx.origin, cards.first.$1),
    );
    media = _trialMediaUrls(detailHtml);
    if (media.isEmpty) {
      return _trialFail(code, '详情无可播地址', '首页首卡详情页无可播地址');
    }
  }
  final title = _trialTitle(detailHtml);
  if (title.isEmpty) {
    return _trialFail(code, '详情无标题', '可播页无标题');
  }
  final keyword = _trialKeyword(title);
  if (keyword.isEmpty) {
    return _trialFail(code, '搜索无关键词', '可播页无标题，无法构造搜索关键词');
  }
  final searchCards = _trialLinks(
    await ctx.fetch('${ctx.origin}/?s=${Uri.encodeComponent(keyword)}'),
  );
  if (searchCards.isEmpty) {
    return _trialFail(code, '搜索无结果', '搜索页无结果卡片');
  }
  final ok = await _trialMediaOk(ctx.client, media.first, ctx.referer);
  if (!ok) {
    return _trialFail(code, '取流首字节未通过', '播放地址首字节校验未通过');
  }
  return _trialPass(code, '分类首页通过、模板不分页、详情通过、搜索通过、取流通过');
}

Future<OneClickTrialAttempt> _verifyTrialT9(_TrialCtx ctx) async {
  const code = 'T9';
  if (ctx.content != OneClickContent.video &&
      ctx.content != OneClickContent.audio) {
    return _trialFail(code, '类型不符', '该模板只出视频与音频流，与所选类型不符');
  }
  final links = <String>[...ctx.identification.apiLinks];
  final inputUrl = ctx.identification.inputUrl;
  if (inputUrl.isNotEmpty && inputUrl != ctx.origin && !links.contains(inputUrl)) {
    links.add(inputUrl);
  }
  if (links.isEmpty) {
    return _trialFail(code, '未探到接口路径', '首页无 /api/ 链接，输入地址也不是接口地址');
  }
  String? working;
  List<Map<String, dynamic>> rows = const [];
  for (final link in links) {
    final probes = <String>[];
    if (link == inputUrl) {
      probes.add(link);
    }
    final sep = link.contains('?') ? '&' : '?';
    probes.add('$link${sep}page=1');
    for (final probe in probes) {
      final probed = _trialJsonRows(await ctx.fetch(probe));
      if (probed.isNotEmpty) {
        working = link;
        rows = probed;
        break;
      }
    }
    if (working != null) {
      break;
    }
  }
  if (working == null) {
    return _trialFail(code, '接口无数据', '接口探针未返回列表');
  }
  final sep = working.contains('?') ? '&' : '?';
  final page2 = _trialJsonRows(await ctx.fetch('$working${sep}page=2'));
  final pageNote = page2.isNotEmpty ? '翻页通过' : '翻页未验（第二页无数据，可能单页）';
  final firstId = _trialRowString(rows.first, ['vod_id', 'id', 'vid', 'aid']);
  Map<String, dynamic>? detail;
  if (firstId.isNotEmpty) {
    for (final param in ['id', 'album_id', 'albumId']) {
      detail = _trialJsonDetail(
        await ctx.fetch('$working$sep$param=${Uri.encodeComponent(firstId)}'),
      );
      if (detail != null) {
        break;
      }
    }
  }
  detail ??= rows.first;
  final name = _trialRowString(detail, ['vod_name', 'name', 'title']);
  final media = _trialRowString(detail, [
    'url',
    'play_url',
    'video_url',
    'm3u8',
    'mp4',
    'audio_url',
    'src',
  ]);
  if (name.isEmpty) {
    return _trialFail(code, '详情无数据', '详情接口未返回标题');
  }
  final keyword = _trialKeyword(name);
  if (keyword.isEmpty) {
    return _trialFail(code, '搜索无关键词', '详情无标题，无法构造搜索关键词');
  }
  var searchOk = false;
  for (final param in ['q', 'key', 'wd', 'keyword']) {
    final searchRows = _trialJsonRows(
      await ctx.fetch('$working$sep$param=${Uri.encodeComponent(keyword)}'),
    );
    if (searchRows.isNotEmpty) {
      searchOk = true;
      break;
    }
  }
  if (!searchOk) {
    return _trialFail(code, '搜索无结果', '搜索接口未返回结果');
  }
  if (media.isEmpty || !media.startsWith('http')) {
    return _trialFail(code, '取流无地址', '详情无 http 播放地址');
  }
  final ok = await _trialMediaOk(ctx.client, media, ctx.referer);
  if (!ok) {
    return _trialFail(code, '取流首字节未通过', '播放地址首字节校验未通过');
  }
  return _trialPass(
    code,
    '分类首页通过、$pageNote、详情通过、搜索通过、取流通过',
    effectiveApiLinks: [working],
  );
}

Future<OneClickTrialAttempt> _verifyTrialCandidate({
  required String code,
  required OneClickIdentification identification,
  required String homeHtml,
  OneClickContent? contentType,
  required http.Client client,
}) async {
  final template = oneClickTemplates[code];
  if (template == null) {
    return _trialFail(code, '无此模板', '模板库无此模板');
  }
  final ctx = _TrialCtx(
    identification: identification,
    content: contentType ?? template.content,
    client: client,
    homeHtml: homeHtml,
  );
  switch (code) {
    case 'T1':
      return _verifyTrialT1(ctx);
    case 'T3':
      return _verifyTrialT3(ctx);
    case 'T5':
      return _verifyTrialT5(ctx);
    case 'T6':
      return _verifyTrialT6(ctx);
    case 'T9':
      return _verifyTrialT9(ctx);
    default:
      return _trialFail(code, '不在试套范围', '该模板不在试套优先顺序内');
  }
}

/// 试套用：按候选顺序逐项自检，首个全过的胜出；全不过返回空胜出
/// 与逐项失败原因，调用方如实报套不上，不导入任何站点。
Future<OneClickTrialOutcome> runTrialFit({
  required OneClickIdentification identification,
  OneClickContent? contentType,
  required http.Client client,
}) async {
  var inputHtml = '';
  final inputUrl = identification.inputUrl;
  if (inputUrl.isNotEmpty && inputUrl != identification.origin) {
    inputHtml = await _trialFetch(
      client,
      inputUrl,
      '${identification.origin}/',
    );
  }
  final homeHtml = inputHtml.isEmpty
      ? identification.homeHtml
      : '${identification.homeHtml}\n$inputHtml';
  final attempts = <OneClickTrialAttempt>[];
  for (final code in identification.trialCandidates) {
    final attempt = await _verifyTrialCandidate(
      code: code,
      identification: identification,
      homeHtml: homeHtml,
      contentType: contentType,
      client: client,
    );
    attempts.add(attempt);
    if (attempt.passed) {
      final template = oneClickTemplates[code]!;
      final winner = OneClickIdentification(
        template: template,
        origin: identification.origin,
        siteKey: identification.siteKey,
        siteName: identification.siteName,
        apiLinks: attempt.effectiveApiLinks,
        fallbackNote: '试套用：按 $code ${template.name}试验生成；${attempt.summary}',
      );
      return OneClickTrialOutcome(winner: winner, attempts: attempts);
    }
  }
  return OneClickTrialOutcome(attempts: attempts);
}

class OneClickHistoryEntry {
  const OneClickHistoryEntry({
    required this.name,
    required this.url,
    required this.templateCode,
    this.apiLinks = const [],
    required this.updatedAt,
  });

  final String name;
  final String url;
  final String templateCode;
  final List<String> apiLinks;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'templateCode': templateCode,
    'apiLinks': apiLinks,
    'updatedAt': updatedAt,
  };

  static OneClickHistoryEntry? fromJson(dynamic decoded) {
    if (decoded is! Map) {
      return null;
    }
    final name = decoded['name'];
    final url = decoded['url'];
    final templateCode = decoded['templateCode'];
    final updatedAt = decoded['updatedAt'];
    if (name is! String ||
        url is! String ||
        templateCode is! String ||
        updatedAt is! int) {
      return null;
    }
    final rawLinks = decoded['apiLinks'];
    final links = <String>[];
    if (rawLinks is List) {
      for (final link in rawLinks) {
        if (link is String) {
          links.add(link);
        }
      }
    }
    return OneClickHistoryEntry(
      name: name,
      url: url,
      templateCode: templateCode,
      apiLinks: links,
      updatedAt: updatedAt,
    );
  }
}

List<OneClickHistoryEntry> filterHistory(
  List<OneClickHistoryEntry> entries,
  String keyword,
) {
  final needle = keyword.trim().toLowerCase();
  if (needle.isEmpty) {
    return entries;
  }
  return [
    for (final entry in entries)
      if (entry.name.toLowerCase().contains(needle) ||
          entry.url.toLowerCase().contains(needle))
        entry,
  ];
}

List<OneClickHistoryEntry> addHistoryEntry(
  List<OneClickHistoryEntry> entries,
  OneClickHistoryEntry entry,
) {
  final next = [
    entry,
    for (final item in entries)
      if (normalizeSiteUrl(item.url) != normalizeSiteUrl(entry.url)) item,
  ];
  if (next.length > 50) {
    return next.sublist(0, 50);
  }
  return next;
}

class OneClickHistoryStore {
  static const key = 'one_click_py_history_v1';

  Future<List<OneClickHistoryEntry>> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(key);
      if (raw == null || raw.isEmpty) {
        return const [];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return [
        for (final item in decoded)
          if (OneClickHistoryEntry.fromJson(item) != null)
            OneClickHistoryEntry.fromJson(item)!,
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<OneClickHistoryEntry> entries) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        key,
        jsonEncode([for (final entry in entries) entry.toJson()]),
      );
    } catch (_) {}
  }

  Future<void> add(OneClickHistoryEntry entry) async {
    final entries = await load();
    await save(addHistoryEntry(entries, entry));
  }

  Future<void> remove(String url) async {
    final entries = await load();
    final target = normalizeSiteUrl(url);
    await save([
      for (final entry in entries)
        if (normalizeSiteUrl(entry.url) != target) entry,
    ]);
  }
}

class OneClickStructureCheck {
  static const requiredMethods = [
    'getName',
    'getDependence',
    'init',
    'destroy',
    'homeContent',
    'homeVideoContent',
    'categoryContent',
    'detailContent',
    'searchContent',
    'playerContent',
    'localProxy',
    'isVideoFormat',
    'manualVideoCheck',
    'action',
  ];

  static String? check(String source) {
    if (!source.contains('class Spider')) {
      return '缺少 class Spider';
    }
    for (final method in requiredMethods) {
      if (!RegExp('def $method\\s*\\(').hasMatch(source)) {
        return '缺少方法 $method';
      }
    }
    final cjk = RegExp('[\u4e00-\u9fff]');
    final reBlock = RegExp(r'^\s*#.*RE_(TARGET|PATH|OBSTACLE|EVIDENCE)');
    for (final line in source.split('\n')) {
      if (reBlock.hasMatch(line)) {
        return '带有 RE 头块';
      }
      if (line.trimLeft().startsWith('#') && cjk.hasMatch(line)) {
        return '带有中文注释行';
      }
    }
    return null;
  }
}

abstract class OneClickDownloadSink {
  Future<String> saveText({required String fileName, required String text});
}

class PlatformOneClickDownloadSink implements OneClickDownloadSink {
  const PlatformOneClickDownloadSink();

  static const _channel = AppMethodChannel('fqapp/downloads');

  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('saveText', {
      'fileName': fileName,
      'text': text,
    });
    final path = result?['path'];
    if (path is! String || path.isEmpty) {
      throw StateError('系统未返回导出路径');
    }
    if (result?['public'] == false) {
      throw StateError('当前系统不支持直接写入下载文件夹，文件未保存');
    }
    return path;
  }
}

typedef OneClickImportSite =
    Future<SourceEntry> Function({
      required String name,
      required String source,
      required ContentType contentType,
      required String fileBaseName,
      required bool oneClick,
      required String? downloadPath,
    });

typedef OneClickRemoveSite = Future<void> Function(String id);

Future<SourceEntry> _defaultImportSite({
  required String name,
  required String source,
  required ContentType contentType,
  required String fileBaseName,
  required bool oneClick,
  required String? downloadPath,
}) {
  return SourceRegistry.instance.addPyImport(
    name,
    source,
    contentType: contentType,
    fileBaseName: fileBaseName,
    oneClick: oneClick,
    downloadPath: downloadPath,
  );
}

class OneClickGenerateResult {
  const OneClickGenerateResult({
    required this.entry,
    required this.identification,
    required this.displayName,
    required this.pySource,
    this.downloadPath,
  });

  final SourceEntry entry;
  final OneClickIdentification identification;
  final String displayName;
  final String pySource;
  final String? downloadPath;
}

Future<OneClickGenerateResult> generateAndImport({
  required String url,
  String? name,
  bool adult = false,
  OneClickContent? contentType,
  http.Client? client,
  OneClickDownloadSink? downloadSink,
  OneClickImportSite? importSite,
  OneClickRemoveSite? removeSite,
  OneClickHistoryStore? historyStore,
}) async {
  final store = historyStore ?? OneClickHistoryStore();
  final history = await store.load();
  final httpClient = client ?? http.Client();
  try {
    var identification = await identifySite(
      url,
      client: httpClient,
      history: history,
    );
    if (identification.trialMode) {
      final outcome = await runTrialFit(
        identification: identification,
        contentType: contentType,
        client: httpClient,
      );
      final winner = outcome.winner;
      if (winner == null) {
        final reasons = [
          for (final attempt in outcome.attempts)
            '${attempt.code}：${attempt.failedStep}',
        ].join('；');
        throw OneClickUnsupported(
          '试套不上：已按 T1、T3、T5、T6、T9 顺序试套，均未通过交付门自检（$reasons），未导入任何站点，请走完整流程。',
          needsFullFlow: true,
        );
      }
      identification = winner;
    }
    final rawName = (name ?? '').trim();
    final baseName = rawName.isEmpty ? identification.siteName : rawName;
    final displayName = adult ? '🔞$baseName' : baseName;
    final content = contentType ?? identification.template.content;
    final py = buildOneClickPy(
      identification,
      siteName: baseName,
      contentOverride: contentType,
    );
    final checkError = OneClickStructureCheck.check(py);
    if (checkError != null) {
      throw StateError('生成自检未通过：$checkError');
    }
    final downloadPath =
        await (downloadSink ?? const PlatformOneClickDownloadSink())
            .saveText(fileName: '${identification.siteKey}.py', text: py);
    final importFn = importSite ?? _defaultImportSite;
    final entry = await importFn(
      name: displayName,
      source: py,
      contentType: content.registryType,
      fileBaseName: identification.siteKey,
      oneClick: true,
      downloadPath: downloadPath,
    );
    if (entry.detail.contains('校验未通过')) {
      final removeFn = removeSite ?? SourceRegistry.instance.removeCustom;
      await removeFn(entry.id);
      throw StateError('导入校验未通过：${entry.detail}，已撤掉登记');
    }
    try {
      await store.add(
        OneClickHistoryEntry(
          name: baseName,
          url: normalizeSiteUrl(url),
          templateCode: identification.template.code,
          apiLinks: identification.apiLinks,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (_) {}
    return OneClickGenerateResult(
      entry: entry,
      identification: identification,
      displayName: displayName,
      pySource: py,
      downloadPath: downloadPath,
    );
  } finally {
    if (client == null) {
      httpClient.close();
    }
  }
}

String buildOneClickPy(
  OneClickIdentification identification, {
  required String siteName,
  OneClickContent? contentOverride,
}) {
  final content = contentOverride ?? identification.template.content;
  final contentKey = switch (content) {
    OneClickContent.video => 'video',
    OneClickContent.novel => 'novel',
    OneClickContent.comic => 'comic',
    OneClickContent.audio => 'audio',
  };
  return _oneClickPyTemplate
      .replaceAll('__API_LINKS__', jsonEncode(identification.apiLinks))
      .replaceAll('__SITE__', identification.origin)
      .replaceAll('__KEY__', identification.siteKey)
      .replaceAll('__NAME__', _pyQuoted(siteName))
      .replaceAll('__TMPL__', identification.template.code)
      .replaceAll('__CTYPE__', contentKey);
}

String _pyQuoted(String value) {
  return value
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ');
}

const _oneClickPyTemplate = r'''
import gzip
import json
import re
import urllib.parse
import urllib.request

SITE = "__SITE__"
KEY = "__KEY__"
NAME = "__NAME__"
TMPL = "__TMPL__"
CTYPE = "__CTYPE__"
API_LINKS = __API_LINKS__
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

try:
    from base.spider import BaseSpider
except Exception:
    class BaseSpider:
        pass


def _headers():
    return {"User-Agent": UA, "Referer": SITE + "/"}


def _get(url):
    req = urllib.request.Request(url, headers=_headers())
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
        return raw.decode("utf-8", errors="ignore")


def _get_safe(url):
    try:
        return _get(url)
    except Exception:
        return ""


def _abs(href):
    if not href:
        return ""
    return urllib.parse.urljoin(SITE + "/", href)


def _text(html):
    return re.sub(r"<[^>]+>", "", html or "").strip()


def _json_list(obj):
    if isinstance(obj, list):
        return obj
    if isinstance(obj, dict):
        for key in ("list", "data", "rows", "items", "results"):
            value = obj.get(key)
            if isinstance(value, list):
                return value
            if isinstance(value, dict):
                inner = _json_list(value)
                if inner:
                    return inner
    return []


def _json_rows(text):
    try:
        return _json_list(json.loads(text))
    except Exception:
        return []


def _pick(row, keys):
    for key in keys:
        value = row.get(key)
        if value not in (None, ""):
            return value
    return ""


def _row_item(row):
    pic = _pick(row, ("vod_pic", "pic", "cover", "img", "image"))
    return {
        "vod_id": str(_pick(row, ("vod_id", "id", "vid", "aid"))),
        "vod_name": str(_pick(row, ("vod_name", "name", "title"))),
        "vod_pic": _abs(str(pic)) if pic else "",
        "vod_remarks": str(_pick(row, ("vod_remarks", "remarks", "note"))),
    }


def _links(html, pattern):
    found = []
    for match in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', html or "", re.S):
        href = match.group(1)
        if pattern and not re.search(pattern, href):
            continue
        name = _text(match.group(2))
        if not name:
            title = re.search(r'title="([^"]+)"', match.group(0))
            name = title.group(1) if title else ""
        if href and name:
            found.append((href, name))
    return found


def _cards(html, pattern):
    items = []
    seen = set()
    for match in re.finditer(r'<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', html or "", re.S):
        href = match.group(1)
        if pattern and not re.search(pattern, href):
            continue
        block = match.group(2)
        img = re.search(r'<img[^>]+src="([^"]+)"', block)
        name = _text(block)
        if not name:
            title = re.search(r'title="([^"]+)"', match.group(0))
            name = title.group(1) if title else ""
        if not href or not name or href in seen:
            continue
        seen.add(href)
        items.append({
            "vod_id": href,
            "vod_name": name[:80],
            "vod_pic": _abs(img.group(1)) if img else "",
        })
    return items


def _media_urls(html):
    urls = []
    for pattern in (
        r'https?://[^"\'\s<>]+\.m3u8[^"\'\s<>]*',
        r'https?://[^"\'\s<>]+\.mp4[^"\'\s<>]*',
        r'https?://[^"\'\s<>]+\.mp3[^"\'\s<>]*',
        r'https?://[^"\'\s<>]+\.webm[^"\'\s<>]*',
        r'https?://[^"\'\s<>]+\.m4a[^"\'\s<>]*',
        r'data-m3u8="([^"]+)"',
        r'data-url="([^"]+\.(?:m3u8|mp4|mp3|webm|m4a)[^"]*)"',
        r'<source[^>]+src="([^"]+)"',
    ):
        for match in re.finditer(pattern, html or ""):
            url = match.group(1) if match.lastindex else match.group(0)
            if url and url not in urls:
                urls.append(url)
    return urls


def _episodes(urls):
    parts = []
    for index, url in enumerate(urls, 1):
        parts.append("第%d集$%s" % (index, url))
    return "#".join(parts)


def _page_text(html):
    texts = []
    for match in re.finditer(r"<p[^>]*>(.*?)</p>", html or "", re.S):
        text = _text(match.group(1))
        if len(text) > 10:
            texts.append(text)
    if texts:
        return "\n".join(texts)
    body = re.search(r"<body[^>]*>(.*?)</body>", html or "", re.S)
    return _text(body.group(1)) if body else ""


def _images(html):
    urls = []
    for match in re.finditer(r'<img[^>]+src="([^"]+)"', html or ""):
        url = _abs(match.group(1))
        if url and url not in urls:
            urls.append(url)
    return urls


def _html_list(html, pattern, page):
    return {"list": _cards(html, pattern), "page": page, "pagecount": 9999, "limit": 20, "total": 0}


def _api_url(link, page):
    sep = "&" if "?" in link else "?"
    return link + sep + "page=%d" % page


CAT_PATTERNS = {
    "T3": r"/arttype/",
    "T4": r"/cstype/",
    "T2": r"/type/id/",
    "T5": r"/(post|article|category)/",
}


class Spider(BaseSpider):
    def getName(self):
        return NAME

    def getDependence(self):
        return []

    def init(self, extend=""):
        pass

    def destroy(self):
        pass

    def homeContent(self, filter=""):
        if TMPL == "T1":
            classes = [{"type_id": "all", "type_name": "全部"}]
            try:
                rows = _json_rows(_get(SITE + "/api.php/provide/vod/?ac=videolist"))
                typed = []
                for row in rows:
                    if not isinstance(row, dict):
                        continue
                    tid = _pick(row, ("type_id", "id"))
                    tname = _pick(row, ("type_name", "name"))
                    if tid and tname:
                        typed.append({"type_id": str(tid), "type_name": str(tname)})
                if typed:
                    classes = typed
            except Exception:
                pass
            return {"class": classes, "filters": {}}
        if TMPL in CAT_PATTERNS:
            classes = []
            try:
                html = _get(SITE + "/")
                for href, name in _links(html, CAT_PATTERNS[TMPL]):
                    tid = href
                    if TMPL == "T3":
                        found = re.search(r"/arttype/(\d+)/", href)
                        tid = found.group(1) if found else href
                    elif TMPL == "T4":
                        found = re.search(r"/cstype/(\d+)/", href)
                        tid = found.group(1) if found else href
                    elif TMPL == "T2":
                        found = re.search(r"/type/id/(\d+)\.html", href)
                        tid = found.group(1) if found else href
                    if all(item["type_id"] != tid for item in classes):
                        classes.append({"type_id": tid, "type_name": name})
            except Exception:
                pass
            if not classes:
                classes = [{"type_id": "all", "type_name": "全部"}]
            return {"class": classes, "filters": {}}
        return {"class": [{"type_id": "all", "type_name": "全部"}], "filters": {}}

    def homeVideoContent(self):
        result = self.categoryContent("all", "1")
        return {"list": result.get("list", [])}

    def categoryContent(self, tid, pg, filter="", extend=None):
        page = int(pg or 1)
        if TMPL == "T1":
            params = {"ac": "list", "pg": page}
            if tid not in ("all", "0", ""):
                params["t"] = tid
            url = SITE + "/api.php/provide/vod/?" + urllib.parse.urlencode(params)
            try:
                data = json.loads(_get(url))
            except Exception:
                data = {}
            rows = _json_list(data)
            pagecount = 1
            total = len(rows)
            if isinstance(data, dict):
                for key in ("pagecount", "pageCount"):
                    if data.get(key):
                        pagecount = int(data[key])
                if data.get("total"):
                    total = int(data["total"])
            return {"list": [_row_item(r) for r in rows if isinstance(r, dict)], "page": page, "pagecount": pagecount, "limit": 20, "total": total}
        if TMPL == "T3":
            url = SITE + "/arttype/%s/" % tid if page == 1 else SITE + "/arttype/%s-%d/" % (tid, page)
            return _html_list(_get_safe(url), r"/artdetail-", page)
        if TMPL == "T4":
            url = SITE + "/cstype/%s/" % tid if page == 1 else SITE + "/cstype/%s-%d/" % (tid, page)
            return _html_list(_get_safe(url), r"/cs-", page)
        if TMPL == "T2":
            url = SITE + "/type/id/%s.html" % tid if page == 1 else SITE + "/type/id/%s-%d.html" % (tid, page)
            return _html_list(_get_safe(url), r"/(info|play)/\d+\.html", page)
        if TMPL == "T5":
            base = _abs(tid) if tid not in ("all", "") else SITE
            url = base.rstrip("/") + "/" if page == 1 else base.rstrip("/") + "/page/%d/" % page
            return _html_list(_get_safe(url), r"/(post|article)/", page)
        if TMPL == "T8":
            tid_value = tid if tid not in ("all", "") else "0"
            url = SITE + "/list.php?id=%s&page=%d" % (tid_value, page)
            return _html_list(_get_safe(url), r"video\.php\?id=", page)
        if TMPL in ("T9", "T13", "T16"):
            for link in API_LINKS:
                try:
                    rows = _json_rows(_get(_api_url(link, page)))
                except Exception:
                    rows = []
                if rows:
                    return {"list": [_row_item(r) for r in rows if isinstance(r, dict)], "page": page, "pagecount": 9999, "limit": 20, "total": 0}
            return {"list": [], "page": page, "pagecount": 1, "limit": 20, "total": 0}
        if TMPL == "T10":
            tid_value = tid if tid not in ("all", "") else "0"
            url = SITE + "/forum.php?mod=forumdisplay&fid=%s&mobile=1&page=%d" % (tid_value, page)
            return _html_list(_get_safe(url), r"mod=viewthread", page)
        if TMPL == "T12":
            base = _abs(tid) if tid not in ("all", "") else SITE
            sep = "&" if "?" in base else "?"
            url = base.rstrip("/") + "/" if page == 1 else base + sep + "page=%d" % page
            return _html_list(_get_safe(url), r"/(comic|album|manga)/", page)
        if TMPL == "T14":
            url = SITE + "/discovery" if page == 1 else SITE + "/discovery?page=%d" % page
            return _html_list(_get_safe(url), r"/novel/(show|series)/", page)
        if TMPL == "T15":
            url = SITE + "/" if page == 1 else SITE + "/?page=%d" % page
            return _html_list(_get_safe(url), None, page)
        return _html_list(_get_safe(SITE + "/"), None, page)

    def _api_detail(self, vid):
        for link in API_LINKS:
            for param in ("id", "album_id", "albumId"):
                try:
                    rows = _json_rows(_get(link + ("&" if "?" in link else "?") + param + "=" + urllib.parse.quote(str(vid))))
                except Exception:
                    rows = []
                for row in rows:
                    if not isinstance(row, dict):
                        continue
                    media = _pick(row, ("url", "play_url", "video_url", "m3u8", "mp4", "audio_url"))
                    if media:
                        item = _row_item(row)
                        item["vod_play_from"] = "在线播放"
                        item["vod_play_url"] = "正片$%s" % media
                        return item
        return None

    def _api_tracks(self, vid):
        for link in API_LINKS:
            for param in ("album_id", "albumId", "id"):
                try:
                    rows = _json_rows(_get(link + ("&" if "?" in link else "?") + param + "=" + urllib.parse.quote(str(vid))))
                except Exception:
                    rows = []
                parts = []
                for index, row in enumerate(rows, 1):
                    if not isinstance(row, dict):
                        continue
                    media = _pick(row, ("url", "play_url", "audio_url", "src"))
                    if not media:
                        continue
                    label = _pick(row, ("name", "title"))
                    if not label:
                        label = "第%d集" % index
                    parts.append("%s$%s" % (label, media))
                if parts:
                    return "#".join(parts)
        return ""

    def detailContent(self, ids):
        vid = ids[0] if ids else ""
        if TMPL == "T1":
            try:
                data = json.loads(_get(SITE + "/api.php/provide/vod/?ac=detail&ids=" + urllib.parse.quote(str(vid))))
            except Exception:
                data = {}
            rows = _json_list(data)
            row = rows[0] if rows else (data if isinstance(data, dict) else {})
            item = _row_item(row) if isinstance(row, dict) else {"vod_id": str(vid), "vod_name": "", "vod_pic": ""}
            if isinstance(row, dict):
                item["vod_content"] = str(_pick(row, ("vod_content", "vod_blurb", "blurb", "desc")))
                item["vod_play_from"] = str(_pick(row, ("vod_play_from", ""))) or "在线播放"
                item["vod_play_url"] = str(_pick(row, ("vod_play_url", "")))
            return {"list": [item]}
        if TMPL in ("T9", "T13"):
            item = self._api_detail(vid)
            if item is not None:
                return {"list": [item]}
        if TMPL == "T16":
            tracks = self._api_tracks(vid)
            if tracks:
                return {"list": [{
                    "vod_id": str(vid), "vod_name": "", "vod_pic": "",
                    "vod_play_from": "在线播放", "vod_play_url": tracks,
                }]}
        url = vid if str(vid).startswith("http") else _abs(str(vid))
        html = _get_safe(url)
        title = ""
        found = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S)
        if found:
            title = _text(found.group(1))
        if not title:
            found = re.search(r"<title>(.*?)</title>", html, re.S)
            title = _text(found.group(1)) if found else ""
        pic = ""
        found = re.search(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', html)
        if found:
            pic = _abs(found.group(1))
        if CTYPE == "novel":
            content = _page_text(html)
            payload = json.dumps({"title": title, "content": content}, ensure_ascii=False)
            return {"list": [{
                "vod_id": str(vid), "vod_name": title, "vod_pic": pic,
                "vod_play_from": "阅读", "vod_play_url": "正片$novel://" + payload,
            }]}
        if CTYPE == "comic":
            chapters = _links(html, r"(chapter|detail|/ch/)")
            if chapters:
                parts = []
                for index, (href, name) in enumerate(chapters, 1):
                    label = name if name else "第%d话" % index
                    parts.append("%s$%s" % (label, _abs(href)))
                return {"list": [{
                    "vod_id": str(vid), "vod_name": title, "vod_pic": pic,
                    "vod_play_from": "查看", "vod_play_url": "#".join(parts),
                }]}
            imgs = _images(html)
            return {"list": [{
                "vod_id": str(vid), "vod_name": title, "vod_pic": pic,
                "vod_play_from": "查看", "vod_play_url": "查看$pics://" + "&&".join(imgs),
            }]}
        if CTYPE == "audio":
            urls = _media_urls(html)
            if not urls:
                for link in API_LINKS:
                    try:
                        rows = _json_rows(_get(link))
                    except Exception:
                        rows = []
                    for row in rows:
                        if isinstance(row, dict):
                            found_url = _pick(row, ("url", "play_url", "audio_url", "src"))
                            if found_url:
                                urls.append(str(found_url))
                    if urls:
                        break
            parts = []
            for index, media in enumerate(urls, 1):
                parts.append("第%d集$%s" % (index, media))
            return {"list": [{
                "vod_id": str(vid), "vod_name": title, "vod_pic": pic,
                "vod_play_from": "在线播放", "vod_play_url": "#".join(parts),
            }]}
        urls = _media_urls(html)
        if TMPL == "T2" and not urls:
            play_id = re.search(r"/info/(\d+)\.html", str(vid))
            if play_id:
                urls = _media_urls(_get_safe(SITE + "/play/%s.html" % play_id.group(1)))
        if not urls:
            iframe = re.search(r'<iframe[^>]+src="([^"]+)"', html)
            if iframe:
                urls = _media_urls(_get_safe(_abs(iframe.group(1))))
        return {"list": [{
            "vod_id": str(vid), "vod_name": title, "vod_pic": pic,
            "vod_play_from": "在线播放", "vod_play_url": _episodes(urls),
        }]}

    def searchContent(self, key, quick=False, pg="1"):
        page = int(pg or 1)
        word = urllib.parse.quote(str(key))
        if TMPL == "T1":
            url = SITE + "/api.php/provide/vod/?ac=list&wd=%s&pg=%d" % (word, page)
            try:
                rows = _json_list(json.loads(_get(url)))
            except Exception:
                rows = []
            return {"list": [_row_item(r) for r in rows if isinstance(r, dict)], "page": page}
        if TMPL == "T3":
            url = SITE + "/artsearch/-------/?wd=%s" % word if page == 1 else SITE + "/artsearch/%s------%d-/" % (word, page)
            return {"list": _cards(_get_safe(url), r"/artdetail-"), "page": page}
        if TMPL == "T4":
            url = SITE + "/cssearch/-------/?wd=%s" % word if page == 1 else SITE + "/cssearch/%s------%d-/" % (word, page)
            return {"list": _cards(_get_safe(url), r"/cs-"), "page": page}
        if TMPL == "T5":
            url = SITE + "/?s=%s" % word if page == 1 else SITE + "/page/%d/?s=%s" % (page, word)
            return {"list": _cards(_get_safe(url), r"/(post|article)/"), "page": page}
        if TMPL == "T8":
            return {"list": _cards(_get_safe(SITE + "/search.php?content=%s" % word), r"video\.php\?id="), "page": page}
        if TMPL in ("T9", "T13", "T16"):
            for link in API_LINKS:
                for param in ("q", "key", "wd", "keyword"):
                    try:
                        rows = _json_rows(_get(link + ("&" if "?" in link else "?") + param + "=" + word))
                    except Exception:
                        rows = []
                    if rows:
                        return {"list": [_row_item(r) for r in rows if isinstance(r, dict)], "page": page}
            return {"list": [], "page": page}
        if TMPL == "T10":
            url = SITE + "/search.php?mod=forum&mobile=1&srchtxt=%s" % word
            return {"list": _cards(_get_safe(url), r"mod=viewthread"), "page": page}
        if TMPL == "T14":
            return {"list": _cards(_get_safe(SITE + "/search/novels?q=%s" % word), r"/novel/(show|series)/"), "page": page}
        if TMPL == "T2":
            return {"list": _cards(_get_safe(SITE + "/search?wd=%s" % word), r"/(info|play)/\d+\.html"), "page": page}
        if TMPL == "T12":
            return {"list": _cards(_get_safe(SITE + "/search?q=%s" % word), r"/(comic|album|manga)/"), "page": page}
        return {"list": _cards(_get_safe(SITE + "/?s=%s" % word), None), "page": page}

    def playerContent(self, flag, id, vipFlags=None):
        text = str(id or "")
        if text.startswith("novel://") or text.startswith("pics://"):
            return {"parse": 0, "url": text, "header": {}}
        if CTYPE == "novel":
            url = text if text.startswith("http") else _abs(text)
            html = _get_safe(url)
            title = ""
            found = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S)
            if found:
                title = _text(found.group(1))
            content = _page_text(html)
            if TMPL == "T15":
                chapter_id = ""
                id_match = re.search(r"(\d+)", url)
                if id_match:
                    chapter_id = id_match.group(1)
                v_match = re.search(r"[?&]v=([^\"&]+)", html)
                if not v_match:
                    v_match = re.search(r"""v\s*=\s*["']([^"']+)""", html)
                if chapter_id and v_match:
                    body = _get_safe(SITE + "/_getcontent.php?id=" + chapter_id + "&v=" + urllib.parse.quote(v_match.group(1)))
                    if body.strip():
                        content = _text(body)
            payload = json.dumps({"title": title, "content": content}, ensure_ascii=False)
            return {"parse": 0, "url": "novel://" + payload, "header": {}}
        if CTYPE == "comic":
            url = text if text.startswith("http") else _abs(text)
            imgs = _images(_get_safe(url))
            return {"parse": 0, "url": "pics://" + "&&".join(imgs), "header": {}}
        if text.startswith("http"):
            return {"parse": 0, "url": text, "header": _headers()}
        if TMPL == "T1":
            try:
                data = json.loads(_get(SITE + "/api.php/provide/vod/?ac=detail&ids=" + urllib.parse.quote(text)))
                rows = _json_list(data)
                row = rows[0] if rows else {}
                play_url = str(_pick(row, ("vod_play_url", ""))) if isinstance(row, dict) else ""
                first = play_url.split("#")[0] if play_url else ""
                if "$" in first:
                    first = first.split("$")[-1]
                if first.startswith("http"):
                    return {"parse": 0, "url": first, "header": _headers()}
            except Exception:
                pass
        return {"parse": 0, "url": text, "header": _headers()}

    def localProxy(self, param=None):
        return [404, "text/plain", "", {}]

    def isVideoFormat(self, url):
        return str(url or "").lower().split("?")[0].endswith((".m3u8", ".mp4", ".mkv", ".flv", ".mov", ".webm", ".mp3", ".m4a"))

    def manualVideoCheck(self):
        return False

    def action(self, action=None):
        return ""
''';
