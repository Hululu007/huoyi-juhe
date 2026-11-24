// DRAFT — target: lib/actress/jav_code_meta.dart (copy into the
// smart-match worktree after the user gives the go-ahead; see REPORT.md).
//
// 三站番号元数据（首批 420 码：JavLibrary / JavDB / FANZA 合并，见
// ~/workspace/jav_code_meta_crawl_20261123/MERGE_REPORT.md）。
//
// 资源：`assets/jav_code_meta.txt.gz` —— 紧凑行格式，每行 10 个
// `||` 分隔字段：番号||标题||标题别名（／分隔）||年份||导演||厂商||
// 女优（; 分隔）||男优（; 分隔）||女优头像（; 分隔，与女优一一对应）||
// 男优头像（; 分隔，与男优一一对应）。头像来自女优库 actresses.avatar
//（who's 头像地址），由 build_resource.py 按番号+名字对上来；没有头像
// 的那位留空，详情页回落到名字首字圆圈。gzip 压后约 59KB（420 行）。
// 生成脚本见 ~/workspace/actress_smart_match_20261123/build_resource.py
// （分隔符安全性已验：`||` / `;` / `／` 在首批数据里不与任何值冲突；
// 超出 10 个字段的部分忽略、缺失的尾字段当空，换新数据文件不用改代码）。
// 只读：加载后只查，不写盘、不改库、不联网。播放地址不进资源。
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

import 'actress_crosssite_probe.dart';
import 'actress_models.dart';
import 'whos_json_index.dart';

/// 一条番号的三站元数据（已去重、已归一；缺失字段为空，不编值）。
class CodeMeta {
  const CodeMeta({
    required this.code,
    required this.title,
    required this.titleAlts,
    required this.year,
    required this.director,
    required this.maker,
    required this.female,
    required this.male,
    this.femaleAvatars = const [],
    this.maleAvatars = const [],
    this.fromWhos = false,
  });

  /// 番号标准写法：全大写 + 横杠，后缀保留（如 EBWH-035-UNCENSORED-LEAK
  /// 与 EBWH-035 不是同一部片，绝不互相回落）。
  final String code;

  /// 展示用标题（可能为空：63 条男优番号无库行也无站标题）。
  final String title;

  /// 标题别名（含库标题写法，用于标题兜底）。
  final List<String> titleAlts;

  /// 发行年份（可能为空）。
  final int? year;

  /// 导演（可能为空：首批 343/420 缺导演）。
  final String director;

  /// 厂商（可能为空：首批 291/420 缺厂商）。
  final String maker;

  /// 女优（页顺序；`素人`已在解析时剔除——那是通用标注，不是真人）。
  final List<String> female;

  /// 男优（排女优之后，只从男优作品列表来）。
  final List<String> male;

  /// 女优头像地址，与 [female] 按下标一一对应；没有头像时该位为空。
  /// 来源是女优库 actresses.avatar（who's 头像），由 build_resource.py
  /// 按番号+名字从数据库映射里对上来。
  final List<String> femaleAvatars;

  /// 男优头像地址，与 [male] 按下标一一对应；没有头像时该位为空。
  final List<String> maleAvatars;

  /// 演员是否来自 who's.json 内置索引（true 时导演仍只来自 420 码，
  /// 演员是 json 索引与 420 码合并后的结果；仅内部用，不显示番号）。
  final bool fromWhos;

  /// 全部演员：女优在前、男优在后。
  List<String> get cast => [...female, ...male];

  /// 全部演员配头像：女优在前、男优在后；没有头像时 avatarUrl 为空，
  /// 详情页回落到名字首字圆圈。
  List<({String name, String avatarUrl})> get castWithAvatars => [
    for (var i = 0; i < female.length; i++)
      (
        name: female[i],
        avatarUrl: i < femaleAvatars.length ? femaleAvatars[i] : '',
      ),
    for (var i = 0; i < male.length; i++)
      (
        name: male[i],
        avatarUrl: i < maleAvatars.length ? maleAvatars[i] : '',
      ),
  ];

  /// 除番号外还有可显示的东西（导演/厂商/年份/演员任一有值）。
  bool get hasUseful =>
      director.isNotEmpty ||
      maker.isNotEmpty ||
      year != null ||
      cast.isNotEmpty;
}

/// 三站番号元数据加载器（懒加载单例，首批 420 码）。
///
/// 查法（按顺序，只读）：
/// 1. 番号查：精确（全大写带横杠）→ 归一化键（normalizeAvCode：去
///    分隔符、去前导零，与 App 内 codeKey 同一套口径；覆盖 codeKey
///    形态 `RKI6042`、库里下划线写法 `caribbeancompr-120916_003`、
///    前导零写法 `ABW-020`）。首批 420 码归一化后无冲突（已验）。
/// 2. 标题兜底：归一化标题（去首尾空白、空白折叠、小写）在标题 +
///    别名索引里查。首批自测：库标题 357/357 命中。
/// 注意：泄露版与原正片是不同片，绝不从带后缀的番号回落到无后缀的
/// （如 EBWH-035-UNCENSORED-LEAK 查不到时不回落到 EBWH-035）。
class JavCodeMeta {
  JavCodeMeta._(this._byCode, this._byCodeKey, this._byTitle);

  /// 懒加载单例：首次调用时读资源、解压、建索引；之后常驻内存。
  static JavCodeMeta? _instance;
  static Future<JavCodeMeta> get instance async {
    final existing = _instance;
    if (existing != null) return existing;
    final loaded = await _load();
    _instance = loaded;
    return loaded;
  }

  /// 测试/注入用：直接拿现成行建映射（不读资源）。
  factory JavCodeMeta.fromLines(Iterable<String> lines) {
    final byCode = <String, CodeMeta>{};
    final byCodeKey = <String, CodeMeta>{};
    final byTitle = <String, CodeMeta>{};
    for (final line in lines) {
      final meta = _parseLine(line);
      if (meta == null) continue;
      byCode[meta.code] = meta;
      byCodeKey[normalizeAvCode(meta.code)] = meta;
      for (final t in [meta.title, ...meta.titleAlts]) {
        final key = normalizeTitle(t);
        if (key.isNotEmpty) byTitle.putIfAbsent(key, () => meta);
      }
    }
    return JavCodeMeta._(byCode, byCodeKey, byTitle);
  }

  static const assetPath = 'assets/jav_code_meta.txt.gz';

  static Future<JavCodeMeta> _load() async {
    final bytes = await rootBundle.load(assetPath);
    final text = utf8.decode(
      const GZipDecoder().decodeBytes(bytes.buffer.asUint8List()),
    );
    return JavCodeMeta.fromLines(text.split('\n'));
  }

  /// 解析一行紧凑格式；格式不对（空行、缺番号）返回 null。
  /// 第 9、10 字段（下标 8、9）是女优/男优头像地址，与第 7、8 字段
  /// 的名字按下标一一对应；缺失的尾字段当空（老 8 字段文件照常读）。
  static CodeMeta? _parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    final parts = trimmed.split('||');
    if (parts.isEmpty) return null;
    final code = parts[0].trim().toUpperCase();
    if (code.isEmpty) return null;
    String at(int i) => i < parts.length ? parts[i].trim() : '';
    // 名字与头像一起解析：去重、剔素人时头像跟着名字走，保证下标对齐。
    (List<String>, List<String>) namesAndAvatars(int nameIdx, int avatarIdx) {
      final raw = at(nameIdx);
      if (raw.isEmpty) return (const [], const []);
      final rawAvatars = at(avatarIdx);
      final avatarList = rawAvatars.isEmpty
          ? const <String>[]
          : rawAvatars.split(';');
      final names = <String>[];
      final avatars = <String>[];
      final seen = <String>{};
      final nameList = raw.split(';');
      for (var i = 0; i < nameList.length; i++) {
        final name = nameList[i].trim();
        if (name.isEmpty) continue;
        // `素人`是通用标注不是真人（MERGE_REPORT.md），不进演员表。
        if (name == '素人') continue;
        if (!seen.add(name)) continue;
        names.add(name);
        avatars.add(i < avatarList.length ? avatarList[i].trim() : '');
      }
      return (names, avatars);
    }

    final year = int.tryParse(at(3));
    final (female, femaleAvatars) = namesAndAvatars(6, 8);
    final (male, maleAvatars) = namesAndAvatars(7, 9);
    return CodeMeta(
      code: code,
      title: at(1),
      titleAlts: at(2).isEmpty
          ? const []
          : at(2)
                .split('／')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
      year: year,
      director: at(4),
      maker: at(5),
      female: female,
      male: male,
      femaleAvatars: femaleAvatars,
      maleAvatars: maleAvatars,
    );
  }

  final Map<String, CodeMeta> _byCode;
  final Map<String, CodeMeta> _byCodeKey;
  final Map<String, CodeMeta> _byTitle;

  /// 番号查元数据：精确 → 归一化键；查不到返回 null。
  /// 传入的番号可以是库 vod_id 小写、codeKey 形态、下划线写法，
  /// 归一化后统一比对。
  CodeMeta? metaForCode(String code) {
    final key = code.trim().toUpperCase();
    if (key.isEmpty) return null;
    return _byCode[key] ?? _byCodeKey[normalizeAvCode(key)];
  }

  /// 标题兜底查元数据：归一化标题在标题 + 别名索引里查；查不到 null。
  CodeMeta? metaForTitle(String title) {
    final key = normalizeTitle(title);
    if (key.isEmpty) return null;
    return _byTitle[key];
  }

  /// 详情页匹配入口：先番号、再标题兜底；都查不到返回 null。
  /// [id] 是详情页 drama.id（如 `json:chaoliu:rki-6042`、
  /// `code_RKI-6042`），[title] 是详情页标题。
  /// [whosIndex] 传了时，演员先从 who's.json 内置索引查（339,526 码），
  /// 再与 420 码的演员合并去重（json 在前）；导演仍只来自 420 码。
  /// json 索引里没有头像，头像只从 420 码里按名字对（对不上留空回落首字）。
  CodeMeta? match({
    required String id,
    required String title,
    String sourceId = '',
    WhosJsonIndex? whosIndex,
  }) {
    final code = resolveCode(id: id, title: title, sourceId: sourceId);
    if (code.isNotEmpty) {
      final byCode = metaForCode(code);
      final whosCast = whosIndex?.castForCode(code) ?? const <String>[];
      final whosVideo = whosIndex?.videoForCode(code);
      if (byCode != null || whosCast.isNotEmpty) {
        return _mergeWithWhos(
          code: code,
          base: byCode,
          whosCast: whosCast,
          whosTitle: whosVideo?.title ?? '',
        );
      }
    }
    return metaForTitle(title);
  }

  /// 把 420 码元数据与 who's 索引的演员合并成一条 CodeMeta。
  /// 演员：json 在前、420 码在后，去重；导演/厂商/年份/标题只取 420 码，
  /// 420 码没有时标题取 json 视频标题（其余留空）。
  CodeMeta _mergeWithWhos({
    required String code,
    required CodeMeta? base,
    required List<String> whosCast,
    required String whosTitle,
  }) {
    final female = <String>[];
    final femaleAvatars = <String>[];
    final seen = <String>{};
    // json 演员在前（whos 映射只有女优）。
    for (final name in whosCast) {
      if (seen.add(name)) {
        female.add(name);
        femaleAvatars.add(_avatarFor(name, base));
      }
    }
    // 420 码女优在后，去重。
    for (var i = 0; i < (base?.female.length ?? 0); i++) {
      final name = base!.female[i];
      if (seen.add(name)) {
        female.add(name);
        femaleAvatars.add(
          i < base.femaleAvatars.length ? base.femaleAvatars[i] : '',
        );
      }
    }
    return CodeMeta(
      code: code,
      title: (base?.title ?? '').isNotEmpty ? base!.title : whosTitle,
      titleAlts: base?.titleAlts ?? const [],
      year: base?.year,
      director: base?.director ?? '',
      maker: base?.maker ?? '',
      female: female,
      male: base?.male ?? const [],
      femaleAvatars: femaleAvatars,
      maleAvatars: base?.maleAvatars ?? const [],
      fromWhos: whosCast.isNotEmpty,
    );
  }

  /// 在 420 码元数据里按名字找头像；找不到返回空（回落首字圆圈）。
  String _avatarFor(String name, CodeMeta? base) {
    if (base == null) return '';
    final idx = base.female.indexOf(name);
    if (idx < 0) return '';
    return idx < base.femaleAvatars.length ? base.femaleAvatars[idx] : '';
  }

  /// 从详情页信息里抠番号（返回全大写标准写法，抠不到返回 ''）。
  /// 顺序：id 直取（保留后缀）→ id 本身就是番号 → extractAvId。
  /// id 直取只认 `json:` / `code_` / `jpcode:` 前缀（`json:<站>:<番号>`
  /// 取最后一段），余下部分须像番号才认（防 URL、哈希串误认）。
  static String resolveCode({
    required String id,
    required String title,
    String sourceId = '',
  }) {
    final rawId = id.trim();
    for (final prefix in const ['json:', 'code_', 'jpcode:']) {
      if (rawId.startsWith(prefix)) {
        var rest = rawId.substring(prefix.length).trim();
        final colon = rest.lastIndexOf(':');
        if (colon >= 0) rest = rest.substring(colon + 1).trim();
        if (_looksLikeCode(rest)) return rest.toUpperCase();
      }
    }
    if (_looksLikeCode(rawId)) return rawId.toUpperCase();
    final av = extractAvId(title: title, id: id, sourceId: sourceId);
    // extractAvId 会把后缀剥掉（如 EBWH-035-UNCENSORED-LEAK →
    // EBWH-035），这是它既有的行为；这里只把它当兜底，直取优先。
    return av ?? '';
  }

  /// 像番号：以横杠分段，每段非空且只含字母数字；至少含一位数字；
  /// 含字母，或是无码日期码形（YYMMDD-NN，如 042816-01）。覆盖数字
  /// 开头（788-AOI-01）、FC2-PPV-1234567、后缀（EBWH-035-UNCENSORED-LEAK）。
  /// 误认无害：认错的“番号”查不到元数据时只回落到标题兜底。
  static bool _looksLikeCode(String value) {
    if (value.isEmpty || value.length > 40) return false;
    if (value.contains(RegExp(r'[/:?#\s]'))) return false;
    final segments = value.split('-');
    if (segments.length < 2 || segments.length > 5) return false;
    for (final seg in segments) {
      if (seg.isEmpty) return false;
      if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(seg)) return false;
    }
    if (!RegExp(r'[0-9]').hasMatch(value)) return false;
    if (RegExp(r'[A-Za-z]').hasMatch(value)) return true;
    return RegExp(r'^\d{6}-\d{2}$').hasMatch(value);
  }

  /// 标题归一化（与自测脚本同一口径）：去首尾空白、空白折叠、小写。
  /// 首批数据验证：加不加 NFKC 都是 357/357 命中，故不用 NFKC。
  static String normalizeTitle(String title) =>
      title.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

  int get codeCount => _byCode.length;
}
