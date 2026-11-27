/// 网盘文件名解析：从发布式文件名里拆出剧名、季、集、年份与刮削用标题。
///
/// 只做“解析”，不做“猜测”：拆不出来的字段留空，调用方按空值回落
/// （不分组、不刮削、显示原文件名），绝不编一个假剧名出来。
/// 季/集的基础写法复用 TMDB 那套现成解析（[seasonFromTitle]、
/// [seasonEpisodeFromTitle]、[baseTitleForSearch]），这里只补文件名
/// 特有的部分：扩展名、发布标签、裸集号。
library;

import 'cloud_title_parse.dart';

/// 文件名解析结果。
class ParsedCloudFileName {
  const ParsedCloudFileName({
    required this.seriesTitle,
    required this.normalizedKey,
    required this.searchTitle,
    this.season,
    this.episode,
    this.year,
  });

  /// 剧名（已去掉季/集标记与发布标签）；拆不出剧名时为空
  /// （如裸“第1集.mp4”），调用方不得拿它当剧名分组。
  final String seriesTitle;

  /// 归一键（小写、去全部空白与标点，只留字母数字）：同一剧的
  /// 不同写法（空格/点/下划线分隔）归到同一个键；剧名为空时为空。
  final String normalizedKey;

  /// 刮削搜索标题：有剧名时等于剧名，剧名为空时回落为去扩展名的
  /// 原文件名（刮削方拿它去搜，搜不到就回落，不阻塞）。
  final String searchTitle;

  /// 季号（无季标记时为 null）。
  final int? season;

  /// 集号（无集标记时为 null）。
  final int? episode;

  /// 年份（文件名里无年份时为 null）。
  final String? year;

  /// 是否可用于剧集分组：必须有剧名归一键且有集号。
  bool get groupable => normalizedKey.isNotEmpty && episode != null;
}

/// 发布标签词（不分大小写，独立词组才去掉，剧名里的同字词不动，
/// 如“高清”连在剧名里不是独立词时不删；词表只收发行/编码类词）。
final _releaseTokens = <RegExp>[
  // 清晰度/编码/来源。
  RegExp(r'\b(2160p|1080p|720p|480p|4k|8k|uhd|fhd|hd)\b', caseSensitive: false),
  RegExp(
    r'\b(x264|x265|h\.?264|h\.?265|hevc|avc|av1|10bit|8bit|hdr10|hdr|dolby|dts|truehd|ddp\d?\.?\d?|aac|ac3|flac)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(web-?dl|webrip|bluray|blu-?ray|bdrip|brrip|hdtv|dvdrip|remux|proper|repack)\b',
    caseSensitive: false,
  ),
  // 语言/字幕（中文词，\b 无效，改用分隔符定界）。
  RegExp(
    r'(?:^|[\s._\-－—\[\]()（）【】])(国语|粤语|中字|简繁|双语|内嵌字幕|外挂字幕|中英字幕)(?=$|[\s._\-－—\[\]()（）【】])',
  ),
  // 版本/状态词（中文词，分隔符定界；“全N集”带数字，误伤可能极低，不定界）。
  RegExp(
    r'(?:^|[\s._\-－—\[\]()（）【】])(完整版|未删减版|导演剪辑版|加长版|抢先版|全集|完结|更新至)(?=$|[\s._\-－—\[\]()（）【】])',
  ),
  RegExp(r'全\s*\d+\s*集'),
];

/// 解析一个网盘文件名。
ParsedCloudFileName parseCloudFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final base = (dot > 0 ? fileName.substring(0, dot) : fileName).trim();

  final seasonEpisode = seasonEpisodeFromTitle(base);
  int? season = seasonEpisode?.season;
  int? episode = seasonEpisode?.episode;
  season ??= seasonFromTitle(base);
  episode ??= _episodeOnly(base);
  final year = yearFromText(base);

  var cleaned = base;
  // 先去掉括号/方括号里的整段发布信息（含年份括号）。
  cleaned = cleaned.replaceAll(RegExp(r'\[[^\[\]]*\]'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'【[^【】]*】'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'\([^()]*\)'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'（[^（）]*）'), ' ');
  // 独立成词的年份（如“流浪地球 2019”）也去掉，归到 year 字段；
  // 贴在剧名里的年份（如“2001太空漫游”）不动。
  cleaned = cleaned.replaceAll(
    RegExp(r'(^|[\s._\-－—])((?:19|20)\d{2})(?=$|[\s._\-－—])'),
    ' ',
  );
  // 再去掉散在外面的发布标签词。
  for (final token in _releaseTokens) {
    cleaned = cleaned.replaceAll(token, ' ');
  }
  // 季/集标记与分隔符归一（复用 TMDB 的标题清理）。
  cleaned = baseTitleForSearch(cleaned);
  cleaned = cleaned.replaceAll(RegExp(r'[._\-－—]+'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 清理后残留的空括号/首尾标点。
  cleaned = cleaned.replaceAll(RegExp(r'^[\s·:：,，。.!！？\-—_（）()\[\]]+'), '');
  cleaned = cleaned.replaceAll(RegExp(r'[\s·:：,，。.!！？\-—_（）()\[\]]+$'), '');
  cleaned = cleaned.trim();

  final normalizedKey = cleaned.isEmpty
      ? ''
      : cleaned.toLowerCase().replaceAll(
          RegExp(r'[^\p{L}\p{N}]', unicode: true),
          '',
        );
  return ParsedCloudFileName(
    seriesTitle: cleaned,
    normalizedKey: normalizedKey,
    searchTitle: cleaned.isEmpty ? base : cleaned,
    season: season,
    episode: episode,
    year: year,
  );
}

/// 只有集号、没有季号时的集号提取（SxxEyy 与“第X季第Y集”已由
/// [seasonEpisodeFromTitle] 覆盖，这里只补三种裸写法）：
/// - 中文“第 Y 集/话”（含中文数字）；
/// - 裸 E/EP + 数字（前面不能紧贴字母数字，避免把“E5”当集号）；
/// - 末尾分隔符 + 1~3 位数字（如“剧名 12”“剧名-03”；4 位数
/// 可能是年份，不认）。
int? _episodeOnly(String base) {
  final chinese = RegExp(r'第\s*([零〇一二两三四五六七八九十百\d]+)\s*[集话]').firstMatch(base);
  if (chinese != null) return parseChineseNumber(chinese.group(1)!);
  final bare = RegExp(r'\b[eE][pP]?\s*0*(\d{1,4})\b').firstMatch(base);
  if (bare != null) {
    final before = bare.start == 0 ? '' : base[bare.start - 1];
    if (before.isEmpty || !_isAsciiAlphanumeric(before)) {
      return int.tryParse(bare.group(1)!);
    }
  }
  final trailing = RegExp(r'[\s._\-－—]+0*(\d{1,3})\s*$').firstMatch(base);
  if (trailing != null) return int.tryParse(trailing.group(1)!);
  return null;
}

bool _isAsciiAlphanumeric(String char) {
  final code = char.codeUnitAt(0);
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A);
}
