import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'actress_adapter_models.dart';
import 'actress_database.dart';
import 'actress_m3u_index.dart';
import 'actress_models.dart';

/// 女优库 JSON 兜底：用户自己在 MYTV/db 里放的 json 文件
///（现爬落盘的 mjv011.json、旧版分站文件）与 MYTV/m3u 里的
/// 用户 m3u 文件。
///
/// 2026-11-22 用户令最终口径：App 里不内置任何数据库与 JSON
/// 种子——随包的 mjv011.json / whos.json 不再打包、也不再读，
/// 这里只读用户本地文件；没有本地文件就是空兜底，不悄悄造数据。
///
/// 格式照 UPDATE_RULES.md（~/workspace/mjv_whos_crawl_20261119/）：
/// 13 个 hsck 字段同顺序 + 末尾 vod_code、vod_actress_pic；
/// 顶层 list/parse/jx/last_update；indent=2；简介单段 <p>；
/// 备注一律“高清”；值照实数。两站各管各，不跨站合并。
///
/// 落法（2026-11-20 用户令：所有数据全部进本地的 mjv011.json
/// 这一个文件，json 是唯一落地口径）：
/// - 权威文件就是本地 mjv011.json（同名同格式 15 字段）；
///   爬虫腿（任何站）拿到的视频行只追加进这一个文件，不分站另存；
/// - 读时本地各站文件按更新规则合并（番号+播放链接完全一样
///   才跳过，任一处不同就替换；同番号不同站都留）；
/// - 旧版分站本地文件（mjv.json、whos.json、各站 json）只读不写，
///   过渡期并存、数据不丢；
/// - 单文件里多站的行按 vod_play_from 认站（mjv011 → mjv，
///   其余来源名即站 id）；去重键仍是各站内的（分类，番号），
///   同番号不同站各留各的，不跨站合并。
/// 没有服务端托管，不编下载地址。

/// hsck 13 字段顺序 + 末尾 vod_code、vod_actress_pic。
const actressJsonFieldOrder = <String>[
  'vod_id',
  'vod_name',
  'vod_pic',
  'vod_actor',
  'vod_director',
  'vod_remarks',
  'vod_pubdate',
  'vod_area',
  'vod_year',
  'vod_content',
  'vod_play_from',
  'vod_play_url',
  'type_name',
  'vod_code',
  'vod_actress_pic',
];

const actressJsonTopKeys = <String>{'list', 'parse', 'jx', 'last_update'};

/// 校验一份 JSON 文档是否合 hsck 格式：顶层四键齐、每行 15 字段
/// 同顺序、播放地址为空或 `正片$http(s)://...`。不对就抛 FormatException，
/// 说明里写清哪一行哪一项坏了。
void validateActressJsonDocument(Map<String, dynamic> doc, String label) {
  final problems = <String>[];
  if (!actressJsonTopKeys.every(doc.containsKey)) {
    problems.add('顶层缺键（要 list/parse/jx/last_update）');
  }
  final list = doc['list'];
  if (list is! List) {
    problems.add('顶层 list 不是数组');
  } else {
    for (var i = 0; i < list.length; i++) {
      final row = list[i];
      if (row is! Map) {
        problems.add('第 $i 行不是对象');
        continue;
      }
      final keys = row.keys.map((e) => e.toString()).toList();
      if (!_sameOrder(keys, actressJsonFieldOrder)) {
        problems.add('第 $i 行字段顺序不对（要 13 字段 + vod_code + vod_actress_pic）');
      }
      final playUrl = row['vod_play_url']?.toString() ?? '';
      if (playUrl.isNotEmpty &&
          !(playUrl.startsWith('正片\$http://') ||
              playUrl.startsWith('正片\$https://'))) {
        problems.add('第 $i 行 vod_play_url 不是“正片\$地址”');
      }
    }
  }
  if (problems.isNotEmpty) {
    throw FormatException('$label 格式不对：${problems.take(3).join('；')}');
  }
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 行内播放来源 → 站：mjv011 是 mjv 站在 json 里的播放来源名；
/// 其余来源名即站 id（whos、各片库站蜘蛛 id）。空来源回落为 ''，
/// 由调用方按文件定站。
String siteForPlayFrom(String playFrom) =>
    playFrom == 'mjv011' ? 'mjv' : playFrom;

/// json → 库镜像：同一批条目先落 json 文件、再按本函数同步进库
/// （json 是唯一落地口径，库是 json 的派生索引，不是第二份原始写）。
/// 有女优名的行按名字建/合人物、作品行按（站，番号）去重进 works 表；
/// 没女优名的行只留在 json 里，不进库（没有可挂的人）；mjv 行的
/// 演员记 sex 'female'，其他站 sex 未知记空；分类名是有码/无码时
/// 记为标签（与分册筛选同一口径），其余分类不记标签。
Future<void> mirrorActressJsonEntriesToDb(
  ActressDatabase db,
  Iterable<ActressJsonEntry> entries,
) async {
  if (db.isVideoLibrary) {
    // 视频库模式：条目按合并规则写进 videos / video_category
    //（不写 persons/works，那两张表这个库里没有）。
    // vod_id 用小写番号（entry.vodCode 归一化）；vodCode 为空
    // 时退回 entry.vodId（md5/slug，仍可用作键）；都没有就跳过。
    // 女优名（vodActor）有就按名字精确匹配 actresses 链
    // video_actress，没有就不链（whos 条目本来就没女优名，
    // 只进 videos/video_category）。
    final videoEntries = <VideoLibraryEntry>[];
    for (final entry in entries) {
      final vodId = entry.vodCode.trim().isNotEmpty
          ? videoLibraryVodId(entry.vodCode)
          : entry.vodId.trim();
      if (vodId.isEmpty) continue;
      videoEntries.add((
        vodId: vodId,
        title: entry.vodName,
        picUrl: entry.vodPic,
        playUrl: entry.playUrl,
        remarks: entry.vodRemarks,
        pubdate: entry.vodPubdate,
        area: entry.vodArea,
        year: entry.vodYear,
        content: entry.vodContent,
        playFrom: entry.vodPlayFrom,
        typeName: entry.typeName,
        category: entry.typeName,
        actressName: entry.vodActor.trim(),
      ));
    }
    await db.upsertVideoEntries(videoEntries);
    return;
  }
  for (final entry in entries) {
    final actor = entry.vodActor.trim();
    if (actor.isEmpty) continue;
    final code = entry.vodCode;
    final title = entry.vodName;
    if (code.isEmpty && title.isEmpty) continue;
    for (final name in actressNameVariants(actor)) {
      final person = await db.upsertCrawledPerson(
        name: name,
        sex: entry.site == 'mjv' ? 'female' : '',
        tags: entry.typeName == '有码' || entry.typeName == '无码'
            ? [entry.typeName]
            : const [],
      );
      if (person == null) continue;
      await db.upsertWorks(
        person.localId,
        [
          RosterFilm(
            code: code,
            title: title,
            date: entry.vodPubdate,
            category: entry.typeName,
          ),
        ],
        coverSource: '',
        site: ActressJsonFallback.spiderIdForSite(entry.site),
      );
    }
  }
}

/// 名字归一化（仅兜底匹配用）：去空白、全小写。
String normalizeActressJsonName(String name) =>
    name.replaceAll(RegExp(r'\s+'), '').toLowerCase();

/// JSON 里的一条视频：一个站的一条，不跨站合并。
class ActressJsonEntry {
  ActressJsonEntry({
    required this.site,
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodActor,
    required this.vodDirector,
    required this.vodRemarks,
    required this.vodPubdate,
    required this.vodArea,
    required this.vodYear,
    required this.vodContent,
    required this.vodPlayFrom,
    required this.vodPlayUrl,
    required this.typeName,
    required this.vodCode,
    required this.vodActressPic,
    this.directPlay = false,
  });

  factory ActressJsonEntry.fromRow(Map<String, dynamic> row, String site) {
    String text(String key) => row[key]?.toString() ?? '';
    return ActressJsonEntry(
      site: site,
      vodId: text('vod_id'),
      vodName: text('vod_name'),
      vodPic: text('vod_pic'),
      vodActor: text('vod_actor'),
      vodDirector: text('vod_director'),
      vodRemarks: text('vod_remarks'),
      vodPubdate: text('vod_pubdate'),
      vodArea: text('vod_area'),
      vodYear: text('vod_year'),
      vodContent: text('vod_content'),
      vodPlayFrom: text('vod_play_from'),
      vodPlayUrl: text('vod_play_url'),
      typeName: text('type_name'),
      vodCode: text('vod_code'),
      vodActressPic: text('vod_actress_pic'),
    );
  }

  /// 站：mjv / whos（取自文件名，不跨站）。
  final String site;
  final String vodId;
  final String vodName;
  final String vodPic;
  final String vodActor;
  final String vodDirector;
  final String vodRemarks;
  final String vodPubdate;
  final String vodArea;
  final String vodYear;
  final String vodContent;
  final String vodPlayFrom;
  final String vodPlayUrl;
  final String typeName;
  final String vodCode;
  final String vodActressPic;

  /// 集 id 本身就是可播直链（本地库条目）：播放器直接播这个地址，
  /// 不再绕蜘蛛取一次流（蜘蛛站挂了/没这个番号也不会播不出来）。
  final bool directPlay;

  /// 归一化番号（与库内 works.codeKey 同一口径）。
  String get codeKey => normalizeAvCode(vodCode);

  /// `正片$地址` 里的直链地址；空表示这条还没取到流。
  String get playUrl {
    const marker = '正片\$';
    if (!vodPlayUrl.startsWith(marker)) return '';
    return vodPlayUrl.substring(marker.length);
  }

  /// 能播：有 http(s) 直链。
  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  /// 更新规则的键：（分类，番号）；没番号时退回 vod_id。
  String get mergeKey => '$typeName|${codeKey.isNotEmpty ? codeKey : vodId}';

  /// 按 15 字段顺序写回（indent=2 时与爬取成品同结构）。
  Map<String, dynamic> toRow() => <String, dynamic>{
    'vod_id': vodId,
    'vod_name': vodName,
    'vod_pic': vodPic,
    'vod_actor': vodActor,
    'vod_director': vodDirector,
    'vod_remarks': vodRemarks,
    'vod_pubdate': vodPubdate,
    'vod_area': vodArea,
    'vod_year': vodYear,
    'vod_content': vodContent,
    'vod_play_from': vodPlayFrom,
    'vod_play_url': vodPlayUrl,
    'type_name': typeName,
    'vod_code': vodCode,
    'vod_actress_pic': vodActressPic,
  };

  /// 兜底卡点播用的合成详情：单集“正片”，集 id 就是直链地址；
  /// resolve 时走潮流蜘蛛 playerContent 原始分支，原样回 parse=0
  /// 直链 + 播放头，不再解析一次。
  DramaDetail toDramaDetail() {
    final drama = Drama(
      id: 'json:$site:$vodId',
      source: ActressJsonFallback.spiderIdForSite(site),
      title: vodName,
      description: vodContent,
      cover: vodPic,
      episodes: 1,
      category: typeName,
      onlineDate: vodPubdate,
    );
    return DramaDetail(drama, [
      Episode({
        'id': playUrl,
        'title': '正片',
        if (directPlay) 'direct': true,
      }, 1),
    ]);
  }
}

/// 女优库 JSON 兜底加载器：只读本地 json 文件（MYTV/db），
/// 再叠 whos m3u 分片索引（用户 2026-11-19 发来的 9 个女优合集 m3u）。
/// JSON 行优先：同一播放地址 m3u 行不重复占位；m3u 行只补 JSON 没有的。
/// 影视库 db 兜底提供方（2026-11-20 18:57 用户令“全部使用数据库兜底”）：
/// 兜底先查 MYTV/db/女优库.db，读不到再回退 json/m3u 做种子。
/// 实现由影视库模块提供（FilmLibraryService），本文件只认接口，
/// 不直接依赖影视库文件，避免循环引用。实现方永不抛错：
/// 库打不开、结构不对都回空列表，兜底继续走 json/m3u。
abstract class FilmDbFallbackProvider {
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  });

  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  });
}

// 注意：批量按番号取作品（entriesForCodes）不要加进上面这个接口——
// 三个测试替身（test/actress_*_test.dart）都是 implements 它，
// 接口多一个方法它们就编不过，而测试文件不在本次可改范围。
// 批量方法只挂在两个真实实现上（FilmLibraryService、
// MultiDbFilmFallback），调用方（详情页）按运行时类型分发，
// 其它实现（含测试替身）逐条回落，见 _dbEntriesForCodes。

class ActressJsonFallback {
  ActressJsonFallback({
    Directory? documentsDir,
    WhosM3uIndex? m3uIndex,
    Directory? localJsonDir,
    this.filmDb,
  }) : _documentsDir = documentsDir,
       _m3uIndex = m3uIndex,
       _localJsonDir = localJsonDir;

  /// 2026-11-20 MYTV 绑定：绑定解析出来后调，本地 json 影子
  /// 目录改走 MYTV/db（jsonDir），用户 m3u 目录改走 MYTV/m3u。
  /// 未绑定时传 documents 下的旧目录或 null，等价于原来行为；
  /// 只在列表页自己建的实例上调，测试注入的实例不动。
  void bindLocalDirs({Directory? jsonDir, Directory? userM3uDir}) {
    if (jsonDir != null) _localJsonDir = jsonDir;
    m3uIndex.bindUserM3uDir(userM3uDir);
  }

  /// whos m3u 索引：懒建，第一次查 m3u 时才解 manifest。
  WhosM3uIndex get m3uIndex => _m3uIndex ??= WhosM3uIndex();

  WhosM3uIndex? _m3uIndex;

  /// 兜底线路的解析通道：mjv/whos 走潮流蜘蛛（mjv 全站蜘蛛）；
  /// 片库站走本站蜘蛛自己的站 id。whos 条目暂无自己的蜘蛛，也走
  /// 这条原始分支（地址原样回 parse=0）；手机上 whos 直链若因头
  /// 不对播不了，再立 whos 专用通道。
  static const playSource = 'chaoliu';

  /// 兜底卡点播走哪个蜘蛛取流：mjv/whos 走潮流蜘蛛，其余站走本站。
  static String spiderIdForSite(String site) =>
      (site == 'mjv' || site == 'mjv011' || site == 'whos')
      ? playSource
      : site;

  /// 本地现爬文件目录名（documents 下）。
  static const localDirName = 'actress_json';

  final Directory? _documentsDir;

  /// 2026-11-20 MYTV 绑定：绑定后的本地 json 目录覆盖
  /// （MYTV/db）；不设时走原来的 documents/actress_json。
  Directory? _localJsonDir;

  var _loaded = false;
  var _entries = <ActressJsonEntry>[];
  final _byCode = <String, List<ActressJsonEntry>>{};
  final _byActor = <String, List<ActressJsonEntry>>{};
  final _counts = <String, int>{};
  final _lastUpdate = <String, String>{};

  bool get loaded => _loaded;

  List<ActressJsonEntry> get entries => List.unmodifiable(_entries);

  /// 每站条数（本地现爬过的各站）。
  Map<String, int> get counts => Map.unmodifiable(_counts);

  /// 每站 last_update（本地各站文件里最新的那份）。
  Map<String, String> get lastUpdate => Map.unmodifiable(_lastUpdate);

  /// 读本地各站文件（有才读），按更新规则合并不去重。
  /// 单文件模型（2026-11-20 用户令）：新写只进本地 mjv011.json
  /// 这一个文件；读的时候旧版分站本地文件（mjv.json、whos.json、
  /// 各站 json）先读、单文件 mjv011.json 最后读（它权威，同键
  /// 不同内容时以后读的为准）。随包 json 已不再打包、不再读
  /// （2026-11-22 用户令最终口径）。
  /// 站的认定：mjv011.json 这个单文件里的行按 vod_play_from 认站
  /// （多站同文件），其余文件按文件名认站（mjv011/mjv → mjv）。
  /// 同站内按更新规则合并：同 mergeKey 且同 vodPlayUrl 跳过、
  /// 任一字段不同替换；同番号不同站各留各的。
  Future<void> load() async {
    final merged = <String, Map<String, ActressJsonEntry>>{};
    final lastUpdates = <String, String>{};

    void apply(
      Iterable<ActressJsonEntry> entries,
      String lastUpdate,
    ) {
      for (final entry in entries) {
        final byKey = merged.putIfAbsent(
          entry.site,
          () => <String, ActressJsonEntry>{},
        );
        final key = entry.mergeKey;
        final old = byKey[key];
        // 番号相同且播放链接相同才跳过；任一字段不同就替换。
        if (old != null && old.vodPlayUrl == entry.vodPlayUrl) continue;
        byKey[key] = entry;
      }
      if (lastUpdate.isNotEmpty) {
        for (final entry in entries) {
          final current = lastUpdates[entry.site] ?? '';
          if (lastUpdate.compareTo(current) > 0) {
            lastUpdates[entry.site] = lastUpdate;
          }
        }
      }
    }

    // 本地：旧版分站文件先读、单文件 mjv011.json 最后读（它权威，
    // 同键不同内容时以后读的为准）。随包 json 已不再读
    // （2026-11-22 用户令最终口径：不内置任何 JSON 种子）。
    for (final file in await _localJsonFiles()) {
      final isCanonical = path.basename(file.path) == localFileName;
      final fileSite = _siteIdForLocalFile(file);
      final local = await _readLocalFile(file, fileSite, isCanonical);
      apply(local.entries, local.lastUpdate);
    }
    _entries = [
      for (final byKey in merged.values) ...byKey.values,
    ];
    _byCode.clear();
    _byActor.clear();
    for (final entry in _entries) {
      if (entry.codeKey.isNotEmpty) {
        (_byCode[entry.codeKey] ??= []).add(entry);
      }
      final actorKey = normalizeActressJsonName(entry.vodActor);
      if (actorKey.isNotEmpty) {
        (_byActor[actorKey] ??= []).add(entry);
      }
    }
    _counts.clear();
    for (final site in merged.keys) {
      _counts[site] = merged[site]!.length;
    }
    _lastUpdate.clear();
    _lastUpdate.addAll(lastUpdates);
    _loaded = true;
  }

  /// 合并后的单文件文档（导出用）：本地全部行按更新规则合并后
  /// 的全文，15 字段同顺序、顶层四键，indent=2 序列化后可直接
  /// 拷走当 mjv011.json 用。last_update 取各站最新的那份。
  /// load() 之前调只会拿到空文档。
  Map<String, dynamic> mergedDocument() {
    var lastUpdate = '';
    for (final value in _lastUpdate.values) {
      if (value.compareTo(lastUpdate) > 0) lastUpdate = value;
    }
    return <String, dynamic>{
      'list': [for (final entry in _entries) entry.toRow()],
      'parse': 0,
      'jx': 0,
      'last_update': lastUpdate,
    };
  }

  /// 本地单文件的文件名：mjv011.json，爬虫腿只写它。
  static const localFileName = 'mjv011.json';

  /// 本地 json 文件列表：旧版分站文件在前、单文件 mjv011.json 在
  /// 后（后读的权威）。文件不存在或目录不存在时回空，不抛错。
  Future<List<File>> _localJsonFiles() async {
    try {
      final dir = await _localDir();
      if (!dir.existsSync()) return const [];
      final files = <File>[];
      // 同步列目录：widget 测试里 `await for` 扫 Directory.list()
      // 永远等不到返回（FakeAsync 下挂起），listSync 在真机与
      // 测试里都直接返回。
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        if (!path.basename(entity.path).endsWith('.json')) continue;
        files.add(entity);
      }
      files.sort((a, b) {
        final aCanonical = path.basename(a.path) == localFileName;
        final bCanonical = path.basename(b.path) == localFileName;
        if (aCanonical == bCanonical) {
          return a.path.compareTo(b.path);
        }
        return aCanonical ? 1 : -1;
      });
      return files;
    } catch (_) {
      return const [];
    }
  }

  /// 本地文件名 → 站：mjv011.json（单文件）与旧版 mjv.json 都是
  /// mjv 站，其余按文件名（去后缀）即站 id。
  String _siteIdForLocalFile(File file) {
    final name = path.basename(file.path);
    final site = name.substring(0, name.length - 5);
    if (site == 'mjv011' || site == 'mjv') return 'mjv';
    return site;
  }

  /// 本地单文件里的行按 vod_play_from 认站（多站同文件）；
  /// 其余文件整文件一个站（文件名认站）。
  String _rowSite(
    Map<String, dynamic> row,
    String fileSite,
    bool canonical,
  ) {
    if (!canonical) return fileSite;
    final playFrom = row['vod_play_from']?.toString() ?? '';
    if (playFrom.isEmpty) return fileSite;
    return siteForPlayFrom(playFrom);
  }

  /// 读一个本地 json 文件：单文件 mjv011.json 里的行按
  /// vod_play_from 认站，其余旧版分站文件整文件一个站（文件名认站）。
  Future<({List<ActressJsonEntry> entries, String lastUpdate})>
  _readLocalFile(File file, String fileSite, bool canonical) async {
    try {
      if (!file.existsSync()) {
        return (entries: <ActressJsonEntry>[], lastUpdate: '');
      }
      final doc = jsonDecode(file.readAsStringSync());
      if (doc is! Map<String, dynamic>) {
        return (entries: <ActressJsonEntry>[], lastUpdate: '');
      }
      validateActressJsonDocument(doc, file.path);
      final rows = doc['list'] as List;
      return (
        entries: [
          for (final row in rows)
            if (row is Map<String, dynamic>)
              ActressJsonEntry.fromRow(
                row,
                _rowSite(row, fileSite, canonical),
              ),
        ],
        lastUpdate: doc['last_update']?.toString() ?? '',
      );
    } catch (_) {
      return (entries: <ActressJsonEntry>[], lastUpdate: '');
    }
  }

  Future<Directory> _localDir() async {
    if (_localJsonDir != null) return _localJsonDir!;
    if (_documentsDir != null) {
      return Directory(path.join(_documentsDir.path, localDirName));
    }
    final docs = await getApplicationDocumentsDirectory();
    return Directory(path.join(docs.path, localDirName));
  }

  /// 按番号取兜底条目（两站各留各的，不跨站合并）。
  List<ActressJsonEntry> entriesForCode(String codeKey, {String? site}) {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return const [];
    final rows = _byCode[key] ?? const [];
    if (site == null || site == 'all') return List.unmodifiable(rows);
    return [for (final e in rows) if (e.site == site) e];
  }

  /// 按女优名取兜底条目（名字归一化后相等才认）。
  List<ActressJsonEntry> entriesForActress(String name, {String? site}) {
    final key = normalizeActressJsonName(name);
    if (key.isEmpty) return const [];
    final rows = _byActor[key] ?? const [];
    if (site == null || site == 'all') return List.unmodifiable(rows);
    return [for (final e in rows) if (e.site == site) e];
  }

  /// 某人（名字 + 本地作品番号集合）在某站有没有 JSON 兜底条目。
  bool hasSiteEntriesForPerson({
    required List<String> names,
    required Set<String> codeKeys,
    required String site,
  }) {
    for (final name in names) {
      if (entriesForActress(name, site: site).isNotEmpty) return true;
    }
    for (final codeKey in codeKeys) {
      if (entriesForCode(codeKey, site: site).isNotEmpty) return true;
    }
    return false;
  }

  /// 异步版：JSON 行 + whos m3u 行合并（JSON 优先，m3u 补缺）。
  /// m3u 只有 whos 一路；只有全部/whos 才并 m3u，选片库站时只回
  /// 本站 JSON 行。m3u 索引读失败时只回 JSON 行，不让 m3u 的问题
  /// 拖垮兜底。
  Future<List<ActressJsonEntry>> entriesForActressAsync(
    String name, {
    String? site,
  }) async {
    final jsonRows = entriesForActress(name, site: site);
    if (site != null && site != 'all' && site != 'whos') return jsonRows;
    final m3uRows = await m3uEntriesForActress(name);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：按番号取 JSON + m3u 合并行（JSON 优先，m3u 补缺）。
  Future<List<ActressJsonEntry>> entriesForCodeAsync(
    String codeKey, {
    String? site,
  }) async {
    final jsonRows = entriesForCode(codeKey, site: site);
    if (site != null && site != 'all' && site != 'whos') return jsonRows;
    final m3uRows = await m3uEntriesForCode(codeKey);
    return _mergeJsonFirst(jsonRows, m3uRows);
  }

  /// 异步版：某人在某站有没有兜底条目（JSON 或 m3u）。
  Future<bool> hasSiteEntriesForPersonAsync({
    required List<String> names,
    required Set<String> codeKeys,
    required String site,
  }) async {
    if (hasSiteEntriesForPerson(
      names: names,
      codeKeys: codeKeys,
      site: site,
    )) {
      return true;
    }
    if (site != 'whos') return false;
    try {
      return await m3uIndex.hasEntriesForPerson(
        names: names,
        codeKeys: codeKeys,
      );
    } catch (_) {
      return false;
    }
  }

  /// 只取 m3u 行（不含 JSON 行）：详情页第二阶段补流用。
  /// m3u 只有 whos 一路；读失败回空，不拖垮兜底。
  Future<List<ActressJsonEntry>> m3uEntriesForActress(String name) async {
    try {
      return await m3uIndex.entriesForActress(name);
    } catch (_) {
      return const [];
    }
  }

  /// 影视库 db 兜底（2026-11-20 18:57）：先查 MYTV/db/女优库.db；
  /// 没接提供方（测试注入的实例）或库读不到时回空，调用方继续
  /// 走 json/m3u。详情页把它排在 json 行之前、m3u 行之前。
  FilmDbFallbackProvider? filmDb;

  Future<List<ActressJsonEntry>> dbEntriesForActress(
    String name, {
    String? site,
  }) async {
    final provider = filmDb;
    if (provider == null) return const [];
    try {
      return await provider.entriesForActress(name, site: site);
    } catch (_) {
      return const [];
    }
  }

  Future<List<ActressJsonEntry>> dbEntriesForCode(
    String codeKey, {
    String? site,
  }) async {
    final provider = filmDb;
    if (provider == null) return const [];
    try {
      return await provider.entriesForCode(codeKey, site: site);
    } catch (_) {
      return const [];
    }
  }

  // 批量按番号取库里条目不在这里（见文件顶部接口下的说明）：
  // 调用方（详情页）按运行时类型分发到两个真实提供方。

  /// 只取 m3u 行（不含 JSON 行）：详情页第二阶段补流用。
  Future<List<ActressJsonEntry>> m3uEntriesForCode(String codeKey) async {
    try {
      return await m3uIndex.entriesForCode(codeKey);
    } catch (_) {
      return const [];
    }
  }

  /// JSON 行在前、m3u 行补缺：同一播放地址只留 JSON 那条；
  /// 没播放地址的按（站，分类|番号）去重。
  List<ActressJsonEntry> _mergeJsonFirst(
    List<ActressJsonEntry> jsonRows,
    List<ActressJsonEntry> m3uRows,
  ) {
    final seenUrls = <String>{};
    final seenKeys = <String>{};
    final out = <ActressJsonEntry>[];
    void add(ActressJsonEntry entry) {
      if (entry.playUrl.isNotEmpty) {
        if (!seenUrls.add(entry.playUrl)) return;
      } else {
        if (!seenKeys.add('${entry.site}|${entry.mergeKey}')) return;
      }
      out.add(entry);
    }

    for (final entry in jsonRows) {
      add(entry);
    }
    for (final entry in m3uRows) {
      add(entry);
    }
    return out;
  }
}

/// 从兜底池里挑出「能播、且番号与这部作品对得上」的行（库行本来就
/// 排在池子最前，返回顺序即点播尝试顺序）。
///
/// 2026-11-22 修：作品侧的 codeKey 是库里的 vod_id 原样（`rki-6042`），
/// 兜底条目的 codeKey 是归一化番号（`RKI6042`）——两边直接比字符串
/// 永远不相等，库里 32 万条直链一条都取不到，点播放只能回退去跨站
/// 爬。这里统一走 normalizeAvCode 归一化再比。
List<ActressJsonEntry> jsonEntriesForWorkCode(
  Iterable<ActressJsonEntry> pool,
  String workCode,
) {
  final key = normalizeAvCode(workCode);
  if (key.isEmpty) return const [];
  return [
    for (final entry in pool)
      if (entry.playable && entry.codeKey == key) entry,
  ];
}

/// 按标题匹配池子条目：通用库作品没有番号（code 列为空、标题里
/// 才有番号）时用，codeKey 为空才走这条。标题归一化后为空
///（纯中文标题归一化会 strip 成空）或不相等时不匹配，不硬认。
/// 2026-11-23：通用库（lsp/yellow/AV 总库）作品进合并后要能播。
List<ActressJsonEntry> jsonEntriesForWorkTitle(
  Iterable<ActressJsonEntry> pool,
  String workTitle,
) {
  final key = normalizeAvCode(workTitle);
  if (key.isEmpty) return const [];
  return [
    for (final entry in pool)
      if (entry.playable &&
          normalizeAvCode(entry.vodName) == key) entry,
  ];
}
