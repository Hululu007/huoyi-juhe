import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'actress_database.dart';
import 'actress_film_library.dart';
import 'actress_json_fallback.dart';
import 'video_db_normalize.dart';

/// whos 本地兜底库的一条作品。
///
/// 只留目录/搜索/播放要用到的字段：在线 whos.tv 前面挂着 Cloudflare，
/// 取页通道一断整站就是空的，这时全靠这份本地行把内容撑起来。
class WhosLocalWork {
  const WhosLocalWork({
    required this.id,
    required this.title,
    this.cover = '',
    this.playUrl = '',
    this.code = '',
    this.brand = '',
    this.area = '',
    this.year = '',
  });

  final String id;
  final String title;
  final String cover;
  final String playUrl;
  final String code;
  final String brand;
  final String area;
  final String year;

  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  String get displayTitle => title.isNotEmpty ? title : code;

  /// 厂牌：番号里第一个 `-` 前面的字母段（fc2ppv-4913308 → fc2ppv，
  /// sdam-186 → sdam）。没有 `-` 时取开头的连续字母段。
  static String brandOfCode(String code) =>
      _brandFromCode(code.trim().toLowerCase());

  static String _brandFromCode(String code) {
    if (code.isEmpty) return '';
    // 番号形如 sdam-186 / fc2ppv-4913308 / ssis-001-uncensored：
    // 取第一个分隔符前的整段（可以是字母数字混合，FC2 这类就是要的）。
    var head = code;
    for (final sep in const ['-', '_', ' ', '.']) {
      final at = head.indexOf(sep);
      if (at > 0) head = head.substring(0, at);
    }
    if (head.isEmpty) return '';
    final first = head.codeUnitAt(0);
    final startsWithLetter = first >= 0x61 && first <= 0x7a;
    if (!startsWithLetter) return '';
    for (final rune in head.runes) {
      final ch = String.fromCharCode(rune);
      final isWord =
          (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7a) ||
          (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39);
      if (!isWord) return '';
    }
    return head.length >= 2 ? head : '';
  }
}

/// 站内分类 id：最新作品、排行榜、厂牌前缀。
const whosLocalNewCategory = 'new';
const whosLocalRankCategory = 'rank';
const whosLocalBrandPrefix = 'brand:';

/// 厂牌分类的展示名（不认识的按大写前缀显示）。
String whosBrandLabel(String brand) {
  const known = <String, String>{
    'fc2ppv': 'FC2',
    'fc2': 'FC2',
    'ssis': 'SSIS',
    'sdam': 'SDAM',
    'ipzz': 'IPZZ',
    'ipz': 'IPZ',
    'ipx': 'IPX',
    'midv': 'MIDV',
    'mide': 'MIDE',
    'miaa': 'MIAA',
    'sone': 'SONE',
    'soe': 'SOE',
    'sir': 'SIRO',
    'cnt': 'CNT',
    'sta': 'STARS',
    'prtd': 'PRTD',
    'hntd': 'HNTD',
    'cjvr': 'CJVR',
    'dsvr': 'DSVR',
    'vvvd': 'VVVD',
    'vr': 'VR',
    'juq': 'JUQ',
    'meyd': 'MEYD',
    'abw': 'ABW',
    'abp': 'ABP',
    'jul': 'JUL',
    'pred': 'PRED',
    'start': 'START',
    'fsts': 'FSTS',
    'gvh': 'GVH',
    'royd': 'ROYD',
    't28': 'T28',
  };
  final key = brand.toLowerCase();
  final label = known[key];
  if (label != null) return label;
  return brand.toUpperCase();
}

/// whos 本地兜底库。
///
/// 数据只来自本地文件（2026-11-22 用户令最终口径：不内置任何
/// JSON 种子，随包的 whos.json 已删）：
/// `documents/actress_json/whos.json` 与现爬落库的 `mjv011.json`
/// 里 `vod_play_from == whos` 的行（用户自己爬到的更新内容）。
///
/// 目录维度全在本地算（最新 / 排行榜 / 厂牌 + 关键词），所以在线取不到
/// 内容时，分类页、搜索、详情、直链播放都不至于空着。
class WhosLocalLibrary {
  WhosLocalLibrary._(this._works, {this.sourceNote = ''});

  /// 测试/注入用：直接拿现成条目建库。
  factory WhosLocalLibrary.fromWorks(
    List<WhosLocalWork> works, {
    String sourceNote = 'test',
  }) => WhosLocalLibrary._(List<WhosLocalWork>.of(works), sourceNote: sourceNote);

  /// 全局单例：桥层在没有网络时拿它出内容。
  static final WhosLocalLibrary shared = WhosLocalLibrary._(
    <WhosLocalWork>[],
    sourceNote: 'shared',
  );

  static const localDirName = 'actress_json';

  final List<WhosLocalWork> _works;
  final String sourceNote;

  /// 数据库模式（2026-11-23）：读本地数据库时不把 34 万行全读进内存，
  /// 按页懒查（见 pageAsync / categoriesAsync / byIdAsync）。
  FilmLibraryService? _dbService;

  /// 数据库模式下的作品总数（打开时一次 COUNT 拿到，见 _loadFromDb）。
  int? _dbTotal;

  /// 数据库模式下的厂牌维度（一次聚合后缓存，见 _dbFacets）。
  List<({String brand, int count})>? _dbFacets;

  Map<String, List<WhosLocalWork>>? _byBrand;
  Map<String, WhosLocalWork>? _byCode;
  Future<bool>? _loading;

  bool get isLoaded => _works.isNotEmpty || _dbService != null;

  int get count => _dbService != null ? (_dbTotal ?? 0) : _works.length;

  /// 是不是在读本地数据库（而不是 JSON 文件）。
  bool get isDbBacked => _dbService != null;

  /// 首次调用时加载；已加载直接返回。失败（资源缺失之类）返回 false，
  /// 但不抛异常——降级失败也要让上层照常走在线报错，不掩盖真问题。
  Future<bool> ensureLoaded() {
    if (isLoaded) return Future.value(true);
    return _loading ??= _load().catchError((Object _) {
      _loading = null;
      return false;
    });
  }

  Future<bool> _load() async {
    // 2026-11-23 v58 验机：优先读本地数据库（MYTV/db/女优库.db）——
    // 原来只读 documents/actress_json/ 里的 whos.json / mjv011.json，
    // v58 删了包内 whos.json、用户 23:39 又定 App 里不内置任何 JSON，
    // 没那两个文件就确定性播不了（直播里报“内置片库没读出来”）。
    // 库里 34 万部、地址封面都有；没库/库打不开才读 JSON。
    // 绝不往包里加回内置种子。
    if (await _loadFromDb()) return true;
    final merged = <String, WhosLocalWork>{};
    void absorb(String? text, {required String origin}) {
      if (text == null || text.trim().isEmpty) return;
      for (final work in parseWorks(text, origin: origin)) {
        final key = work.id.toLowerCase();
        final existing = merged[key];
        if (existing == null) {
          merged[key] = work;
          continue;
        }
        // 同一条既有封面又有播放地址的版本优先。
        if (existing.cover.isEmpty && work.cover.isNotEmpty) {
          merged[key] = work;
        }
      }
    }

    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$localDirName');
      if (await dir.exists()) {
        final files = <String>['whos.json', 'mjv011.json'];
        for (final name in files) {
          final file = File('${dir.path}/$name');
          if (!await file.exists()) continue;
          absorb(
            await file.readAsString(),
            origin: name == 'mjv011.json' ? 'local-mjv' : 'local',
          );
        }
      }
    } catch (_) {}

    _works.addAll(merged.values);
    _byBrand = null;
    _byCode = null;
    return _works.isNotEmpty;
  }

  /// 读本地数据库模式：打开 MYTV/db/女优库.db（只读连接），成功且
  /// 是严格结构、有作品就切到数据库模式（懒查，不把 34 万行全读进
  /// 内存）；失败回 false，调用方再读 JSON。索引是快读的前提：
  /// 主库开库时已补，别的库/还没跑过主库时在这里后台补一次。
  Future<bool> _loadFromDb() async {
    final service = FilmLibraryService(
      database: SqfliteActressDatabase.instance,
    );
    try {
      final opened = await service.open();
      if (opened.error != null || !opened.strict || opened.total <= 0) {
        await service.close();
        return false;
      }
      unawaited(ensureVideoDbIndexes(service.dbPath));
      _dbService = service;
      _dbTotal = opened.total;
      _dbFacets = null;
      return true;
    } catch (_) {
      try {
        await service.close();
      } catch (_) {}
      return false;
    }
  }

  /// 数据库行 → 本地库条目。
  static WhosLocalWork _dbWork(FilmLibraryEntry entry) {
    final code = entry.code;
    final year = entry.date.length >= 4 ? entry.date.substring(0, 4) : '';
    return WhosLocalWork(
      id: entry.vodId,
      title: entry.title,
      cover: entry.coverUrl,
      playUrl: entry.playUrl,
      code: code,
      brand: WhosLocalWork.brandOfCode(code),
      area: '',
      year: year,
    );
  }

  /// 兜底条目 → 本地库条目（byId 按番号回捞时用）。
  static WhosLocalWork _entryWork(ActressJsonEntry entry) {
    final code = entry.vodCode;
    return WhosLocalWork(
      id: entry.vodId,
      title: entry.vodName,
      cover: entry.vodPic,
      playUrl: entry.playUrl,
      code: code,
      brand: WhosLocalWork.brandOfCode(code),
      area: entry.vodArea,
      year: entry.vodYear,
    );
  }

  /// 取一页（异步版）：数据库模式按页查库，JSON 模式走内存同步取。
  /// 同步版 page() 只服务 JSON 模式（测试与旧调用方），数据库模式
  /// 下它回空——调用方一律用这个。
  Future<List<WhosLocalWork>> pageAsync({
    String category = '',
    String query = '',
    String videoCategory = '',
    int page = 1,
    int pageSize = 24,
  }) async {
    final db = _dbService;
    if (db == null) {
      // pageAsync 的 page 参数会遮住同名方法 page()，必须显式用 this.page。
      return this.page(
        category: category,
        query: query,
        page: page,
        pageSize: pageSize,
      );
    }
    if (page < 1 || pageSize <= 0) return const [];
    var brand = '';
    if (category.startsWith(whosLocalBrandPrefix)) {
      brand = category
          .substring(whosLocalBrandPrefix.length)
          .trim()
          .toLowerCase();
    }
    final entries = await db.listLibraryFilms(
      brand: brand,
      query: query,
      videoCategory: videoCategory,
      offset: (page - 1) * pageSize,
      limit: pageSize,
    );
    return [for (final entry in entries) _dbWork(entry)];
  }

  /// 分类里有多少条（异步版，不含分页）。
  Future<int> countForAsync({
    String category = '',
    String query = '',
    String videoCategory = '',
  }) async {
    final db = _dbService;
    if (db == null) return countFor(category: category, query: query);
    var brand = '';
    if (category.startsWith(whosLocalBrandPrefix)) {
      brand = category
          .substring(whosLocalBrandPrefix.length)
          .trim()
          .toLowerCase();
    }
    return db.countLibraryFilms(
      brand: brand,
      query: query,
      videoCategory: videoCategory,
    );
  }

  /// 目录分类（异步版）：最新、排行榜、厂牌前缀。
  Future<List<({String id, String name, int count})>> categoriesAsync({
    int brandLimit = 30,
  }) async {
    final db = _dbService;
    if (db == null) return categories(brandLimit: brandLimit);
    final total = _dbTotal ?? 0;
    final facets = await _dbBrandFacets();
    return [
      (id: whosLocalNewCategory, name: '最新作品', count: total),
      (id: whosLocalRankCategory, name: '排行榜', count: total),
      for (final facet in facets.take(brandLimit))
        (
          id: '$whosLocalBrandPrefix${facet.brand}',
          name: whosBrandLabel(facet.brand),
          count: facet.count,
        ),
    ];
  }

  /// 视频主分类（异步版）：数据库模式走库里 video_category 聚合
  /// （有码/无码/国产/4K…，按数量倒序）；JSON 模式没有主分类维度，
  /// 返回空。供分类页在站点分类取不到时也能摆出全部主分类标签。
  Future<List<({String name, int count})>> mainCategoriesAsync() async {
    final db = _dbService;
    if (db == null) return const [];
    final rows = await db.categories();
    return [
      for (final (name, count) in rows) (name: name, count: count),
    ];
  }

  /// 数据库模式的厂牌维度（一次聚合后缓存；只留 2 部以上的厂牌，
  /// 与 JSON 模式的 brandFacets 口径一致）。
  Future<List<({String brand, int count})>> _dbBrandFacets() async {
    final cached = _dbFacets;
    if (cached != null) return cached;
    final db = _dbService;
    if (db == null) return const [];
    final facets = await db.libraryBrandFacets(limit: 40);
    final kept = [
      for (final facet in facets)
        if (facet.count >= 2) facet,
    ];
    _dbFacets = kept;
    return kept;
  }

  /// 按 id 取一条（异步版）：数据库模式先主键查，查不到再按番号回捞。
  Future<WhosLocalWork?> byIdAsync(String id) async {
    final db = _dbService;
    if (db == null) return byId(id);
    final entry = await db.libraryFilmById(id);
    if (entry != null) return _dbWork(entry);
    final byCode = await db.entriesForCode(id);
    if (byCode.isEmpty) return null;
    return _entryWork(byCode.first);
  }

  /// 解析一份 json 文本（数组，或 `{'list': [...]}` 包装）。
  ///
  /// 兼容 whos.json 的 `vod_*` 键与 m3u 条目的简写键；没有标题的行丢掉。
  static List<WhosLocalWork> parseWorks(String text, {String origin = ''}) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const [];
    }
    List<Object?> rows;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map) {
      final list = decoded['list'] ?? decoded['items'] ?? decoded['data'];
      rows = list is List ? list : const [];
    } else {
      return const [];
    }

    final out = <WhosLocalWork>[];
    var index = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      index++;
      final map = Map<String, dynamic>.from(row);
      final playFrom = (map['vod_play_from'] ?? map['play_from'] ?? '')
          .toString()
          .toLowerCase();
      final playUrl = _extractPlayUrl(
        (map['vod_play_url'] ?? map['play_url'] ?? map['url'] ?? '').toString(),
      );
      // mjv011.json 是混站大表：只收 whos 的行；没写来源又没地址的也丢。
      if (origin == 'local-mjv' && playFrom.isNotEmpty && playFrom != 'whos') {
        continue;
      }
      final code = (map['vod_code'] ?? map['code'] ?? '').toString().trim();
      final title = (map['vod_name'] ?? map['name'] ?? map['title'] ?? '')
          .toString()
          .trim();
      if (title.isEmpty && code.isEmpty) continue;
      final cover = (map['vod_pic'] ?? map['pic'] ?? map['cover'] ?? '')
          .toString()
          .trim();
      if (playUrl.isEmpty && cover.isEmpty) continue;
      final id =
          (map['vod_id'] ??
                  map['id'] ??
                  map['hash'] ??
                  (code.isNotEmpty ? code : 'local-$index'))
              .toString();
      out.add(
        WhosLocalWork(
          id: id,
          title: title,
          cover: cover,
          playUrl: playUrl,
          code: code.isNotEmpty ? code : _codeFromTitle(title),
          brand: WhosLocalWork.brandOfCode(
            code.isNotEmpty ? code : _codeFromTitle(title),
          ),
          area: (map['vod_area'] ?? map['area'] ?? '').toString(),
          year: (map['vod_year'] ?? map['year'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  /// `正片$https://…m3u8` / `第1集$url#第2集$url` 里取第一条 http 地址。
  static String _extractPlayUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    for (final entry in text.split('#')) {
      var part = entry;
      final dollar = part.lastIndexOf(r'$');
      if (dollar >= 0) part = part.substring(dollar + 1);
      part = part.trim();
      if (part.startsWith('http://') || part.startsWith('https://')) {
        return part;
      }
    }
    return '';
  }

  /// 标题里带番号（全大写 2-6 字母 + 数字）时当番号用。
  static String _codeFromTitle(String title) {
    final match = RegExp(r'([A-Za-z]{2,6})[-_ ]?(\d{2,6})').firstMatch(title);
    if (match == null) return '';
    return '${match.group(1)}-${match.group(2)}'.toLowerCase();
  }

  List<WhosLocalWork> get _all => _works
      .where((work) => work.playable || work.cover.isNotEmpty)
      .toList(growable: false);

  Map<String, List<WhosLocalWork>> get _brands {
    final cached = _byBrand;
    if (cached != null) return cached;
    final map = <String, List<WhosLocalWork>>{};
    for (final work in _all) {
      if (work.brand.isEmpty) continue;
      map.putIfAbsent(work.brand, () => <WhosLocalWork>[]).add(work);
    }
    _byBrand = map;
    return map;
  }

  Map<String, WhosLocalWork> get _codes {
    final cached = _byCode;
    if (cached != null) return cached;
    final map = <String, WhosLocalWork>{};
    for (final work in _all) {
      final code = work.code.toLowerCase();
      if (code.isEmpty) continue;
      map.putIfAbsent(code, () => work);
    }
    _byCode = map;
    return map;
  }

  /// 厂牌分类：按条目数从多到少。
  List<({String brand, int count})> brandFacets({int limit = 40}) {
    final entries = _brands.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return [
      for (final entry in entries.take(limit))
        if (entry.value.length >= 2)
          (brand: entry.key, count: entry.value.length),
    ];
  }

  /// 分类里有多少条（不含分页）。category 支持
  /// `new` / `rank` / `brand:<前缀>` / 空（= 全部）。
  int countFor({String category = '', String query = ''}) =>
      _match(category: category, query: query).length;

  /// 取一页。page 从 1 开始。
  List<WhosLocalWork> page({
    String category = '',
    String query = '',
    int page = 1,
    int pageSize = 24,
  }) {
    if (page < 1 || pageSize <= 0) return const [];
    final rows = _match(category: category, query: query);
    final start = (page - 1) * pageSize;
    if (start >= rows.length) return const [];
    final end = start + pageSize > rows.length ? rows.length : start + pageSize;
    return rows.sublist(start, end);
  }

  List<WhosLocalWork> _match({String category = '', String query = ''}) {
    var rows = _all;
    if (category.startsWith(whosLocalBrandPrefix)) {
      final brand = category
          .substring(whosLocalBrandPrefix.length)
          .trim()
          .toLowerCase();
      rows = _brands[brand] ?? const <WhosLocalWork>[];
    }
    final keyword = query.trim().toLowerCase();
    if (keyword.isEmpty) return rows;
    final tokens = keyword
        .split(RegExp(r'[\s,，]+'))
        .where((token) => token.isNotEmpty)
        .toList();
    return rows.where((work) {
      final haystack =
          '${work.title} ${work.code} ${work.brand} ${work.area} ${work.year}'
              .toLowerCase();
      return tokens.every(haystack.contains);
    }).toList(growable: false);
  }

  WhosLocalWork? byId(String id) {
    final key = id.trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final work in _all) {
      if (work.id.toLowerCase() == key) return work;
    }
    return _codes[key];
  }

  /// 目录分类（本地维度）：最新、排行榜、厂牌前缀。
  ///
  /// 排行榜没有离线数据，按「有封面优先 + 条目顺序」顶上——离线时至少
  /// 有内容可看，不显示成空列表。
  List<({String id, String name, int count})> categories({int brandLimit = 30}) {
    final newCount = _all.length;
    final out = <({String id, String name, int count})>[
      (id: whosLocalNewCategory, name: '最新作品', count: newCount),
      (id: whosLocalRankCategory, name: '排行榜', count: newCount),
    ];
    for (final facet in brandFacets(limit: brandLimit)) {
      out.add((
        id: '$whosLocalBrandPrefix${facet.brand}',
        name: whosBrandLabel(facet.brand),
        count: facet.count,
      ));
    }
    return out;
  }
}
