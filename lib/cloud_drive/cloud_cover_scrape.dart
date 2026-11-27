/// 网盘卡片番号封面刮削：115 等网盘的目录接口不回封面，文件名/
/// 文件夹名里带番号的条目此前在网盘屏恒显占位图。本服务按番号
/// 补真封面，只供网盘屏卡片显示——不写回网盘、不改文件名、不
/// 碰上传/离线/播放链。
///
/// 刮削链（优先级按现成资产定）：
/// 1. 本地女优库：.sql 导入的工作库按番号批量查（复用演员库现行
///    读法 [FilmLibraryService.entriesForCodes]，返回行自带封面）；
/// 2. JavDB 接口：本地库没有才走（复用 [JavdbApiClient.searchMovies]，
///    番号精确相等才认，封面是 JavDB 图床地址、显示走 JavdbImage
///    的 XOR 解密路径）；
/// 3. 都查不到回空，卡片保持占位——绝不拿别的图冒充。
///
/// 番号提取复用演员库 115 批已移植的星辰115 CodeExtractor 等价
/// 实现（[pan115ExtractCode]），只在其屏蔽表误杀真番号的窄形状
/// 上补一口救援（[panCoverExtractCode]），不另写第二套规则、
/// 不动提取器本体（离线匹配链共用它，风险口径不同）。
library;

import '../actress/actress_database.dart';
import '../actress/actress_film_library.dart';
import '../actress/actress_json_fallback.dart';
import '../actress/actress_javdb_api.dart';
import 'cloud_115_offline.dart';

/// 刮削专用番号提取：先走 [pan115ExtractCode]（星辰115
/// CodeExtractor 等价实现），提不到再走下面的窄口径救援。
String? panCoverExtractCode(String name) {
  final code = pan115ExtractCode(name);
  if (code != null) return code;
  return _blockedPrefixRescue(name);
}

/// 窄口径救援：CodeExtractor 的屏蔽表把真番号前缀也挡掉的形状
/// （典型：Alice Japan 的 DV 系列——DV 在屏蔽表里是杜比视界的
/// 规格词，DV-390 这类真番号被误杀，星辰原版对这类文件走截帧
/// 兜底、没有番号可用；刮削这里有本地库/JavDB 精确相等兜底，
/// 误报自限，才敢补这一口）。只认两种有佐证的形状：
/// 1. 名字以「字母-数字」番号开头，且无横杠写法在名字后段再
///    现一次（DV-390(53dv390) 的括号段就是这种双写）；
/// 2. 名字除番号外只剩分隔符与常见后缀词（DV-390-C、DV-390
///    1080p 这类）。
/// 年份形数字（19xx/20xx 四位）不认。提不到回 null。
String? _blockedPrefixRescue(String fileName) {
  var name = fileName.trim();
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.toUpperCase();
  final match = RegExp(r'^([A-Z]{2,6})-(\d{2,5})(?!\d)').firstMatch(name);
  if (match == null) return null;
  final prefix = match.group(1)!;
  final digits = match.group(2)!;
  if (digits.length == 4 &&
      (digits.startsWith('19') || digits.startsWith('20'))) {
    return null;
  }
  final candidate = '$prefix-$digits';
  final rest = name.substring(match.end);
  if (rest.contains('$prefix$digits')) return candidate;
  const suffixTokens = {
    'C',
    'UC',
    'U',
    'CH',
    'SUB',
    'HD',
    'FHD',
    'UHD',
    '1080P',
    '720P',
    '2160P',
    '480P',
    '4K',
    '8K',
  };
  final tokens = rest
      .split(RegExp(r'[-_.\s()\[\]]+'))
      .where((token) => token.isNotEmpty);
  if (tokens.every(suffixTokens.contains)) return candidate;
  return null;
}

/// 本地库命中行 → 封面：第一条与所查番号同 slug（vodId 或库里
/// 番号任一对上）且带封面的地址；对不上/没封面回空串，不串片。
String panLocalCoverOf(List<ActressJsonEntry> entries, String code) {
  final slug = filmSlugCode(code);
  if (slug.isEmpty) return '';
  for (final entry in entries) {
    if (entry.vodPic.isEmpty) continue;
    if (filmSlugCode(entry.vodId) == slug ||
        filmSlugCode(entry.vodCode) == slug) {
      return entry.vodPic;
    }
  }
  return '';
}

/// 本地库取封面（测试注入点）：给番号回封面地址，查不到回空串。
typedef PanLocalCoverLookup = Future<String> Function(String code);

/// JavDB 取封面（测试注入点）：给番号回封面地址，查不到回空串。
typedef PanJavdbCoverLookup = Future<String> Function(String code);

/// 网盘番号封面刮削服务（无状态，可复用单例 [instance]）。
class PanCoverScrapeService {
  PanCoverScrapeService({
    PanLocalCoverLookup? localLookup,
    PanJavdbCoverLookup? javdbLookup,
  }) : _localLookup = localLookup,
       _javdbLookup = javdbLookup;

  /// 全局单例：本地库连接懒开、进程内复用（只读连接，与演员库
  /// 各页自建 FilmLibraryService 的现行做法一致）。
  static final PanCoverScrapeService instance = PanCoverScrapeService();

  final PanLocalCoverLookup? _localLookup;
  final PanJavdbCoverLookup? _javdbLookup;

  FilmLibraryService? _filmLibrary;
  JavdbApiClient? _javdbClient;

  FilmLibraryService get _film => _filmLibrary ??= FilmLibraryService(
    database: SqfliteActressDatabase.instance,
  );

  JavdbApiClient get _javdb => _javdbClient ??= JavdbApiClient();

  /// 文件名/文件夹名 → 封面地址：提不出番号直接回空（不发任何
  /// 查询）；提得出按 本地库 → JavDB 顺序找，任何一段失败都静默
  /// 落到下一段，最终查不到回空串。
  Future<String> coverForName(String name) async {
    final code = panCoverExtractCode(name);
    if (code == null || code.isEmpty) return '';
    return coverForCode(code);
  }

  /// 番号 → 封面地址（本地库优先、JavDB 兜底、都没有回空串）。
  Future<String> coverForCode(String code) async {
    final local = await _localCover(code);
    if (local.isNotEmpty) return local;
    return _javdbCover(code);
  }

  Future<String> _localCover(String code) async {
    final injected = _localLookup;
    if (injected != null) {
      try {
        return (await injected(code)).trim();
      } catch (_) {
        return '';
      }
    }
    try {
      // entriesForCodes 已按 slug 过滤，panLocalCoverOf 再核一道
      // 才认，不串片。
      final entries = await _film.entriesForCodes([code]);
      return panLocalCoverOf(entries, code);
    } catch (_) {
      // 库没导入/打不开：静默落到 JavDB 段。
      return '';
    }
  }

  Future<String> _javdbCover(String code) async {
    final injected = _javdbLookup;
    if (injected != null) {
      try {
        return (await injected(code)).trim();
      } catch (_) {
        return '';
      }
    }
    try {
      final movies = await _javdb.searchMovies(code);
      final wanted = code.trim().toUpperCase();
      for (final movie in movies) {
        // 番号精确相等才认（与 JavDB 补剧照同一口径）：搜出来
        // 的相近番号不拿来冒充本片封面。
        if (movie.number.trim().toUpperCase() == wanted &&
            movie.poster.isNotEmpty) {
          return movie.poster;
        }
      }
    } catch (_) {
      // 本机出口/接口失败：回空保持占位，不抛错到列表。
    }
    return '';
  }
}
