import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart';
import 'actress_db_fields_page.dart';
import 'actress_generic_db.dart';
import 'actress_json_fallback.dart';
import 'actress_models.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_adapter_models.dart';
import 'actress_adapter_player.dart';

/// 影视库分类（2026-11-20 用户令）：根据用户放进 MYTV/db 的
/// 女优库.db 新增的影视库分类。
///
/// 读库分两路，走 MYTV 绑定那批的通用读库层（actress_generic_db.dart），
/// 本文件不另起字段映射：
/// - 女优库结构（videos/actresses/video_actress/video_category）：
///   严格路径，本文件直接 SQL 读（女优名、分类、站点全取到）；
/// - 别的结构：走 [ActressDatabase.genericReader]，动态探表与字段、
///   启发式映射；认不出的表进“数据库字段”页由用户手动指定。
/// 播放地址取值（正片$、JSON、$$$/# 分隔）与换库重读以通用层为准，
/// 本文件只用 [extractPlayUrl] 与 [GenericDbReader]，不自写解析。
/// 播放走现有链：条目转兜底条目（单集“正片”，集 id 即直链），
/// 潮流蜘蛛 playerContent 原始分支原样回 parse=0 直链 + dict 头。
///
/// 2026-11-26 只读化（用户令删同步/写入）：本文件全只读——开库
/// 只读连接 + 只读 PRAGMA 组；原先的域名批量替换、失效链接自动
/// 修复写回、递增追加进女优库与 sidecar 状态文件整套已删，库内容
/// 变更只经换库文件；域名只从库里地址现算，探活只提示不写回。

/// 合并番号键（与离线合并脚本 merge.py 的 norm_code 同一口径，
/// 两边改了要同步）：小写、从第一个非 [a-z0-9-] 处截断、去掉
/// -uncensored-leak/-uncensored/-leak 后缀。
/// 注意它与 [normalizeAvCode] 不同：后者去全部非字母数字并去前导零
/// （SSIS-00123 → SSIS123），是库内 works 去重口径；这里是
/// videos 表 slug 口径（mvsd-546、jul-893），不要混用。
String filmSlugCode(String raw) {
  final lower = raw.trim().toLowerCase();
  final match = RegExp(r'[a-z0-9]+(?:-[a-z0-9]+)*').firstMatch(lower);
  var code = match?.group(0) ?? '';
  for (final suffix in ['-uncensored-leak', '-uncensored', '-leak']) {
    while (code.endsWith(suffix)) {
      code = code.substring(0, code.length - suffix.length);
    }
  }
  return code.trim().replaceAll(RegExp(r'-+$'), '');
}

/// 播放来源名 → 站 id：whos.tv/mjv011 归一到 whos/mjv，其余原样
/// （小写去空白）。找不到对应站时修链接流程按“无对应站点”跳过，
/// 不瞎猜。
String filmSiteId(String playFrom) {
  final s = playFrom.trim().toLowerCase();
  if (s == 'whos.tv' || s == 'whos' || s == 'www.whos.tv') return 'whos';
  if (s == 'mjv011' || s == 'mjv' || s == 'mjv011.com') return 'mjv';
  return s;
}

/// 播放地址的域名（host）：取不到、不是 http(s) 时返回 ''。
String filmPlayHost(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasAuthority) return '';
  if (uri.scheme != 'http' && uri.scheme != 'https') return '';
  return uri.host.toLowerCase();
}

/// 探出来的结构是不是女优库 videos 严格结构：作品表是 videos，
/// 且有 video_actress（女优关联）与 video_category（主分类）。
bool filmIsStrictVideosSchema(GenericDbSchema schema) {
  final works = schema.worksTable;
  if (works == null || works.table != 'videos') return false;
  final tables = {for (final t in schema.tables) t.table};
  return tables.contains('video_actress') && tables.contains('video_category');
}

/// 影视库统一条目：严格路径 SQL 行与通用路径 [GenericDbWork] 都
/// 转成它，列表/详情/修复共用。
class FilmLibraryEntry {
  const FilmLibraryEntry({
    required this.vodId,
    required this.title,
    this.coverUrl = '',
    this.playUrl = '',
    this.actress = '',
    this.code = '',
    this.category = '',
    this.site = '',
    this.date = '',
    this.remarks = '',
    this.typeName = '',
    this.content = '',
  });

  /// 行主键：videos 表是 vod_id slug；通用表是行 id（或标题）。
  final String vodId;
  final String title;
  final String coverUrl;
  final String playUrl;
  final String actress;
  final String code;
  final String category;
  final String site;
  final String date;
  final String remarks;
  final String typeName;

  /// 剧情简介原文（videos.vod_content，含 HTML 标签，显示时去标签）。
  final String content;

  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  String get displayTitle => title.isNotEmpty ? title : code;

  String get displaySubtitle {
    final parts = <String>[];
    if (actress.isNotEmpty) parts.add(actress);
    if (code.isNotEmpty && code != title) parts.add(code);
    if (category.isNotEmpty) parts.add(category);
    if (date.isNotEmpty) parts.add(date);
    return parts.join(' · ');
  }

  /// 转成兜底条目走现有播放链：单集“正片”，集 id 即直链地址；
  /// mjv/whos 走潮流蜘蛛原始分支 parse=0 直通，其余站走本站蜘蛛。
  ActressJsonEntry toJsonEntry() => ActressJsonEntry(
    site: filmSiteId(site).isEmpty ? 'chaoliu' : filmSiteId(site),
    vodId: vodId,
    vodName: title,
    vodPic: coverUrl,
    // 镜像按 [,，、] 拆女优名：库里多人以 ' / ' 连着，写进镜像前
    // 转成 '、'，否则多人会被当成一个女优名（2026-11-20 19:01 追加）。
    vodActor: actress.replaceAll(RegExp(r'\s*/\s*'), '、'),
    vodDirector: '',
    vodRemarks: remarks.isNotEmpty ? remarks : '高清',
    vodPubdate: date,
    vodArea: '',
    vodYear: '',
    vodContent: content,
    vodPlayFrom: site,
    vodPlayUrl: '正片\$$playUrl',
    typeName: typeName.isNotEmpty ? typeName : category,
    vodCode: code,
    vodActressPic: '',
    // 库里存的就是 m3u8 直链：标记 direct，播放时内核直接用它开播，
    // 不再绕站源解析（站源挂了/没这个番号也照播）。
    directPlay: playable,
  );

  DramaDetail toDramaDetail() => toJsonEntry().toDramaDetail();
}

/// 影视库打开结果。
class FilmLibraryOpenResult {
  const FilmLibraryOpenResult({
    required this.dbPath,
    required this.displayPath,
    required this.strict,
    required this.total,
    required this.schema,
    required this.domain,
    this.error,
  });

  /// 实际打开的库文件路径。
  final String dbPath;

  /// 界面显示的落点（MYTV/db/女优库.db，或未找到外置数据库）。
  final String displayPath;

  /// true = 女优库 videos 严格结构（分类/站点/女优筛选全有）；
  /// false = 通用结构（只按通用映射读作品）。
  final bool strict;

  /// 作品总数（打不开/无作品表时为 0）。
  final int total;

  final GenericDbSchema schema;

  /// 当前播放域名（打开时从库里地址现算的主域名）。
  final String domain;

  /// 打不开的原因（能打开时为 null）。
  final String? error;
}

/// 影视库服务：打开绑定库、列表/筛选/计数，全只读（2026-11-26
/// 只读化：域名批量替换、失效链接修复写回、递增追加整套已删）。
/// 同时是兜底提供方（implements FilmDbFallbackProvider）：详情页/
/// 播放兜底先查本库。
class FilmLibraryService implements FilmDbFallbackProvider {
  FilmLibraryService({required this.database});

  final ActressDatabase database;

  Database? _readDb;
  GenericDbSchema? _schema;
  String? _dbPath;
  String? _displayPath;
  GenericDbReader? _genericReader;

  /// video_tag 表存在性探测缓存（2026-11-25 读库提速：表结构探测
  /// 的映射）：typeFolders/listFilms/countFilms 每次都查一次
  /// sqlite_master，同一连接上表结构不会变，记下来只探一次；
  /// close() 时清掉，下次 open 重探。
  bool? _hasVideoTagTableCache;

  bool get isOpen => _readDb != null;

  /// 严格结构（女优库 videos 表）时为 true。
  bool get isStrict => _schema != null && filmIsStrictVideosSchema(_schema!);

  GenericDbSchema? get schema => _schema;

  String get dbPath => _dbPath ?? '';

  String get displayPath => _displayPath ?? '';

  String get fingerprint => _schema?.fingerprint ?? '';

  GenericDbReader? get genericReader => _genericReader;

  /// 打开绑定的影视库文件（只读连接；换库后重读以绑定层为准）。
  /// 当前域名打开时从库里地址现算（前 200 条的众数），只读不写。
  Future<FilmLibraryOpenResult> open() async {
    await close();
    final bind = await ActressMytvBind.instance.ensureBound();
    final dbPath = bind.dbPath;
    _dbPath = dbPath;
    _displayPath = bind.displayPath;
    if (dbPath.isEmpty) {
      return FilmLibraryOpenResult(
        dbPath: dbPath,
        displayPath: bind.displayPath,
        strict: false,
        total: 0,
        schema: const GenericDbSchema(tables: [], fingerprint: ''),
        domain: '',
        error: '未找到外置数据库：MYTV/db/女优库.db',
      );
    }
    final file = File(dbPath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return FilmLibraryOpenResult(
        dbPath: dbPath,
        displayPath: bind.displayPath,
        strict: false,
        total: 0,
        schema: const GenericDbSchema(tables: [], fingerprint: ''),
        domain: '',
        error: '库文件不存在或为空：$dbPath',
      );
    }
    final db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
      onOpen: applyActressDbReadPragmas,
    );
    _readDb = db;
    final schema = await probeGenericDbSchema(db);
    _schema = schema;
    final strict = filmIsStrictVideosSchema(schema);
    GenericDbReader? generic;
    if (!strict) {
      generic = await database.genericReader();
      _genericReader = generic;
    }
    final total = await countFilms();
    final domain = await _currentDomainFromDb();
    return FilmLibraryOpenResult(
      dbPath: dbPath,
      displayPath: bind.displayPath,
      strict: strict,
      total: total,
      schema: schema,
      domain: domain,
    );
  }

  Future<void> close() async {
    final db = _readDb;
    _readDb = null;
    _schema = null;
    _genericReader = null;
    _filmActressNames = null;
    _hasVideoTagTableCache = null;
    await db?.close();
  }

  /// 库里实际主域名（公开给播放链判域名是否变化用）：严格结构取
  /// m3u8_url 前 200 条非空地址的众数；通用结构取通用读出的前
  /// 200 条作品的播放地址众数。
  Future<String> currentDomainFromDb() => _currentDomainFromDb();

  /// 库里实际主域名：严格结构取 m3u8_url 前 200 条非空地址的众数；
  /// 通用结构取通用读出的前 200 条作品的播放地址众数。
  Future<String> _currentDomainFromDb() async {
    final hosts = <String, int>{};
    void add(String url) {
      final host = filmPlayHost(url);
      if (host.isEmpty) return;
      hosts[host] = (hosts[host] ?? 0) + 1;
    }

    if (isStrict) {
      final db = _readDb;
      if (db != null) {
        final rows = await db.rawQuery(
          'SELECT m3u8_url FROM videos WHERE m3u8_url IS NOT NULL '
          'AND m3u8_url <> \'\' LIMIT 200',
        );
        for (final row in rows) {
          add(row['m3u8_url']?.toString() ?? '');
        }
      }
    } else {
      final reader = _genericReader;
      if (reader != null) {
        final works = await reader.works(offset: 0, limit: 200);
        for (final work in works) {
          add(work.playUrl);
        }
      }
    }
    if (hosts.isEmpty) return '';
    return hosts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  /// 分类列表：严格结构读 video_category 的主分类（按数量倒序）；
  /// 通用结构从映射的分类列取前 1000 条作品的去重分类。
  Future<List<(String, int)>> categories() async {
    final db = _readDb;
    if (db == null) return [];
    if (isStrict) {
      final rows = await db.rawQuery(
        'SELECT main_category, COUNT(*) AS c FROM video_category '
        'WHERE main_category IS NOT NULL AND main_category <> \'\' '
        'GROUP BY main_category ORDER BY c DESC',
      );
      return [
        for (final row in rows)
          (row['main_category'].toString(), (row['c'] as num).toInt()),
      ];
    }
    final reader = _genericReader;
    if (reader == null) return [];
    final counts = <String, int>{};
    final works = await reader.works(offset: 0, limit: 1000);
    for (final work in works) {
      if (work.category.isEmpty) continue;
      counts[work.category] = (counts[work.category] ?? 0) + 1;
    }
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in list) (e.key, e.value)];
  }

  /// 站点列表：严格结构读 videos.vod_play_from 去重；通用结构没有
  /// 站点列，返回空（界面不显示站点筛选）。
  Future<List<String>> sites() async {
    final db = _readDb;
    if (db == null || !isStrict) return [];
    final rows = await db.rawQuery(
      'SELECT DISTINCT vod_play_from FROM videos '
      'WHERE vod_play_from IS NOT NULL AND vod_play_from <> \'\' '
      'ORDER BY vod_play_from',
    );
    return [for (final row in rows) row['vod_play_from'].toString()];
  }

  /// 类型文件夹（2026-11-24 文件夹视图）：按 videos.type_name
  /// 分组计数（成人影片/国产精品/无码专区…，女优库 v3 实查 26 个
  /// 类型，总和 449,068），从多到少。注意它与 video_category
  /// 主分类（有码/无码/国产…）是两套不同的维度，别混。
  /// 选了标签时 [videoTag] 只算带该标签的作品（video_tag 表
  /// EXISTS 半连接；库里没有 video_tag 表时带标签的作品一条都
  /// 筛不出来，回空、不抛错、不暗地里回未过滤的数）；[category]
  /// 是 video_category 主分类（与标签 AND）。
  /// 通用结构走读库的 [GenericDbReader.typeNameFacet]（作品表
  /// 没有 type_name 列时回空，页里如实显示“暂无文件夹”）。
  /// 一次全表聚合，调用方缓存着用，别每页都调。
  Future<List<(String, int)>> typeFolders({
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    final db = _readDb;
    if (db == null) return [];
    if (isStrict) {
      if (videoTag.isNotEmpty && !await _hasVideoTagTable(db)) return [];
      final where = <String>[
        "v.type_name IS NOT NULL AND TRIM(v.type_name) <> ''",
      ];
      final args = <Object?>[];
      if (videoTag.isNotEmpty) {
        where.add(
          'EXISTS (SELECT 1 FROM video_tag vt '
          'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?)',
        );
        args.add(videoTag);
      }
      if (category.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(category);
      }
      final rows = await db.rawQuery(
        'SELECT v.type_name AS name, COUNT(*) AS c FROM videos v '
        'WHERE ${where.join(' AND ')} '
        'GROUP BY v.type_name ORDER BY c DESC',
        args,
      );
      return [
        for (final row in rows)
          (row['name'].toString(), (row['c'] as num).toInt()),
      ];
    }
    final reader = _genericReader;
    if (reader == null) return [];
    return reader.typeNameFacet(tagKey: genericTagKey, tag: videoTag);
  }

  /// 类型文件夹封面（2026-11-24 文件夹卡片用封面）：每个类型取
  /// 该类型视频列表里第一条视频的 pic_url——与 [listFilms]
  /// （typeName + videoTag + category）同一过滤、同一排序
  /// （严格结构 ORDER BY vod_id，通用结构 ORDER BY rowid），即
  /// 点开文件夹后列表里第一条视频的封面。第一条视频没封面
  /// （pic_url 为空）或该类型一条视频都没有时回 ''，调用方
  /// 回落到原来的文件夹图标。
  /// 严格结构 2026-11-25 结构性修法（读库提速）：原来每类型一次
  /// listFilms(limit 1) + 一次女优拼接 = 26 个类型 52 次查询，
  /// 无 type_name 索引时每次全表扫（实测 5.4–10.3 秒）；现在一次
  /// GROUP BY 取每类型最小 vod_id（与 listFilms 同过滤、同排序，
  /// 首条即最小 vod_id）+ 一次 IN 批量取封面，共 2 次查询。
  /// 通用结构没有聚合接口，保持原来逐条复用 listFilms。
  /// 封面是装饰：调用方取不到也不该挡文件夹网格（页里包了
  /// try/catch，失败时整份回空、卡片全回落图标）。
  Future<Map<String, String>> typeFolderCovers({
    required List<String> typeNames,
    String videoTag = '',
    String category = '',
    String genericTagKey = '',
  }) async {
    final covers = <String, String>{};
    if (typeNames.isEmpty) return covers;
    if (isStrict) {
      final db = _readDb;
      if (db == null) return covers;
      if (videoTag.isNotEmpty && !await _hasVideoTagTable(db)) {
        return {for (final name in typeNames) name: ''};
      }
      final where = <String>[
        "v.type_name IS NOT NULL AND TRIM(v.type_name) <> ''",
      ];
      final args = <Object?>[];
      if (videoTag.isNotEmpty) {
        where.add(
          'EXISTS (SELECT 1 FROM video_tag vt '
          'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?)',
        );
        args.add(videoTag);
      }
      if (category.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(category);
      }
      final firstRows = await db.rawQuery(
        'SELECT v.type_name AS name, MIN(v.vod_id) AS first_id '
        'FROM videos v '
        'WHERE ${where.join(' AND ')} GROUP BY v.type_name',
        args,
      );
      final firstByType = <String, String>{
        for (final row in firstRows)
          row['name'].toString(): row['first_id'].toString(),
      };
      final wanted = <String>[
        for (final name in typeNames)
          if (firstByType[name] != null) firstByType[name]!,
      ];
      if (wanted.isEmpty) {
        return {for (final name in typeNames) name: ''};
      }
      final placeholders = List.filled(wanted.length, '?').join(',');
      final coverRows = await db.rawQuery(
        'SELECT vod_id, pic_url FROM videos '
        'WHERE vod_id IN ($placeholders)',
        wanted,
      );
      final coverById = <String, String>{
        for (final row in coverRows)
          row['vod_id'].toString(): (row['pic_url']?.toString() ?? ''),
      };
      for (final name in typeNames) {
        final firstId = firstByType[name];
        covers[name] = firstId == null ? '' : (coverById[firstId] ?? '');
      }
      return covers;
    }
    for (final name in typeNames) {
      final first = await listFilms(
        typeName: name,
        videoTag: videoTag,
        category: category,
        genericTagKey: genericTagKey,
        offset: 0,
        limit: 1,
      );
      covers[name] = first.isEmpty ? '' : first.first.coverUrl;
    }
    return covers;
  }

  /// 标签列表（2026-11-24 标签筛选）：严格结构读主库的
  /// video_tag 表（与 SqfliteActressDatabase.dbTags 同口径）；
  /// 通用结构走读库的 tagFacet。回的 key 就是筛选时传给
  /// [typeFolders]/[listFilms] 的 genericTagKey（严格结构不用它，
  /// key 固定是 `video_tag.tag_name`）。须在 [open] 之后调，
  /// 没打开时回空。
  Future<({String key, List<(String, int)> values})> tags() async {
    if (_readDb == null) {
      return (key: '', values: const <(String, int)>[]);
    }
    if (isStrict) {
      final values = await database.dbTags();
      return (key: 'video_tag.tag_name', values: values);
    }
    final reader = _genericReader;
    if (reader == null) {
      return (key: '', values: const <(String, int)>[]);
    }
    return reader.tagFacet();
  }

  Future<bool> _hasVideoTagTable(Database db) async {
    final cached = _hasVideoTagTableCache;
    if (cached != null) return cached;
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sqlite_master "
      "WHERE type = 'table' AND name = 'video_tag'",
    );
    final has = ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
    _hasVideoTagTableCache = has;
    return has;
  }

  /// 列表：严格结构 SQL 直查（分类/站点/女优/关键词四筛，再加
  /// 类型名 [typeName] 与标签 [videoTag] 两筛）；通用结构走
  /// 通用读出 + 内存里按分类筛（通用读出只有标题/番号搜）。
  /// [genericTagKey] 是通用结构下标签筛选的 filters 键（[tags]
  /// 回的 key）；通用结构下标签非空但 key 为空时回空（筛不出，
  /// 不暗地里回未过滤的列表）；类型名非空但作品表没有 type_name
  /// 列时同样回空。
  Future<List<FilmLibraryEntry>> listFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
    required int offset,
    required int limit,
  }) async {
    final db = _readDb;
    if (db == null) return [];
    if (isStrict) {
      final where = <String>[];
      final args = <Object?>[];
      if (category.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(category);
      }
      if (site.isNotEmpty) {
        where.add('v.vod_play_from = ?');
        args.add(site);
      }
      if (actress.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_actress '
          'WHERE cate_id = ?)',
        );
        args.add(actress);
      }
      if (typeName.isNotEmpty) {
        where.add('v.type_name = ?');
        args.add(typeName);
      }
      if (videoTag.isNotEmpty) {
        if (!await _hasVideoTagTable(db)) return [];
        where.add(
          'EXISTS (SELECT 1 FROM video_tag vt '
          'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?)',
        );
        args.add(videoTag);
      }
      final q = query.trim();
      if (q.isNotEmpty) {
        final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
        where.add('(v.title LIKE ? OR v.vod_id LIKE ?)');
        args.addAll([like, like]);
      }
      // 2026-11-22 加载优化：原来一页 60 行也要先对 34 万行做
      // LEFT JOIN video_actress + GROUP BY v.vod_id 再 LIMIT，
      // 首页实测 0.09~0.35 秒、翻到 100 页（OFFSET 6000）要
      // 1.6~3.5 秒；改成两步——先只查 videos + video_category
      // 取本页 60 行（主键序，无 JOIN 无 GROUP，实测约 0.01 秒），
      // 再一次 GROUP_CONCAT 批量取这 60 行的女优名。结果与改前
      // 完全一致（vod_id 是主键，本来就没有重复行可去重）。
      final rows = await db.rawQuery(
        'SELECT v.vod_id, v.title, v.pic_url, v.m3u8_url, v.vod_play_url, '
        'v.vod_play_from, v.vod_pubdate, v.vod_remarks, v.type_name, '
        'v.vod_content, vc.main_category '
        'FROM videos v '
        'LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY v.vod_id LIMIT ? OFFSET ?',
        [...args, limit, offset],
      );
      return _strictRowsWithActresses(rows);
    }
    final reader = _genericReader;
    if (reader == null) return [];
    if (videoTag.isNotEmpty && genericTagKey.isEmpty) return [];
    if (typeName.isNotEmpty) {
      final worksTable = reader.schema.worksTable;
      if (worksTable == null || !worksTable.allColumns.contains('type_name')) {
        return [];
      }
    }
    final filters = <String, List<String>>{};
    if (typeName.isNotEmpty) filters['type_name'] = [typeName];
    if (videoTag.isNotEmpty) filters[genericTagKey] = [videoTag];
    final works = await reader.works(
      offset: offset,
      limit: limit,
      query: query,
      filters: filters,
    );
    final out = <FilmLibraryEntry>[];
    for (final work in works) {
      if (category.isNotEmpty && work.category != category) continue;
      out.add(_genericWorkToEntry(work));
    }
    return out;
  }

  Future<int> countFilms({
    String category = '',
    String site = '',
    String actress = '',
    String query = '',
    String typeName = '',
    String videoTag = '',
    String genericTagKey = '',
  }) async {
    final db = _readDb;
    if (db == null) return 0;
    if (isStrict) {
      final where = <String>[];
      final args = <Object?>[];
      if (category.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(category);
      }
      if (site.isNotEmpty) {
        where.add('v.vod_play_from = ?');
        args.add(site);
      }
      if (actress.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_actress '
          'WHERE cate_id = ?)',
        );
        args.add(actress);
      }
      if (typeName.isNotEmpty) {
        where.add('v.type_name = ?');
        args.add(typeName);
      }
      if (videoTag.isNotEmpty) {
        if (!await _hasVideoTagTable(db)) return 0;
        where.add(
          'EXISTS (SELECT 1 FROM video_tag vt '
          'WHERE vt.vod_id = v.vod_id AND vt.tag_name = ?)',
        );
        args.add(videoTag);
      }
      final q = query.trim();
      if (q.isNotEmpty) {
        final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
        where.add('(v.title LIKE ? OR v.vod_id LIKE ?)');
        args.addAll([like, like]);
      }
      // COUNT(*) 与 COUNT(DISTINCT vod_id) 等价：这里没有 JOIN，不会
      // 产生重复行；DISTINCT 会逼出临时 B 树，冷库全表扫时更慢。
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM videos v '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}',
        args,
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    }
    final reader = _genericReader;
    if (reader == null) return 0;
    if (videoTag.isNotEmpty && genericTagKey.isEmpty) return 0;
    if (typeName.isNotEmpty) {
      final worksTable = reader.schema.worksTable;
      if (worksTable == null || !worksTable.allColumns.contains('type_name')) {
        return 0;
      }
    }
    final filters = <String, List<String>>{};
    if (typeName.isNotEmpty) filters['type_name'] = [typeName];
    if (videoTag.isNotEmpty) filters[genericTagKey] = [videoTag];
    return reader.countWorks(query: query, filters: filters);
  }

  /// 直播内置片库（whos_lib）读库分页（2026-11-23 v58 验机）：
  /// 内置片库原来只读 documents/actress_json/ 里的 whos.json /
  /// mjv011.json，v58 删了包内 whos.json、用户又定 App 里不内置
  /// 任何 JSON，没那两个文件就确定性播不了；改成优先读本地数据库
  /// （MYTV/db/女优库.db，34 万部、地址封面都有），没库才读 JSON。
  /// 只读严格结构库；打不开/非严格结构回空，不抛错。
  /// 排序是最新在前（vod_pubdate 倒序，不是 listFilms 的 vod_id
  /// 字典序）；brand 按番号前缀筛（`rki-%`，走 vod_id 主键前缀）；
  /// query 搜标题/番号（前导 % LIKE，大库上本来就慢，只在用户
  /// 主动搜时跑）；videoCategory 按 video_category 主分类筛
  /// （有码/无码/国产…，空着不过滤；空分类的只在“全部”里出现）。
  Future<List<FilmLibraryEntry>> listLibraryFilms({
    String brand = '',
    String query = '',
    String videoCategory = '',
    required int offset,
    required int limit,
  }) async {
    try {
      if (!await _ensureFilmOpen() || !isStrict) return const [];
      final db = _readDb;
      if (db == null) return const [];
      final where = <String>[];
      final args = <Object?>[];
      final cleanBrand = brand.trim().toLowerCase();
      if (cleanBrand.isNotEmpty) {
        where.add('v.vod_id LIKE ?');
        args.add('$cleanBrand-%');
      }
      final cleanVideoCategory = videoCategory.trim();
      if (cleanVideoCategory.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(cleanVideoCategory);
      }
      final q = query.trim();
      if (q.isNotEmpty) {
        final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
        where.add('(v.title LIKE ? OR v.vod_id LIKE ?)');
        args.addAll([like, like]);
      }
      final rows = await db.rawQuery(
        'SELECT v.vod_id, v.title, v.pic_url, v.m3u8_url, v.vod_play_url, '
        'v.vod_play_from, v.vod_pubdate, v.vod_remarks, v.type_name, '
        'v.vod_content, vc.main_category '
        'FROM videos v LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY v.vod_pubdate DESC, v.vod_id ASC LIMIT ? OFFSET ?',
        [...args, limit, offset],
      );
      return [for (final row in rows) _strictRowToEntry(row)];
    } catch (_) {
      return const [];
    }
  }

  /// 直播内置片库计数（与 [listLibraryFilms] 同一过滤条件）。
  Future<int> countLibraryFilms({
    String brand = '',
    String query = '',
    String videoCategory = '',
  }) async {
    try {
      if (!await _ensureFilmOpen() || !isStrict) return 0;
      final db = _readDb;
      if (db == null) return 0;
      final where = <String>[];
      final args = <Object?>[];
      final cleanBrand = brand.trim().toLowerCase();
      if (cleanBrand.isNotEmpty) {
        where.add('v.vod_id LIKE ?');
        args.add('$cleanBrand-%');
      }
      final cleanVideoCategory = videoCategory.trim();
      if (cleanVideoCategory.isNotEmpty) {
        where.add(
          'v.vod_id IN (SELECT vod_id FROM video_category '
          'WHERE main_category = ?)',
        );
        args.add(cleanVideoCategory);
      }
      final q = query.trim();
      if (q.isNotEmpty) {
        final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
        where.add('(v.title LIKE ? OR v.vod_id LIKE ?)');
        args.addAll([like, like]);
      }
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM videos v '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}',
        args,
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 直播内置片库厂牌维度：番号前缀（`rki-6042` → `rki`）分组计数，
  /// 从多到少。一次全表聚合，调用方缓存着用，别每页都调。
  Future<List<({String brand, int count})>> libraryBrandFacets({
    int limit = 30,
  }) async {
    try {
      if (!await _ensureFilmOpen() || !isStrict) return const [];
      final db = _readDb;
      if (db == null) return const [];
      final rows = await db.rawQuery(
        "SELECT SUBSTR(vod_id, 1, INSTR(vod_id, '-') - 1) AS brand, "
        'COUNT(*) AS c FROM videos '
        "WHERE INSTR(vod_id, '-') > 1 "
        'GROUP BY brand ORDER BY c DESC, brand ASC LIMIT ?',
        [limit],
      );
      return [
        for (final row in rows)
          if ((row['brand']?.toString() ?? '').length >= 2)
            (
              brand: row['brand'].toString().toLowerCase(),
              count: (row['c'] as num?)?.toInt() ?? 0,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 直播内置片库按 id 取一条（主键查；大小写两种写法都试）。
  Future<FilmLibraryEntry?> libraryFilmById(String vodId) async {
    try {
      if (!await _ensureFilmOpen() || !isStrict) return null;
      final key = vodId.trim();
      if (key.isEmpty) return null;
      final films = await _strictFilmsByIds([
        key,
        key.toLowerCase(),
        key.toUpperCase(),
      ]);
      if (films.isEmpty) return null;
      return films.first;
    } catch (_) {
      return null;
    }
  }

  /// 兜底提供方实现（2026-11-20 18:57 全部使用数据库兜底）：
  /// 详情页/播放兜底先查本库，读不到再回退 json/m3u。永不抛错。
  /// 按女优名取作品：严格结构按归一化名匹配 video_actress 的
  /// cate_id（同名不同写法各算一个女优，不跨名合并）；通用结构
  /// 按通用读出的女优字段归一化匹配。
  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async {
    try {
      if (!await _ensureFilmOpen()) return const [];
      final key = normalizeActressJsonName(name);
      if (key.isEmpty) return const [];
      if (isStrict) {
        final db = _readDb;
        if (db == null) return const [];
        // 2026-11-22 加载优化：原来从 video_actress（47 万行）取
        // DISTINCT cate_id，每次 0.25~0.28 秒；actresses 表只有
        // 2.9 万行、cate_id 同值（实测 video_actress 里没有
        // actresses 之外的 cate_id，0 个孤儿键），改查它只要
        // 0.003~0.02 秒。缓存仍只建一次。
        _filmActressNames ??= [
          for (final row in await db.rawQuery(
            'SELECT DISTINCT cate_id FROM actresses',
          ))
            row['cate_id'].toString(),
        ];
        final matched = [
          for (final n in _filmActressNames!)
            if (normalizeActressJsonName(n) == key) n,
        ];
        if (matched.isEmpty) return const [];
        final out = <ActressJsonEntry>[];
        for (final n in matched) {
          final films = await listFilms(actress: n, offset: 0, limit: 500);
          out.addAll([for (final f in films) f.toJsonEntry()]);
        }
        return _filterFallbackSite(out, site);
      }
      final reader = _genericReader;
      if (reader == null) return const [];
      final works = await reader.works(offset: 0, limit: 1000);
      final out = <ActressJsonEntry>[
        for (final work in works)
          if (normalizeActressJsonName(work.actress) == key)
            _genericWorkToEntry(work).toJsonEntry(),
      ];
      return _filterFallbackSite(out, site);
    } catch (_) {
      return const [];
    }
  }

  /// 按番号取作品：严格结构按 slug 精确匹配（jul-893 与
  /// jul-893-uncensored-leak 是同一 slug 的两行，都回）；
  /// 通用结构按通用读出的番号归一化匹配。
  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async {
    try {
      if (!await _ensureFilmOpen()) return const [];
      final slug = filmSlugCode(codeKey);
      if (slug.isEmpty) return const [];
      if (isStrict) {
        // 2026-11-22 加载优化：先走主键精确取（约 0.003 秒）。
        // 只有库里写法与所给番号对不上（大小写/分隔符差异）时，
        // 才回落到原来的 LIKE 扫表 + slug 过滤（全表扫，慢）。
        final fast = await entriesForCodes([codeKey], site: site);
        if (fast.isNotEmpty) return fast;
        final films = await listFilms(query: slug, offset: 0, limit: 100);
        final out = <ActressJsonEntry>[
          for (final f in films)
            if (filmSlugCode(f.vodId) == slug) f.toJsonEntry(),
        ];
        return _filterFallbackSite(out, site);
      }
      final reader = _genericReader;
      if (reader == null) return const [];
      final works = await reader.works(offset: 0, limit: 1000, query: slug);
      final out = <ActressJsonEntry>[
        for (final work in works)
          if (filmSlugCode(work.code) == slug)
            _genericWorkToEntry(work).toJsonEntry(),
      ];
      return _filterFallbackSite(out, site);
    } catch (_) {
      return const [];
    }
  }

  /// 批量按番号取作品（2026-11-22 女优库加载优化）：
  /// 严格结构一次主键 IN 取回全部番号的行（60 个番号约 0.003 秒），
  /// 不再逐番号 LIKE 扫表（一次 LIKE + GROUP BY 在 34 万行库上
  /// 实测可达数秒以上，60 次就是几分钟——详情页地址池建不起来、
  /// 点卡报“库里暂无播放地址”的直接原因）。
  /// IN 键 = 原样番号 + slug + 大小写两种写法（库里 vod_id 大小写
  /// 不统一，如 003T28-262）；返回时仍按 slug 精确过滤，与
  /// [entriesForCode] 语义一致（jul-893 与
  /// jul-893-uncensored-leak 是同一 slug 的两行，都回）。
  /// 通用结构沿用逐条（外来小库，便宜）。本方法不在
  /// [FilmDbFallbackProvider] 接口上（见 actress_json_fallback.dart
  /// 顶部说明），只挂真实实现。
  Future<List<ActressJsonEntry>> entriesForCodes(
    List<String> codeKeys, {
    String? site,
  }) async {
    try {
      if (!await _ensureFilmOpen()) return const [];
      final wanted = <String>{};
      for (final codeKey in codeKeys) {
        final slug = filmSlugCode(codeKey);
        if (slug.isEmpty) continue;
        wanted.add(slug);
        final trimmed = codeKey.trim();
        wanted.add(trimmed);
        wanted.add(trimmed.toLowerCase());
        wanted.add(trimmed.toUpperCase());
      }
      if (wanted.isEmpty) return const [];
      if (isStrict) {
        final films = await _strictFilmsByIds(wanted.toList());
        final out = <ActressJsonEntry>[
          for (final f in films)
            if (wanted.contains(filmSlugCode(f.vodId))) f.toJsonEntry(),
        ];
        return _filterFallbackSite(out, site);
      }
      final out = <ActressJsonEntry>[];
      for (final codeKey in codeKeys) {
        out.addAll(await entriesForCode(codeKey, site: site));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 兜底打开守卫：没打开过就打开；绑定路径变了（用户换了 db 文件）
  /// 就关旧连接重开。失败回 false，调用方回空、不拖垮兜底。
  Future<bool> _ensureFilmOpen() async {
    try {
      final bind = await ActressMytvBind.instance.ensureBound();
      if (isOpen && _dbPath == bind.dbPath) return true;
      await close();
      final result = await open();
      return result.error == null;
    } catch (_) {
      return false;
    }
  }

  List<ActressJsonEntry> _filterFallbackSite(
    List<ActressJsonEntry> entries,
    String? site,
  ) {
    if (site == null || site == 'all') return entries;
    return [
      for (final e in entries)
        if (filmSiteId(e.site) == site) e,
    ];
  }

  /// 本次打开后缓存的 video_actress 去重女优名（归一化匹配用；
  /// 换库重开时清空）。
  List<String>? _filmActressNames;

  /// 严格结构行 + 女优名批量补齐（见 listFilms 两步查）：
  /// 只对已取到的行做一次 GROUP_CONCAT，不扫全表。
  Future<List<FilmLibraryEntry>> _strictRowsWithActresses(
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return const [];
    final db = _readDb;
    if (db == null) return [for (final row in rows) _strictRowToEntry(row)];
    final ids = [for (final row in rows) row['vod_id']?.toString() ?? ''];
    final inList = List.filled(ids.length, '?').join(',');
    final actressRows = await db.rawQuery(
      'SELECT vod_id, GROUP_CONCAT(DISTINCT cate_id) AS actresses '
      'FROM video_actress WHERE vod_id IN ($inList) GROUP BY vod_id',
      ids,
    );
    final actressById = <String, String>{
      for (final row in actressRows)
        row['vod_id'].toString(): row['actresses']?.toString() ?? '',
    };
    return [
      for (final row in rows)
        _strictRowToEntry({
          ...row,
          'actresses': actressById[row['vod_id']?.toString() ?? ''] ?? '',
        }),
    ];
  }

  /// 严格结构按主键批量取行（供 [entriesForCodes] 用）：
  /// vod_id 是主键，IN 一次取回，不走 LIKE 扫表。
  Future<List<FilmLibraryEntry>> _strictFilmsByIds(List<String> vodIds) async {
    final db = _readDb;
    if (db == null || vodIds.isEmpty) return const [];
    final inList = List.filled(vodIds.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT v.vod_id, v.title, v.pic_url, v.m3u8_url, v.vod_play_url, '
      'v.vod_play_from, v.vod_pubdate, v.vod_remarks, v.type_name, '
      'v.vod_content, vc.main_category '
      'FROM videos v LEFT JOIN video_category vc ON vc.vod_id = v.vod_id '
      'WHERE v.vod_id IN ($inList)',
      vodIds,
    );
    return _strictRowsWithActresses(rows);
  }

  FilmLibraryEntry _strictRowToEntry(Map<String, Object?> row) {
    String text(String key) => row[key]?.toString() ?? '';
    final play = extractPlayUrl(
      text('m3u8_url').isNotEmpty ? text('m3u8_url') : text('vod_play_url'),
    );
    final actresses = text('actresses');
    return FilmLibraryEntry(
      vodId: text('vod_id'),
      title: text('title'),
      coverUrl: resolveCoverUrl(text('pic_url')),
      playUrl: play,
      actress: actresses.replaceAll(',', ' / '),
      code: filmSlugCode(text('vod_id')),
      category: _categoryOf(row),
      site: text('vod_play_from'),
      date: text('vod_pubdate'),
      remarks: text('vod_remarks'),
      typeName: text('type_name'),
      content: text('vod_content'),
    );
  }

  String _categoryOf(Map<String, Object?> row) {
    final main = row['main_category']?.toString() ?? '';
    if (main.isNotEmpty) return main;
    return row['type_name']?.toString() ?? '';
  }

  FilmLibraryEntry _genericWorkToEntry(GenericDbWork work) {
    return FilmLibraryEntry(
      vodId: work.id?.toString() ?? work.title,
      title: work.title,
      coverUrl: work.coverUrl,
      playUrl: work.playUrl,
      actress: work.actress,
      code: filmSlugCode(work.code),
      category: work.category,
      site: '',
      date: work.date,
      remarks: '',
      typeName: work.category,
      content: '',
    );
  }
}

/// 探活结果：alive 能播；dead 死了（404/410/403/超时都算死，原因
/// 写进 reason）；unknown 探不出来（没网这类本地网络错，不当死处理）。
enum FilmLinkStatus { alive, dead, unknown }

class FilmLinkProbe {
  const FilmLinkProbe({
    required this.status,
    this.httpCode = 0,
    this.reason = '',
  });

  final FilmLinkStatus status;
  final int httpCode;
  final String reason;
}

/// 轻量探活（只读网络探测，不写任何东西）：Range 0-0 取首字节。
/// 200/206 为活；404/410/403 为死；超时为死（用户口径：超时即
/// 失效）；没网这类本地错为 unknown。原 FilmLinkRepairService 的
/// 探活部分，修复服务已随 2026-11-26 只读化删除，探活保留给
/// 播放链判域名变化后的死链提示用。
Future<FilmLinkProbe> probeFilmPlayUrl(
  String url, {
  Duration timeout = const Duration(seconds: 8),
  HttpClient? httpClient,
}) async {
  if (url.isEmpty) {
    return const FilmLinkProbe(status: FilmLinkStatus.dead, reason: '无播放地址');
  }
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return const FilmLinkProbe(
      status: FilmLinkStatus.dead,
      reason: '地址不是合法链接',
    );
  }
  final client = httpClient ?? HttpClient();
  final owned = httpClient == null;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('Range', 'bytes=0-0');
    request.headers.set(
      'User-Agent',
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
    );
    final response = await request.close().timeout(timeout);
    // 只读状态行：不读 body，Range 响应只有 1 字节。
    await response.drain<void>().timeout(const Duration(seconds: 3));
    final code = response.statusCode;
    if (code == 200 || code == 206) {
      return FilmLinkProbe(status: FilmLinkStatus.alive, httpCode: code);
    }
    if (code == 404 || code == 410 || code == 403) {
      return FilmLinkProbe(
        status: FilmLinkStatus.dead,
        httpCode: code,
        reason: 'HTTP $code',
      );
    }
    return FilmLinkProbe(
      status: FilmLinkStatus.unknown,
      httpCode: code,
      reason: 'HTTP $code',
    );
  } on TimeoutException {
    return const FilmLinkProbe(status: FilmLinkStatus.dead, reason: '超时');
  } on SocketException catch (e) {
    return FilmLinkProbe(
      status: FilmLinkStatus.unknown,
      reason: '网络错：${e.message}',
    );
  } catch (e) {
    return FilmLinkProbe(status: FilmLinkStatus.unknown, reason: e.toString());
  } finally {
    if (owned) client.close(force: true);
  }
}

/// 去 HTML 标签（vod_content 是站方简介 + 标签列表的 HTML）。
String filmPlainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// 影视库页：按影片浏览绑定库里的全部作品（卡片：封面/标题/女优/
/// 番号），分类/站点/女优/关键词筛选，点卡进详情页（不直播放）。
class FilmLibraryPage extends StatefulWidget {
  const FilmLibraryPage({
    super.key,
    required this.database,
    required this.repository,
    required this.store,
  });

  final ActressDatabase database;
  final AppRepository repository;
  final LocalStore store;

  @override
  State<FilmLibraryPage> createState() => _FilmLibraryPageState();
}

class _FilmLibraryPageState extends State<FilmLibraryPage> {
  static const _pageSize = 60;

  late final FilmLibraryService _service = FilmLibraryService(
    database: widget.database,
  );
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();

  FilmLibraryOpenResult? _open;
  List<(String, int)> _categories = [];
  List<String> _sites = [];
  List<FilmLibraryEntry> _films = [];
  var _total = 0;
  var _loading = true;
  var _loadingMore = false;

  /// 加载下一页失败了没有：失败时 [_loadingMore] 必须清掉，否则
  /// 滚动守卫永远拦住、列表卡死；底脚改摆重试，点后才继续。
  var _loadMoreFailed = false;

  /// 已展示作品的 vodId：按偏移翻页时库里数据若有变动会重出
  /// 同一条，追加时按 vodId 去重。
  final Set<String> _seenVodIds = <String>{};
  var _hasMore = true;
  String _category = '';
  String _site = '';
  String _actress = '';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _openLibrary();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _service.close();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients ||
        _loadingMore ||
        _loadMoreFailed ||
        !_hasMore) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    _loadMore();
  }

  Future<void> _openLibrary() async {
    final open = await _service.open();
    if (!mounted) return;
    setState(() {
      _open = open;
      _total = open.total;
    });
    if (open.error == null) {
      // 2026-11-22 加载优化：分类/站点不再堵首屏——原来串行等
      // categories() + sites()（站点去重全表扫 1.8~8.3 秒）完了
      // 才取列表，页上一直转圈；现在列表先出，分类/站点后台取、
      // 到了再补 chips。
      unawaited(_loadFilters());
      await _reload();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadFilters() async {
    try {
      final categories = await _service.categories();
      final sites = await _service.sites();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _sites = sites;
      });
    } catch (_) {
      // 页面已关/库已关：chips 不补，不崩。
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _films = [];
      _seenVodIds.clear();
      _loadMoreFailed = false;
      _hasMore = true;
    });
    // 2026-11-22 加载优化：列表与总数并行取，不再串行等两遍。
    final filmsFuture = _service.listFilms(
      category: _category,
      site: _site,
      actress: _actress,
      query: _query,
      offset: 0,
      limit: _pageSize,
    );
    final totalFuture = _service.countFilms(
      category: _category,
      site: _site,
      actress: _actress,
      query: _query,
    );
    final films = await filmsFuture;
    final total = await totalFuture;
    if (!mounted) return;
    setState(() {
      _films = films;
      _seenVodIds.addAll(films.map((film) => film.vodId));
      _total = total;
      _loading = false;
      _hasMore = films.length >= _pageSize;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    try {
      final films = await _service.listFilms(
        category: _category,
        site: _site,
        actress: _actress,
        query: _query,
        offset: _films.length,
        limit: _pageSize,
      );
      if (!mounted) return;
      final fresh = [
        for (final film in films)
          if (_seenVodIds.add(film.vodId)) film,
      ];
      setState(() {
        _films = [..._films, ...fresh];
        _loadingMore = false;
        _hasMore = films.length >= _pageSize;
      });
    } catch (_) {
      // 取下一页抛错：原来这里没接住，_loadingMore 永久为真、
      // 滚动守卫永远拦住，列表滑到底就卡死。清掉标记、底脚摆重试。
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _loadMoreFailed = true;
      });
    }
  }

  Future<void> _openFieldsPage() async {
    final reader = _service.genericReader;
    if (reader == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ActressDbFieldsPage(reader: reader)),
    );
    if (changed != true || !mounted) return;
    await _openLibrary();
  }

  /// 列表行封面上的播放键：与详情页同一条链（见 [playFilmEntry]），
  /// 点键直接播；行主体仍进详情。
  Future<void> _playFilm(FilmLibraryEntry entry) async {
    if (!entry.playable) return;
    await playFilmEntry(
      context,
      entry: entry,
      service: _service,
      repository: widget.repository,
      store: widget.store,
    );
  }

  Future<void> _openFilm(FilmLibraryEntry entry) async {
    final actress = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => FilmDetailPage(
          entry: entry,
          database: widget.database,
          repository: widget.repository,
          store: widget.store,
          service: _service,
        ),
      ),
    );
    if (actress != null && actress.isNotEmpty && mounted) {
      setState(() => _actress = actress);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _open;
    return Scaffold(
      appBar: actressNeonAppBar(
        title: const Text('影视库'),
        actions: [
          if (_service.genericReader != null)
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: '数据库字段',
              onPressed: _openFieldsPage,
            ),
        ],
      ),
      body: _loading && open == null
          ? const Center(child: CircularProgressIndicator())
          : open?.error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '影视库打不开：${open!.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${open!.displayPath} · 共 $_total 部'
                          '${open.strict ? '' : ' · 通用结构'}',
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 2,
                        ),
                      ),
                      if (_actress.isNotEmpty)
                        ActionChip(
                          label: Text('女优：$_actress'),
                          onPressed: () async {
                            setState(() => _actress = '');
                            await _reload();
                          },
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜标题 / 番号',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () async {
                                _searchController.clear();
                                setState(() => _query = '');
                                await _reload();
                              },
                            ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (value) async {
                      setState(() => _query = value.trim());
                      await _reload();
                    },
                  ),
                ),
                if (_categories.isNotEmpty)
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        _CategoryChip(
                          label: '全部',
                          selected: _category.isEmpty,
                          onTap: () async {
                            setState(() => _category = '');
                            await _reload();
                          },
                        ),
                        for (final (name, count) in _categories)
                          _CategoryChip(
                            label: '$name（$count）',
                            selected: _category == name,
                            onTap: () async {
                              setState(() => _category = name);
                              await _reload();
                            },
                          ),
                      ],
                    ),
                  ),
                if (_sites.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: DropdownButtonFormField<String>(
                      initialValue: _site.isEmpty ? null : _site,
                      decoration: const InputDecoration(
                        labelText: '站点',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: '', child: Text('全部站点')),
                        for (final site in _sites)
                          DropdownMenuItem(value: site, child: Text(site)),
                      ],
                      onChanged: (value) async {
                        setState(() => _site = value ?? '');
                        await _reload();
                      },
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _films.isEmpty
                      ? const Center(child: Text('没有符合条件的作品'))
                      : ListView.builder(
                          controller: _scrollController,
                          itemCount:
                              _films.length +
                              (_hasMore || _loadMoreFailed ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index >= _films.length) {
                              // 底脚三态：加载中转圈；失败摆重试（点后
                              // 取同一页）；有下一页但没在加载时不摆
                              // 转圈，免得用户以为一直在加载。
                              if (_loadMoreFailed) {
                                return Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Center(
                                    child: TextButton(
                                      key: const ValueKey('film_library_retry'),
                                      onPressed: _loadMore,
                                      child: const Text('加载失败，点我重试'),
                                    ),
                                  ),
                                );
                              }
                              if (_loadingMore) {
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            }
                            final film = _films[index];
                            return _FilmCard(
                              film: film,
                              onTap: () => _openFilm(film),
                              onPlay: film.playable
                                  ? () => unawaited(_playFilm(film))
                                  : null,
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: ActressNeonPill(label: label, selected: selected, onTap: onTap),
    );
  }
}

class _FilmCard extends StatelessWidget {
  const _FilmCard({required this.film, required this.onTap, this.onPlay});

  final FilmLibraryEntry film;
  final VoidCallback onTap;

  /// 封面上的播放键（可空）：只在有可播地址时摆；点键直接播，
  /// 行主体仍进详情。不传时不摆键，老行为不变。
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Container(
        decoration: actressNeonCardDecoration(),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    height: 128,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: film.coverUrl.isEmpty
                              ? Container(
                                  color: Neon.surfaceHigh,
                                  child: const Icon(
                                    Icons.movie_outlined,
                                    color: Neon.textDim,
                                  ),
                                )
                              : Image.network(
                                  film.coverUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: Neon.surfaceHigh,
                                    child: const Icon(
                                      Icons.movie_outlined,
                                      color: Neon.textDim,
                                    ),
                                  ),
                                ),
                        ),
                        if (onPlay != null && film.playable)
                          Center(
                            child: PosterPlayBadge(
                              onPressed: onPlay,
                              size: 44,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            film.displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.titleMedium?.copyWith(color: Neon.text),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            film.displaySubtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Neon.textDim),
                          ),
                          if (!film.playable)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '暂无可播地址',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.error),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 影视库条目直播（详情页海报/“正片”行、卡片墙播放键共用同一条链）：
/// 地址是库里刚取的直链（[FilmLibraryEntry.toDramaDetail] 标 direct），
/// resolve 时原样直通、不绕站源解析；域名与库当前主域名不一样时先
/// 轻量探活，死了提示、不硬播（2026-11-26 只读化：不再记失效、
/// 不再修复写回，库只读）。调用方须先确认 entry.playable。
/// 海报播放键播不了与“正片”行播不了是同一根因，不另起取流路。
Future<void> playFilmEntry(
  BuildContext context, {
  required FilmLibraryEntry entry,
  required FilmLibraryService service,
  required AppRepository repository,
  required LocalStore store,
}) async {
  final host = filmPlayHost(entry.playUrl);
  final current = await service.currentDomainFromDb();
  if (host.isNotEmpty && current.isNotEmpty && host != current) {
    final probe = await probeFilmPlayUrl(entry.playUrl);
    if (probe.status != FilmLinkStatus.alive) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('这条播不了（${probe.reason}）')),
      );
      return;
    }
  }
  if (!context.mounted) return;
  await pushPlayer<void>(
    context,
    detail: entry.toDramaDetail(),
    initialIndex: 0,
    repository: repository,
    store: store,
  );
}

/// 影视库详情页：FongMiTV 式（海报 + 头项 + 简介 + 播放线路行），
/// 点卡只进详情不直播放；播放从海报或“正片”行点，播放器自带暂停。
class FilmDetailPage extends StatefulWidget {
  const FilmDetailPage({
    super.key,
    required this.entry,
    required this.database,
    required this.repository,
    required this.store,
    required this.service,
  });

  final FilmLibraryEntry entry;
  final ActressDatabase database;
  final AppRepository repository;
  final LocalStore store;
  final FilmLibraryService service;

  @override
  State<FilmDetailPage> createState() => _FilmDetailPageState();
}

class _FilmDetailPageState extends State<FilmDetailPage> {
  var _checking = false;

  FilmLibraryEntry get _entry => widget.entry;

  /// 点播：与卡片墙播放键同一条链（见 [playFilmEntry]），点海报、
  /// 点海报上的播放键、点“正片”行都走这里。
  Future<void> _play() async {
    if (!_entry.playable) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这条没有可播地址')));
      return;
    }
    if (mounted) setState(() => _checking = true);
    try {
      await playFilmEntry(
        context,
        entry: _entry,
        service: widget.service,
        repository: widget.repository,
        store: widget.store,
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final synopsis = filmPlainText(_entry.content);
    final actresses = _entry.actress
        .split(RegExp(r'[/,，、]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(_entry.displayTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: _checking ? null : _play,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                // 海报上的透明播放键：点海报或点键都走同一个 _play（正片
                // 直链）；没地址时不摆键，免得误导。不是“立即播放”按钮，
                // 播放/暂停在播放器里。
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _entry.coverUrl.isEmpty
                        ? Container(
                            color: colors.surfaceContainerHighest,
                            child: const Icon(Icons.movie_outlined, size: 48),
                          )
                        : Image.network(
                            _entry.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              color: colors.surfaceContainerHighest,
                              child: const Icon(
                                Icons.movie_outlined,
                                size: 48,
                              ),
                            ),
                          ),
                    if (_entry.playable)
                      const Center(child: PosterPlayBadge()),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _entry.displayTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_entry.code.isNotEmpty) Chip(label: Text(_entry.code)),
              if (_entry.category.isNotEmpty)
                Chip(label: Text(_entry.category)),
              if (_entry.site.isNotEmpty) Chip(label: Text(_entry.site)),
              if (_entry.date.isNotEmpty) Chip(label: Text(_entry.date)),
              if (_entry.remarks.isNotEmpty) Chip(label: Text(_entry.remarks)),
            ],
          ),
          if (actresses.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in actresses)
                  ActionChip(
                    label: Text(name),
                    avatar: const Icon(Icons.person_outline, size: 16),
                    // 点女优名：回列表只筛这个女优的作品。
                    onPressed: () => Navigator.of(context).pop(name),
                  ),
              ],
            ),
          ],
          if (synopsis.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('简介', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(synopsis),
          ],
          const SizedBox(height: 16),
          Text('播放线路', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.play_circle_fill),
            title: const Text('正片'),
            subtitle: Text(_entry.playable ? '直链播放（parse=0）' : '暂无可播地址'),
            trailing: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checking ? null : _play,
          ),
        ],
      ),
    );
  }
}
