import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import 'actress_adapter_http.dart';
import 'actress_generic_db.dart';
import 'actress_roster_sources.dart';

/// 女优库标准结构（2026-11-22 用户定：任何外来的视频库，都按这一套
/// 整理——缺的列补上、多的列去掉、值搬到对得上的列里）。
///
/// 顺序有意义：videos/actresses 先建，关联表的后键才落得下来。
class VideoDbStandards {
  const VideoDbStandards._();

  /// 作品表。
  static const Map<String, String> videos = {
    'vod_id': 'TEXT',
    'title': 'TEXT',
    'pic_url': 'TEXT',
    'm3u8_url': 'TEXT',
    'vod_remarks': 'TEXT',
    'vod_pubdate': 'TEXT',
    'vod_area': 'TEXT',
    'vod_year': 'TEXT',
    'vod_content': 'TEXT',
    'vod_play_from': 'TEXT',
    'vod_play_url': 'TEXT',
    'type_name': 'TEXT',
    'created_at': 'INTEGER',
  };

  /// 人物表（女优 / 男优）。
  static const Map<String, String> actresses = {
    'cate_id': 'INTEGER',
    'name': 'TEXT',
    'avatar': 'TEXT',
    'sex': 'TEXT',
    'created_at': 'INTEGER',
  };

  /// 作品 ↔ 人物。
  static const Map<String, String> videoActress = {
    'vod_id': 'TEXT',
    'cate_id': 'INTEGER',
  };

  /// 作品 ↔ 大类（有码 / 无码 / 4K…）。
  static const Map<String, String> videoCategory = {
    'vod_id': 'TEXT',
    'main_category': 'TEXT',
  };

  static const Map<String, String> tags = {
    'tag_name': 'TEXT',
    'created_at': 'INTEGER',
  };

  static const Map<String, String> videoTag = {
    'vod_id': 'TEXT',
    'tag_name': 'TEXT',
  };

  static const Map<String, String> actorRanking = {
    'vod_id': 'TEXT',
    'cate_id': 'INTEGER',
  };

  static const Map<String, String> videoRanking = {
    'vod_id': 'TEXT',
    'cate_id': 'INTEGER',
  };

  /// 表名 → 标准列（建表/补列/删多余列都按这张表）。
  static const Map<String, Map<String, String>> tables = {
    'videos': videos,
    'actresses': actresses,
    'video_actress': videoActress,
    'video_category': videoCategory,
    'tags': tags,
    'video_tag': videoTag,
    'actor_ranking': actorRanking,
    'video_ranking': videoRanking,
  };

  /// 主键（建库用；判断表有没有主键就别再补）。
  static const Map<String, List<String>> primaryKeys = {
    'videos': ['vod_id'],
    'actresses': ['cate_id'],
    'video_actress': ['vod_id', 'cate_id'],
    'video_category': ['vod_id', 'main_category'],
    'tags': ['tag_name'],
    'video_tag': ['vod_id', 'tag_name'],
    'actor_ranking': ['vod_id', 'cate_id'],
    'video_ranking': ['vod_id', 'cate_id'],
  };

  /// 建表语句。[name] 可覆盖表名（重建时先建临时表）。
  static String createSql(String table, {String? name}) {
    final target = name ?? table;
    final columns = tables[table];
    if (columns == null) throw ArgumentError('不是标准表：$table');
    final keys = primaryKeys[table] ?? const <String>[];
    final defs = <String>[
      for (final entry in columns.entries)
        '${_quote(entry.key)} ${entry.value}'
            '${keys.length == 1 && keys.first == entry.key ? ' PRIMARY KEY' : ''}',
    ];
    if (keys.length > 1) defs.add('PRIMARY KEY (${keys.map(_quote).join(', ')})');
    return 'CREATE TABLE IF NOT EXISTS ${_quote(target)} (\n  '
        '${defs.join(',\n  ')}\n)';
  }

  /// 建表之后要的索引（大库上按 vod_id / 人物名查得动）。
  static const List<String> indexSql = [
    'CREATE INDEX IF NOT EXISTS idx_va_vod ON video_actress(vod_id)',
    'CREATE INDEX IF NOT EXISTS idx_va_cate ON video_actress(cate_id)',
    'CREATE INDEX IF NOT EXISTS idx_vc_category ON video_category(main_category)',
    'CREATE INDEX IF NOT EXISTS idx_vt_tag ON video_tag(tag_name)',
    'CREATE INDEX IF NOT EXISTS idx_actresses_name ON actresses(name)',
    // 2026-11-23 v58 验机补齐：videos(vod_pubdate)（点人 ORDER BY
    // vod_pubdate DESC）、video_category(vod_id)（LEFT JOIN 探针）、
    // videos(vod_play_from)（站点去重/筛选）。只加索引，不动行。
    'CREATE INDEX IF NOT EXISTS idx_moyi_v_pubdate ON videos(vod_pubdate)',
    'CREATE INDEX IF NOT EXISTS idx_moyi_vc_vod ON video_category(vod_id)',
    'CREATE INDEX IF NOT EXISTS idx_moyi_v_play_from ON videos(vod_play_from)',
  ];

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';
}

/// 给任何一个已落盘的视频库补索引（2026-11-23 v58 验机：全球丽影库读
/// videos 太慢——合并库的 videos 表除主键外一个索引都没有，34 万行
/// 全表扫；而且影视库不只读主库 女优库.db，MYTV/db/ 下别的 .db 也读，
/// 补索引与快读必须对任何一个打开的库都生效，不能只修主库）。
///
/// 只 CREATE INDEX，不改任何一行数据；表/列不存在、库只读、磁盘满时
/// 单条跳过，整体永不抛错。调用方在只读打开前顺手调一次即可
/// （unawaited，不堵首屏；建过一次后 IF NOT EXISTS 直接跳过）。
/// 返回建成的条数（0 也正常：已经建过、或这个库不是视频库结构）。
Future<int> ensureVideoDbIndexes(String filePath) async {
  Database? db;
  try {
    final file = File(filePath);
    if (!await file.exists()) return 0;
    db = await openDatabase(filePath, singleInstance: false);
    var built = 0;
    for (final sql in VideoDbStandards.indexSql) {
      try {
        await db.execute(sql);
        built++;
      } catch (_) {
        // 表/列不存在（不是视频库结构）或库只读：跳过这条。
      }
    }
    return built;
  } catch (_) {
    return 0;
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}

/// 整理结果（给用户看的数字 + 过程说明）。
class VideoDbNormalizeReport {
  VideoDbNormalizeReport();

  /// 新建出来的表（外来库缺的表）。
  final List<String> createdTables = [];

  /// 补上的列，形如 `videos.vod_year`。
  final List<String> addedColumns = [];

  /// 去掉的列，形如 `videos.vod_actor`。
  final List<String> droppedColumns = [];

  /// 因为要去多余列而重建过的表。
  final List<String> rebuiltTables = [];

  /// 从外来列搬到标准列的行数（标题/封面/播放地址/分类/日期）。
  var remappedRows = 0;

  /// 播放地址两列互填（m3u8_url ↔ vod_play_url）的行数。
  var playUrlBackfilled = 0;

  /// 用潮流名册补上的头像数。
  var avatarsFilled = 0;

  /// 补上的性别数（女优 / 男优）。
  var sexesFilled = 0;

  /// 体检过的播放域名数。
  var hostsChecked = 0;

  /// 判死的域名（原域名）。
  final List<String> deadHosts = [];

  /// 换成功的域名映射：老 host → 新 host。
  final Map<String, String> hostFixes = {};

  /// 换掉域名的行数。
  var urlsRewritten = 0;

  /// 判断用的话（没凑齐数据、跳过某步之类）。
  final List<String> notes = [];

  bool get changed =>
      createdTables.isNotEmpty ||
      addedColumns.isNotEmpty ||
      droppedColumns.isNotEmpty ||
      remappedRows > 0 ||
      playUrlBackfilled > 0 ||
      avatarsFilled > 0 ||
      sexesFilled > 0 ||
      urlsRewritten > 0;

  String get summary {
    final parts = <String>[];
    if (createdTables.isNotEmpty) parts.add('补建表 ${createdTables.length} 张');
    if (addedColumns.isNotEmpty) parts.add('补字段 ${addedColumns.length} 个');
    if (droppedColumns.isNotEmpty) parts.add('去掉多余字段 ${droppedColumns.length} 个');
    if (rebuiltTables.isNotEmpty) parts.add('重建表 ${rebuiltTables.length} 张');
    if (remappedRows > 0) parts.add('搬正字段值 $remappedRows 行');
    if (playUrlBackfilled > 0) parts.add('补齐播放地址 $playUrlBackfilled 行');
    if (avatarsFilled > 0) parts.add('补头像 $avatarsFilled 人');
    if (sexesFilled > 0) parts.add('补性别 $sexesFilled 人');
    if (hostFixes.isNotEmpty) parts.add('换播放域名 ${hostFixes.length} 个');
    if (urlsRewritten > 0) parts.add('换地址 $urlsRewritten 行');
    return parts.isEmpty ? '这个库本来就是女优库结构，没动它' : parts.join('，');
  }
}

/// 把外来视频库整理成女优库结构。
///
/// 一次做完四件事：
/// 1. 结构对齐：标准表/列补齐，多余列去掉（值能对上的先搬正再删）；
/// 2. 地址两列互填：`m3u8_url` 与 `vod_play_url` 谁空补谁；
/// 3. 头像/性别：用潮流名册（同 `chaoliu.py` 的 actors.json）补空头像；
/// 4. 播放域名：库里的域名逐个验活，判死的换到能通的同源域名上。
///
/// 任何一步失败都不抛给上层——写进 [VideoDbNormalizeReport.notes]，
/// 其余步骤照做（用户要的是「能修的都修」，不是「一步失败全废」）。
class VideoDbNormalizer {
  const VideoDbNormalizer._();

  /// 单个库最多查多少个播放域名（域名一般十几个，这里防脏数据）。
  static const maxHosts = 60;

  /// 每个域名最多取几条样本来验活（省流量、也够判）。
  static const samplesPerHost = 2;

  static Future<VideoDbNormalizeReport> run(
    String filePath, {
    GenericDbSchema? schema,
    void Function(String stage)? onStage,
    Map<String, ({String avatar, String sex})>? profiles,
    List<String> extraHosts = const <String>[],
    bool fillProfiles = true,
    bool repairHosts = true,
    bool dropExtraColumns = false,
  }) async {
    final report = VideoDbNormalizeReport();
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('库文件不存在：$filePath');
    }
    onStage?.call('打开库…');
    final db = await openDatabase(filePath);
    try {
      await db.execute('PRAGMA foreign_keys = OFF');
      onStage?.call('对齐表结构');
      await _alignSchema(db, schema, report, onStage, dropExtraColumns);

      onStage?.call('补齐播放地址');
      await _backfillPlayUrl(db, report);

      if (fillProfiles) {
        onStage?.call('补齐女优头像');
        await _fillProfiles(db, report, profiles, onStage);
      }

      if (repairHosts) {
        onStage?.call('检查播放域名');
        await _repairHosts(db, report, extraHosts, onStage);
      }

      onStage?.call('收尾');
      try {
        await db.execute('ANALYZE');
      } catch (_) {}
    } finally {
      await db.close();
    }
    return report;
  }

  // ── 1. 结构对齐 ────────────────────────────────────────────────

  static Future<void> _alignSchema(
    Database db,
    GenericDbSchema? schema,
    VideoDbNormalizeReport report,
    void Function(String stage)? onStage,
    bool dropExtraColumns,
  ) async {
    final existing = await _tableNames(db);
    for (final table in VideoDbStandards.tables.keys) {
      if (!existing.contains(table)) {
        try {
          await db.execute(VideoDbStandards.createSql(table));
          report.createdTables.add(table);
        } catch (error) {
          report.notes.add('建 $table 失败：$error');
        }
      }
    }

    for (final entry in VideoDbStandards.tables.entries) {
      final table = entry.key;
      final standard = entry.value;
      if (!await _tableExists(db, table)) continue;
      final current = await _columns(db, table);
      // 缺列：直接加（SQLite 只能加在末尾，够用）。
      for (final column in standard.keys) {
        if (current.any((name) => name.toLowerCase() == column)) continue;
        try {
          await db.execute(
            'ALTER TABLE ${VideoDbStandards._quote(table)} '
            'ADD COLUMN ${VideoDbStandards._quote(column)} ${standard[column]}',
          );
          report.addedColumns.add('$table.$column');
        } catch (error) {
          report.notes.add('$table 补列 $column 失败：$error');
        }
      }
    }

    // 先把外来的值搬到标准列（不然重建表一删列，数据就没了）。
    await _remapValues(db, schema, report);

    // 多出来的列：只在用户明确要求「按女优库结构整理」时才重建表去掉。
    //
    // 体检修复默认**不动**外来库的字段集合——外来库里常有 vod_lang /
    // vod_director / vod_serial 这类标准表没有的列，那都是用户的数据，
    // 修个播放地址就把它们删了，等于修完反而少东西。所以默认只补列、
    // 只搬值，删列留给单独的「结构整理」动作。
    if (!dropExtraColumns) {
      for (final entry in VideoDbStandards.tables.entries) {
        final table = entry.key;
        final standard = entry.value;
        if (!await _tableExists(db, table)) continue;
        final current = await _columns(db, table);
        final extra = current
            .where(
              (name) => !standard.keys.any((c) => c == name.toLowerCase()),
            )
            .toList();
        if (extra.isNotEmpty) {
          report.notes.add('$table 的 ${extra.length} 个非标准字段保持原样：${extra.join('、')}');
        }
      }
    }
    if (dropExtraColumns) {
        for (final entry in VideoDbStandards.tables.entries) {
          final table = entry.key;
          final standard = entry.value;
          if (!await _tableExists(db, table)) continue;
          final current = await _columns(db, table);
          final extra = current
              .where(
                (name) => !standard.keys.any((c) => c == name.toLowerCase()),
              )
              .toList();
          if (extra.isEmpty) continue;
          onStage?.call('去掉 $table 的多余字段（${extra.length} 个）');
          try {
            await _rebuild(db, table, standard, report);
            report.rebuiltTables.add(table);
            for (final column in extra) {
              report.droppedColumns.add('$table.$column');
            }
          } catch (error) {
            report.notes.add('$table 去多余列失败（原样保留）：$error');
          }
        }

    }
    for (final sql in VideoDbStandards.indexSql) {
      try {
        await db.execute(sql);
      } catch (_) {}
    }
  }

  /// 外来库的字段名跟女优库不一样：按探测/手动映射把值搬进标准列。
  ///
  /// 只填空列（标准列已有值不动），所以重复执行安全。
  static Future<void> _remapValues(
    Database db,
    GenericDbSchema? schema,
    VideoDbNormalizeReport report,
  ) async {
    if (!await _tableExists(db, 'videos')) return;
    final columns = await _columns(db, 'videos');
    final lower = {for (final c in columns) c.toLowerCase(): c};
    final targets = <String, List<String>>{
      // 主键：外来库的主键常常就叫 plain `id`（2026-11-22 截图库），
      // 不搬过来标准列 `vod_id` 全空，后面重建表会因主键空整批跳过。
      'vod_id': ['vod_id', 'id', 'video_id', 'videoid', 'vid', 'movie_id'],
      'title': ['title', 'vod_name', 'name', 'moviename', 'videoname', '片名', '标题'],
      'pic_url': ['pic_url', 'vod_pic', 'cover', 'pic', 'img', 'image', '封面'],
      'vod_play_url': ['vod_play_url', 'play_url', 'url', 'playurl', 'm3u8_url', 'm3u8', '播放地址'],
      // `category_id` 是外来库最常见的分类列名：旧表只有 `category` /
      // `class` / `type`，`category_id` 对不上，分类搬不过来。
      'type_name': ['type_name', 'category', 'category_id', 'categoryid', 'class', 'type', '分类'],
      'vod_pubdate': ['vod_pubdate', 'date', 'pubdate', 'update_time', '时间'],
    };
    // 探测/手动映射到的列优先（那才是用户确认过的口径）。
    final roles = schema?.worksTable?.columns;
    if (roles != null) {
      void prefer(String standard, GenericDbRole role) {
        final actual = roles[role];
        if (actual == null || actual.isEmpty) return;
        final list = targets[standard];
        if (list == null) return;
        list.remove(actual);
        list.insert(0, actual);
      }

      prefer('title', GenericDbRole.title);
      prefer('pic_url', GenericDbRole.cover);
      prefer('vod_play_url', GenericDbRole.playUrl);
      prefer('type_name', GenericDbRole.category);
      prefer('vod_pubdate', GenericDbRole.date);
    }

    for (final entry in targets.entries) {
      final standard = entry.key;
      final standardColumn = lower[standard];
      if (standardColumn == null) continue;
      for (final candidate in entry.value) {
        final source = lower[candidate.toLowerCase()];
        if (source == null || source == standardColumn) continue;
        try {
          final changed = await db.rawUpdate(
            'UPDATE ${VideoDbStandards._quote('videos')} '
            'SET ${VideoDbStandards._quote(standardColumn)} = ${VideoDbStandards._quote(source)} '
            'WHERE (${VideoDbStandards._quote(standardColumn)} IS NULL '
            'OR TRIM(${VideoDbStandards._quote(standardColumn)}) = \'\') '
            'AND ${VideoDbStandards._quote(source)} IS NOT NULL '
            'AND TRIM(${VideoDbStandards._quote(source)}) <> \'\'',
          );
          report.remappedRows += changed;
        } catch (error) {
          report.notes.add('搬 $source → $standard 失败：$error');
          break;
        }
      }
    }
  }

  /// 重建一张表：先建同结构的临时表，把共有列分批拷过去，再换名。
  ///
  /// 大库（几十万行）也照这个走，只是批小一点；拷完才删旧表，中途失败
  /// 旧表还在，不会把库弄没。
  ///
  /// 三道守卫（2026-11-22 用户报「修复把数据库删坏了」后加）：
  /// 1. 共有列是空的——外来库的列名跟标准列一个都对不上（截图库的
  ///    videos：id/category_id/name/image/… 对标准列全是空交集），
  ///    这时重建等于把整表换成空表：直接拦下，原表不动；
  /// 2. 主键列不在共有列里——拷过去的行会因主键空被整批跳过，同样
  ///    等于清空：直接拦下，原表不动；
  /// 3. 行数校验——临时表行数 + 因主键空跳过的行数必须等于原表行数，
  ///    对不上就删临时表、抛错，原表不动；
  /// 换表（删旧表 + 改名）放进同一个事务里，中途失败原表还在。
  static Future<void> _rebuild(
    Database db,
    String table,
    Map<String, String> standard,
    VideoDbNormalizeReport report,
  ) async {
    final quoted = VideoDbStandards._quote(table);
    final tmp = '${table}__norm_tmp';
    final tmpQuoted = VideoDbStandards._quote(tmp);

    final current = await _columns(db, table);
    final shared = [
      for (final column in standard.keys)
        if (current.any((name) => name.toLowerCase() == column)) column,
    ];
    if (shared.isEmpty) {
      throw StateError(
        '重建 $table 被拦下：没有一列能对上标准列，重建会清空整表，原表未动',
      );
    }
    final keys = VideoDbStandards.primaryKeys[table] ?? const <String>[];
    final missingKeys = [
      for (final key in keys)
        if (!shared.any((c) => c.toLowerCase() == key)) key,
    ];
    if (missingKeys.isNotEmpty) {
      throw StateError(
        '重建 $table 被拦下：主键列 ${missingKeys.join('、')} 不在原表里，'
        '重建会丢全部行，原表未动',
      );
    }

    await db.execute('DROP TABLE IF EXISTS $tmpQuoted');
    await db.execute(VideoDbStandards.createSql(table, name: tmp));

    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $quoted'),
        ) ??
        0;
    final columnList = shared.map(VideoDbStandards._quote).join(', ');
    const batch = 2000;
    var done = 0;
    var skipped = 0;
    while (done < total) {
      final rows = await db.rawQuery(
        'SELECT $columnList FROM $quoted LIMIT $batch OFFSET $done',
      );
      if (rows.isEmpty) break;
      final insert = db.batch();
      for (final row in rows) {
        final values = <String, Object?>{
          for (final column in shared) column: row[column],
        };
        // 主键列空的行没法进标准表（主键非空），跳过。
        if (keys.any((key) => values[key] == null || '${values[key]}'.isEmpty)) {
          skipped++;
          continue;
        }
        insert.insert(
          tmp,
          values,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await insert.commit(noResult: true);
      done += rows.length;
    }

    // 行数校验：主键冲突去重也会让行数对不上，对不上就是数据丢了。
    final copied =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $tmpQuoted'),
        ) ??
        0;
    if (copied + skipped != total) {
      await db.execute('DROP TABLE $tmpQuoted');
      throw StateError(
        '重建 $table 被拦下：拷过去 $copied 行、跳过 $skipped 行，'
        '对不上原表 $total 行，临时表已删、原表未动',
      );
    }

    await db.transaction((txn) async {
      await txn.execute('DROP TABLE $quoted');
      await txn.execute('ALTER TABLE $tmpQuoted RENAME TO $quoted');
    });
  }

  // ── 2. 播放地址两列互填 ────────────────────────────────────────

  /// `m3u8_url` 是女优库的主用列，`vod_play_url` 是「名字$地址」选集串。
  /// 外来库常常只填其中一列，这里互相补齐（空的那列从满的那列取）。
  static Future<void> _backfillPlayUrl(
    Database db,
    VideoDbNormalizeReport report,
  ) async {
    if (!await _tableExists(db, 'videos')) return;
    final columns = await _columns(db, 'videos');
    bool has(String name) => columns.any((c) => c.toLowerCase() == name);
    if (!has('m3u8_url') || !has('vod_play_url')) return;

    final total =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM videos'),
        ) ??
        0;
    const batch = 3000;
    var offset = 0;
    while (offset < total) {
      final rows = await db.rawQuery(
        'SELECT rowid AS rid, m3u8_url, vod_play_url FROM videos '
        'LIMIT $batch OFFSET $offset',
      );
      if (rows.isEmpty) break;
      final updates = <String, Map<String, Object?>>{};
      for (final row in rows) {
        final m3u8 = (row['m3u8_url'] as String?)?.trim() ?? '';
        final play = (row['vod_play_url'] as String?)?.trim() ?? '';
        if (m3u8.isEmpty && play.isNotEmpty) {
          final url = firstUrlIn(play);
          if (url.isNotEmpty) updates['${row['rid']}'] = {'m3u8_url': url};
        } else if (play.isEmpty && m3u8.isNotEmpty) {
          updates['${row['rid']}'] = {'vod_play_url': '正片\$$m3u8'};
        }
      }
      if (updates.isNotEmpty) {
        final b = db.batch();
        for (final entry in updates.entries) {
          b.update(
            'videos',
            entry.value,
            where: 'rowid = ?',
            whereArgs: [int.tryParse(entry.key) ?? entry.key],
          );
        }
        await b.commit(noResult: true);
        report.playUrlBackfilled += updates.length;
      }
      offset += rows.length;
      if (rows.length < batch) break;
    }
  }

  // ── 3. 头像 / 性别 ─────────────────────────────────────────────

  /// 用潮流名册补空头像、空性别。
  ///
  /// 库里已有的头像不覆盖（用户自己挑的图别动）；只补空的和明显坏掉的
  /// （data: 空串、非 http 开头）。名字按 `归一名` 对上——全半角、空格、
  /// 括号别名都归一后再比。
  static Future<void> _fillProfiles(
    Database db,
    VideoDbNormalizeReport report,
    Map<String, ({String avatar, String sex})>? profiles,
    void Function(String stage)? onStage,
  ) async {
    if (!await _tableExists(db, 'actresses')) return;
    final columns = await _columns(db, 'actresses');
    bool has(String name) => columns.any((c) => c.toLowerCase() == name);
    if (!has('name')) return;

    Map<String, ({String avatar, String sex})> map;
    if (profiles != null) {
      map = profiles;
    } else {
      onStage?.call('取潮流名册');
      try {
        map = await fetchChaoliuProfiles();
      } catch (error) {
        report.notes.add('取潮流名册失败（头像这步跳过）：$error');
        return;
      }
    }
    if (map.isEmpty) {
      report.notes.add('潮流名册是空的，头像这步跳过');
      return;
    }

    final rows = await db.rawQuery(
      'SELECT rowid AS rid, '
      '${VideoDbStandards._quote('name')} AS name, '
      '${has('avatar') ? '${VideoDbStandards._quote('avatar')} AS avatar' : 'NULL AS avatar'}, '
      '${has('sex') ? '${VideoDbStandards._quote('sex')} AS sex' : 'NULL AS sex'} '
      'FROM actresses',
    );
    final b = db.batch();
    var pending = 0;
    for (final row in rows) {
      final name = normalizeActressName('${row['name'] ?? ''}');
      if (name.isEmpty) continue;
      final profile = map[name];
      if (profile == null) continue;
      final avatar = '${row['avatar'] ?? ''}'.trim();
      final sex = '${row['sex'] ?? ''}'.trim();
      final needAvatar =
          profile.avatar.isNotEmpty &&
          (avatar.isEmpty || !isHttpUrl(avatar));
      final needSex = profile.sex.isNotEmpty && sex.isEmpty;
      if (!needAvatar && !needSex) continue;
      final values = <String, Object?>{};
      if (needAvatar) values['avatar'] = profile.avatar;
      if (needSex) values['sex'] = profile.sex;
      b.update(
        'actresses',
        values,
        where: 'rowid = ?',
        whereArgs: [row['rid']],
      );
      if (needAvatar) report.avatarsFilled++;
      if (needSex) report.sexesFilled++;
      pending++;
      if (pending % 500 == 0) await b.commit(noResult: true);
    }
    if (pending > 0) await b.commit(noResult: true);
  }

  /// 潮流名册（`chaoliu.py` 同源）：名字 → 头像 + 性别。
  static Future<Map<String, ({String avatar, String sex})>>
  fetchChaoliuProfiles() async {
    final response = await ContentHttp().getRaw(
      '${ChaoliuRosterSource.webBase}/jp220/actors.json'
      '?v=${ChaoliuRosterSource.jpVersion}',
      headers: const {'Accept': 'application/json'},
      timeout: const Duration(seconds: 45),
    );
    if (response.statusCode != 200) {
      throw StateError('chaoliu roster http ${response.statusCode}');
    }
    return parseChaoliuProfiles(
      utf8.decode(response.bodyBytes, allowMalformed: true),
    );
  }

  /// 解析潮流 actors.json → 名字 → 头像/性别。纯函数，便于测试。
  static Map<String, ({String avatar, String sex})> parseChaoliuProfiles(
    String body,
  ) {
    final decoded = jsonDecode(body);
    final actors = decoded is Map ? decoded['actors'] : decoded;
    if (actors is! List) {
      throw const FormatException('chaoliu roster: expected an array');
    }
    final out = <String, ({String avatar, String sex})>{};
    for (final item in actors) {
      if (item is! Map) continue;
      final name = normalizeActressName('${item['n'] ?? ''}');
      if (name.isEmpty) continue;
      var avatar = '${item['a'] ?? ''}'.trim();
      if (avatar.isEmpty) {
        // 跟名册同一回落：没给图就用 /jp/av/<id>.jpg。
        final id = '${item['id'] ?? ''}'.trim();
        if (id.isNotEmpty) {
          avatar = '${ChaoliuRosterSource.webBase}/jp/av/$id.jpg';
        }
      }
      final sex = '${item['s'] ?? ''}'.trim();
      if (avatar.isEmpty && sex.isEmpty) continue;
      out[name] = (avatar: isHttpUrl(avatar) ? avatar : '', sex: sex);
    }
    return out;
  }

  // ── 4. 播放域名 ────────────────────────────────────────────────

  /// 库里的播放域名逐个验活：能通的记录，判死的找替换。
  ///
  /// 替换候选按可靠度排：
  /// 1. 库里同一个注册域下活得下来的域名（`v.hersav.me` ↔ `hersav.me`）；
  /// 2. 调用方给的站域名池（内置站当前域名）；
  /// 3. 去掉子域的主域、以及 `v.` / `www.` 变体。
  ///
  /// 每个候选都拿死域名的一条真实样本地址试播（保留原 path），通了才
  /// 全库替换；一个候选都通就只在报告里列出来，**不瞎改地址**。
  static Future<void> _repairHosts(
    Database db,
    VideoDbNormalizeReport report,
    List<String> extraHosts,
    void Function(String stage)? onStage,
  ) async {
    if (!await _tableExists(db, 'videos')) return;
    final columns = await _columns(db, 'videos');
    final urlColumns = [
      for (final name in ['m3u8_url', 'vod_play_url'])
        if (columns.any((c) => c.toLowerCase() == name)) name,
    ];
    if (urlColumns.isEmpty) return;

    // 采样：域名 → 样本地址（每域名留两三条）。
    final select = [
      'rowid AS rid',
      for (final name in urlColumns) VideoDbStandards._quote(name),
    ].join(', ');
    final rows = await db.rawQuery('SELECT $select FROM videos');
    final samples = <String, List<String>>{};
    for (final row in rows) {
      for (final name in urlColumns) {
        final value = row[name];
        if (value is! String || value.trim().isEmpty) continue;
        final url = firstUrlIn(value);
        if (url.isEmpty) continue;
        final host = hostOf(url);
        if (host.isEmpty) continue;
        final list = samples.putIfAbsent(host, () => <String>[]);
        if (list.length < samplesPerHost && !list.contains(url)) {
          list.add(url);
        }
      }
      if (samples.length >= maxHosts) break;
    }
    if (samples.isEmpty) {
      report.notes.add('库里没有可用的播放地址，域名这步跳过');
      return;
    }

    // 验活：每个域名先试第一条样本，再看第二条（单条抽风不算死）。
    final alive = <String>{};
    final dead = <String>[];
    var checked = 0;
    for (final entry in samples.entries) {
      checked++;
      onStage?.call('验播放域名 $checked/${samples.length}：${entry.key}');
      var verdict = RepairVerdict.dead;
      for (final url in entry.value) {
        verdict = await probeUrl(url);
        if (verdict == RepairVerdict.alive) break;
      }
      if (verdict == RepairVerdict.alive) {
        alive.add(entry.key);
      } else if (verdict == RepairVerdict.dead) {
        dead.add(entry.key);
      } else {
        report.notes.add('${entry.key} 测不准（403/超时），保留原样不换');
      }
    }
    report.hostsChecked = checked;
    report.deadHosts.addAll(dead);
    if (dead.isEmpty) return;

    // 判死的逐个找替换。
    for (final host in dead) {
      final candidates = candidateHosts(host, alive, extraHosts);
      if (candidates.isEmpty) {
        report.notes.add('$host 判死，但找不到可替换的域名');
        continue;
      }
      final sampleUrl = samples[host]!.first;
      String? picked;
      for (final candidate in candidates) {
        onStage?.call('试替换 $host → $candidate');
        final probe = replaceHost(sampleUrl, candidate);
        if (probe.isEmpty) continue;
        final verdict = await probeUrl(probe);
        if (verdict == RepairVerdict.alive) {
          picked = candidate;
          break;
        }
      }
      if (picked == null) {
        report.notes.add(
          '$host 判死，候选域名 ${candidates.take(3).join(' / ')} 都放不出这个地址',
        );
        continue;
      }
      var rewritten = 0;
      for (final name in urlColumns) {
        final quotedName = VideoDbStandards._quote(name);
        rewritten += await db.rawUpdate(
          'UPDATE videos SET $quotedName = REPLACE($quotedName, ?, ?) '
          'WHERE $quotedName LIKE ?',
          ['://$host', '://$picked', '%://$host%'],
        );
      }
      report.hostFixes[host] = picked;
      report.urlsRewritten += rewritten;
      alive.add(picked);
    }
  }

  // ── 探活 ──────────────────────────────────────────────────────

  static Future<RepairVerdict> probeUrl(String url) async {
    final target = url.trim();
    final uri = Uri.tryParse(target);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return RepairVerdict.dead;
    }
    try {
      final response = await probeStreamHead(
        target,
        const {},
        const Duration(seconds: 12),
      );
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        if (target.toLowerCase().contains('.m3u8')) {
          final head = String.fromCharCodes(
            response.headBytes.take(16).toList(growable: false),
          );
          return head.contains('#EXTM3U')
              ? RepairVerdict.alive
              : RepairVerdict.unknown;
        }
        return RepairVerdict.alive;
      }
      if (code == 404 || code == 410) return RepairVerdict.dead;
      return RepairVerdict.unknown;
    } catch (error) {
      final text = error.toString().toLowerCase();
      // DNS 不解析 / 拒绝连接 = 域名没了；超时/重置算测不准，不乱判死。
      if (text.contains('failed host lookup') ||
          text.contains('nodename nor servname') ||
          text.contains('connection refused') ||
          text.contains('no address associated')) {
        return RepairVerdict.dead;
      }
      return RepairVerdict.unknown;
    }
  }
}

/// 探测结论（跟体检修复同一套语义：只删真死的）。
enum RepairVerdict { alive, dead, unknown }

/// 从「名字$地址#第2集$地址」这种选集串里取第一个 http 地址。
String firstUrlIn(String value) {
  final match = RegExp(r'https?://[^\s$#|]+').firstMatch(value);
  return match?.group(0)?.trim() ?? '';
}

/// URL 的 host（带端口的一并带上，替换时要用原样的 host:port）。
String hostOf(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return '';
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// 把 url 的 host 换成 [host]（path/query 原样保留，用来试候选域名）。
String replaceHost(String url, String host) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty || host.isEmpty) return '';
  return uri
      .replace(host: host.split(':').first, port: host.contains(':') ? int.tryParse(host.split(':').last) : null)
      .toString();
}

/// 注册域（近似：取最后两段）。`v.hersav.me` → `hersav.me`。
String registrableDomain(String host) {
  final clean = host.split(':').first.toLowerCase();
  final parts = clean.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.length <= 2) return clean;
  return parts.sublist(parts.length - 2).join('.');
}

/// 给一个判死的域名找候选替换域名（按可靠度排序）。
///
/// 纯函数：只算候选，不联网；[alive] 是库里验活过的域名，[extra] 是
/// 调用方补的站域名池。
List<String> candidateHosts(
  String dead,
  Set<String> alive,
  List<String> extra,
) {
  final domain = registrableDomain(dead);
  final out = <String>[];
  void add(String host) {
    final clean = host.trim().toLowerCase();
    if (clean.isEmpty || clean == dead.toLowerCase()) return;
    if (out.contains(clean)) return;
    out.add(clean);
  }

  // 1. 同一个注册域的活域名（`v.hersav.me` 死了，`hersav.me` 还活）。
  for (final host in alive) {
    if (registrableDomain(host) == domain) add(host);
  }
  // 2. 主域本身，和常见子域变体。
  add(domain);
  for (final prefix in ['www', 'v', 'm']) {
    add('$prefix.$domain');
  }
  // 3. 调用方给的站域名池（内置站当前域名）里同注册域的。
  for (final host in extra) {
    if (registrableDomain(host) == domain) add(host);
  }
  // 4. 池子里其它域名也排上（有些站整批迁域名，对得上 path 就通）。
  for (final host in extra) {
    add(host);
  }
  return out;
}

/// 女优名归一：全半角、空格、括号别名、大小写都抹平后再比。
String normalizeActressName(String name) {
  var text = name.trim().toLowerCase();
  if (text.isEmpty) return '';
  // 全角 → 半角。
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buffer.writeCharCode(rune - 0xFEE0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  text = buffer.toString();
  // 别名/备注：(xxx)、[xxx]、【xxx】全去掉。
  text = text
      .replaceAll(RegExp(r'[\(（\[【].*?[\)）\]】]'), '')
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[·・.,，。]'), '');
  return text;
}

bool isHttpUrl(String value) {
  final text = value.trim().toLowerCase();
  return text.startsWith('http://') || text.startsWith('https://');
}

/// 从一批 URL 里挑一组域名（给调用方传 extraHosts 用）。
List<String> hostsFromUrls(Iterable<String> urls) {
  final out = <String>{};
  for (final url in urls) {
    final host = hostOf(url);
    if (host.isNotEmpty) out.add(host);
  }
  return out.toList();
}

/// 插一个便于 UI 显示的域名统计（域名 → 条数），从库里抽样统计。
Future<Map<String, int>> countPlayHosts(Database db, {int limit = 200000}) async {
  final columns = await _columnsOf(db, 'videos');
  final targets = [
    for (final name in ['m3u8_url', 'vod_play_url'])
      if (columns.any((c) => c.toLowerCase() == name)) name,
  ];
  final out = <String, int>{};
  if (targets.isEmpty) return out;
  final rows = await db.rawQuery(
    'SELECT ${targets.map((c) => VideoDbStandards._quote(c)).join(', ')} '
    'FROM videos LIMIT $limit',
  );
  for (final row in rows) {
    for (final name in targets) {
      final value = row[name];
      if (value is! String || value.isEmpty) continue;
      final host = hostOf(firstUrlIn(value));
      if (host.isEmpty) continue;
      out[host] = (out[host] ?? 0) + 1;
    }
  }
  return out;
}

Future<List<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '%__norm_tmp'",
  );
  return [for (final row in rows) '${row['name']}'];
}

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
    [table],
  );
  return rows.isNotEmpty;
}

Future<List<String>> _columns(Database db, String table) =>
    _columnsOf(db, table);

Future<List<String>> _columnsOf(Database db, String table) async {
  try {
    final rows = await db.rawQuery(
      'PRAGMA table_info(${VideoDbStandards._quote(table)})',
    );
    return [for (final row in rows) '${row['name']}'];
  } catch (_) {
    return const [];
  }
}

/// 记录一次整理过程里最大的表行数（UI 上提醒大库耗时的依据）。
Future<int> largestTableRows(Database db) async {
  var best = 0;
  for (final table in VideoDbStandards.tables.keys) {
    if (!await _tableExists(db, table)) continue;
    try {
      final count =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM ${VideoDbStandards._quote(table)}',
            ),
          ) ??
          0;
      best = math.max(best, count);
    } catch (_) {}
  }
  return best;
}
