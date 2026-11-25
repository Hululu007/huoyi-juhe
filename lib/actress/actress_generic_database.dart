import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart';
import 'actress_generic_db.dart';
import 'actress_models.dart';

String _q(String identifier) =>
    '"${identifier.replaceAll('"', '""')}"';

/// 通用库适配器（2026-11-23 用户令：数据库全部支持勾选）。
///
/// 把任意结构的视频库（表名/字段名与女优库三表不同，但里面有能播
/// 的视频地址）接进多库合并：人物按作品表里的女优列分组（每 distinct
/// 女优值一个人），作品/分类/去重键都走通用读法的字段映射
///（GenericDbReader 探出来的 worksTable + 角色列），不硬套
/// videos/video_actress/actresses 三表。
///
/// 读法口径与严格库同一套：
/// - 人物归并按归一化名字（列表页 _loadMergedPersons 做，与严格库同）；
/// - 作品去重键是 `归一化番号|有效播放地址`（与严格库
///   distinctWorkKeysForName 同形，番号键都过 normalizeAvCode，
///   跨库同作品才能对上；无番号的作品用标题当番号位）；
/// - 分类取通用读法的分类（优先 video_category.main_category，
///   否则作品表自己的分类列，见 GenericDbReader.categories）。
///
/// 限制（如实写，不编）：
/// - 作品表里没有女优列、或女优列全空的库（如 lsp.db 的 actor 列
///   全空、yellow.db 根本没有女优列、AV 总库的 results 表只有
///   番号没有女优列），分组不出人：listPersons 回空，合并时这个
///   库加 0 个人。它的作品仍在播放池里（MultiDbFilmFallback 早
///   就能开通用库），勾上后不白勾，但人是从 v3 合库那条路来的，
///   不是这个适配器变出来的。
/// - 只读：写/同步/叠加方法都是空操作（外来库文件一个字不动，
///   与 SqfliteActressDatabase.forPath 同口径）。
/// - 性别未知：通用库没有 sex 列，性别筛（女优/男优）时这个库
///   不出人（与严格库无 sex 列时同一口径）。
class GenericActressDatabase implements ActressDatabase {
  GenericActressDatabase._({
    required this.path,
    required Database db,
    required GenericDbSchema schema,
    required GenericDbReader reader,
    required String signature,
  }) : _db = db,
       _schema = schema,
       _reader = reader,
       _signature = signature;

  /// 只读打开一个通用库：没有作品表（认不出标题 + 播放地址）
  /// 时回 null，调用方跳过这个库。
  static Future<GenericActressDatabase?> open(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync() || file.lengthSync() == 0) return null;
    Database? db;
    try {
      // 2026-11-24 掉线修复：探库独立连接（singleInstance: false），
      // 关完不拖主库的共享连接掉线。
      db = await openDatabase(
        filePath,
        readOnly: true,
        singleInstance: false,
      );
      final schema = await probeGenericDbSchema(db);
      if (schema.worksTable == null) {
        await db.close();
        return null;
      }
      final reader = GenericDbReader(
        db: db,
        schema: schema,
        mappingStore: GenericDbMappingStore(
          file: File(p.join(p.dirname(filePath), '字段映射.json')),
        ),
      );
      return GenericActressDatabase._(
        path: filePath,
        db: db,
        schema: schema,
        reader: reader,
        signature: _signatureOf(file),
      );
    } catch (_) {
      await db?.close();
      return null;
    }
  }

  static String _signatureOf(File file) {
    try {
      final stat = file.statSync();
      return '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return '';
    }
  }

  final String path;

  Database _db;
  GenericDbSchema _schema;
  GenericDbReader _reader;
  String _signature;

  GenericDbTableMapping? get _works => _schema.worksTable;

  String? _col(GenericDbRole role) => _works?.columnFor(role);

  /// 作品表里的女优列：没有它就分不出人。
  String? get _actressCol => _col(GenericDbRole.actress);

  /// 跨表分类维度（作品表本身没有分类列、分类在副表里时用，
  /// 与 GenericDbReader._where 的 facet 写法同形）。
  GenericDbRelation? _categoryRelation() {
    for (final relation in _schema.facetRelations) {
      if (relation.columnFor(GenericDbRole.category) != null) {
        return relation;
      }
    }
    return null;
  }

  /// 分类过滤条件：作品表自己的分类列直接比；没有时走副表
  /// 半连接；两条路都没有时回 null（调方按“筛不出”处理）。
  (String, List<Object?>)? _categoryCondition(String category) {
    final works = _works;
    if (works == null) return null;
    final categoryCol = _col(GenericDbRole.category);
    if (categoryCol != null) {
      return ('CAST(${_q(categoryCol)} AS TEXT) = ?', [category]);
    }
    final relation = _categoryRelation();
    if (relation != null) {
      final relCatCol = relation.columnFor(GenericDbRole.category)!;
      return (
        'CAST(${_q(works.table)}.${_q(relation.primaryKey)} AS TEXT) '
        'IN (SELECT CAST(${_q(relation.foreignKey)} AS TEXT) '
        'FROM ${_q(relation.table)} '
        'WHERE CAST(${_q(relCatCol)} AS TEXT) = ?)',
        [category],
      );
    }
    return null;
  }

  /// 标签过滤条件（2026-11-24 标签筛选）：与 [_categoryCondition]
  /// 同形——副表（video_tag.tag_name）走精确 IN 半连接；作品表
  /// 自己的标签列（如 tags 列，常是逗号拼的多个标签）走 LIKE 模糊
  /// 匹配（可能误含子串，如实写，不冒充精确）；两条路都没有回 null
  ///（调用方按“筛不出”处理）。
  (String, List<Object?>)? _tagCondition(String tag) {
    final works = _works;
    if (works == null) return null;
    // 精确的副表优先（video_tag.tag_name）；没有才退到作品表
    // 自己的标签列。
    for (final relation in _schema.facetRelations) {
      final col = relation.columnFor(GenericDbRole.category);
      if (col == null) continue;
      if (!normalizeDbFieldName(col).contains('tag')) continue;
      return (
        'CAST(${_q(works.table)}.${_q(relation.primaryKey)} AS TEXT) '
        'IN (SELECT CAST(${_q(relation.foreignKey)} AS TEXT) '
        'FROM ${_q(relation.table)} '
        'WHERE CAST(${_q(col)} AS TEXT) = ?)',
        [tag],
      );
    }
    for (final column in categoryFacetColumns(works)) {
      if (normalizeDbFieldName(column).contains('tag')) {
        return (
          'CAST(${_q(column)} AS TEXT) LIKE ?',
          ['%$tag%'],
        );
      }
    }
    return null;
  }

  /// 作品行里分类值的取法：自己的分类列、或副表关联取、
  /// 或没有（空字符串）。
  String _categorySelect(String alias) {
    final categoryCol = _col(GenericDbRole.category);
    if (categoryCol != null) {
      return 'CAST($alias.${_q(categoryCol)} AS TEXT) AS category';
    }
    final relation = _categoryRelation();
    if (relation != null) {
      final relCatCol = relation.columnFor(GenericDbRole.category)!;
      return '(SELECT CAST(${_q(relCatCol)} AS TEXT) '
          'FROM ${_q(relation.table)} '
          'WHERE CAST(${_q(relation.foreignKey)} AS TEXT) = '
          'CAST($alias.${_q(relation.primaryKey)} AS TEXT) '
          'LIMIT 1) AS category';
    }
    return "'' AS category";
  }

  /// 女优值 → 人（localId 取该女优作品里最小的 rowid，
  /// 与 listPersons 的分组 id 同一口径）。
  Future<ActressPerson?> _personForName(String name) async {
    final works = _works;
    final actressCol = _actressCol;
    if (works == null || actressCol == null) return null;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final rows = await _db.rawQuery(
      'SELECT MIN(rowid) AS id, COUNT(*) AS c, '
      'MAX(${_dateOrder()}) AS last_date '
      'FROM ${_q(works.table)} '
      'WHERE ${_q(actressCol)} = ?',
      [trimmed],
    );
    if (rows.isEmpty) return null;
    final id = (rows.first['id'] as num?)?.toInt();
    final count = (rows.first['c'] as num?)?.toInt() ?? 0;
    if (id == null || count <= 0) return null;
    return ActressPerson(
      localId: id,
      displayName: trimmed,
      worksCount: count,
      rosterWorks: count,
      exactWorks: count,
    );
  }

  /// 日期列的排序表达式：没有日期列时按 rowid（入库顺序）排。
  String _dateOrder() {
    final dateCol = _col(GenericDbRole.date);
    if (dateCol == null) return 'rowid';
    return 'CAST(${_q(dateCol)} AS TEXT)';
  }

  /// 人物行 → 作品行（详情页用）：先按 rowid 取女优值，
  /// 再按女优值精确匹配作品（不 LIKE，避免同名串台）。
  Future<String?> _actressOfRow(int localId) async {
    final works = _works;
    final actressCol = _actressCol;
    if (works == null || actressCol == null) return null;
    final rows = await _db.rawQuery(
      'SELECT ${_q(actressCol)} AS name FROM ${_q(works.table)} '
      'WHERE rowid = ? LIMIT 1',
      [localId],
    );
    if (rows.isEmpty) return null;
    final name = rows.first['name']?.toString().trim() ?? '';
    return name.isEmpty ? null : name;
  }

  ActressWork _workFromRow(Map<String, Object?> row, int personId) {
    final code = row['code_key']?.toString().trim() ?? '';
    final title = row['title']?.toString().trim() ?? '';
    return ActressWork(
      id: (row['id'] as num?)?.toInt() ?? 0,
      personId: personId,
      codeKey: code,
      titleKey: code,
      codeDisplay: code,
      title: title,
      date: row['date']?.toString() ?? '',
      coverUrl: resolveCoverUrl(row['cover_url']),
      category: row['category']?.toString() ?? '',
    );
  }

  @override
  bool get isVideoLibrary => false;

  @override
  String? get openFallbackNote => null;

  @override
  Future<ActressPerson?> personById(int localId) async {
    final name = await _actressOfRow(localId);
    if (name == null) return null;
    return _personForName(name);
  }

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
    final works = _works;
    final actressCol = _actressCol;
    if (works == null || actressCol == null) return const [];
    // 通用库没有 sex 列：性别筛时不出人（与严格库无 sex 列同口径）。
    if (sex != ActressSexFilter.all) return const [];
    final conditions = <String>[
      '${_q(actressCol)} IS NOT NULL',
      "TRIM(CAST(${_q(actressCol)} AS TEXT)) <> ''",
    ];
    final args = <Object?>[];
    final trimmedQuery = query.trim();
    if (trimmedQuery.isNotEmpty) {
      conditions.add('${_q(actressCol)} LIKE ?');
      args.add('%$trimmedQuery%');
    }
    if (category.isNotEmpty) {
      final condition = _categoryCondition(category);
      if (condition == null) return const [];
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    if (videoTag.isNotEmpty) {
      final condition = _tagCondition(videoTag);
      if (condition == null) return const [];
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final where = 'WHERE ${conditions.join(' AND ')}';
    final dateCol = _col(GenericDbRole.date);
    final order = switch (sort) {
      ActressSort.worksDesc => 'works_count DESC, display_name ASC',
      ActressSort.nameAsc => 'display_name ASC',
      ActressSort.recentDesc => dateCol == null
          ? 'works_count DESC, display_name ASC'
          : 'last_date DESC, display_name ASC',
    };
    final rows = await _db.rawQuery(
      'SELECT MIN(rowid) AS id, ${_q(actressCol)} AS display_name, '
      'COUNT(*) AS works_count, MAX(${_dateOrder()}) AS last_date '
      'FROM ${_q(works.table)} $where '
      'GROUP BY ${_q(actressCol)} '
      'ORDER BY $order LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return [
      for (final row in rows)
        ActressPerson(
          localId: (row['id'] as num?)?.toInt() ?? 0,
          displayName: row['display_name']?.toString() ?? '',
          worksCount: (row['works_count'] as num?)?.toInt() ?? 0,
          rosterWorks: (row['works_count'] as num?)?.toInt() ?? 0,
          exactWorks: (row['works_count'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<int> countPersons({
    required ActressSexFilter sex,
    required String query,
    String tag = '',
    String videoTag = '',
  }) async {
    final works = _works;
    final actressCol = _actressCol;
    if (works == null || actressCol == null) return 0;
    if (sex != ActressSexFilter.all) return 0;
    final trimmedQuery = query.trim();
    final conditions = <String>[
      '${_q(actressCol)} IS NOT NULL',
      "TRIM(CAST(${_q(actressCol)} AS TEXT)) <> ''",
    ];
    final args = <Object?>[];
    if (trimmedQuery.isNotEmpty) {
      conditions.add('${_q(actressCol)} LIKE ?');
      args.add('%$trimmedQuery%');
    }
    if (videoTag.isNotEmpty) {
      final condition = _tagCondition(videoTag);
      if (condition == null) return 0;
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final rows = await _db.rawQuery(
      'SELECT COUNT(DISTINCT ${_q(actressCol)}) AS c '
      'FROM ${_q(works.table)} '
      'WHERE ${conditions.join(' AND ')}',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<List<ActressPerson>> allPersonsForRanking({
    required ActressSexFilter sex,
  }) async {
    return listPersons(
      sex: sex,
      sort: ActressSort.worksDesc,
      query: '',
      offset: 0,
      limit: 100000,
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
    final works = _works;
    if (works == null) return const [];
    final name = await _actressOfRow(personId);
    if (name == null) return const [];
    final actressCol = _actressCol!;
    final codeCol = _col(GenericDbRole.code);
    final titleCol = _col(GenericDbRole.title);
    final coverCol = _col(GenericDbRole.cover);
    final dateCol = _col(GenericDbRole.date);
    final conditions = <String>['${_q(actressCol)} = ?'];
    final args = <Object?>[name];
    final useCategory = category != null && category.isNotEmpty;
    if (useCategory) {
      final condition = _categoryCondition(category);
      if (condition == null) return const [];
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final useVideoTag = videoTag != null && videoTag.isNotEmpty;
    if (useVideoTag) {
      final condition = _tagCondition(videoTag);
      if (condition == null) return const [];
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final columns = <String>[
      'w.rowid AS id',
      if (codeCol != null) 'CAST(w.${_q(codeCol)} AS TEXT) AS code_key',
      if (codeCol == null) "'' AS code_key",
      if (titleCol != null) 'CAST(w.${_q(titleCol)} AS TEXT) AS title',
      if (titleCol == null) "'' AS title",
      if (coverCol != null) 'w.${_q(coverCol)} AS cover_url',
      if (coverCol == null) "'' AS cover_url",
      if (dateCol != null) 'CAST(w.${_q(dateCol)} AS TEXT) AS date',
      if (dateCol == null) "'' AS date",
      _categorySelect('w'),
    ];
    final rows = await _db.rawQuery(
      'SELECT ${columns.join(', ')} FROM ${_q(works.table)} w '
      'WHERE ${conditions.join(' AND ')} '
      'ORDER BY ${dateCol == null ? 'w.rowid' : 'CAST(w.${_q(dateCol)} AS TEXT)'} DESC, '
      'w.rowid DESC LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return [for (final row in rows) _workFromRow(row, personId)];
  }

  @override
  Future<int> countWorks(int personId, {String? category, String? videoTag}) async {
    final works = _works;
    if (works == null) return 0;
    final name = await _actressOfRow(personId);
    if (name == null) return 0;
    final actressCol = _actressCol!;
    final conditions = <String>['${_q(actressCol)} = ?'];
    final args = <Object?>[name];
    final useCategory = category != null && category.isNotEmpty;
    if (useCategory) {
      final condition = _categoryCondition(category);
      if (condition == null) return 0;
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final useVideoTag = videoTag != null && videoTag.isNotEmpty;
    if (useVideoTag) {
      final condition = _tagCondition(videoTag);
      if (condition == null) return 0;
      conditions.add(condition.$1);
      args.addAll(condition.$2);
    }
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${_q(works.table)} '
      'WHERE ${conditions.join(' AND ')}',
      args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Set<String>> distinctWorkKeysForName(String name) async {
    final works = _works;
    if (works == null) return const {};
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const {};
    final actressCol = _actressCol;
    if (actressCol == null) return const {};
    try {
      final codeCol = _col(GenericDbRole.code);
      final titleCol = _col(GenericDbRole.title);
      final playUrlCol = _col(GenericDbRole.playUrl);
      final relation = playUrlCol == null
          ? _schema.relationFor(GenericDbRole.playUrl)
          : null;
      final select = <String>[
        if (codeCol != null) 'CAST(w.${_q(codeCol)} AS TEXT) AS code_key',
        if (codeCol == null && titleCol != null)
          'CAST(w.${_q(titleCol)} AS TEXT) AS code_key',
        if (codeCol == null && titleCol == null) "'' AS code_key",
        if (playUrlCol != null) 'w.${_q(playUrlCol)} AS play_url',
        if (playUrlCol == null && relation != null)
          '(SELECT ${_q(relation.columnFor(GenericDbRole.playUrl)!)} '
              'FROM ${_q(relation.table)} '
              'WHERE CAST(${_q(relation.foreignKey)} AS TEXT) = '
              'CAST(w.${_q(relation.primaryKey)} AS TEXT) '
              'LIMIT 1) AS play_url',
        if (playUrlCol == null && relation == null) "'' AS play_url",
      ];
      final rows = await _db.rawQuery(
        'SELECT ${select.join(', ')} FROM ${_q(works.table)} w '
        'WHERE w.${_q(actressCol)} = ? LIMIT 50000',
        [trimmed],
      );
      return {
        for (final row in rows)
          '${normalizeAvCode(row['code_key']?.toString() ?? '')}|'
              '${extractPlayUrl(row['play_url'])}',
      };
    } catch (_) {
      return const {};
    }
  }

  @override
  Future<List<({String name, int count})>> workCategories(
    int personId,
  ) async {
    final works = _works;
    if (works == null) return const [];
    final name = await _actressOfRow(personId);
    if (name == null) return const [];
    final actressCol = _actressCol!;
    final categoryCol = _col(GenericDbRole.category);
    final relation = categoryCol == null ? _categoryRelation() : null;
    if (categoryCol == null && relation == null) return const [];
    final groupExpr = categoryCol != null
        ? 'CAST(w.${_q(categoryCol)} AS TEXT)'
        : '(SELECT CAST(${_q(relation!.columnFor(GenericDbRole.category)!)} AS TEXT) '
            'FROM ${_q(relation.table)} '
            'WHERE CAST(${_q(relation.foreignKey)} AS TEXT) = '
            'CAST(w.${_q(relation.primaryKey)} AS TEXT) LIMIT 1)';
    final rows = await _db.rawQuery(
      'SELECT $groupExpr AS name, COUNT(*) AS c '
      'FROM ${_q(works.table)} w '
      'WHERE w.${_q(actressCol)} = ? AND $groupExpr <> \'\' '
      'GROUP BY $groupExpr ORDER BY c DESC, name ASC',
      [name],
    );
    return [
      for (final row in rows)
        (
          name: row['name']?.toString() ?? '',
          count: (row['c'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  @override
  Future<List<(String, int)>> dbCategories() async {
    return _reader.categories();
  }

  /// 全库作品标签（通用读法的标签维度，见 [GenericDbReader.tagFacet]）。
  @override
  Future<List<(String, int)>> dbTags() async {
    final tag = await _reader.tagFacet();
    return tag.values;
  }

  @override
  Future<GenericDbReader?> genericReader() async => _reader;

  @override
  Future<({bool reloaded, String? error})> reloadIfChanged({
    bool force = false,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      return (reloaded: false, error: '数据库文件找不到了：$path');
    }
    final signature = _signatureOf(file);
    if (!force && signature == _signature && _db.isOpen) {
      return (reloaded: false, error: null);
    }
    Database? next;
    try {
      // 2026-11-24 掉线修复：探库独立连接，关完不拖主库掉线。
      next = await openDatabase(
        path,
        readOnly: true,
        singleInstance: false,
      );
      final schema = await probeGenericDbSchema(next);
      if (schema.worksTable == null) {
        await next.close();
        return (reloaded: false, error: '这个库认不出作品表');
      }
      final reader = GenericDbReader(
        db: next,
        schema: schema,
        mappingStore: GenericDbMappingStore(
          file: File(p.join(p.dirname(path), '字段映射.json')),
        ),
      );
      final old = _db;
      _db = next;
      _schema = schema;
      _reader = reader;
      _signature = signature;
      await old.close();
      return (reloaded: true, error: null);
    } catch (e) {
      await next?.close();
      return (reloaded: false, error: e.toString());
    }
  }

  @override
  Future<ActressSyncOverview> overview() async {
    final works = _works;
    var totalWorks = 0;
    if (works != null) {
      try {
        final rows = await _db.rawQuery(
          'SELECT COUNT(*) AS c FROM ${_q(works.table)}',
        );
        totalWorks = (rows.first['c'] as num?)?.toInt() ?? 0;
      } catch (_) {}
    }
    return ActressSyncOverview(
      persons: await countPersons(sex: ActressSexFilter.all, query: ''),
      works: totalWorks,
      sources: const {},
      lastUpdatedAt: 0,
    );
  }

  @override
  Future<void> close() async {
    if (_db.isOpen) await _db.close();
  }
}
