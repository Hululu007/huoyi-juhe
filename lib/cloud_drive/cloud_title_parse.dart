// 适配层：魔蚁 lib/tmdb/tmdb_metadata.dart 里被 cloud_filename.dart
// 用到的标题解析函数原样移植（parseChineseNumber / seasonFromTitle /
// seasonEpisodeFromTitle / baseTitleForSearch / yearFromText 及
// _chineseNumerals 表），行为不变；修仙版没有 tmdb 模块，故收进
// cloud_drive 内部，不对外扩散。
library;

const _chineseNumerals = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
  '十': 10,
  '百': 100,
};

int? parseChineseNumber(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final digits = int.tryParse(trimmed);
  if (digits != null) return digits;
  var total = 0;
  var current = 0;
  var seen = false;
  for (var i = 0; i < trimmed.length; i++) {
    final value = _chineseNumerals[trimmed[i]];
    if (value == null) return null;
    seen = true;
    if (value == 10 || value == 100) {
      total += (current == 0 ? 1 : current) * value;
      current = 0;
    } else {
      current = current * 10 + value;
    }
  }
  if (!seen) return null;
  return total + current;
}

int? seasonFromTitle(String title) {
  final seasonMatch = RegExp(
    r'第\s*([零〇一二两三四五六七八九十百\d]+)\s*季',
  ).firstMatch(title);
  if (seasonMatch != null) {
    return parseChineseNumber(seasonMatch.group(1)!);
  }
  final sMatch = RegExp(
    r'\bS(\d{1,3})\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (sMatch != null) return int.tryParse(sMatch.group(1)!);
  return null;
}

({int season, int episode})? seasonEpisodeFromTitle(String title) {
  final match = RegExp(
    r'\bS(\d{1,3})\s*E(\d{1,4})\b',
    caseSensitive: false,
  ).firstMatch(title);
  if (match != null) {
    final season = int.tryParse(match.group(1)!);
    final episode = int.tryParse(match.group(2)!);
    if (season != null && episode != null) {
      return (season: season, episode: episode);
    }
  }
  final season = seasonFromTitle(title);
  final episodeMatch = RegExp(
    r'第\s*([零〇一二两三四五六七八九十百\d]+)\s*[集话]',
  ).firstMatch(title);
  if (season != null && episodeMatch != null) {
    final episode = parseChineseNumber(episodeMatch.group(1)!);
    if (episode != null) return (season: season, episode: episode);
  }
  return null;
}

String baseTitleForSearch(String title) {
  var cleaned = title;
  cleaned = cleaned.replaceAll(RegExp(r'第\s*[零〇一二两三四五六七八九十百\d]+\s*季'), ' ');
  cleaned = cleaned.replaceAll(
    RegExp(r'\bS\d{1,3}\s*E\d{1,4}\b', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(
    RegExp(r'\bS\d{1,3}\b', caseSensitive: false),
    ' ',
  );
  cleaned = cleaned.replaceAll(RegExp(r'第\s*[零〇一二两三四五六七八九十百\d]+\s*[集话]'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  return cleaned;
}

String? yearFromText(String? text) {
  if (text == null || text.isEmpty) return null;
  final match = RegExp(r'(19|20)\d{2}').firstMatch(text);
  return match?.group(0);
}
