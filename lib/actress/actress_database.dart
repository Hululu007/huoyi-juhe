import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_db_source.dart';
import 'actress_generic_db.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';

/// 没有外置数据库：女优库只读 MYTV/db/女优库.db（2026-11-22 用户令
/// 最终口径），绑定不到它、或文件不存在/为空时开库抛这个错；
/// 调用方（列表页/详情页）接住它显示空态提示，不回落任何内置库、
/// 不建新库、不悄悄造数据。
class ActressNoExternalDbException implements Exception {
  const ActressNoExternalDbException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 没找到已激活女优库时的统一文案（2026-11-27 激活批）：生效
/// 路径为空只剩一种原因——演员库未激活（外置文件不再直通）。
const actressNoActivatedDbMessage =
    '未找到已激活的女优库：请先到数据库管理页导入女优库完成激活';

/// 重读失败文案：没找到已激活库时直说，没有“仍用旧库”（没有
/// 旧库可留）；其它失败（新库打不开）才说留旧库继续用。
String actressReloadErrorText(String error) =>
    error.startsWith('未找到已激活的女优库')
        ? error
        : '数据库重读失败：$error（仍用旧库）';

/// 读库 PRAGMA 组（2026-11-26 只读化后定版，照公开仓调研的只读
/// 打开姿势）：query_only 本连接只读兜底、cache_size 16MB 页缓存、
/// mmap 256MB 内存映射、temp_store 进内存（GROUP BY / ORDER BY
/// 的临时排序不再落盘）。四项只影响本连接，不动 journal_mode、
/// 不改同步级别；女优库自 2026-11-26 起全只读打开，任何写路径
/// 都不存在。设不上也不挡读（个别 PRAGMA 在只读连接上可能被
/// 拒绝），调用方开库处统一调一次即可。
Future<void> applyActressDbReadPragmas(Database db) async {
  try {
    await db.execute('PRAGMA query_only = ON');
    await db.execute('PRAGMA cache_size = -16000');
    await db.execute('PRAGMA mmap_size = 268435456');
    await db.execute('PRAGMA temp_store = MEMORY');
  } catch (_) {
    // 设不上也不挡读。
  }
}

/// 同步断点：每源每阶段一条，记录下次接着跑的位置。
class ActressSyncCheckpoint {
  const ActressSyncCheckpoint({
    required this.source,
    required this.phase,
    this.cursor = '',
    this.total = 0,
    this.finished = false,
    this.error = '',
    this.updatedAt = 0,
  });

  /// 'roster' | 'films' | 'ranking'。
  final String source;
  final String phase;

  /// roster/ranking：下一页页码；films：最后完成的人物 localId。
  final String cursor;
  final int total;
  final bool finished;
  final String error;
  final int updatedAt;
}

/// 全站叠加断点在 sync_state 里的键：source 与 phase 均为 'stacking'，
/// 与三家名册源的检查点分键，互不干扰。
const actressStackingCheckpointSource = 'stacking';
const actressStackingCheckpointPhase = 'stacking';

/// 同步总览：列表页横幅与手动刷新判断用。
class ActressSyncOverview {
  const ActressSyncOverview({
    required this.persons,
    required this.works,
    required this.sources,
    required this.lastUpdatedAt,
    this.personsWithWorks = 0,
  });

  final int persons;
  final int works;

  /// 有入库作品的人数（SELECT COUNT(DISTINCT person_id) FROM
  /// works）：头顶人数只算这个（2026-11-20 用户令：要入库才算），
  /// 只有名册、还没入库作品的人不算；[persons] 仍是名册总人数，
  /// 供同步进度与叠加总量用，不改语义。
  final int personsWithWorks;

  /// 每源：是否三阶段都完成。
  final Map<ActressRosterSourceId, bool> sources;
  final int lastUpdatedAt;

  bool get hasAnything => persons > 0;
  bool get allDone => sources.values.every((done) => done);
}

/// 女优本地库接口：只读本地外置库（2026-11-26 用户令：同步/写入
/// 整套删除，库只读，内容变更只经换库文件）。sqflite 实现跑真机，
/// 内存实现跑测试与预览；两者读语义必须一致。
abstract class ActressDatabase {
  Future<ActressPerson?> personById(int localId);

  /// 人物列表：[tag] 是人物自身的标签（名册 tags 列，有码/无码/
  /// 欧美那行）；[videoTag] 是作品标签（video_tag.tag_name）——
  /// 只留有该标签作品的人（2026-11-24 标签筛选）。[category]
  /// 是视频主分类（video_category.main_category）。
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
    String videoTag = '',
  });

  /// 人物总数（与 [listPersons] 同一过滤口径，含 [videoTag]）。
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String videoTag = '',
  });

  /// 排行榜全量取数（榜内 Dart 侧按综合分排，读本地不联网）。
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  });

  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,

    /// 只取该分类的作品：null/空 = 全部（头顶总数与旧调用同一口径）。
    String? category,

    /// 只取带该作品标签的作品：null/空 = 全部（2026-11-24 标签筛选）。
    /// 与 [category] 是 AND 关系。
    String? videoTag,
  });

  Future<int> countWorks(int personId, {String? category, String? videoTag});

  /// 多库合并去重用：该人名下全部作品的（番号，播放链接）键集合
  ///（键形如 `番号键|有效播放地址`，番号键是归一化后的番号
  ///（normalizeAvCode，跨库同作品才能对上：严格库的 vod_id
  ///是小写 slug、通用库的 code 列可能是大写带连字符），有效地址
  ///口径与播放链一致：m3u8_url 优先、否则 vod_play_url，再过
  ///extractPlayUrl）。
  /// 2026-11-20 合并规则：只有番号与播放链接完全一样才过滤，
  /// 同番号不同地址各留一条。视频库模式才有数据；其它模式回空集
  ///（合并时退回相加口径）。默认实现回空集——测试替身与内存库
  /// 不用实现。
  Future<Set<String>> distinctWorkKeysForName(String name) async =>
      const <String>{};

  /// 全库一级分类（去重计数）：多库勾选时列表页分类行取各库并集。
  /// 严格库读 video_category.main_category；通用库读通用读法
  /// 的分类（优先 video_category、否则作品表自己的分类列，
  /// 见 GenericDbReader.categories）。默认实现回空集——测试替身
  /// 与内存库不用实现。
  Future<List<(String, int)>> dbCategories() async => const [];

  /// 全库作品标签（去重计数，按作品数倒序）：严格库读
  /// video_tag.tag_name（2026-11-24 标签筛选，底部弹窗的数据
  /// 来源）；通用库读通用读法的标签维度（video_tag.tag_name
  /// 优先，否则作品表里含 tag 的列，见 GenericDbReader.tagFacet）。
  /// 没有 video_tag 表的库直接抛错，调用方跳过（与 dbCategories
  /// 同一口径）。默认实现回空集——测试替身与内存库不用实现。
  Future<List<(String, int)>> dbTags() async => const [];

  /// 该人物作品里实际存在的分类（只含 category 非空的行），按作品
  /// 数从多到少、同数按名字排；没有分类的作品不产生标签、不丢数据
  /// （它们只在“全部”里显示）。详情页分类筛选的标签来源。
  Future<List<({String name, int count})>> workCategories(int personId);

  Future<ActressSyncOverview> overview();

  /// 热换库（2026-11-20 用户令）：比对当前绑定路径下数据库文件的
  /// 大小与修改时间，变了先验新库（能打开、结构对）再关旧连接重开；
  /// 验不过留旧库并回原因，不崩、不丢数据。没变回
  /// (reloaded: false, error: null)。[force] 为 true 时不管指纹
  /// 都重读一次（手动“重新加载数据库”用）。实现落在共用的打开
  /// 路径上（SqfliteActressDatabase），同步/现爬/叠加读库都走
  /// 同一个实例，换库后它们读到的都是新库。
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  });

  /// 通用读库（2026-11-20 用户令）：当前打开的库不是女优库结构
  /// 时返回通用读取器（动态探结构 + 字段映射，见
  /// actress_generic_db.dart）；是女优库结构时返回 null，走严格
  /// 路径。每次调用都按当前文件指纹重探，不沿用旧库的字段映射。
  Future<GenericDbReader?> genericReader();

  /// 是不是用户视频库（MYTV/db/女优库.db：actresses + videos +
  /// video_actress + video_category）：是时读走视频库 SQL（人用
  /// actresses.rowid），写只走 videos / video_category 合并，
  /// 不碰 persons/works（那两张表这个库里没有）。
  bool get isVideoLibrary;

  /// 开库回退提示（2026-11-20 用户令“全部使用数据库兜底”）：
  /// MYTV 库损坏/打不开时自动回退到 app 内置 actress.db，
  /// 本字段记下回退原因（供列表页绑定行显示）；正常打开时为 null。
  String? get openFallbackNote;

  Future<void> close();
}


/// 视频库结构判定（纯函数，供测试与 _isVideoLibraryDb 共用）：
/// 表名集合里同时有 actresses、videos、video_actress 三张表即
/// 用户视频库（video_category 是分类表，有没有不影响判定）。
bool isVideoLibrarySchema(Set<String> tableNames) =>
    tableNames.contains('actresses') &&
    tableNames.contains('videos') &&
    tableNames.contains('video_actress');

/// 没有 actresses 表的视频库（2026-11-24 用户报“切换其他数据库
/// 没有显示数据”）：只有 videos + video_actress + video_category
/// 三张表，人物按 video_actress.cate_id（人名）分组现算（见
/// listPersons / countPersons / worksForPerson 的回退），同样认
/// 作视频库，不走通用读法、也不当成空库。
bool isVideoLibrarySchemaWithoutActresses(Set<String> tableNames) =>
    tableNames.contains('videos') &&
    tableNames.contains('video_actress') &&
    tableNames.contains('video_category');

/// 第三行分类里去掉数据库名称分类（2026-11-24 用户令）：外来库把
/// 库名写成了 video_category 的主分类，合并后行 3 会冒出“东瀛丽库
/// 1 / 综合合集”这种库名项。类别名等于任一已知 .db 文件名（去后
/// 缀），或以“<库名>/”开头的，一律不进第三行；真分类（有码/无码/
/// 国产……不在库名集合里）原样保留。库名集合为空时原样返回。
List<(String, int)> filterLibraryNameCategories(
  List<(String, int)> categories,
  Set<String> libraryNames,
) {
  if (libraryNames.isEmpty) return categories;
  return [
    for (final c in categories)
      if (!libraryNames.any(
        (name) => c.$1 == name || c.$1.startsWith('$name/'),
      ))
        c,
  ];
}



Map<String, String> _decodeAbout(Object? value) {
  if (value is! String || value.isEmpty) return const {};
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return const {};
    final out = <String, String>{};
    decoded.forEach((key, item) {
      if (item != null) out[key.toString()] = item.toString();
    });
    return out;
  } catch (_) {
    return const {};
  }
}

ActressPerson _personFromRow(Map<String, Object?> row) {
  List<String> decodeList(Object? value) {
    if (value is! String || value.isEmpty) return const [];
    final decoded = jsonDecode(value);
    if (decoded is! List) return const [];
    return [for (final item in decoded) item.toString()];
  }

  return ActressPerson(
    localId: (row['id'] as num?)?.toInt() ?? 0,
    displayName: (row['display_name'] as String?) ?? '',
    aliases: decodeList(row['aliases']),
    sex: (row['sex'] as String?) ?? '',
    avatarUrl: (row['avatar_url'] as String?) ?? '',
    tags: decodeList(row['tags']),
    worksCount: (row['works_count'] as num?)?.toInt() ?? 0,
    rosterWorks: (row['roster_works'] as num?)?.toInt() ?? 0,
    fromChaoliu: (row['from_chaoliu'] as num?)?.toInt() == 1,
    fromWhos: (row['from_whos'] as num?)?.toInt() == 1,
    fromMissav: (row['from_missav'] as num?)?.toInt() == 1,
    chaoliuId: (row['chaoliu_id'] as String?) ?? '',
    whosSlug: (row['whos_slug'] as String?) ?? '',
    missavPath: (row['missav_path'] as String?) ?? '',
    missavRank: (row['missav_rank'] as num?)?.toInt(),
    recommended: (row['recommended'] as num?)?.toInt() == 1,
    filmsSyncedAt: (row['films_synced_at'] as num?)?.toInt(),
    enrichedAt: (row['enriched_at'] as num?)?.toInt(),
    whosRank: (row['whos_rank'] as num?)?.toInt(),
    rating: (row['rating'] as num?)?.toDouble(),
    exactWorks: (row['exact_works'] as num?)?.toInt() ?? 0,
    about: _decodeAbout(row['about']),
  );
}

ActressWork _workFromRow(Map<String, Object?> row) => ActressWork(
  id: (row['id'] as num?)?.toInt() ?? 0,
  personId: (row['person_id'] as num?)?.toInt() ?? 0,
  codeKey: (row['code_key'] as String?) ?? '',
  titleKey: (row['title_key'] as String?) ?? '',
  site: (row['site'] as String?) ?? '',
  codeDisplay: (row['code_display'] as String?) ?? '',
  title: (row['title'] as String?) ?? '',
  date: (row['date'] as String?) ?? '',
  coverSource: (row['cover_source'] as String?) ?? '',
  coverDramaId: (row['cover_drama_id'] as String?) ?? '',
  coverUrl: (row['cover_url'] as String?) ?? '',
  fromCrossSite: (row['from_cross_site'] as num?)?.toInt() == 1,
  category: (row['category'] as String?) ?? '',
);

/// 视频库（女优库.db）行 → 人：localId 用 actresses.rowid，人一律
/// sex 'female'；worksCount/rosterWorks/exactWorks 都是 LEFT JOIN
/// video_actress 计出的作品数（要入库才算）。
ActressPerson videoLibraryPersonFromRow(Map<String, Object?> row) {
  final count = (row['works_count'] as num?)?.toInt() ?? 0;
  // cate_id 决定来源身份（作品阶段取流靠 sourceIdFor）：新补的行是
  // 'whos:'/'mjv:'/'missav:' 前缀 + 来源 id；原库 29237 行的
  // cate_id 就是名字本身（无前缀），来源身份为空（她们大多已有
  // 作品，作品阶段不需再取）。
  final cateId = (row['cate_id'] as String?) ?? '';
  var fromChaoliu = false;
  var fromWhos = false;
  var fromMissav = false;
  var chaoliuId = '';
  var whosSlug = '';
  var missavPath = '';
  if (cateId.startsWith('whos:')) {
    fromWhos = true;
    whosSlug = cateId.substring('whos:'.length);
  } else if (cateId.startsWith('mjv:')) {
    fromChaoliu = true;
    chaoliuId = cateId.substring('mjv:'.length);
  } else if (cateId.startsWith('missav:')) {
    fromMissav = true;
    missavPath = cateId.substring('missav:'.length);
  }
  // 2026-11-23 修复（v58 验机：貞松大輔是男优却显示“女”）：
  // 库里 actresses 有 sex 列时按列取值（名册同步写，见
  // upsertRosterPerson）；老库没有该列、或列值为空时性别是未知，
  // 不许再默认成“女”——未知就是未知，界面不显示性别
  // （actressSexLabel 对未知返回空）。
  final sexValue = (row['sex'] as String?)?.trim() ?? '';
  return ActressPerson(
    localId: (row['id'] as num?)?.toInt() ?? 0,
    displayName: (row['display_name'] as String?) ?? '',
    sex: sexValue,
    avatarUrl: (row['avatar_url'] as String?) ?? '',
    worksCount: count,
    rosterWorks: count,
    exactWorks: count,
    fromChaoliu: fromChaoliu,
    fromWhos: fromWhos,
    fromMissav: fromMissav,
    chaoliuId: chaoliuId,
    whosSlug: whosSlug,
    missavPath: missavPath,
  );
}

/// 名册汇总累加器（见内存汇总 [_buildPersonSummary]）：同一个人被拆成多行时，
/// 作品数相加、头像取第一条可用（见 [preferLoadableAvatar]）、最新作品日期取最大。
class _RollupAcc {
  _RollupAcc(this.firstRowid);

  final int firstRowid;
  String avatar = '';
  int works = 0;
  String lastDate = '';

  /// 2026-11-22：性别按人归并（同一名字下有一行是男优就算男优）。
  /// 2026-11-23：默认改未知（''），不再默认女——没有男优行只说明
  /// 没确认过性别，不等于女。
  String sex = '';
}

/// 名单内存汇总一行（按名字归并后的人物）：替代原 actress_rollup
/// 落表（2026-11-26 只读化）。lastDate 懒加载（见 _ensureSummaryDates）。
class _PersonSummary {
  _PersonSummary({
    required this.firstRowid,
    required this.name,
    required this.avatar,
    required this.works,
    required this.sex,
  });

  final int firstRowid;
  final String name;
  final String avatar;
  final int works;
  final String sex;
  String lastDate = '';
}

/// 视频库（女优库.db）行 → 作品：id 用 videos.rowid；vod_id 作
/// codeKey/titleKey/codeDisplay/coverDramaId（播放链路按番号经
/// filmDb 兜底查女优库.db 取直链，不直接用这里的地址）；
/// vod_play_from 作 site 与 coverSource；pic_url 作 coverUrl；
/// category 是 COALESCE(main_category, type_name, '')。
ActressWork videoLibraryWorkFromRow(
  Map<String, Object?> row,
  int personId,
) {
  final code = (row['code_key'] as String?) ?? '';
  return ActressWork(
    id: (row['id'] as num?)?.toInt() ?? 0,
    personId: personId,
    codeKey: code,
    titleKey: code,
    site: (row['site'] as String?) ?? '',
    codeDisplay: code,
    title: (row['title'] as String?) ?? '',
    date: (row['date'] as String?) ?? '',
    coverSource: (row['cover_source'] as String?) ?? '',
    coverDramaId: code,
    coverUrl: (row['cover_url'] as String?) ?? '',
    category: (row['category'] as String?) ?? '',
  );
}

/// sqflite 实现：独立 actress.db，不动 app.db 的版本与表结构。
class SqfliteActressDatabase implements ActressDatabase {
  SqfliteActressDatabase._({this.pathOverride});

  static final SqfliteActressDatabase instance = SqfliteActressDatabase._();

  /// 多库勾选：按指定路径开一个只读库实例（不走 MYTV 绑定）。
  /// 只读打开、不跑迁移、不补索引、不补列、不写汇总表，用户的
  /// 外来库文件一个字都不动；读走与主库同一套 SQL。
  factory SqfliteActressDatabase.forPath(String path) =>
      SqfliteActressDatabase._(pathOverride: path);

  /// 非空时 _openNow 不读绑定，直接开这个路径（只读）。
  final String? pathOverride;

  Database? _db;

  /// 视频库模式（2026-11-21 用户令：女优库加载 MYTV/db/女优库.db）：
  /// 当前打开的是用户视频库时为 true，读走视频库 SQL、写只走
  /// videos / video_category 合并。由 _openDbAt 按实际打开的
  /// 文件定，close() 时清掉。
  bool _videoLibraryMode = false;

  @override
  bool get isVideoLibrary => _videoLibraryMode;

  /// 正在进行的开库 Future：并发调用共用同一份结果，不轮询自旋
  /// （旧的 10ms 自旋在开库挂起时越转越久，还会留 pending Timer）。
  Future<Database>? _openFuture;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null && existing.isOpen) return existing;
    // 2026-11-24 掉线修复（自愈）：_db 已被从外面关掉（探库 close
    // 误关共享连接）时，_openFuture 仍是旧的已完成 future，直接
    // await 它会拿回已关闭的连接、此后全掉线还卡死。先把旧连接
    // 与旧 future 都清掉，重新开库。
    if (existing != null && !existing.isOpen) {
      _db = null;
      _openFuture = null;
    }
    var pending = _openFuture;
    if (pending == null) {
      pending = _openNow();
      _openFuture = pending;
    }
    try {
      final db = await pending;
      _db = db;
      return db;
    } catch (_) {
      if (identical(_openFuture, pending)) _openFuture = null;
      rethrow;
    }
  }

  Future<Database> _openNow() async {
    // 2026-11-23 多库勾选：指定了路径就只读开那个文件，不读绑定、
    // 不跑迁移、不补索引列，文件一个字都不动。
    final override = pathOverride;
    if (override != null && override.isNotEmpty) {
      final db = await _openDbAt(override, readOnly: true);
      _openedPath = override;
      _openedSignature = _signatureOf(File(override));
      _genericReaderCache = null;
      _genericReaderKey = null;
      return db;
    }
    // 2026-11-22 用户令口径（2026-11-27 激活批修订）：女优库
    // 只认经导入激活的库；生效路径为空（未激活）就抛
    // ActressNoExternalDbException，界面显示未激活空态＋导入
    // 引导；库损坏/打不开也直接抛错，不回落任何内置库、
    // 不建新库。
    await ActressMytvBind.instance.ensureBound();
    // 激活批：开库路径走来源层生效路径（只有 imported 槽里
    // 已激活的库有路径，外置文件不再直通），不再直读绑定路径。
    final filePath = await ActressDbSource.instance.effectiveDbPath();
    _openFallbackNote = null;
    if (filePath.isEmpty) {
      throw const ActressNoExternalDbException(
        actressNoActivatedDbMessage,
      );
    }
    final db = await _openDbAt(filePath);
    _openedPath = filePath;
    _openedSignature = _signatureOf(File(filePath));
    _genericReaderCache = null;
    _genericReaderKey = null;
    return db;
  }

  @override
  String? get openFallbackNote => _openFallbackNote;

  /// 按文件探结构再开库（2026-11-26 只读化）：不存在/空文件直接
  /// 抛没有外置数据库——绝不在用户文件位置新建库（2026-11-22
  /// 用户令：没有外置库就是空库，不悄悄造数据）。三种结构（女优库
  /// persons/works、用户视频库、外来库）一律只读打开
  /// （openDatabase readOnly、不传 version、无 onCreate/onUpgrade），
  /// 不跑迁移、不补索引、不补列、不写汇总表，用户库文件一个字
  /// 都不动；结构只决定 _videoLibraryMode 标志与读法。
  Future<Database> _openDbAt(String filePath, {bool readOnly = false}) async {
    final file = File(filePath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      _videoLibraryMode = false;
      throw ActressNoExternalDbException(
        '数据库文件不存在或为空：$filePath',
      );
    }
    final isActressDb = await _looksLikeActressDb(filePath);
    final isVideoDb =
        !isActressDb && await _looksLikeVideoLibraryDb(filePath);
    _videoLibraryMode = isVideoDb;
    final db = await openDatabase(
      filePath,
      readOnly: true,
      onOpen: applyActressDbReadPragmas,
    );
    // 强制读一次文件头：损坏文件 open 时不一定报错，第一次查询
    // 才抛；这里验出来就关掉重抛，不开坏库。
    try {
      await db.rawQuery('SELECT COUNT(*) FROM sqlite_master');
    } catch (_) {
      _videoLibraryMode = false;
      await db.close();
      rethrow;
    }
    return db;
  }

  /// 视频库里一个人的全部关联键（2026-11-21 注意字段）：这个库的
  /// `actresses.cate_id` 存的是**名字**（如「今村由美」），
  /// `video_actress` 用它关联，不是数字 ID；rowid 才是列表里用的 id。
  ///
  /// 而且同一个人常有两行：`木下ひまり（花沢ひまり）` 与 `木下ひまり`，
  /// 作品劈成两半。所以按 rowid 找到这个人 → 取同名 → 返回**所有**
  /// 同名 cate_id，作品按这批 cate_id 一起取，才不漏。
  Future<List<String>> _videoCateIdsOf(Database db, int personRowId) async {
    final rows = await db.rawQuery(
      'SELECT cate_id FROM actresses WHERE name = '
      '(SELECT name FROM actresses WHERE rowid = ?)',
      [personRowId],
    );
    return [
      for (final row in rows)
        if ((row['cate_id']?.toString() ?? '').isNotEmpty)
          row['cate_id'].toString(),
    ];
  }

  /// 库里有没有 video_tag 表（2026-11-24 标签筛选）：没有的库
  /// 选了标签筛不出人，调用方直接回空，不抛错。
  Future<bool> _hasVideoTagTable(Database db) async {
    try {
      final rows = await db.rawQuery(
        "SELECT 1 AS x FROM sqlite_master "
        "WHERE type = 'table' AND name = 'video_tag' LIMIT 1",
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 库里 actresses 是否有 sex 列（2026-11-22 合并版库才有；老库没有）。
  Future<bool> _hasActressSexColumn(Database db) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info(actresses)');
      return rows.any((r) => (r['name']?.toString() ?? '') == 'sex');
    } catch (_) {
      return false;
    }
  }

  /// 库里有没有 actresses 表（2026-11-24 用户报“切换其他数据库
  /// 没有显示数据”）：外来库可能只有 videos + video_actress +
  /// video_category，没有这张表；没它时人物查询走 video_actress
  /// 分组回退（见 listPersons / countPersons），不抛错。
  Future<bool> _hasActressesTable(Database db) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info(actresses)');
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 没有 actresses 表时按 video_actress 的 rowid 反查 cate_id
  ///（人名）：回退人物的 localId 就是该人 video_actress 行里最小
  /// 的 rowid（与通用库同一口径，见 GenericActressDatabase）。
  Future<String?> _cateIdOfVideoActressRow(
    Database db,
    int rowId,
  ) async {
    try {
      final rows = await db.rawQuery(
        'SELECT cate_id FROM video_actress WHERE rowid = ? LIMIT 1',
        [rowId],
      );
      if (rows.isEmpty) return null;
      final name = rows.first['cate_id']?.toString().trim() ?? '';
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  /// 视频库里一个人名的 cate_id 集合：先按 actresses.rowid 取同名
  /// cate_id；没有 actresses 表的外来库按 rowid 反查 cate_id 再取
  /// 作品（worksForPerson / countWorks / workCategories 共用）。
  Future<List<String>> _videoCateIdsForPerson(
    Database db,
    int personId,
  ) async {
    final cateIds = await _videoCateIdsOf(db, personId);
    if (cateIds.isNotEmpty) return cateIds;
    final name = await _cateIdOfVideoActressRow(db, personId);
    if (name == null) return const [];
    return [name];
  }

  static String _placeholders(int n) =>
      List.filled(n, '?').join(', ');

  /// 名单内存汇总（2026-11-26 只读化，替代 actress_rollup 落表）：
  /// 视频库模式 + 有 actresses 表时，进库一次把「按名字归并的人物
  /// 汇总」建在内存里（per_cate 只算 COUNT、不 JOIN videos 的便宜
  /// 版 + actresses 全行扫，Dart 侧按名归并），默认视图（无分类/
  /// 标签筛选）与计数都从这张内存表切页，不再往用户库写汇总表。
  /// 挂在连接实例上：换连接（换库/强制重载）即失效重建；
  /// close() 一并清。最近更新排序要的 last_date 懒加载——第一次
  /// 按最近更新排时才跑一遍带 JOIN 的日期聚合合并进来。
  List<_PersonSummary>? _personSummary;
  Database? _personSummaryDb;
  Future<List<_PersonSummary>>? _personSummaryFuture;
  var _personSummaryDatesLoaded = false;

  Future<List<_PersonSummary>> _summaryFor(Database db) {
    final cached = _personSummary;
    if (cached != null && identical(_personSummaryDb, db)) {
      return Future.value(cached);
    }
    final pending = _personSummaryFuture;
    if (pending != null && identical(_personSummaryDb, db)) return pending;
    _personSummaryDb = db;
    _personSummaryDatesLoaded = false;
    final future = _buildPersonSummary(db);
    _personSummaryFuture = future;
    return future.then((rows) {
      if (identical(_personSummaryDb, db)) _personSummary = rows;
      return rows;
    });
  }

  Future<List<_PersonSummary>> _buildPersonSummary(Database db) async {
    final hasSex = await _hasActressSexColumn(db);
    final perCate = await db.rawQuery(
      'SELECT cate_id AS cate_id, COUNT(*) AS n '
      'FROM video_actress GROUP BY cate_id',
    );
    final works = <String, int>{
      for (final row in perCate)
        row['cate_id'].toString(): (row['n'] as num?)?.toInt() ?? 0,
    };
    final people = await db.rawQuery(
      'SELECT rowid AS rid, name AS name, cate_id AS cate_id, '
      "COALESCE(NULLIF(avatar,''),'') AS avatar, "
      "${hasSex ? "COALESCE(NULLIF(sex,''),'')" : "''"} AS sex "
      'FROM actresses ORDER BY rowid',
    );
    final byName = <String, _RollupAcc>{};
    for (final row in people) {
      final name = row['name']?.toString() ?? '';
      final cateId = row['cate_id']?.toString() ?? '';
      if (name.isEmpty || cateId.isEmpty) continue;
      final acc = byName.putIfAbsent(
        name,
        () => _RollupAcc((row['rid'] as num).toInt()),
      );
      acc.avatar = preferLoadableAvatar(
        acc.avatar,
        row['avatar']?.toString() ?? '',
      );
      if ((row['sex']?.toString() ?? '') == 'male') acc.sex = 'male';
      acc.works += works[cateId] ?? 0;
    }
    return [
      for (final entry in byName.entries)
        _PersonSummary(
          firstRowid: entry.value.firstRowid,
          name: entry.key,
          avatar: entry.value.avatar,
          works: entry.value.works,
          sex: entry.value.sex,
        ),
    ];
  }

  /// 最近更新排序用的 last_date 懒加载：带 JOIN 的日期聚合只在
  /// 第一次按最近更新排序时跑一遍，合并进内存汇总后不再重跑。
  Future<void> _ensureSummaryDates(Database db) async {
    if (_personSummaryDatesLoaded) return;
    final rows = await _summaryFor(db);
    final perCate = await db.rawQuery(
      'SELECT va.cate_id AS cate_id, MAX(v.vod_pubdate) AS d '
      'FROM video_actress va '
      'LEFT JOIN videos v ON v.vod_id = va.vod_id '
      'GROUP BY va.cate_id',
    );
    final dateByCate = <String, String>{
      for (final row in perCate)
        if ((row['d']?.toString() ?? '').isNotEmpty)
          row['cate_id'].toString(): row['d'].toString(),
    };
    final cateByName = <String, List<String>>{};
    final people = await db.rawQuery(
      'SELECT name AS name, cate_id AS cate_id FROM actresses',
    );
    for (final row in people) {
      final name = row['name']?.toString() ?? '';
      final cateId = row['cate_id']?.toString() ?? '';
      if (name.isEmpty || cateId.isEmpty) continue;
      (cateByName[name] ??= []).add(cateId);
    }
    for (final person in rows) {
      var best = '';
      for (final cateId in cateByName[person.name] ?? const <String>[]) {
        final d = dateByCate[cateId] ?? '';
        if (d.compareTo(best) > 0) best = d;
      }
      person.lastDate = best;
    }
    _personSummaryDatesLoaded = true;
  }

  /// 内存汇总切页：query（名字包含，大小写不敏感近似 SQL LIKE）+
  /// sex（male 只留男、female 留非男，与原汇总表路口径一致）+
  /// 三种排序，与原 actress_rollup 路的 ActressPerson 形状一致
  ///（localId=同名首行 rowid、works/roster/exact 同数）。
  List<ActressPerson> _summaryPage(
    List<_PersonSummary> all, {
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
  }) {
    final q = query.trim().toLowerCase();
    final rows = [
      for (final person in all)
        if ((q.isEmpty || person.name.toLowerCase().contains(q)) &&
            (sex == ActressSexFilter.all ||
                (sex == ActressSexFilter.male
                    ? person.sex == 'male'
                    : person.sex != 'male')))
          person,
    ];
    switch (sort) {
      case ActressSort.worksDesc:
        rows.sort((a, b) {
          final byWorks = b.works.compareTo(a.works);
          return byWorks != 0 ? byWorks : a.name.compareTo(b.name);
        });
      case ActressSort.nameAsc:
        rows.sort((a, b) => a.name.compareTo(b.name));
      case ActressSort.recentDesc:
        rows.sort((a, b) {
          final byDate = b.lastDate.compareTo(a.lastDate);
          return byDate != 0 ? byDate : a.name.compareTo(b.name);
        });
    }
    if (offset >= rows.length) return const [];
    final end = (offset + limit).clamp(0, rows.length);
    return [
      for (final person in rows.sublist(offset, end))
        ActressPerson(
          localId: person.firstRowid,
          displayName: person.name,
          sex: person.sex,
          avatarUrl: person.avatar,
          worksCount: person.works,
          rosterWorks: person.works,
          exactWorks: person.works,
        ),
    ];
  }

  int _summaryCount(
    List<_PersonSummary> all, {
    required ActressSexFilter sex,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    var n = 0;
    for (final person in all) {
      if (q.isNotEmpty && !person.name.toLowerCase().contains(q)) continue;
      if (sex == ActressSexFilter.male && person.sex != 'male') continue;
      if (sex == ActressSexFilter.female && person.sex == 'male') continue;
      n++;
    }
    return n;
  }

  /// 当前打开库的文件指纹（大小 + 修改时间毫秒）：开库时记一次，
  /// 热换库比对它，变了才重开。
  String? _openedPath;
  ({int length, int modifiedMs})? _openedSignature;

  /// 开库提示（见 openFallbackNote）：2026-11-22 起不再回退任何
  /// 内置库，恒为 null（接口保留，列表页的显示分支不动）。
  String? _openFallbackNote;

  /// 通用读取器缓存：按（路径，文件指纹）缓存，文件变了自动重探，
  /// 不沿用旧库的字段映射。
  GenericDbReader? _genericReaderCache;
  String? _genericReaderKey;

  static ({int length, int modifiedMs})? _signatureOf(File file) {
    try {
      final stat = file.statSync();
      return (
        length: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }

  /// 只读探一下：是不是女优库结构（persons + works 表，且 works
  /// 有 code_key 列）。文件损坏/不是 sqlite 时返回 false（调用方
  /// 再按外来库直接打开，同样打不开就报错，不静默当空库）。
  Future<bool> _looksLikeActressDb(String filePath) async {
    Database? probe;
    try {
      probe = await openDatabase(filePath, readOnly: true);
      return await _isActressSchemaDb(probe);
    } catch (_) {
      return false;
    } finally {
      await probe?.close();
    }
  }

  /// 已打开的库是不是女优库结构（persons + works 表，且 works 有
  /// code_key 列）：严格路径只认这一套；表名撞上、字段不对的按
  /// 外来库走通用映射。
  Future<bool> _isActressSchemaDb(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = {for (final row in tables) row['name'].toString()};
    if (!names.contains('persons') || !names.contains('works')) {
      return false;
    }
    final cols = await db.rawQuery('PRAGMA table_info("works")');
    final colNames = {for (final row in cols) row['name'].toString()};
    return colNames.contains('code_key') &&
        colNames.contains('person_id');
  }

  /// 只读探一下：是不是用户视频库（actresses + videos +
  /// video_actress 三张表同时在）。文件损坏/不是 sqlite 时返回
  /// false（调用方再按外来库直接打开，同样打不开就报错，不静默
  /// 当空库）。只探表，不写文件。
  Future<bool> _looksLikeVideoLibraryDb(String filePath) async {
    Database? probe;
    try {
      probe = await openDatabase(filePath, readOnly: true);
      return await _isVideoLibraryDb(probe);
    } catch (_) {
      return false;
    } finally {
      await probe?.close();
    }
  }

  /// 已打开的库是不是用户视频库：sqlite_master 里同时有
  /// actresses、videos、video_actress 三张表即 true（video_category
  /// 是分类表，有没有不影响判定，读分类时 LEFT JOIN 即可）。
  /// 没有 actresses 表、只有 videos + video_actress +
  /// video_category 的外来库同样认（人物按 video_actress.cate_id
  /// 分组现算，见 listPersons 等方法的回退）。
  Future<bool> _isVideoLibraryDb(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = {for (final row in tables) row['name'].toString()};
    return isVideoLibrarySchema(names) ||
        isVideoLibrarySchemaWithoutActresses(names);
  }

  /// 验一个已打开的候选库：女优库结构核对 works.code_key；用户
  /// 视频库（actresses + videos + video_actress）是合法的女优库
  /// 源，直接认；外来库至少要有一张能认出作品的表（标题 + 播放
  /// 地址），否则抛错——调用方留旧库并报原因。空库（0 张表）也
  /// 接受（后面自动生成会灌种子；通用模式下列表为空，不报错）。
  Future<void> _validateOpenDb(Database db) async {
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    if (tables.isEmpty) return;
    if (await _isActressSchemaDb(db)) return;
    if (await _isVideoLibraryDb(db)) return;
    final schema = await probeGenericDbSchema(db);
    if (schema.worksTable == null) {
      throw StateError('没有找到带标题与播放地址的作品表');
    }
  }

  static String _shortDbError(Object error) {
    final first = error.toString().split('\n').first.trim();
    return first.length > 120 ? '${first.substring(0, 120)}…' : first;
  }

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async {
    // 重解析绑定：新放进 / 删掉的女优库.db 只有重解析才看得到
    // （“重新加载数据库”与进页热换库都靠它）。
    await ActressMytvBind.instance.ensureBound(refresh: true);
    // 双库批：重读目标同样走来源层生效路径；切换必然换路径，
    // 下面的路径比对会触发关旧连接重开新库（同路径换文件靠
    // force 或文件戳，见 actress_db_source.dart 类注释）。
    final currentPath = await ActressDbSource.instance.effectiveDbPath();
    if (currentPath.isEmpty) {
      return (reloaded: false, error: actressNoActivatedDbMessage);
    }
    final file = File(currentPath);
    FileStat? stat;
    try {
      stat = await file.stat();
    } catch (_) {
      stat = null;
    }
    if (stat == null || stat.type == FileSystemEntityType.notFound) {
      return (reloaded: false, error: '数据库文件不存在：$currentPath');
    }
    final signature = (
      length: stat.size,
      modifiedMs: stat.modified.millisecondsSinceEpoch,
    );
    // 在途的开库先等它落定（不然它完成后会把 _db 指回旧文件，
    // 盖掉这次换库）。
    final pending = _openFuture;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // 开库失败：下面按没开过库走。
      }
    }
    final opened = _db;
    if (!force &&
        opened != null &&
        opened.isOpen &&
        _openedPath == currentPath &&
        _openedSignature == signature) {
      return (reloaded: false, error: null);
    }
    // 同一文件、只是内容变了（指纹变了）：不重开。镜像/同步正是
    // 通过当前连接在写这个文件，当前连接本来就能读到已提交的新
    // 数据；重开反而要等镜像的写锁（PRAGMA journal_mode 报
    // SQLITE_BUSY，2026-11-21 用户截图里详情页一点作品就弹这个
    // 错），还把正在用的连接关了。只有换了路径（重新绑定到另一
    // 个文件）或用户手动点“重新加载数据库”（force）时才重开；
    // 外部直接替换同路径文件时也用手动重载。
    if (!force &&
        opened != null &&
        opened.isOpen &&
        _openedPath == currentPath) {
      _openedSignature = signature;
      return (reloaded: false, error: null);
    }
    if (opened == null) {
      // 还没开过库：下次 _open 会按当前文件开；手动重载时在这里
      // 开一次就算重载。
      if (!force) return (reloaded: false, error: null);
      try {
        await _open();
        _openedPath = currentPath;
        _openedSignature = signature;
        _genericReaderCache = null;
        _genericReaderKey = null;
        return (reloaded: true, error: null);
      } catch (e) {
        return (reloaded: false, error: '数据库打不开：${_shortDbError(e)}');
      }
    }
    // 先在新连接上打开并验结构（旧库还开着）：验不过留旧库。
    Database? candidate;
    try {
      candidate = await _openDbAt(currentPath);
      await _validateOpenDb(candidate);
    } catch (e) {
      await candidate?.close();
      return (reloaded: false, error: '新数据库打不开：${_shortDbError(e)}');
    }
    // 验过：换连接（旧连接关掉；_openFuture 指向新库）。
    final old = _db;
    _db = candidate;
    _openFuture = Future.value(candidate);
    _openedPath = currentPath;
    _openedSignature = signature;
    _genericReaderCache = null;
    _genericReaderKey = null;
    await old?.close();
    return (reloaded: true, error: null);
  }

  @override
  Future<GenericDbReader?> genericReader() async {
    final db = await _open();
    // 视频库是合法的女优库源（不是通用库）：返回 null，走视频库
    // 严格路径，不走通用映射。
    if (_videoLibraryMode) return null;
    if (await _isActressSchemaDb(db)) return null;
    final key =
        '$_openedPath|${_openedSignature?.length}|'
        '${_openedSignature?.modifiedMs}';
    final cached = _genericReaderCache;
    if (cached != null && _genericReaderKey == key) return cached;
    final schema = await probeGenericDbSchema(db);
    // 手动映射文件与库文件放一起（MYTV/db/字段映射.json；未绑定
    // 时在 documents 下），换同结构库直接复用。
    final bind = await ActressMytvBind.instance.ensureBound();
    // 双库批：映射文件跟实际打开的库放一起（生效路径优先，
    // 没有才退绑定路径，与改前的外置库口径一致）。
    final openedPath = _openedPath;
    final store = GenericDbMappingStore(
      file: File(
        path.join(
          path.dirname(
            openedPath != null && openedPath.isNotEmpty
                ? openedPath
                : bind.dbPath,
          ),
          '字段映射.json',
        ),
      ),
    );
    var resolvedSchema = schema;
    final saved = await store.loadMapping(schema.fingerprint);
    if (saved != null) {
      resolvedSchema = schema.withManualMapping(
        table: saved.table,
        columns: saved.columns,
      );
    }
    final reader = GenericDbReader(
      db: db,
      schema: resolvedSchema,
      mappingStore: store,
    );
    _genericReaderCache = reader;
    _genericReaderKey = key;
    return reader;
  }

  @override
  Future<ActressPerson?> personById(int localId) async {
    final db = await _open();
    if (_videoLibraryMode) {
      // 没有 actresses 表的外来库：人物 id 是 video_actress 的
      // rowid，按它反查人名再现算作品数。
      if (!await _hasActressesTable(db)) {
        final name = await _cateIdOfVideoActressRow(db, localId);
        if (name == null) return null;
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM video_actress WHERE cate_id = ?',
          [name],
        );
        return videoLibraryPersonFromRow({
          'id': localId,
          'display_name': name,
          'cate_id': name,
          'avatar_url': '',
          'works_count': (rows.first['c'] as num?)?.toInt() ?? 0,
        });
      }
      // 2026-11-23：sex 列存在时一起取出来（详情页头显性别靠它；
      // 没这列时 videoLibraryPersonFromRow 按未知处理，不默认女）。
      final hasSex = await _hasActressSexColumn(db);
      final rows = await db.rawQuery(
        'SELECT a.rowid AS id, a.name AS display_name, '
        'a.cate_id AS cate_id, a.avatar AS avatar_url, '
        "${hasSex ? 'a.sex AS sex, ' : ''}"
        'COUNT(va.vod_id) AS works_count '
        'FROM actresses a '
        'LEFT JOIN video_actress va ON va.cate_id = a.cate_id '
        'WHERE a.rowid = ? '
        'GROUP BY a.rowid, a.name, a.avatar',
        [localId],
      );
      if (rows.isEmpty) return null;
      return videoLibraryPersonFromRow(rows.first);
    }
    final rows = await db.query(
      'persons',
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (await _withLiveWorksCounts([_personFromRow(rows.first)])).first;
  }

  String _sexWhere(ActressSexFilter sex, List<Object?> args) {
    switch (sex) {
      case ActressSexFilter.all:
        return '1 = 1';
      case ActressSexFilter.female:
        args.add('female');
        return 'sex = ?';
      case ActressSexFilter.male:
        args.add('male');
        return 'sex = ?';
    }
  }

  String _queryWhere(String query, List<Object?> args) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return '1 = 1';
    final like = '%$trimmed%';
    final keyLike = '%${actressNameKey(trimmed)}%';
    args.addAll([like, like, keyLike]);
    var where =
        '(display_name LIKE ? OR aliases LIKE ? OR id IN '
        '(SELECT person_id FROM person_names WHERE name_key LIKE ?)';
    // 番号搜索：输入像番号时，另按作品番号键模糊匹配（SSIS-12 能命中
    // SSIS123）；键只含大写字母与数字，拼进 LIKE 无通配符风险。
    final codeKey = actressCodeQueryKey(trimmed);
    if (codeKey != null) {
      args.add('%$codeKey%');
      where +=
          ' OR id IN (SELECT person_id FROM works WHERE code_key LIKE ?)';
    }
    return '$where)';
  }

  // 标签存为 JSON 数组文本，带引号匹配避免子串误中（'"有码"' 只中整标签）。
  String _tagWhere(String tag, List<Object?> args) {
    if (tag.isEmpty) return '1 = 1';
    args.add('%${jsonEncode(tag)}%');
    return 'tags LIKE ?';
  }

  // 数据库分类：只留该分类里有作品的人（video_category 主分类
  // 经同步写进 works.category；见 upsertWorks）。
  String _categoryWhere(String category, List<Object?> args) {
    if (category.isEmpty) return '1 = 1';
    args.add(category);
    return 'EXISTS (SELECT 1 FROM works w '
        'WHERE w.person_id = persons.id AND w.category = ?)';
  }

  String _sortOrder(ActressSort sort) => switch (sort) {
    // 作品数只算入库数（2026-11-20 用户令：要入库才算），
    // 不再拿 MAX(works_count, roster_works) 充数。
    ActressSort.worksDesc => 'works_count DESC, display_name ASC',
    ActressSort.nameAsc => 'display_name ASC',
    // 最近更新：每人入库作品里最新作品日期倒序；COALESCE 把
    // 无入库作品的人的空值当 ''，倒序时沉底；同日按名字。
    // 只算 works 表里实际有的日期，不用站方宣称的更新时间。
    ActressSort.recentDesc =>
      "COALESCE((SELECT MAX(date) FROM works WHERE works.person_id = persons.id), '') DESC, display_name ASC",
  };

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
    String videoTag = '',
  }) async {
    final db = await _open();
    if (_videoLibraryMode) {
      // 2026-11-24 标签筛选：没有 video_tag 表的库筛不出带标签的
      // 作品，选了标签直接回空（不抛错、不暗地里回未过滤的列表）。
      final useVideoTag = videoTag.isNotEmpty;
      if (useVideoTag && !await _hasVideoTagTable(db)) return const [];
      // 2026-11-22 用户令（男优与女优分开）：合并版库 actresses 带
      // sex 列（男优 257 位，按 who's 番号绑定作品），男优筛选按列
      // 过滤；老库没有 sex 列时保持改前行为（male 无结果）。
      final hasSex = await _hasActressSexColumn(db);
      if (sex != ActressSexFilter.all && !hasSex) return const [];
      // 没有 actresses 表的外来库（只有 videos + video_actress +
      // video_category）：直接按 video_actress.cate_id（人名）分组
      // 现算人物——头像与性别未知（空），作品数按组计数，localId 取
      // 该人 video_actress 行里最小的 rowid（worksForPerson 按它
      // 反查人名，与通用库同一口径）。没有这条回退时旧的两条路都
      // 会抛错、被调用方静默跳过，人物列表永远是主库数据。
      if (!await _hasActressesTable(db)) {
        final trimmedQuery = query.trim();
        final args = <Object?>[];
        final conditions = <String>[];
        if (trimmedQuery.isNotEmpty) {
          args.add('%$trimmedQuery%');
          conditions.add('pc.cate_id LIKE ?');
        }
        if (category.isNotEmpty) {
          args.add(category);
          conditions.add(
            'EXISTS (SELECT 1 FROM video_actress va2 '
            'JOIN videos v2 ON v2.vod_id = va2.vod_id '
            'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
            'WHERE va2.cate_id = pc.cate_id '
            "AND COALESCE(vc2.main_category, '') = ?)",
          );
        }
        if (tag.isNotEmpty) {
          // 2026-11-24 册别筛按视频主分类筛人（guochang 口径）：
          // 视频库没有名册标签列，tag 值本身就是主分类名（有码/
          // 无码/国产/4K/动漫/三级/欧美/其他）；为空（全部）时不加
          // 条件，默认列表性能不变。
          args.add(tag);
          conditions.add(
            'EXISTS (SELECT 1 FROM video_actress va2 '
            'JOIN videos v2 ON v2.vod_id = va2.vod_id '
            'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
            'WHERE va2.cate_id = pc.cate_id '
            "AND COALESCE(vc2.main_category, '') = ?)",
          );
        }
        if (useVideoTag) {
          args.add(videoTag);
          conditions.add(
            'EXISTS (SELECT 1 FROM video_actress va2 '
            'JOIN video_tag vt2 ON vt2.vod_id = va2.vod_id '
            'WHERE va2.cate_id = pc.cate_id '
            'AND vt2.tag_name = ?)',
          );
        }
        final where = conditions.isEmpty
            ? ''
            : 'WHERE ${conditions.join(' AND ')}';
        final order = switch (sort) {
          ActressSort.worksDesc => 'pc.n DESC, pc.cate_id ASC',
          ActressSort.nameAsc => 'pc.cate_id ASC',
          ActressSort.recentDesc => 'pc.d DESC, pc.cate_id ASC',
        };
        // 最近更新排序才 join videos 取 MAX(vod_pubdate)，平时纯走
        // video_actress(cate_id) 分组（与回退路同一优化，见下）。
        final perCateSql = sort == ActressSort.recentDesc
            ? 'SELECT va.cate_id AS cate_id, COUNT(*) AS n, '
                'MAX(v.vod_pubdate) AS d, MIN(va.rowid) AS first_rowid '
                'FROM video_actress va '
                'LEFT JOIN videos v ON v.vod_id = va.vod_id '
                'GROUP BY va.cate_id'
            : 'SELECT cate_id AS cate_id, COUNT(*) AS n, '
                "'' AS d, MIN(rowid) AS first_rowid "
                'FROM video_actress GROUP BY cate_id';
        final rows = await db.rawQuery(
          'WITH per_cate AS ($perCateSql) '
          'SELECT pc.first_rowid AS id, pc.cate_id AS display_name, '
          "pc.cate_id AS cate_id, '' AS avatar_url, "
          "pc.n AS works_count, '' AS sex "
          'FROM per_cate pc $where ORDER BY $order LIMIT ? OFFSET ?',
          [...args, limit, offset],
        );
        return rows.map(videoLibraryPersonFromRow).toList();
      }
      final trimmedQuery = query.trim();
      final args = <Object?>[];
      final conditions = <String>[];

      // 默认视图（无分类/册别/作品标签筛选）：走内存汇总切页
      //（2026-11-26 只读化，替代 actress_rollup 汇总表路）：同一
      // 个人被拆成两行时按名字合回一人、作品数相加（217+739）。
      // 带筛选时仍走下面的现算 SQL（EXISTS 口径不变）。
      if (category.isEmpty && tag.isEmpty && !useVideoTag) {
        if (sort == ActressSort.recentDesc) {
          await _ensureSummaryDates(db);
        }
        final summary = await _summaryFor(db);
        return _summaryPage(
          summary,
          sex: sex,
          sort: sort,
          query: query,
          offset: offset,
          limit: limit,
        );
      }


      // 带筛选（分类/册别/作品标签）时现算同一套归并：EXISTS 半
      // 连接筛人，per_cate 只算 COUNT（recentDesc 才 JOIN 取日期）。
      if (trimmedQuery.isNotEmpty) {
        args.add('%$trimmedQuery%');
        conditions.add('a.name LIKE ?');
      }
      if (hasSex && sex == ActressSexFilter.male) {
        conditions.add("a.sex = 'male'");
      } else if (hasSex && sex == ActressSexFilter.female) {
        conditions.add("COALESCE(NULLIF(a.sex,''),'female') = 'female'");
      }
      if (category.isNotEmpty) {
        // 该人有该分类的作品才留：分类口径与 workCategories 同
        // 一份（COALESCE(main_category, type_name, '')），点分类
        // 标签筛出来的人与标签数一致。
        args.add(category);
        conditions.add(
          'EXISTS (SELECT 1 FROM video_actress va2 '
          'JOIN videos v2 ON v2.vod_id = va2.vod_id '
          'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
          'JOIN actresses a3 ON a3.cate_id = va2.cate_id '
          'WHERE a3.name = a.name '
          "AND COALESCE(vc2.main_category, '') = ?)",
        );
      }
      if (tag.isNotEmpty) {
        // 2026-11-24 册别筛按视频主分类筛人（guochang 口径，
        // 见无 actresses 表分支的注释）；tag 值就是主分类名。
        args.add(tag);
        conditions.add(
          'EXISTS (SELECT 1 FROM video_actress va2 '
          'JOIN videos v2 ON v2.vod_id = va2.vod_id '
          'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
          'JOIN actresses a3 ON a3.cate_id = va2.cate_id '
          'WHERE a3.name = a.name '
          "AND COALESCE(vc2.main_category, '') = ?)",
        );
      }
      if (useVideoTag) {
        // 该人有该标签的作品才留（与分类同一口径：EXISTS 半连接，
        // 不走大 JOIN 逐行回表）。
        args.add(videoTag);
        conditions.add(
          'EXISTS (SELECT 1 FROM video_actress va2 '
          'JOIN video_tag vt2 ON vt2.vod_id = va2.vod_id '
          'JOIN actresses a3 ON a3.cate_id = va2.cate_id '
          'WHERE a3.name = a.name '
          'AND vt2.tag_name = ?)',
        );
      }
      final where = conditions.isEmpty
          ? ''
          : 'WHERE ${conditions.join(' AND ')}';
      final order = switch (sort) {
        ActressSort.worksDesc => 'works_count DESC, a.name ASC',
        ActressSort.nameAsc => 'a.name ASC',
        ActressSort.recentDesc => 'last_date DESC, a.name ASC',
      };
      // 2026-11-23 转圈根因之二：回退 CTE 里 LEFT JOIN videos 只为
      // 取 MAX(vod_pubdate)（最近更新排序用），47 万行逐行回表查
      // videos 主键，冷盘实测 36 秒；按作品数/名字排时 last_date
      // 根本不用。只在 recentDesc 时才 join，平时纯走
      // video_actress(cate_id) 索引扫，实测 0.6 秒（冷盘）/ 0.1 秒（热）。
      final needLatestDate = sort == ActressSort.recentDesc;
      final perCateSql = needLatestDate
          ? 'SELECT cate_id AS cate_id, COUNT(*) AS n, '
              'MAX(v.vod_pubdate) AS d FROM video_actress va '
              'LEFT JOIN videos v ON v.vod_id = va.vod_id GROUP BY cate_id'
          : 'SELECT cate_id AS cate_id, COUNT(*) AS n, '
              "'' AS d FROM video_actress GROUP BY cate_id";
      // 2026-11-24 头像修复：回退路 avatar_url 不用 MAX（字典序里
      // 裸域名 https://v.hersav.me/ 的 v 开头必赢 c 开头的真头像），
      // 只在有效头像（LIKE '%://%/%_'：有 scheme、有 host、path
      // 非根）里取 MAX；全行裸/空时回 ''，调用方回落首字圆圈。
      // B 方案（行序第一有效子查询）在新库实测 200 组 1.58 秒、
      // 外推全量约 205 秒，太慢，弃用。
      final rows = await db.rawQuery(
        'WITH per_cate AS ($perCateSql) '
        'SELECT MIN(a.rowid) AS id, a.name AS display_name, '
        'a.name AS cate_id, '
        '${hasSex ? "CASE WHEN SUM(CASE WHEN a.sex='male' THEN 1 ELSE 0 END)>0 "
            "THEN 'male' ELSE '' END" : "''"} AS sex, '
        "COALESCE(MAX(CASE WHEN a.avatar LIKE '%://%/%_' "
        "THEN a.avatar END),'') AS avatar_url, "
        'SUM(COALESCE(pc.n,0)) AS works_count, '
        "COALESCE(MAX(COALESCE(pc.d,'')),'') AS last_date "
        'FROM actresses a LEFT JOIN per_cate pc ON pc.cate_id = a.cate_id '
        '$where GROUP BY a.name ORDER BY $order LIMIT ? OFFSET ?',
        [...args, limit, offset],
      );
      return rows.map(videoLibraryPersonFromRow).toList();
    }
    // 旧 persons/works 结构没有 video_tag 表：选了作品标签筛不出，
    // 回空，不暗地里回未过滤的列表。
    if (videoTag.isNotEmpty) return const [];
    final args = <Object?>[];
    final where =
        '${_sexWhere(sex, args)} AND ${_queryWhere(query, args)} '
        'AND ${_tagWhere(tag, args)} AND ${_categoryWhere(category, args)}';
    final rows = await db.query(
      'persons',
      where: where,
      whereArgs: args,
      orderBy: _sortOrder(sort),
      limit: limit,
      offset: offset,
    );
    return _withLiveWorksCounts(rows.map(_personFromRow).toList());
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String videoTag = '',
  }) async {
    final db = await _open();
    if (_videoLibraryMode) {
      final hasSex = await _hasActressSexColumn(db);
      if (sex != ActressSexFilter.all && !hasSex) return 0;
      // 2026-11-24 标签筛选：没有 video_tag 表的库选了标签回 0。
      final useVideoTag = videoTag.isNotEmpty;
      if (useVideoTag && !await _hasVideoTagTable(db)) return 0;
      // 没有 actresses 表的外来库：按 video_actress.cate_id 分组计数
      //（与 listPersons 的回退同一口径）。
      if (!await _hasActressesTable(db)) {
        final trimmedQuery = query.trim();
        final args = <Object?>[];
        final conditions = <String>[];
        if (trimmedQuery.isNotEmpty) {
          args.add('%$trimmedQuery%');
          conditions.add('cate_id LIKE ?');
        }
        if (tag.isNotEmpty) {
          // 2026-11-24 册别筛按视频主分类计数（guochang 口径，
          // 见 listPersons 无 actresses 表分支的注释）。
          args.add(tag);
          conditions.add(
            'EXISTS (SELECT 1 FROM video_actress va2 '
            'JOIN videos v2 ON v2.vod_id = va2.vod_id '
            'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
            'WHERE va2.cate_id = video_actress.cate_id '
            "AND COALESCE(vc2.main_category, '') = ?)",
          );
        }
        if (useVideoTag) {
          args.add(videoTag);
          conditions.add(
            'EXISTS (SELECT 1 FROM video_actress va2 '
            'JOIN video_tag vt2 ON vt2.vod_id = va2.vod_id '
            'WHERE va2.cate_id = video_actress.cate_id '
            'AND vt2.tag_name = ?)',
          );
        }
        final where = conditions.isEmpty
            ? ''
            : 'WHERE ${conditions.join(' AND ')}';
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM '
          '(SELECT cate_id FROM video_actress $where GROUP BY cate_id)',
          args,
        );
        return (rows.first['c'] as num?)?.toInt() ?? 0;
      }
      // 无册别/作品标签筛选时计数走内存汇总（与 listPersons 默认
      // 路同一份归并，按名字去重）；带筛选走下面的 SQL。
      if (tag.isEmpty && !useVideoTag) {
        final summary = await _summaryFor(db);
        return _summaryCount(summary, sex: sex, query: query);
      }
      final args = <Object?>[];
      final conditions = <String>[];
      final trimmedQuery = query.trim();
      if (trimmedQuery.isNotEmpty) {
        args.add('%$trimmedQuery%');
        conditions.add('name LIKE ?');
      }
      if (sex == ActressSexFilter.male) {
        conditions.add("sex = 'male'");
      } else if (sex == ActressSexFilter.female) {
        conditions.add("COALESCE(NULLIF(sex,''),'female') = 'female'");
      }
      if (tag.isNotEmpty) {
        // 2026-11-24 册别筛按视频主分类计数（guochang 口径，
        // 见 listPersons 无 actresses 表分支的注释）。
        args.add(tag);
        conditions.add(
          'EXISTS (SELECT 1 FROM actresses a2 '
          'JOIN video_actress va2 ON va2.cate_id = a2.cate_id '
          'JOIN videos v2 ON v2.vod_id = va2.vod_id '
          'LEFT JOIN video_category vc2 ON vc2.vod_id = va2.vod_id '
          'WHERE a2.name = actresses.name '
          "AND COALESCE(vc2.main_category, '') = ?)",
        );
      }
      if (useVideoTag) {
        args.add(videoTag);
        conditions.add(
          'EXISTS (SELECT 1 FROM actresses a2 '
          'JOIN video_actress va2 ON va2.cate_id = a2.cate_id '
          'JOIN video_tag vt2 ON vt2.vod_id = va2.vod_id '
          'WHERE a2.name = actresses.name '
          'AND vt2.tag_name = ?)',
        );
      }
      final where = conditions.isEmpty
          ? ''
          : 'WHERE ${conditions.join(' AND ')}';
      // 按名字去重计数（同一个人被拆成两行时只算一个）。
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM '
        '(SELECT name FROM actresses $where GROUP BY name)',
        args,
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    final args = <Object?>[];
    final where =
        '${_sexWhere(sex, args)} AND ${_queryWhere(query, args)} '
        'AND ${_tagWhere(tag, args)}';
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM persons WHERE $where',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async {
    final db = await _open();
    if (_videoLibraryMode) {
      // 视频库没有排行名次/评分：按作品数倒序取前 500 人，走
      // listPersons 的视频库逻辑（同一份 SQL 与映射）。
      return listPersons(
        sex: sex,
        sort: ActressSort.worksDesc,
        query: '',
        offset: 0,
        limit: 500,
      );
    }
    final args = <Object?>[];
    final rows = await db.query(
      'persons',
      where: _sexWhere(sex, args),
      whereArgs: args,
    );
    final persons =
        await _withLiveWorksCounts(rows.map(_personFromRow).toList())
          ..sort(compareActressRank);
    return persons;
  }

  @override
  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
    String? category,
    String? videoTag,
  }) async {
    final db = await _open();
    if (_videoLibraryMode) {
      final useCategory = category != null && category.isNotEmpty;
      final useVideoTag = videoTag != null && videoTag.isNotEmpty;
      if (useVideoTag && !await _hasVideoTagTable(db)) return const [];
      // 2026-11-21：先按 rowid 取这个人（主键，瞬时），再用 cate_id
      // 反查作品。原来一条大 JOIN（videos × video_actress × actresses）
      // 再 ORDER BY 排序，32 万视频的库在手机上点一下要转半天，
      // 看着就是「点了头像没作品」。
      final cateIds = await _videoCateIdsForPerson(db, personId);
      if (cateIds.isEmpty) return const [];
      final inList = _placeholders(cateIds.length);
      final args = <Object?>[
        ...cateIds,
        if (useCategory) category,
        if (useVideoTag) videoTag,
        limit,
        offset,
      ];
      final rows = await db.rawQuery(
        'SELECT v.rowid AS id, v.vod_id AS code_key, '
        'v.title AS title, v.vod_pubdate AS date, '
        'v.vod_play_from AS site, v.vod_play_from AS cover_source, '
        'v.pic_url AS cover_url, '
        "COALESCE(vc.main_category, '') AS category "
        'FROM videos v '
        'LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
        'WHERE v.vod_id IN (SELECT vod_id FROM video_actress '
        'WHERE cate_id IN ($inList)) '
        "${useCategory ? "AND COALESCE(vc.main_category, '') = ? " : ''}"
        "${useVideoTag ? 'AND EXISTS (SELECT 1 FROM video_tag vt '
            'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?) ' : ''}"
        'ORDER BY v.vod_pubdate DESC, v.vod_id ASC '
        'LIMIT ? OFFSET ?',
        args,
      );
      return [
        for (final row in rows) videoLibraryWorkFromRow(row, personId),
      ];
    }
    if (videoTag != null && videoTag.isNotEmpty) return const [];
    final useCategory = category != null && category.isNotEmpty;
    final rows = await db.query(
      'works',
      where: useCategory ? 'person_id = ? AND category = ?' : 'person_id = ?',
      whereArgs: useCategory ? [personId, category] : [personId],
      orderBy: 'id ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_workFromRow).toList();
  }

  @override
  Future<int> countWorks(int personId, {String? category, String? videoTag}) async {
    final db = await _open();
    if (_videoLibraryMode) {
      final useCategory = category != null && category.isNotEmpty;
      final useVideoTag = videoTag != null && videoTag.isNotEmpty;
      if (useVideoTag && !await _hasVideoTagTable(db)) return 0;
      final cateIds = await _videoCateIdsForPerson(db, personId);
      if (cateIds.isEmpty) return 0;
      final inList = _placeholders(cateIds.length);
      final args = <Object?>[
        ...cateIds,
        if (useCategory) category,
        if (useVideoTag) videoTag,
      ];
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM videos v '
        'LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
        'WHERE v.vod_id IN (SELECT vod_id FROM video_actress '
        'WHERE cate_id IN ($inList)) '
        "${useCategory ? "AND COALESCE(vc.main_category, '') = ?" : ''}"
        "${useVideoTag ? 'AND EXISTS (SELECT 1 FROM video_tag vt '
            'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?)' : ''}",
        args,
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    if (videoTag != null && videoTag.isNotEmpty) return 0;
    final useCategory = category != null && category.isNotEmpty;
    final rows = await db.rawQuery(
      useCategory
          ? 'SELECT COUNT(*) AS c FROM works '
                'WHERE person_id = ? AND category = ?'
          : 'SELECT COUNT(*) AS c FROM works WHERE person_id = ?',
      useCategory ? [personId, category] : [personId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Set<String>> distinctWorkKeysForName(String name) async {
    final db = await _open();
    if (!_videoLibraryMode) return const {};
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const {};
    try {
      final rows = await db.rawQuery(
        'SELECT v.vod_id AS vod_id, v.m3u8_url AS m3u8_url, '
        'v.vod_play_url AS vod_play_url FROM videos v '
        'WHERE v.vod_id IN (SELECT vod_id FROM video_actress '
        'WHERE cate_id IN (SELECT cate_id FROM actresses '
        'WHERE name = ?))',
        [trimmed],
      );
      return {
        for (final row in rows)
          '${normalizeAvCode((row['vod_id'] ?? '').toString())}|'
              '${extractPlayUrl(
            (row['m3u8_url']?.toString() ?? '').isNotEmpty
                ? row['m3u8_url']
                : row['vod_play_url'],
          )}',
      };
    } catch (_) {
      return const {};
    }
  }

  /// 全库一级分类（video_category.main_category，去重计数）：
  /// 多库勾选时列表页分类行取各库并集。只读查询，不写盘；
  /// 没有 video_category 表的库直接抛错，调用方跳过。
  @override
  Future<List<(String, int)>> dbCategories() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT main_category, COUNT(*) AS c FROM video_category '
      "WHERE main_category IS NOT NULL AND main_category <> '' "
      'GROUP BY main_category ORDER BY c DESC',
    );
    return [
      for (final row in rows)
        (row['main_category'].toString(), (row['c'] as num).toInt()),
    ];
  }

  /// 全库作品标签（video_tag.tag_name，去重计数，按作品数倒序）：
  /// 标签筛选底部弹窗的数据来源。只读查询，不写盘；没有 video_tag
  /// 表的库直接抛错，调用方跳过（与 dbCategories 同一口径）。
  @override
  Future<List<(String, int)>> dbTags() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT tag_name, COUNT(*) AS c FROM video_tag '
      "WHERE tag_name IS NOT NULL AND tag_name <> '' "
      'GROUP BY tag_name ORDER BY c DESC',
    );
    return [
      for (final row in rows)
        (row['tag_name'].toString(), (row['c'] as num).toInt()),
    ];
  }

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async {
    final db = await _open();
    if (_videoLibraryMode) {
      // 2026-11-22 加载优化：先按 rowid 取同名 cate_id（已索引，
      // 见 _videoCateIdsOf），再与 worksForPerson 同形走
      // IN (SELECT vod_id FROM video_actress …) 取分类。
      // 原来的 videos × video_actress × actresses 三表 JOIN 再
      // GROUP BY，34 万行库上实测 0.9~6.3 秒、抖动大，详情页首屏
      // 被它堵住一直转圈；改后同量级实测 0.02 秒（热缓存）。
      final cateIds = await _videoCateIdsForPerson(db, personId);
      if (cateIds.isEmpty) return const [];
      final inList = _placeholders(cateIds.length);
      final rows = await db.rawQuery(
        "SELECT COALESCE(vc.main_category, '') AS name, "
        'COUNT(*) AS c FROM videos v '
        'LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
        'WHERE v.vod_id IN (SELECT vod_id FROM video_actress '
        'WHERE cate_id IN ($inList)) '
        "AND COALESCE(vc.main_category, '') <> '' "
        // GROUP BY 必须写完整表达式：写别名 name 有歧义（actresses
        // 表也有 name 列），SQLite 会按人名分组、全并成一组。
        "GROUP BY COALESCE(vc.main_category, '') "
        'ORDER BY c DESC, name ASC',
        cateIds,
      );
      return [
        for (final row in rows)
          (
            name: (row['name'] as String?) ?? '',
            count: (row['c'] as num?)?.toInt() ?? 0,
          ),
      ];
    }
    final rows = await db.rawQuery(
      'SELECT category AS name, COUNT(*) AS c FROM works '
      'WHERE person_id = ? AND category <> \'\' '
      'GROUP BY category ORDER BY c DESC, category ASC',
      [personId],
    );
    return [
      for (final row in rows)
        (
          name: (row['name'] as String?) ?? '',
          count: (row['c'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// 读数口径（2026-11-20 计数修复）：列表卡片与详情头顶的
  /// worksCount 一律以 works 表实时行数为准——单次聚合查询覆盖
  /// 本批全部人，覆盖掉 persons.works_count 缓存列的值。
  /// 缓存列仍由各写路径维护、只供 SQL 排序用；显示数与
  /// countWorks() 从此永远是同一份数，不存在“列表一个数、
  /// 详情另一个数”。
  Future<List<ActressPerson>> _withLiveWorksCounts(
    List<ActressPerson> persons,
  ) async {
    if (persons.isEmpty) return persons;
    final db = await _open();
    final ids = persons.map((person) => person.localId).toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT person_id, COUNT(*) AS c FROM works '
      'WHERE person_id IN ($placeholders) GROUP BY person_id',
      ids,
    );
    final counts = <int, int>{
      for (final row in rows)
        (row['person_id'] as num).toInt(): (row['c'] as num).toInt(),
    };
    return [
      for (final person in persons)
        person.copyWith(worksCount: counts[person.localId] ?? 0),
    ];
  }


  @override
  Future<ActressSyncOverview> overview() async {
    final db = await _open();
    // 视频库没有同步，但头顶人数取 overview.personsWithWorks，
    // 必须回实数——否则头顶显示“0 位演员”，而列表本身正常出人。
    // 实数口径与“要入库才算”一致：persons=actresses 总数，
    // works=videos 总数，personsWithWorks=video_actress 里有
    // 链接的不同女优数。
    if (_videoLibraryMode) {
      final personRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM actresses',
      );
      final workRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM videos',
      );
      final withWorksRows = await db.rawQuery(
        'SELECT COUNT(DISTINCT cate_id) AS c FROM video_actress',
      );
      return ActressSyncOverview(
        persons: (personRows.first['c'] as num?)?.toInt() ?? 0,
        works: (workRows.first['c'] as num?)?.toInt() ?? 0,
        personsWithWorks: (withWorksRows.first['c'] as num?)?.toInt() ?? 0,
        sources: const {},
        lastUpdatedAt: 0,
      );
    }
    final personRows = await db.rawQuery('SELECT COUNT(*) AS c FROM persons');
    final workRows = await db.rawQuery('SELECT COUNT(*) AS c FROM works');
    final withWorksRows = await db.rawQuery(
      'SELECT COUNT(DISTINCT person_id) AS c FROM works',
    );
    final updatedRows = await db.rawQuery(
      'SELECT MAX(updated_at) AS m FROM persons',
    );
    // 同步已删（2026-11-26）：不再有检查点，sources 恒空。
    return ActressSyncOverview(
      persons: (personRows.first['c'] as num?)?.toInt() ?? 0,
      works: (workRows.first['c'] as num?)?.toInt() ?? 0,
      personsWithWorks: (withWorksRows.first['c'] as num?)?.toInt() ?? 0,
      sources: const {},
      lastUpdatedAt: (updatedRows.first['m'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    // 2026-11-20 MYTV 绑定：close 后再开必须重新走 _openNow
    // 拿新路径（授权后重新绑定换库用）。原来只清 _db 不清
    // _openFuture，close 后再开会拿到已关闭的旧库。
    _openFuture = null;
    // 2026-11-20 热换库：指纹与通用缓存也清掉，下次开库重探。
    _openedPath = null;
    _openedSignature = null;
    _genericReaderCache = null;
    _genericReaderKey = null;
    // 2026-11-21 视频库：标志也清掉，下次开库由 _openDbAt 重算，
    // 不让旧标志挂在新库上。
    _videoLibraryMode = false;
    // 名单内存汇总挂在连接上：关库一并清，下次开库重建。
    _personSummary = null;
    _personSummaryDb = null;
    _personSummaryFuture = null;
    _personSummaryDatesLoaded = false;
    await db?.close();
  }
}

/// 内存实现：测试与预览用，与 sqflite 实现同一语义（合并、去重、
/// 断点、进度口径一致；SQL 层本身只在真机上跑）。
class MemoryActressDatabase implements ActressDatabase {
  final _persons = <int, ActressPerson>{};
  final _nameIndex = <String, int>{};
  final _works = <int, ActressWork>{};
  final _filmsState = <String, bool>{};
  final _checkpoints = <String, ActressSyncCheckpoint>{};

  /// 作品标签（测试用，镜像 video_tag 表）：番号键 → 标签集合。
  /// RosterFilm 没有标签字段，测试用 [setWorkTagsForCode] 另行登记。
  final _workTags = <String, Set<String>>{};

  /// 测试用：给某番号登记作品标签（与 video_tag 表同一口径，
  /// 番号键用归一化后的 codeKey）。
  void setWorkTagsForCode(String codeKey, List<String> tags) {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return;
    _workTags[key] = {...tags.where((t) => t.isNotEmpty)};
  }

  bool _workHasVideoTag(ActressWork work, String videoTag) {
    if (videoTag.isEmpty) return true;
    final tags = _workTags[normalizeAvCode(work.codeKey)];
    return tags != null && tags.contains(videoTag);
  }

  /// 内存库永远不是视频库（视频库只走 SqfliteActressDatabase）。
  @override
  bool get isVideoLibrary => false;

  /// 内存库没有 videos 表：空操作。
  Future<void> upsertVideoEntries(List<VideoLibraryEntry> entries) async {}

  /// 全站叠加断点在检查点表里的键（与三家名册源的键分开）。
  static const _stackingCheckpointKey =
      '$actressStackingCheckpointSource:$actressStackingCheckpointPhase';
  int _nextPersonId = 1;
  int _nextWorkId = 1;

  Future<ActressPerson?> upsertRosterPerson(RosterPerson roster) async {
    final variants = actressNameVariants(roster.name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        roster.tags.any(actressTextBlocked) ||
        roster.aliases.any(actressTextBlocked) ||
        roster.about.entries.any(
          (entry) =>
              actressTextBlocked(entry.key) || actressTextBlocked(entry.value),
        )) {
      return null;
    }
    ActressPerson? existing;
    for (final variant in variants) {
      final id = _nameIndex[actressNameKey(variant)];
      if (id != null && _persons.containsKey(id)) {
        existing = _persons[id];
        break;
      }
    }
    final merged = mergeRosterIntoPerson(existing, roster);
    final stored = existing == null
        ? merged.copyWith(localId: _nextPersonId++)
        : merged.copyWith(localId: existing.localId);
    _persons[stored.localId] = stored;
    final keys = <String>{
      actressNameKey(stored.displayName),
      for (final alias in stored.aliases) actressNameKey(alias),
      for (final variant in variants) actressNameKey(variant),
    };
    for (final key in keys) {
      if (key.isNotEmpty) _nameIndex[key] = stored.localId;
    }
    return stored;
  }

  Future<ActressPerson?> upsertCrawledPerson({
    required String name,
    String sex = '',
    List<String> tags = const [],
    String avatarUrl = '',
  }) async {
    final variants = actressNameVariants(name);
    if (variants.isEmpty) return null;
    if (variants.any(actressTextBlocked) ||
        tags.any(actressTextBlocked)) {
      return null;
    }
    ActressPerson? existing;
    for (final variant in variants) {
      final id = _nameIndex[actressNameKey(variant)];
      if (id != null && _persons.containsKey(id)) {
        existing = _persons[id];
        break;
      }
    }
    final ActressPerson merged;
    if (existing == null) {
      merged = ActressPerson(
        displayName: variants.first,
        aliases: variants.skip(1).toList(),
        sex: sex,
        avatarUrl: avatarUrl,
        tags: tags,
      );
    } else {
      final aliasKeys = <String>{
        actressNameKey(existing.displayName),
        for (final alias in existing.aliases) actressNameKey(alias),
      };
      final extra = <String>[];
      for (final variant in variants) {
        if (aliasKeys.add(actressNameKey(variant))) extra.add(variant);
      }
      merged = existing.copyWith(
        aliases: [...existing.aliases, ...extra],
        sex: existing.sex.isNotEmpty ? existing.sex : sex,
        avatarUrl: preferLoadableAvatar(existing.avatarUrl, avatarUrl),
        tags: <String>{...existing.tags, ...tags}.toList(),
      );
    }
    final stored = existing == null
        ? merged.copyWith(localId: _nextPersonId++)
        : merged.copyWith(localId: existing.localId);
    _persons[stored.localId] = stored;
    final keys = <String>{
      actressNameKey(stored.displayName),
      for (final alias in stored.aliases) actressNameKey(alias),
      for (final variant in variants) actressNameKey(variant),
    };
    for (final key in keys) {
      if (key.isNotEmpty) _nameIndex[key] = stored.localId;
    }
    return stored;
  }

  @override
  Future<ActressPerson?> personById(int localId) async {
    final person = _persons[localId];
    return person == null ? null : _withLiveWorksCount(person);
  }

  bool _sexMatches(ActressPerson person, ActressSexFilter sex) => switch (sex) {
    ActressSexFilter.all => true,
    ActressSexFilter.female => person.sex == 'female',
    ActressSexFilter.male => person.sex == 'male',
  };

  bool _queryMatches(ActressPerson person, String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return true;
    if (person.displayName.contains(trimmed)) return true;
    if (person.aliases.any((alias) => alias.contains(trimmed))) return true;
    final key = actressNameKey(trimmed);
    if (key.isNotEmpty) {
      final keys = <String>{
        actressNameKey(person.displayName),
        for (final alias in person.aliases) actressNameKey(alias),
      };
      if (keys.any((candidate) => candidate.contains(key))) return true;
    }
    // 番号搜索：与 SQL 版同一口径，作品番号键模糊匹配。
    final codeKey = actressCodeQueryKey(trimmed);
    if (codeKey != null) {
      return _works.values.any(
        (work) =>
            work.personId == person.localId &&
            work.codeKey.contains(codeKey),
      );
    }
    return false;
  }

  List<ActressPerson> _filtered({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String category = '',
  }) => _persons.values
      .where(
        (person) =>
            _sexMatches(person, sex) &&
            _queryMatches(person, query) &&
            (tag.isEmpty || person.tags.contains(tag)) &&
            (category.isEmpty ||
                _works.values.any(
                  (work) =>
                      work.personId == person.localId &&
                      work.category == category,
                )),
      )
      .toList();

  @override
  Future<List<ActressPerson>> listPersons({
    required ActressSexFilter sex,
    required ActressSort sort,
    required String query,
    required int offset,
    required int limit,
    String tag = '',
    String category = '',
    String videoTag = '',
  }) async {
    final filtered = _filtered(
      sex: sex,
      query: query,
      tag: tag,
      category: category,
    ).where(
      // 作品标签：只留有该标签作品的人（与严格库 video_tag
      // EXISTS 同一口径）。
      (person) =>
          videoTag.isEmpty ||
          _works.values.any(
            (work) =>
                work.personId == person.localId &&
                _workHasVideoTag(work, videoTag),
          ),
    ).toList();
    switch (sort) {
      case ActressSort.worksDesc:
        filtered.sort((a, b) {
          final works = b.displayWorks.compareTo(a.displayWorks);
          if (works != 0) return works;
          return a.displayName.compareTo(b.displayName);
        });
      case ActressSort.nameAsc:
        filtered.sort((a, b) => a.displayName.compareTo(b.displayName));
      case ActressSort.recentDesc:
        // 最近更新：每人入库作品里最新作品日期倒序，无入库作品的
        // 人日期为空串、倒序沉底；同日按名字。只算库里实际有的。
        final latest = <int, String>{};
        for (final work in _works.values) {
          final current = latest[work.personId] ?? '';
          if (work.date.compareTo(current) > 0) {
            latest[work.personId] = work.date;
          }
        }
        filtered.sort((a, b) {
          final cmp = (latest[b.localId] ?? '').compareTo(
            latest[a.localId] ?? '',
          );
          if (cmp != 0) return cmp;
          return a.displayName.compareTo(b.displayName);
        });
    }
    if (offset >= filtered.length) return const [];
    return filtered
        .skip(offset)
        .take(limit)
        .map(_withLiveWorksCount)
        .toList();
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String videoTag = '',
  }) async {
    if (videoTag.isEmpty) {
      return _filtered(sex: sex, query: query, tag: tag).length;
    }
    return _filtered(
      sex: sex,
      query: query,
      tag: tag,
    ).where(
      (person) => _works.values.any(
        (work) =>
            work.personId == person.localId &&
            _workHasVideoTag(work, videoTag),
      ),
    ).length;
  }

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async {
    final filtered =
        _persons.values
            .where((person) => _sexMatches(person, sex))
            .map(_withLiveWorksCount)
            .toList()
          ..sort(compareActressRank);
    return filtered;
  }

  Future<void> setMissavRank(int personId, int rank) async {
    final person = _persons[personId];
    if (person == null) return;
    final current = person.missavRank;
    if (current == null || rank < current) {
      _persons[personId] = person.copyWith(missavRank: rank);
    }
  }

  Future<void> setWhosRank(int personId, int rank) async {
    final person = _persons[personId];
    if (person == null) return;
    final current = person.whosRank;
    if (current == null || rank < current) {
      _persons[personId] = person.copyWith(whosRank: rank);
    }
  }

  Future<void> setPersonAbout(int personId, Map<String, String> about) async {
    final person = _persons[personId];
    if (person == null) return;
    final clean = <String, String>{};
    for (final entry in about.entries) {
      if (actressTextBlocked(entry.key) || actressTextBlocked(entry.value)) {
        continue;
      }
      clean[entry.key] = entry.value;
    }
    if (clean.isEmpty) return;
    _persons[personId] = person.copyWith(
      about: {...clean, ...person.about},
    );
  }

  @override
  Future<List<ActressWork>> worksForPerson(
    int personId, {
    required int offset,
    required int limit,
    String? category,
    String? videoTag,
  }) async {
    final useCategory = category != null && category.isNotEmpty;
    final useVideoTag = videoTag != null && videoTag.isNotEmpty;
    final wantedTag = videoTag ?? '';
    final works = _works.values
        .where((work) => work.personId == personId)
        .where((work) => !useCategory || work.category == category)
        .where(
          (work) => !useVideoTag || _workHasVideoTag(work, wantedTag),
        )
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (offset >= works.length) return const [];
    return works.skip(offset).take(limit).toList();
  }

  @override
  Future<int> countWorks(int personId, {String? category, String? videoTag}) async {
    final useCategory = category != null && category.isNotEmpty;
    final useVideoTag = videoTag != null && videoTag.isNotEmpty;
    final wantedTag = videoTag ?? '';
    return _works.values
        .where((work) => work.personId == personId)
        .where((work) => !useCategory || work.category == category)
        .where(
          (work) => !useVideoTag || _workHasVideoTag(work, wantedTag),
        )
        .length;
  }

  @override
  Future<Set<String>> distinctWorkKeysForName(String name) async {
    // 内存库没有 videos 表（没有播放链接）：只按番号键去重。
    int? personId;
    for (final person in _persons.values) {
      if (person.displayName == name) {
        personId = person.localId;
        break;
      }
    }
    if (personId == null) return const {};
    return {
      for (final work in _works.values)
        if (work.personId == personId) '${work.codeKey}|',
    };
  }

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async {
    final counts = <String, int>{};
    for (final work in _works.values) {
      if (work.personId != personId) continue;
      if (work.category.isEmpty) continue;
      counts[work.category] = (counts[work.category] ?? 0) + 1;
    }
    final out = [
      for (final entry in counts.entries)
        (name: entry.key, count: entry.value),
    ];
    out.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      if (byCount != 0) return byCount;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  /// 内存库没有全库分类表：回空集（多库合并时跳过）。
  @override
  Future<List<(String, int)>> dbCategories() async => const [];

  /// 内存库作品标签计数（按登记的 _workTags × 入库作品现算，
  /// 作品数倒序、同数按名字排；没有登记的标签不出现）。
  @override
  Future<List<(String, int)>> dbTags() async {
    final counts = <String, int>{};
    for (final work in _works.values) {
      final tags = _workTags[normalizeAvCode(work.codeKey)];
      if (tags == null) continue;
      for (final tag in tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    return [for (final e in entries) (e.key, e.value)];
  }

  void _refreshWorksCount(int personId) {
    final person = _persons[personId];
    if (person == null) return;
    final count = _works.values
        .where((work) => work.personId == personId)
        .length;
    _persons[personId] = person.copyWith(worksCount: count);
  }

  /// 读数口径（2026-11-20 计数修复，与 sqflite 实现同一口径）：
  /// 列表卡片与详情头顶的 worksCount 一律以 works 表实时行数为准，
  /// 读时现算，不拿存着的 worksCount 字段充数；显示数与
  /// countWorks() 永远是同一份数。
  ActressPerson _withLiveWorksCount(ActressPerson person) =>
      person.copyWith(
        worksCount: _works.values
            .where((work) => work.personId == person.localId)
            .length,
      );

  Future<void> upsertWorks(
    int personId,
    List<RosterFilm> films, {
    String coverSource = 'whos',
    String site = '',
  }) async {
    for (final film in films) {
      if (actressTextBlocked(film.code) || actressTextBlocked(film.title)) {
        continue;
      }
      final codeKey = film.codeKey;
      final titleKey = film.titleKey;
      if (codeKey.isEmpty && titleKey.isEmpty) continue;
      // 去重键是（人，站，番号/标题）：同站同番号冲突即丢弃，
      // 换站同番号不冲突，各留一条；冲突行只做分类回填（旧行没记
      // 分类、新数据带真实分类时补上，已有分类的不覆盖）。
      ActressWork? existing;
      for (final work in _works.values) {
        if (work.personId != personId) continue;
        if (work.site != site) continue;
        if (codeKey.isNotEmpty) {
          if (work.codeKey == codeKey) existing = work;
        } else if (work.codeKey.isEmpty && work.titleKey == titleKey) {
          existing = work;
        }
        if (existing != null) break;
      }
      if (existing != null) {
        if (existing.category.isEmpty && film.category.isNotEmpty) {
          _works[existing.id] = existing.copyWith(
            category: film.category,
          );
        }
        continue;
      }
      final codeDisplay = film.code.trim();
      final title = film.title.trim();
      _works[_nextWorkId] = ActressWork(
        id: _nextWorkId++,
        personId: personId,
        codeKey: codeKey,
        titleKey: titleKey,
        site: site,
        codeDisplay: codeDisplay,
        title: title == codeDisplay ? '' : title,
        date: film.date.trim(),
        category: film.category,
        // 同步时已取到的封面：开关关闭/无图/来源站为空时三字段恒为空；
        // 封面来源站按调用方传入的 [coverSource] 写，不再写死。
        coverSource: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : coverSource,
        coverDramaId: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : film.detailUrl,
        coverUrl: film.coverUrl.isEmpty || coverSource.isEmpty
            ? ''
            : film.coverUrl,
      );
    }
    _refreshWorksCount(personId);
  }

  Future<void> attachCover({
    required int personId,
    required String codeKey,
    required String titleKey,
    String codeDisplay = '',
    String title = '',
    String date = '',
    required String coverSource,
    required String coverDramaId,
    required String coverUrl,
    bool insertIfMissing = true,
    String site = '',
  }) async {
    if (actressTextBlocked(title) || actressTextBlocked(codeDisplay)) return;
    if (codeKey.isEmpty && titleKey.isEmpty) return;
    bool matches(ActressWork work) {
      if (work.personId != personId) return false;
      if (codeKey.isNotEmpty) return work.codeKey == codeKey;
      return work.codeKey.isEmpty && work.titleKey == titleKey;
    }

    ActressWork? sameSite;
    ActressWork? anySite;
    for (final work in _works.values) {
      if (!matches(work)) continue;
      anySite ??= work;
      if (work.site == site) {
        sameSite = work;
        break;
      }
    }
    // 1）同站行优先：封面/标题/日期只补空位。
    if (sameSite != null) {
      _works[sameSite.id] = sameSite.copyWith(
        coverSource: sameSite.coverUrl.isEmpty
            ? coverSource
            : sameSite.coverSource,
        coverDramaId: sameSite.coverUrl.isEmpty
            ? coverDramaId
            : sameSite.coverDramaId,
        coverUrl: sameSite.coverUrl.isEmpty ? coverUrl : sameSite.coverUrl,
        title: sameSite.title.isEmpty && title.isNotEmpty
            ? title
            : sameSite.title,
        date: sameSite.date.isEmpty && date.isNotEmpty
            ? date
            : sameSite.date,
      );
      _refreshWorksCount(personId);
      return;
    }
    // 2）同站没有：退到该番号任意站的行，只补封面，不挪行。
    if (anySite != null) {
      if (anySite.site.isEmpty) {
        // 旧库行没记站（站未知）：认领到本次命中站名下，封面/
        // 标题/日期只补空位，不新增第二行（名字路只附已有行）。
        _works[anySite.id] = anySite.copyWith(
          site: site,
          coverSource: anySite.coverUrl.isEmpty
              ? coverSource
              : anySite.coverSource,
          coverDramaId: anySite.coverUrl.isEmpty
              ? coverDramaId
              : anySite.coverDramaId,
          coverUrl: anySite.coverUrl.isEmpty ? coverUrl : anySite.coverUrl,
          title: anySite.title.isEmpty && title.isNotEmpty
              ? title
              : anySite.title,
          date: anySite.date.isEmpty && date.isNotEmpty
              ? date
              : anySite.date,
        );
      } else {
        if (anySite.coverUrl.isEmpty) {
          _works[anySite.id] = anySite.copyWith(
            coverSource: coverSource,
            coverDramaId: coverDramaId,
            coverUrl: coverUrl,
          );
        }
        // 找到的行站 ≠ 传入站且允许新增时，按传入站新增一行：
        // 同番号两站各留一条，各算一条可播线路。
        if (insertIfMissing && site.isNotEmpty && anySite.site != site) {
          _works[_nextWorkId] = ActressWork(
            id: _nextWorkId++,
            personId: personId,
            codeKey: codeKey,
            titleKey: titleKey,
            site: site,
            codeDisplay: codeDisplay,
            title: title,
            date: date,
            coverSource: coverSource,
            coverDramaId: coverDramaId,
            coverUrl: coverUrl,
            fromCrossSite: true,
          );
        }
      }
      _refreshWorksCount(personId);
      return;
    }
    // 3）无行：按 insertIfMissing 决定是否按传入站新增一行。
    if (!insertIfMissing) return;
    _works[_nextWorkId] = ActressWork(
      id: _nextWorkId++,
      personId: personId,
      codeKey: codeKey,
      titleKey: titleKey,
      site: site,
      codeDisplay: codeDisplay,
      title: title,
      date: date,
      coverSource: coverSource,
      coverDramaId: coverDramaId,
      coverUrl: coverUrl,
      fromCrossSite: true,
    );
    _refreshWorksCount(personId);
  }

  Future<List<ActressPerson>> personsPendingFilms(
    ActressRosterSourceId source,
  ) async {
    final pending =
        _persons.values
            .where(
              (person) =>
                  person.hasSource(source) &&
                  _filmsState['${person.localId}:${source.name}'] != true,
            )
            .toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return pending;
  }

  Future<List<ActressPerson>> personsNeedingFilmsRepair(
    ActressRosterSourceId source,
  ) async {
    final repair =
        _persons.values
            .where(
              (person) =>
                  person.hasSource(source) &&
                  _filmsState['${person.localId}:${source.name}'] == true &&
                  !_works.values.any(
                    (work) => work.personId == person.localId,
                  ),
            )
            .toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return repair;
  }

  Future<({int done, int total})> filmsProgress(
    ActressRosterSourceId source,
  ) async {
    final total = _persons.values.where((p) => p.hasSource(source)).length;
    final done = _persons.values
        .where(
          (p) =>
              p.hasSource(source) &&
              _filmsState['${p.localId}:${source.name}'] == true,
        )
        .length;
    return (done: done, total: total);
  }

  Future<void> markFilmsState(
    int personId,
    ActressRosterSourceId source, {
    required bool ok,
  }) async {
    _filmsState['$personId:${source.name}'] = ok;
    if (ok) {
      final person = _persons[personId];
      if (person != null && person.filmsSyncedAt == null) {
        _persons[personId] = person.copyWith(
          filmsSyncedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }
  }

  Future<void> markEnriched(int personId) async {
    final person = _persons[personId];
    if (person != null) {
      _persons[personId] = person.copyWith(
        enrichedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  Future<List<ActressPerson>> personsAfterId({
    required int afterId,
    required int limit,
  }) async {
    final persons =
        _persons.values.where((person) => person.localId > afterId).toList()
          ..sort((a, b) => a.localId.compareTo(b.localId));
    return persons.take(limit).toList();
  }

  Future<ActressSyncCheckpoint?> stackingCheckpoint() async =>
      _checkpoints[_stackingCheckpointKey];

  Future<void> saveStackingCheckpoint(ActressSyncCheckpoint checkpoint) async {
    _checkpoints[_stackingCheckpointKey] = ActressSyncCheckpoint(
      source: actressStackingCheckpointSource,
      phase: actressStackingCheckpointPhase,
      cursor: checkpoint.cursor,
      total: checkpoint.total,
      finished: checkpoint.finished,
      error: checkpoint.error,
      updatedAt: checkpoint.updatedAt,
    );
  }

  Future<ActressSyncCheckpoint?> checkpoint(
    ActressRosterSourceId source,
    String phase,
  ) async => _checkpoints['${source.name}:$phase'];

  Future<void> saveCheckpoint(ActressSyncCheckpoint checkpoint) async {
    _checkpoints['${checkpoint.source}:${checkpoint.phase}'] = checkpoint;
  }

  Future<String?> jsonVersionStamp() async =>
      _checkpoints['actress_json:version']?.cursor;

  Future<void> saveJsonVersionStamp(String version) async {
    _checkpoints['actress_json:version'] = ActressSyncCheckpoint(
      source: 'actress_json',
      phase: 'version',
      cursor: version,
      finished: true,
    );
  }

  @override
  Future<ActressSyncOverview> overview() async {
    final sources = <ActressRosterSourceId, bool>{};
    for (final source in ActressRosterSourceId.values) {
      var done = true;
      for (final phase in ['roster', 'films']) {
        final cp = _checkpoints['${source.name}:$phase'];
        if (cp == null || !cp.finished) {
          done = false;
          break;
        }
      }
      sources[source] = done;
    }
    return ActressSyncOverview(
      persons: _persons.length,
      works: _works.length,
      personsWithWorks: {
        for (final work in _works.values) work.personId,
      }.length,
      sources: sources,
      lastUpdatedAt: 0,
    );
  }

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async => (reloaded: false, error: null);

  @override
  Future<GenericDbReader?> genericReader() async => null;

  @override
  String? get openFallbackNote => null;

  @override
  Future<void> close() async {}
}
