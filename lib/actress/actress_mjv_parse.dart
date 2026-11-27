import 'dart:convert';

import '../services/aes_cipher.dart';

/// MJV 模板站（mjv011.com / 18av.nl 同一套系统）的纯解析层：
/// 搜索卡解析、详情页 pid 解密、play.php 取档，与
/// assets/builtin_sites/chaoliu.py 的 _parse_posts /
/// _extract_pids / _decrypt_id / _playphp 逐字对齐移植
/// （2026-11-27 盘点实测：18AV 与 MJV 同内容库、pid 模板
/// 同构，chaoliu.py 的 _extract_pids 原样可解 18AV 详情页）。
/// 本文件只吃文本吐结构，不碰网络，方便夹具离线验。

/// 一张 MJV 模板搜索/列表卡：详情页三段坐标 + 标题 + 封面。
class MjvCard {
  const MjvCard({
    required this.ctype,
    required this.num,
    required this.slug,
    required this.title,
    this.cover = '',
  });

  final String ctype;
  final String num;
  final String slug;
  final String title;
  final String cover;

  /// 详情页地址（[site] 不带尾斜杠）。
  String detailUrl(String site) => '$site/zh/${ctype}_content/$num/$slug.html';
}

String _stripTags(String raw) => raw.replaceAll(RegExp(r'<[^>]*>'), '');

String _firstGroup(String text, Pattern pattern) {
  final match = pattern.allMatches(text).firstOrNull;
  if (match == null) return '';
  return match.group(1) ?? '';
}

/// 搜索/列表页卡片解析（chaoliu.py _parse_posts 的两式：
/// post 块式优先、无命中才走松散式；小说/图片分类不在本层
/// 处理，调用方按 ctype 自行过滤）。
List<MjvCard> parseMjvCards(String text) {
  if (text.isEmpty) return const [];
  final items = <MjvCard>[];
  final p1 = RegExp(
    r'''<div class='post'>\s*<a[^>]*href="([^"]+)"[^>]*><img[^>]*src='([^']+)'[^>]*>\s*</a>\s*<div class='con'>\s*<h3[^>]*><a[^>]*>([^<]+)</a></h3>''',
    dotAll: true,
  );
  var found1 = false;
  for (final m in p1.allMatches(text)) {
    found1 = true;
    _addMjvCard(items, m.group(1)!, m.group(3)!, m.group(2)!);
  }
  if (found1) return items;
  final p2 = RegExp(
    r'''<a[^>]+href="([^"]*zh/[^"]*_content/[^"]*)"[^>]*>.*?<img[^>]+src="([^"]+)"[^>]*>.*?<(?:h3|h2|h4|div\s+class="title")[^>]*>(.*?)</''',
    dotAll: true,
    caseSensitive: false,
  );
  for (final m in p2.allMatches(text)) {
    _addMjvCard(items, m.group(1)!, _stripTags(m.group(3)!), m.group(2)!);
  }
  return items;
}

void _addMjvCard(List<MjvCard> items, String href, String title, String pic) {
  var path = href;
  final hostEnd = path.indexOf('/zh/');
  if (path.startsWith('http') && hostEnd >= 0) path = path.substring(hostEnd);
  if (!path.startsWith('/')) return;
  final mm = RegExp(r'/([^/]+)_content/(\d+)/([^/]+)\.html').firstMatch(path);
  if (mm == null) return;
  items.add(
    MjvCard(
      ctype: mm.group(1)!,
      num: mm.group(2)!,
      slug: mm.group(3)!,
      title: title.trim(),
      cover: pic,
    ),
  );
}

/// 单个 pid 解密（chaoliu.py _decrypt_id 逐字对齐）：
/// enc 按 chr(base+97) 分段，每段按 base 进制读整数、与
/// xorKey 异或得字符，拼起来是 base64，再 AES-128-CBC
/// （key/iv 取 UTF-8 前 16 字节）解出明文。任一步失败回空。
String mjvDecryptId(
  String enc,
  int xorKey,
  int base,
  String aesKey,
  String aesIv,
) {
  if (enc.isEmpty || base < 2 || base > 36) return '';
  final sep = String.fromCharCode(base + 97);
  final buffer = StringBuffer();
  for (final part in enc.split(sep)) {
    if (part.isEmpty) continue;
    final value = int.tryParse(part, radix: base);
    if (value == null) return '';
    final ch = value ^ xorKey;
    if (ch < 0 || ch > 0x10FFFF) return '';
    buffer.writeCharCode(ch);
  }
  List<int> data;
  try {
    data = base64.decode(buffer.toString());
  } catch (_) {
    return '';
  }
  if (data.isEmpty || data.length % 16 != 0) return '';
  try {
    final plain = aesCbcDecrypt(
      data,
      utf8.encode(aesKey).sublist(0, 16),
      utf8.encode(aesIv).sublist(0, 16),
    );
    return utf8.decode(plain, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

/// 详情页 pid 提取（chaoliu.py _extract_pids 逐字对齐）：
/// hadeedg252 作 XOR 钥、hcdeedg252 作基数、页面内
/// argdeqweqweqwe / hdddedg252 作 AES 密钥/IV，解
/// mvarr['10_1'] 数组里每条记录的第 2 段。
List<String> extractMjvPids(String text) {
  final hadeedg = _firstGroup(text, RegExp(r'hadeedg252=(\d+)'));
  final hcdeedg = _firstGroup(text, RegExp(r'hcdeedg252=(\d+)'));
  final aesKey = _firstGroup(
    text,
    RegExp(r"var argdeqweqweqwe = '([^']+)'"),
  );
  final aesIv = _firstGroup(text, RegExp(r"var hdddedg252 = '([^']+)'"));
  final mvarr = _firstGroup(
    text,
    RegExp(r"mvarr\['10_1'\]=(\[.*?\]);", dotAll: true),
  );
  if (hadeedg.isEmpty || hcdeedg.isEmpty || aesKey.isEmpty || aesIv.isEmpty) {
    return const [];
  }
  if (mvarr.isEmpty) return const [];
  final xorKey = int.tryParse(hadeedg);
  final base = int.tryParse(hcdeedg);
  if (xorKey == null || base == null) return const [];
  final pids = <String>[];
  final rowPattern = RegExp(
    r"\['([^']*)','([^']*)','([^']*)','([^']*)','([^']*)','([^']*)'\]",
  );
  for (final m in rowPattern.allMatches(mvarr)) {
    final enc = m.group(2) ?? '';
    final prefix = m.group(4) ?? '';
    if (enc.isEmpty || prefix.isEmpty) continue;
    final pid = mjvDecryptId(enc, xorKey, base, aesKey, aesIv);
    if (pid.isNotEmpty) pids.add(pid);
  }
  return pids;
}

/// play.php 取档（chaoliu.py _playphp 后半逐字对齐）：
/// videoSources 里按 size 找目标档，找不到回第一档；
/// 协议相对地址（//host/...）补 https: 前缀（18AV 实测
/// 形态，MJV 本体回的是全址、补前缀不影响）。
String parsePlayPhpStream(String text, {int preferSize = 720}) {
  if (text.isEmpty) return '';
  final arr = _firstGroup(
    text,
    RegExp(r'videoSources\s*=\s*(\[.*?\]);', dotAll: true),
  );
  String picked = '';
  if (arr.isNotEmpty) {
    final sources = <(String, int)>[];
    final pattern = RegExp(r"src:\s*'([^']+)'[^}]*?size:\s*(\d+)", dotAll: true);
    for (final m in pattern.allMatches(arr)) {
      sources.add((m.group(1)!, int.tryParse(m.group(2)!) ?? 0));
    }
    for (final (src, size) in sources) {
      if (size == preferSize) {
        picked = src;
        break;
      }
    }
    if (picked.isEmpty && sources.isNotEmpty) picked = sources.first.$1;
  }
  if (picked.isEmpty) {
    picked = _firstGroup(text, RegExp("https?://[^\\s\"<>']+?\\.m3u8"));
  }
  if (picked.startsWith('//')) return 'https:$picked';
  return picked;
}

/// 详情页 og 信息（标题/封面）：18AV 详情回填用，页里有才带。
({String title, String cover}) parseMjvDetailInfo(String text) {
  var title = _stripTags(
    _firstGroup(text, RegExp(r'<h1[^>]*>(.*?)</h1>', dotAll: true)),
  ).trim();
  if (title.isEmpty) {
    title = _firstGroup(text, RegExp(r'<title>([^<]+)</title>')).trim();
  }
  var cover = _firstGroup(text, RegExp(r'"thumbnailUrl"\s*:\s*"([^"]+)"'));
  if (cover.isEmpty) {
    cover = _firstGroup(
      text,
      RegExp(r'<meta[^>]*property="og:image"[^>]*content="([^"]+)"'),
    );
  }
  return (title: title, cover: cover);
}
