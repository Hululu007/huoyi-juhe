import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_json_fallback.dart';

/// 通用读库层（2026-11-20 用户令）：用户往 MYTV/db 里放的 db 不一定
/// 是女优库结构——表名、字段名都可能不一样。本层打开 sqlite 文件后
/// 先动态探结构（sqlite_master 列出所有表，每张表 PRAGMA table_info
/// 列出字段），再按字段名启发式映射，不认死字段名。
///
/// 女优库结构继续走严格路径（ActressDatabase 的 persons/works 表，
/// 最快最准）；探不到女优库结构时走这里，不要直接报错、不要显示空白。
/// 换库后重读要重新探结构，不要沿用旧库的字段映射（探结果按文件
/// 指纹缓存，文件变了自动重探）。
///
/// 影视库那批的新分类以后也走这套层，接线入口：
/// - [ActressDatabase.genericReader]（actress_database.dart）：当前
///   库不是女优库结构时返回 [GenericDbReader]，是时返回 null；
/// - [probeGenericDbSchema]：给一个已打开的 [Database] 探结构；
/// - [GenericDbReader.works]/[GenericDbReader.countWorks]：读作品；
/// - [normalizeDbFieldName]/[roleForColumn]：字段名归一化与打分；
/// - [extractPlayUrl]/[resolveCoverUrl]：播放地址与封面取值容差。
///
/// 字段名匹配（2026-11-20 用户加码：字段名差得很多，不能只靠几个
/// 别名硬认）：先归一化（全小写、去下划线/中划线/空格），再按关键词
/// 打分——精确全名最高分，含关键词按权重加分；含 play/url/m3u8/
/// video 一类词优先当播放地址，含 pic/cover/img/thumb 当封面，
/// 含 title/name 当标题。实在认不出的表不猜、不静默丢数据，进
/// “数据库字段”查看入口由用户手动指定（见 actress_db_fields_page.dart，
/// 映射按库文件结构指纹存下来，下次换同结构的库直接用）。

/// 通用映射的字段角色。
enum GenericDbRole { title, cover, playUrl, actress, code, category, date }

GenericDbRole? _roleByName(String name) {
  for (final role in GenericDbRole.values) {
    if (role.name == name) return role;
  }
  return null;
}

/// 字段名归一化：全小写、去下划线/中划线/空格（中英文同义词都在
/// 归一化后的名字上比）。
String normalizeDbFieldName(String name) {
  return name.trim().toLowerCase().replaceAll(RegExp(r'[_\-\s]'), '');
}

/// 精确全名（归一化后）：命中直接最高分。
const _exactNames = <GenericDbRole, List<String>>{
  GenericDbRole.title: [
    'vodname',
    'title',
    'name',
    'moviename',
    'videoname',
    'dramaname',
    'videotitle',
    '片名',
    '标题',
    'subject',
  ],
  GenericDbRole.cover: [
    'vodpic',
    'pic',
    'cover',
    'img',
    'poster',
    '海报',
    '封面',
    'thumb',
    'thumbnail',
    'image',
    'photo',
    'coverurl',
    'picurl',
    'vodpicurl',
    'imgurl',
    'posterurl',
  ],
  GenericDbRole.playUrl: [
    'vodplayurl',
    'playurl',
    'url',
    'm3u8',
    'play',
    'video',
    'videourl',
    '地址',
    '播放地址',
    'playaddress',
    'videopath',
    'filepath',
    'fileurl',
    'streamurl',
    'src',
    'playpath',
  ],
  GenericDbRole.actress: [
    'vodactor',
    'actor',
    'actress',
    '演员',
    '女优',
    'cast',
    'performer',
    'star',
    'artist',
    'actorname',
  ],
  GenericDbRole.code: [
    'vodcode',
    'code',
    '番号',
    'avcode',
    // 2026-11-22 用户报「所有数据库」都认不出番号：外来库的主键就叫
    // plain `id`（或 videoid/vid/vodid/movieid/workid），旧表里一个
    // 都没有，整库的番号角色全灭。精确全名只认整列名，`vid` 不会
    // 误伤 `video`（关键词里绝不加 `vid`，`video` 含 `vid`）。
    'id',
    'videoid',
    'vid',
    'vodid',
    'movieid',
    'workid',
  ],
  GenericDbRole.category: [
    'typename',
    'category',
    'categoryid',
    'type',
    '类别',
    '分类',
    'genre',
    'tag',
    'classname',
  ],
  GenericDbRole.date: [
    'vodpubdate',
    'pubdate',
    'date',
    'year',
    '时间',
    '日期',
    'addtime',
    'createtime',
    'updatetime',
  ],
};

/// 关键词打分（归一化后含该词即加分）：精确全名没命中时用。
/// 同一个字段名里多个关键词可叠加；'coverurl' 这类“封面 + url”
/// 的名字，封面分（cover 3）高于播放地址分（url 2），归封面。
const _keywordScores = <GenericDbRole, List<(String, int)>>{
  GenericDbRole.playUrl: [
    ('m3u8', 5),
    ('play', 3),
    ('stream', 3),
    ('地址', 3),
    ('播放', 3),
    ('url', 2),
    ('video', 2),
    ('链接', 2),
    ('link', 2),
    ('path', 1),
  ],
  GenericDbRole.cover: [
    ('pic', 3),
    ('cover', 3),
    ('img', 3),
    ('thumb', 3),
    ('poster', 3),
    ('海报', 3),
    ('封面', 3),
    ('image', 2),
    ('photo', 2),
  ],
  GenericDbRole.title: [
    ('title', 3),
    ('片名', 3),
    ('标题', 3),
    ('name', 2),
    ('subject', 2),
  ],
  GenericDbRole.actress: [
    ('actor', 3),
    ('actress', 3),
    ('演员', 3),
    ('女优', 3),
    ('cast', 2),
    ('performer', 2),
    ('star', 1),
  ],
  GenericDbRole.code: [('code', 3), ('番号', 3)],
  GenericDbRole.category: [
    ('category', 3),
    ('类别', 3),
    ('分类', 3),
    ('type', 2),
    ('genre', 2),
  ],
  GenericDbRole.date: [
    ('date', 3),
    ('时间', 3),
    ('日期', 3),
    ('time', 2),
    ('year', 2),
  ],
};

/// 平局时的角色优先序：封面 > 播放地址 > 女优 > 标题 > 番号 >
/// 分类 > 日期（'coverurl' 归封面不归播放地址就靠这一序）。
const _roleTieBreakOrder = [
  GenericDbRole.cover,
  GenericDbRole.playUrl,
  GenericDbRole.actress,
  GenericDbRole.title,
  GenericDbRole.code,
  GenericDbRole.category,
  GenericDbRole.date,
];

/// 一个字段名最像哪个角色：精确全名 10 分，否则关键词分累加；
/// 0 分（什么关键词都不含）返回 null——不猜。
(GenericDbRole, int)? roleForColumn(String columnName) {
  final normalized = normalizeDbFieldName(columnName);
  if (normalized.isEmpty) return null;
  GenericDbRole? best;
  var bestScore = 0;
  for (final role in GenericDbRole.values) {
    var score = 0;
    if (_exactNames[role]!.contains(normalized)) {
      score = 10;
    } else {
      for (final (keyword, weight) in _keywordScores[role]!) {
        if (normalized.contains(keyword)) score += weight;
      }
    }
    if (score <= 0) continue;
    if (score > bestScore ||
        (score == bestScore &&
            best != null &&
            _roleTieBreakOrder.indexOf(role) <
                _roleTieBreakOrder.indexOf(best))) {
      best = role;
      bestScore = score;
    }
  }
  if (best == null) return null;
  return (best, bestScore);
}

/// 分类类列的候选词（归一化后含该词即算）：多级筛选要把作品表里
/// 所有像分类/分类名/标签/系列/地区的列都当成可筛选维度，不能只
/// 用自动映射出来的那一个 category 列——库里常常同时有 type/class/
/// tags/series 好几级。
const _facetKeywords = <String>[
  'category',
  'class',
  'type',
  'genre',
  'tag',
  'series',
  'area',
  'kind',
  'group',
  'theme',
  '分类',
  '类别',
  '类型',
  '标签',
  '系列',
  '地区',
  '题材',
];

/// 归一化后含这些词的列不当分类维度（地址/图片/路径类，名字里
/// 带 type 也不算分类）。
const _facetExcludeKeywords = <String>[
  'url',
  'link',
  'pic',
  'img',
  'cover',
  'path',
  'file',
  'address',
  'mime',
];

/// 一张表里哪些列能当分类筛选维度（保持表内字段顺序，自动识别的
/// category 列排第一）。
List<String> categoryFacetColumns(GenericDbTableMapping mapping) {
  final out = <String>[];
  final category = mapping.columnFor(GenericDbRole.category);
  if (category != null) out.add(category);
  for (final column in mapping.allColumns) {
    if (out.contains(column)) continue;
    final normalized = normalizeDbFieldName(column);
    if (normalized.isEmpty) continue;
    if (_facetExcludeKeywords.any(normalized.contains)) continue;
    if (_facetKeywords.any(normalized.contains)) out.add(column);
  }
  return out;
}

/// 一个分类维度里的一个取值：值 + 该值下的作品数。
class GenericDbFacetValue {
  const GenericDbFacetValue({
    required this.value,
    required this.count,
    this.coverUrl = '',
  });

  final String value;
  final int count;

  /// 这个取值下首张作品封面：给「分类按视频卡片显示」用，取不到就空着。
  final String coverUrl;
}

/// 一个分类维度（库里的某个人工列，如 type/class/tags/series）：
/// 列名 + 该列的实际取值（按作品数从多到少）。
class GenericDbFacet {
  const GenericDbFacet({required this.column, required this.values});

  final String column;
  final List<GenericDbFacetValue> values;

  bool get isEmpty => values.isEmpty;
}

/// 跨表关联：作品表本身没存播放地址/封面时，地址常常在另一张表
/// （movie_id → url）。这里记下副表、指回作品表的外键、作品表的
/// 被指向列，以及副表里能提供哪些角色（播放地址/封面）。
class GenericDbRelation {
  const GenericDbRelation({
    required this.table,
    required this.foreignKey,
    required this.primaryKey,
    required this.columns,
  });

  final String table;
  final String foreignKey;
  final String primaryKey;
  final Map<GenericDbRole, String> columns;

  String? columnFor(GenericDbRole role) => columns[role];
}

/// 一张表的字段映射：角色 → 实际字段名（+ 行 id 列）。
class GenericDbTableMapping {
  const GenericDbTableMapping({
    required this.table,
    required this.columns,
    required this.allColumns,
    this.idColumn,
  });

  final String table;

  /// 角色 → 该表里实际的字段名（每角色只留得分最高的一列）。
  final Map<GenericDbRole, String> columns;

  /// 该表的全部字段名（含未识别的）：手动指定映射时下拉要列全，
  /// 只列已识别的就选不到没被认出来的列。
  final List<String> allColumns;

  /// 行 id 列（主键优先，其次是名字像 id 的列，再其次用 rowid）。
  final String? idColumn;

  String? columnFor(GenericDbRole role) => columns[role];

  bool get hasTitleAndPlayUrl =>
      columns.containsKey(GenericDbRole.title) &&
      columns.containsKey(GenericDbRole.playUrl);
}

/// 探结构结果：所有表 + 认出的作品表/人物表 + 未识别的表。
class GenericDbSchema {
  const GenericDbSchema({
    required this.tables,
    required this.fingerprint,
    this.worksTable,
    this.personsTable,
    this.manualTable,
    this.manualColumns,
    this.relations = const [],
    this.facetRelations = const [],
  });

  /// 全部表（每张表的字段角色映射）。
  final List<GenericDbTableMapping> tables;

  /// 结构指纹：表名 + 字段名拼起来（手动映射按它存，下次换同
  /// 结构的库直接用；文件换了结构、指纹就变了，不沿用旧映射）。
  final String fingerprint;

  /// 作品表（同时有标题类字段与播放地址类字段的那张；没有为 null）。
  final GenericDbTableMapping? worksTable;

  /// 人物表（有人名类字段、没有播放地址的那张；没有为 null）。
  final GenericDbTableMapping? personsTable;

  /// 手动指定的作品表（有值时以它为准）。
  final String? manualTable;

  /// 手动指定的字段映射（角色 → 字段名）。
  final Map<GenericDbRole, String>? manualColumns;

  /// 跨表关联：作品表本身没有播放地址/封面时，从副表按外键补。
  final List<GenericDbRelation> relations;

  /// 跨表分类维度：作品表本身没有分类列（或分类在另一张表里）时，
  /// 按外键把副表的分类列做成筛选维度。女优库就是这样——videos
  /// 只有 type_name（值全是「成人影片」），真正的「有码/无码/4K」
  /// 在 video_category(vod_id, main_category) 里，不跨表就一个都读不到。
  ///
  /// 每项的 [GenericDbRelation.columns] 里只放 category 一条角色映射。
  final List<GenericDbRelation> facetRelations;

  GenericDbRelation? relationFor(GenericDbRole role) {
    for (final relation in relations) {
      if (relation.columnFor(role) != null) return relation;
    }
    return null;
  }

  bool get hasWorks => worksTable != null;

  /// 未识别的表（既不是作品表也不是人物表）：进“数据库字段”
  /// 查看入口列出来，不静默丢数据。
  List<GenericDbTableMapping> get unmappedTables => [
    for (final table in tables)
      if (table != worksTable && table != personsTable) table,
  ];

  /// 应用手动映射（用户在“数据库字段”页指定）：标题与播放地址
  /// 两个必填角色缺一不可，缺了返回原 schema 不改。
  GenericDbSchema withManualMapping({
    required String table,
    required Map<GenericDbRole, String> columns,
  }) {
    if (!columns.containsKey(GenericDbRole.title) ||
        !columns.containsKey(GenericDbRole.playUrl)) {
      return this;
    }
    GenericDbTableMapping? known;
    for (final item in tables) {
      if (item.table == table) known = item;
    }
    if (known == null) return this;
    final mapping = GenericDbTableMapping(
      table: table,
      columns: Map.of(columns),
      allColumns: known.allColumns,
      idColumn: known.idColumn,
    );
    final nextTables = [
      for (final item in tables) item.table == table ? mapping : item,
    ];
    return GenericDbSchema(
      tables: nextTables,
      fingerprint: fingerprint,
      worksTable: mapping,
      personsTable: personsTable == known ? null : personsTable,
      manualTable: table,
      manualColumns: Map.of(columns),
      relations: relations,
      facetRelations: facetRelations,
    );
  }
}

/// 表名 → 字段名列表，按字段名启发式映射、再按表分类（纯函数，
/// 不碰数据库，测试直接验）。
GenericDbSchema classifyGenericTables(
  Map<String, List<String>> tableColumns, {
  Map<String, String> pkColumns = const {},
}) {
  final mappings = <GenericDbTableMapping>[];
  for (final entry in tableColumns.entries) {
    final table = entry.key;
    final columns = entry.value;
    final byRole = <GenericDbRole, (String, int)>{};
    for (final column in columns) {
      final scored = roleForColumn(column);
      if (scored == null) continue;
      final (role, score) = scored;
      final current = byRole[role];
      if (current == null || score > current.$2) {
        byRole[role] = (column, score);
      }
    }
    String? idColumn = pkColumns[table];
    if (idColumn == null || !columns.contains(idColumn)) {
      idColumn = null;
      for (final column in columns) {
        final normalized = normalizeDbFieldName(column);
        if (normalized == 'id' || normalized.endsWith('id')) {
          idColumn = column;
          break;
        }
      }
    }
    mappings.add(
      GenericDbTableMapping(
        table: table,
        columns: {for (final kv in byRole.entries) kv.key: kv.value.$1},
        allColumns: List.of(columns),
        idColumn: idColumn,
      ),
    );
  }
  // 作品表：优先挑同时有标题与播放地址的表；没有这样的表时退一步，
  // 挑有标题、且能找到“地址在副表”关联的表（很多库是 movies 元数据
  // 表 + files 地址表分开的，不能因为主表没有 url 列就报认不出）。
  GenericDbTableMapping? worksTable;
  var relations = const <GenericDbRelation>[];
  final strictCandidates = mappings.where((m) => m.hasTitleAndPlayUrl).toList()
    ..sort((a, b) {
      final byRoles = b.columns.length.compareTo(a.columns.length);
      if (byRoles != 0) return byRoles;
      return a.table.compareTo(b.table);
    });
  if (strictCandidates.isNotEmpty) {
    worksTable = strictCandidates.first;
  } else {
    final loose =
        mappings
            .where((m) => m.columns.containsKey(GenericDbRole.title))
            .toList()
          ..sort((a, b) {
            final byRoles = b.columns.length.compareTo(a.columns.length);
            if (byRoles != 0) return byRoles;
            return a.table.compareTo(b.table);
          });
    for (final candidate in loose) {
      final found = _relationsFor(
        primary: candidate,
        mappings: mappings,
        roles: const [GenericDbRole.playUrl, GenericDbRole.cover],
      );
      if (found.any((r) => r.columnFor(GenericDbRole.playUrl) != null)) {
        worksTable = candidate;
        relations = found;
        break;
      }
    }
  }
  // 主表自己有地址时，封面仍可能在副表（封面表单独一张），补上关系。
  if (worksTable != null && relations.isEmpty) {
    relations = _relationsFor(
      primary: worksTable,
      mappings: mappings,
      roles: const [GenericDbRole.cover],
    );
  }
  // 人物表：有人名（标题角色）但没有播放地址；多张时同上排序。
  // 分类字典表（`categories` / `category`：id + 名字）不是人物表：
  // 它也有 `name`（→标题角色），不排除会被当成人物表读，分类名
  // 全跑到人物列表里去（2026-11-22 截图：categories 被标成人物表）。
  final personsCandidates =
      mappings
          .where(
            (m) =>
                m != worksTable &&
                !_isCategoryDictionaryTable(m.table) &&
                m.columns.containsKey(GenericDbRole.title) &&
                !m.columns.containsKey(GenericDbRole.playUrl),
          )
          .toList()
        ..sort((a, b) {
          final byRoles = b.columns.length.compareTo(a.columns.length);
          if (byRoles != 0) return byRoles;
          return a.table.compareTo(b.table);
        });
  final personsTable = personsCandidates.isEmpty
      ? null
      : personsCandidates.first;
  final fingerprint =
      tableColumns.entries.map((e) => '${e.key}(${e.value.join(',')})').toList()
        ..sort();
  // 分类副表（2026-11-22）：主表没有分类列时分类常常在副表里
  // （video_category / video_tag 这种两列表），不跨表就一个维度都读不到。
  final facetRelations = worksTable == null
      ? const <GenericDbRelation>[]
      : _facetRelationsFor(primary: worksTable, mappings: mappings);
  return GenericDbSchema(
    tables: mappings,
    fingerprint: fingerprint.join(';'),
    worksTable: worksTable,
    personsTable: personsTable,
    relations: relations,
    facetRelations: facetRelations,
  );
}

/// 找主表的跨表关联：副表里要有目标角色列（播放地址/封面），还要
/// 有一个能指回主表的外键列。外键判定不认死名字：
/// - `movie_id`/`videoid` 这类「主表名 + id」；
/// - 与主表主键同名的列（`movie_id` 对 `movie_id`）；
/// - `vid/mid/pid/workid/itemid/filmid/vodid/subjectid/parentid` 这类
///   通用短外键。
/// 单列 `id` 不算外键（那是副表自己的主键，会自连接拿错行）。
/// 结果按表名稳定排序，同一角色只认一张副表。
/// 外键关系（公开版，给「数据库字段」页与纯函数测试用）：按主表 +
/// 全部表的字段清单推每张副表补哪个角色。参数与库内探结构用法保持
/// 一致，内部走 [_relationsFor]。
List<GenericDbRelation> relationsFor({
  required String worksTable,
  required String? worksIdColumn,
  required List<String> worksColumns,
  required List<GenericDbTableMapping> tables,
  List<GenericDbRole> roles = GenericDbRole.values,
}) {
  final primary = GenericDbTableMapping(
    table: worksTable,
    columns: const {},
    allColumns: worksColumns,
    idColumn: worksIdColumn,
  );
  return _relationsFor(primary: primary, mappings: tables, roles: roles);
}

List<GenericDbRelation> _relationsFor({
  required GenericDbTableMapping primary,
  required List<GenericDbTableMapping> mappings,
  required List<GenericDbRole> roles,
}) {
  final out = <GenericDbRelation>[];
  final ordered = List.of(mappings)..sort((a, b) => a.table.compareTo(b.table));
  for (final role in roles) {
    GenericDbRelation? found;
    for (final sub in ordered) {
      if (sub.table == primary.table) continue;
      final column = sub.columnFor(role);
      if (column == null) continue;
      final foreignKey = _foreignKeyFor(primary: primary, sub: sub);
      if (foreignKey == null) continue;
      found = GenericDbRelation(
        table: sub.table,
        foreignKey: foreignKey,
        primaryKey: primary.idColumn!,
        columns: sub.columns,
      );
      break;
    }
    if (found != null) out.add(found);
  }
  return out;
}

/// 副表里哪一个列能指回作品表（外键）。判定不认死名字：
/// - `movie_id`/`videoid` 这类「主表名 + id」；
/// - 与主表主键同名的列（`movie_id` 对 `movie_id`）；
/// - `vid/mid/pid/workid/itemid/filmid/vodid/subjectid/parentid` 这类
///   通用短外键。
/// 单列 `id` 不算外键（那是副表自己的主键，会自连接拿错行）。
String? _foreignKeyFor({
  required GenericDbTableMapping primary,
  required GenericDbTableMapping sub,
}) {
  final pk = primary.idColumn;
  if (pk == null) return null;
  final pkNormalized = normalizeDbFieldName(pk);
  final tableNormalized = normalizeDbFieldName(primary.table);
  const genericForeignKeys = {
    'movieid',
    'videoid',
    'filmid',
    'vodid',
    'workid',
    'itemid',
    'subjectid',
    'parentid',
    'vid',
    'mid',
    'pid',
  };
  for (final candidate in sub.allColumns) {
    final normalized = normalizeDbFieldName(candidate);
    if (normalized.isEmpty || normalized == 'id') continue;
    if (normalized == '${tableNormalized}id' ||
        normalized == pkNormalized ||
        genericForeignKeys.contains(normalized)) {
      return candidate;
    }
  }
  return null;
}

/// 分类副表最多收几张（每张一个 chip，太多挤满一屏）。
const _maxFacetTables = 3;

/// 表名是不是分类字典表（`categories` / `category`：主键 + 名字）。
bool _isCategoryDictionaryTable(String table) {
  final normalized = normalizeDbFieldName(table);
  return normalized == 'categories' || normalized == 'category';
}

/// 找「分类在副表」的维度：副表里有一列像分类（category 角色，或者
/// 列名像分类/标签/类型），并且有一个能指回作品表的外键，才算一个
/// 可筛选维度。女优库：video_category(vod_id → main_category)、
/// video_tag(vod_id → tag_name) 都会命中。
///
/// 另有一类反方向的字典表（`categories`：id + name，作品表拿
/// `category_id` 指过去）：副表里没有指回作品表的外键，`_foreignKeyFor`
/// 明确不认裸 `id`（那是字典表自己的主键）。这里单独认：按
/// [GenericDbRelation] 现成的字段装——`primaryKey` 放作品表里那列
/// 外键（`category_id`）、`foreignKey` 放字典表的主键列（`id`）、
/// category 放字典表的名字列——`_where` 与 `facets()` 拼出来的 SQL
/// 正好就是 `works.category_id IN (SELECT id FROM categories
/// WHERE name IN (...))`，读库层不用改。
List<GenericDbRelation> _facetRelationsFor({
  required GenericDbTableMapping primary,
  required List<GenericDbTableMapping> mappings,
}) {
  final out = <GenericDbRelation>[];
  final ordered = List.of(mappings)..sort((a, b) => a.table.compareTo(b.table));
  // 第一相（副表指回作品表）要作品表有主键列；没有就跳过这一相，
  // 第二相（字典表反方向查表）不需要主键列，照做。
  if (primary.idColumn != null) {
    for (final sub in ordered) {
      if (out.length >= _maxFacetTables) break;
      if (sub.table == primary.table) continue;
      // 自带播放地址的表是另一套作品表，不是分类副表。
      if (sub.columns.containsKey(GenericDbRole.playUrl)) continue;
      final column = _facetColumnOf(sub);
      if (column == null) continue;
      final foreignKey = _foreignKeyFor(primary: primary, sub: sub);
      if (foreignKey == null) continue;
      out.add(
        GenericDbRelation(
          table: sub.table,
          foreignKey: foreignKey,
          primaryKey: primary.idColumn!,
          columns: {GenericDbRole.category: column},
        ),
      );
    }
  }
  // 分类字典表（反方向查表）。
  for (final sub in ordered) {
    if (out.length >= _maxFacetTables) break;
    if (sub.table == primary.table) continue;
    if (!_isCategoryDictionaryTable(sub.table)) continue;
    if (out.any((r) => r.table == sub.table)) continue;
    final nameColumn = sub.columnFor(GenericDbRole.title);
    final keyColumn = sub.idColumn;
    if (nameColumn == null || keyColumn == null) continue;
    // 作品表里指过去的那列：`category_id`（归一化后 `categoryid`）。
    const wantFk = 'categoryid';
    String? worksFk;
    for (final column in primary.allColumns) {
      if (normalizeDbFieldName(column) == wantFk) {
        worksFk = column;
        break;
      }
    }
    if (worksFk == null) continue;
    out.add(
      GenericDbRelation(
        table: sub.table,
        foreignKey: keyColumn,
        primaryKey: worksFk,
        columns: {GenericDbRole.category: nameColumn},
      ),
    );
  }
  return out;
}

/// 副表里当分类维度的那一列：先用自动映射出来的 category 列，
/// 没有再看列名像不像分类/标签/类型（tag_name 这类映射会给到标题，
/// 但它本质是分类维度）。
String? _facetColumnOf(GenericDbTableMapping mapping) {
  final category = mapping.columnFor(GenericDbRole.category);
  if (category != null) return category;
  final facets = categoryFacetColumns(mapping);
  return facets.isEmpty ? null : facets.first;
}

/// 给一个已打开的 [Database] 探结构：sqlite_master 列所有表，
/// 每张表 PRAGMA table_info 列字段（含主键信息）。
Future<GenericDbSchema> probeGenericDbSchema(Database db) async {
  final tableRows = await db.rawQuery(
    "SELECT name FROM sqlite_master "
    "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  final tableColumns = <String, List<String>>{};
  final pkColumns = <String, String>{};
  for (final row in tableRows) {
    final table = row['name'].toString();
    final escaped = table.replaceAll('"', '""');
    final cols = await db.rawQuery('PRAGMA table_info("$escaped")');
    final names = <String>[];
    for (final col in cols) {
      final name = col['name'].toString();
      names.add(name);
      if (col['pk'] == 1) pkColumns[table] = name;
    }
    tableColumns[table] = names;
  }
  return classifyGenericTables(tableColumns, pkColumns: pkColumns);
}

/// 播放地址取值容差（纯函数）：
///
/// - `正片$地址`（TVBox 分段格式，也可能是 `标题$地址`）：取第一
///   个 `$` 后面的真地址；
/// - JSON 数组：`["地址1", "地址2"]` 取第一个能播的；
/// - JSON 对象：`{"url": "地址"}` 取 url/playUrl/play_url/src 键；
/// - 多个地址用 `$$$`、`#`、换行、`|`、`;` 隔开：取第一个像地址的
///   （http(s) 开头、含 .m3u8、或 `/` 开头），都没有像地址的取
///   第一个非空段；
/// - 裸地址：原样返回；空/不认的值返回 ''（调用方按不可播处理）。
String extractPlayUrl(dynamic value) {
  if (value == null) return '';
  if (value is List) {
    for (final item in value) {
      final url = extractPlayUrl(item);
      if (url.isNotEmpty) return url;
    }
    return '';
  }
  var text = value.toString().trim();
  if (text.isEmpty) return '';
  // 有的库把地址存成 JSON 转义态（`https:\/\/host\/a\/index.m3u8`），
  // 不还原就是废地址：播放器打不开，体检时还会被当死链整库删掉。
  if (text.contains(r'\/')) {
    text = text.replaceAll(r'\/', '/').trim();
  }
  if (text.startsWith('[')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is List) return extractPlayUrl(decoded);
    } catch (_) {
      // 不是合法 JSON：往下按分隔符继续拆。
    }
  }
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        for (final key in ['url', 'playUrl', 'play_url', 'src', 'video']) {
          if (decoded[key] != null) {
            final url = extractPlayUrl(decoded[key]);
            if (url.isNotEmpty) return url;
          }
        }
      }
    } catch (_) {
      // 不是合法 JSON：往下按分隔符继续拆。
    }
  }
  // 分隔符拆：'正片$地址'、'$$$'、'#'、换行、'|'、';' 都按“取第一
  // 个像地址的段”处理——先拆再选，单 '$' 不能抢在 '$$$' 前面
  // （'a.m3u8$$$b.m3u8' 按第一个 $ 切会切出 '$$b.m3u8' 的错地址）。
  final parts = text.split(RegExp(r'[\$#\n|;]+'));
  for (final part in parts) {
    final candidate = part.trim();
    if (_looksLikePlayAddress(candidate)) return candidate;
  }
  for (final part in parts) {
    if (part.trim().isNotEmpty) return part.trim();
  }
  return text;
}

bool _looksLikePlayAddress(String value) =>
    value.startsWith('http://') ||
    value.startsWith('https://') ||
    value.contains('.m3u8') ||
    value.startsWith('/');

/// 封面取值容差（纯函数）：完整地址原样返回；`//` 开头补 https:；
/// `/` 开头的绝对路径有 baseUrl 时拼成完整地址，没 baseUrl 原样
/// 返回；相对路径原样返回（调用方按站拼或直接加载）。
String resolveCoverUrl(dynamic value, {String? baseUrl}) {
  if (value == null) return '';
  var text = value.toString().trim();
  if (text.isEmpty) return '';
  if (text.contains(r'\/')) {
    text = text.replaceAll(r'\/', '/').trim();
  }
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return text;
  }
  if (text.startsWith('//')) return 'https:$text';
  if (text.startsWith('/')) {
    if (baseUrl != null && baseUrl.isNotEmpty) {
      final uri = Uri.tryParse(baseUrl);
      if (uri != null && uri.hasAuthority) {
        return '${uri.scheme}://${uri.authority}$text';
      }
    }
    return text;
  }
  return text;
}

/// 通用作品行：从任意结构的作品表里按映射读出来的。
class GenericDbWork {
  const GenericDbWork({
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.playUrl = '',
    this.actress = '',
    this.code = '',
    this.category = '',
    this.date = '',
  });

  final Object? id;
  final String title;
  final String coverUrl;
  final String playUrl;
  final String actress;
  final String code;
  final String category;
  final String date;

  bool get playable =>
      playUrl.startsWith('http://') || playUrl.startsWith('https://');

  /// 跨表补地址/封面时用：只换这两个字段，其余照原样。
  GenericDbWork copyWith({String? coverUrl, String? playUrl}) => GenericDbWork(
    id: id,
    title: title,
    coverUrl: coverUrl ?? this.coverUrl,
    playUrl: playUrl ?? this.playUrl,
    actress: actress,
    code: code,
    category: category,
    date: date,
  );

  String get displayTitle => title.isNotEmpty ? title : code;

  String get displaySubtitle {
    final parts = <String>[];
    if (date.isNotEmpty) parts.add(date);
    if (code.isNotEmpty && code != title) parts.add(code);
    if (category.isNotEmpty) parts.add(category);
    return parts.join(' · ');
  }

  /// 转成兜底条目走现有播放链：站走 chaoliu（潮流蜘蛛的
  /// playerContent 对 http 地址直接 parse=0 回流），与 mjv/whos
  /// 兜底条目同一条路，不另写播放器。
  ActressJsonEntry toJsonEntry() => ActressJsonEntry(
    site: 'chaoliu',
    vodId: 'generic:${id ?? title}',
    vodName: title,
    vodPic: coverUrl,
    vodActor: actress,
    vodDirector: '',
    vodRemarks: '高清',
    vodPubdate: date,
    vodArea: '',
    vodYear: '',
    vodContent: '',
    vodPlayFrom: 'chaoliu',
    vodPlayUrl: '正片\$$playUrl',
    typeName: category,
    vodCode: code,
    vodActressPic: coverUrl,
    directPlay: playable,
  );
}

/// 通用人行：从任意结构的人物表里按映射读出来的。
class GenericDbPerson {
  const GenericDbPerson({
    required this.id,
    required this.name,
    this.avatarUrl = '',
  });

  final Object? id;
  final String name;
  final String avatarUrl;
}

/// 手动映射存取：按结构指纹存在库文件夹里的 `字段映射.json`
///（MYTV/db/字段映射.json；未绑定时在 documents 下）。下次换同
/// 结构的库直接用，不用再手动指定。文件坏了只当没有，不崩。
class GenericDbMappingStore {
  GenericDbMappingStore({required this.file});

  final File file;

  Future<({String table, Map<GenericDbRole, String> columns})?> loadMapping(
    String fingerprint,
  ) async {
    try {
      if (!file.existsSync()) return null;
      final doc = jsonDecode(await file.readAsString());
      if (doc is! Map) return null;
      final entry = doc[fingerprint];
      if (entry is! Map) return null;
      final table = entry['table']?.toString();
      final columns = entry['columns'];
      if (table == null || table.isEmpty || columns is! Map) return null;
      final mapped = <GenericDbRole, String>{};
      for (final kv in columns.entries) {
        final role = _roleByName(kv.key.toString());
        final column = kv.value?.toString() ?? '';
        if (role != null && column.isNotEmpty) mapped[role] = column;
      }
      if (mapped.isEmpty) return null;
      return (table: table, columns: mapped);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveMapping(
    String fingerprint,
    String table,
    Map<GenericDbRole, String> columns,
  ) async {
    Map<String, dynamic> doc = {};
    try {
      if (file.existsSync()) {
        final parsed = jsonDecode(await file.readAsString());
        if (parsed is Map<String, dynamic>) {
          doc = parsed;
        } else if (parsed is Map) {
          doc = Map<String, dynamic>.from(parsed);
        }
      }
    } catch (_) {
      doc = {};
    }
    doc[fingerprint] = {
      'table': table,
      'columns': {for (final kv in columns.entries) kv.key.name: kv.value},
    };
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(doc));
    } catch (_) {
      // 映射存不下来不崩：本次仍用内存里的映射。
    }
  }
}

/// 通用读取器：包着已打开的 [Database] 与探出来的 [schema]，
/// 读作品/人物；手动映射改了就地生效并存下来。
/// 测试用 [GenericDbReader.test]：不碰数据库，直接返回给定的作品。
class GenericDbReader {
  GenericDbReader({
    required Database db,
    required this.schema,
    required this.mappingStore,
  }) : _db = db,
       _testWorks = null,
       _testWorkTags = const {};

  GenericDbReader.test({
    required List<GenericDbWork> works,
    GenericDbSchema? schema,
    Map<String, Set<String>> workTags = const {},
  }) : _db = null,
       schema =
           schema ?? const GenericDbSchema(tables: [], fingerprint: 'test'),
       mappingStore = GenericDbMappingStore(
         file: File('/tmp/actress_generic_db_test_mapping.json'),
       ),
       _testWorks = works,
       _testWorkTags = workTags;

  final Database? _db;
  GenericDbSchema schema;
  final GenericDbMappingStore mappingStore;
  final List<GenericDbWork>? _testWorks;

  /// 测试用：作品番号（code 原样）→ 该作品带的标签集合。只供
  /// [GenericDbReader.test] 的标签过滤用（真库走 video_tag 表，
  /// GenericDbWork 本身没有标签字段）。
  final Map<String, Set<String>> _testWorkTags;

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  List<String> _selectColumns(GenericDbTableMapping mapping) {
    final columns = <String>[
      for (final column in mapping.columns.values) _quote(column),
    ];
    if (mapping.idColumn != null) columns.add(_quote(mapping.idColumn!));
    return columns;
  }

  GenericDbWork _rowToWork(
    GenericDbTableMapping mapping,
    Map<String, Object?> row,
  ) {
    String text(GenericDbRole role) {
      final column = mapping.columnFor(role);
      if (column == null) return '';
      return row[column]?.toString().trim() ?? '';
    }

    return GenericDbWork(
      id: mapping.idColumn == null ? null : row[mapping.idColumn],
      title: text(GenericDbRole.title),
      coverUrl: resolveCoverUrl(
        mapping.columnFor(GenericDbRole.cover) == null
            ? ''
            : row[mapping.columnFor(GenericDbRole.cover)],
      ),
      playUrl: extractPlayUrl(
        mapping.columnFor(GenericDbRole.playUrl) == null
            ? ''
            : row[mapping.columnFor(GenericDbRole.playUrl)],
      ),
      actress: text(GenericDbRole.actress),
      code: text(GenericDbRole.code),
      category: text(GenericDbRole.category),
      date: text(GenericDbRole.date),
    );
  }

  /// 统一的 WHERE 组装：关键词搜（标题/番号 LIKE）+ 分类筛选
  /// （每列 IN 一组值，跨列 AND、同列 OR）+ 单分类 [category]
  /// （非空时只留该分类的作品，见 [_videoCategoryTable]）。
  (String?, List<Object?>) _where(
    String query,
    Map<String, List<String>> filters, {
    String category = '',
  }) {
    final mapping = schema.worksTable;
    if (mapping == null) return (null, const []);
    final clauses = <String>[];
    final args = <Object?>[];
    final trimmed = query.trim();
    if (trimmed.isNotEmpty) {
      final like = '%${trimmed.replaceAll('%', '').replaceAll('_', '')}%';
      // 关键词同时搜标题/番号/女优/分类：外来库的标题常常是编号，
      // 用户搜「素人」这类分类词、或搜女优名时也得搜得出来。
      final searchable = <String>[
        for (final role in const [
          GenericDbRole.title,
          GenericDbRole.code,
          GenericDbRole.actress,
          GenericDbRole.category,
        ])
          if (mapping.columnFor(role) != null) _quote(mapping.columnFor(role)!),
      ];
      // 副表里的分类值也一起搜：女优库搜「有码」得搜得出来（值不在
      // 作品表，在 video_category 里）。用 IN 半连接而不是 EXISTS ——
      // EXISTS 是逐行子查询，30 万行上会跑成几分钟（实测超时）。
      final facetSearch = <String>[
        for (final relation in schema.facetRelations)
          if (relation.columnFor(GenericDbRole.category) != null)
            'CAST(${_quote(mapping.table)}.${_quote(relation.primaryKey)} '
                'AS TEXT) IN (SELECT CAST(${_quote(relation.foreignKey)} AS TEXT) '
                'FROM ${_quote(relation.table)} '
                'WHERE CAST(${_quote(relation.columnFor(GenericDbRole.category)!)} '
                'AS TEXT) LIKE ?)',
      ];
      final tokens = [
        for (final column in searchable) '$column LIKE ?',
        ...facetSearch,
      ];
      if (tokens.isNotEmpty) {
        clauses.add('(${tokens.join(' OR ')})');
        args.addAll([for (final _ in tokens) like]);
      }
    }
    for (final entry in filters.entries) {
      final values = [
        for (final value in entry.value)
          if (value.trim().isNotEmpty) value,
      ];
      if (values.isEmpty) continue;
      // 副表分类维度：key 是 `表.列`（video_category.main_category）。
      // 作品表里没有这一列，按外键反查：主表 id IN (SELECT fk FROM 副表
      // WHERE 列 IN (...))。
      final dot = entry.key.indexOf('.');
      if (dot > 0) {
        final table = entry.key.substring(0, dot);
        final column = entry.key.substring(dot + 1);
        GenericDbRelation? relation;
        for (final item in schema.facetRelations) {
          if (item.table == table &&
              item.columnFor(GenericDbRole.category) == column) {
            relation = item;
            break;
          }
        }
        if (relation == null) continue;
        clauses.add(
          'CAST(${_quote(mapping.table)}.${_quote(relation.primaryKey)} '
          'AS TEXT) IN ('
          'SELECT CAST(${_quote(relation.foreignKey)} AS TEXT) '
          'FROM ${_quote(relation.table)} '
          'WHERE CAST(${_quote(column)} AS TEXT) IN '
          '(${List.filled(values.length, '?').join(',')}))',
        );
        args.addAll(values);
        continue;
      }
      if (!mapping.allColumns.contains(entry.key)) continue;
      // CAST 成文本比较：库里的分类列可能是 INTEGER 型 id，而筛选
      // 值是从列表里点出来的字符串，不 CAST 会一个都匹配不上。
      clauses.add(
        'CAST(${_quote(entry.key)} AS TEXT) IN '
        '(${List.filled(values.length, '?').join(',')})',
      );
      args.addAll(values);
    }
    final wanted = category.trim();
    if (wanted.isNotEmpty) {
      final vodIdCol = _worksVodIdColumn();
      final categoryCol = mapping.columnFor(GenericDbRole.category);
      if (_videoCategoryTable() != null && vodIdCol != null) {
        clauses.add(
          '${_quote(vodIdCol)} IN (SELECT vod_id FROM "video_category" '
          'WHERE main_category = ?)',
        );
        args.add(wanted);
      } else if (categoryCol != null) {
        // 与上面 filters 的 CAST 写法一致：分类列可能是 INTEGER 型。
        clauses.add('CAST(${_quote(categoryCol)} AS TEXT) = ?');
        args.add(wanted);
      } else {
        // 分类要筛、两条路都没有：筛不出而不是错筛出未过滤的行。
        clauses.add('1 = 0');
      }
    }
    if (clauses.isEmpty) return (null, const []);
    return (clauses.join(' AND '), args);
  }

  /// 本库自带的分类表（video_category：vod_id + main_category）：
  /// 有这张表才按它取分类、按它筛作品；没有就不认、不编。
  GenericDbTableMapping? _videoCategoryTable() {
    for (final table in schema.tables) {
      if (table.table != 'video_category') continue;
      if (table.allColumns.contains('vod_id') &&
          table.allColumns.contains('main_category')) {
        return table;
      }
    }
    return null;
  }

  /// 作品表里连分类表的键：只有作品表本身有 vod_id 列时才连得上。
  String? _worksVodIdColumn() {
    final mapping = schema.worksTable;
    if (mapping == null) return null;
    for (final column in mapping.allColumns) {
      if (column == 'vod_id') return column;
    }
    return null;
  }

  /// 分类列表（2026-11-22：数据库视频列表页顶部的分类 chips）：
  /// 优先读本库自带的 video_category 表（main_category + 作品数，
  /// 按数量倒序）；没有这张表时退到作品表自己的分类列去重计数；
  /// 都没有时回空——界面如实显示无分类，不编。分类取自数据库
  /// 本身，不写死。测试构造器按给定作品的 category 字段算。
  Future<List<(String, int)>> categories() async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final counts = <String, int>{};
      for (final work in testWorks) {
        if (work.category.isEmpty) continue;
        counts[work.category] = (counts[work.category] ?? 0) + 1;
      }
      final list = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return [for (final e in list) (e.key, e.value)];
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    if (_videoCategoryTable() != null) {
      final rows = await db.rawQuery(
        'SELECT main_category, COUNT(*) AS c FROM "video_category" '
        "WHERE main_category IS NOT NULL AND main_category <> '' "
        'GROUP BY main_category ORDER BY c DESC',
      );
      return [
        for (final row in rows)
          (
            row['main_category'].toString(),
            (row['c'] as num).toInt(),
          ),
      ];
    }
    final categoryCol = mapping.columnFor(GenericDbRole.category);
    if (categoryCol == null) return const [];
    // 与 facets() 的写法一致：CAST 成文本再分组，分类列是
    // INTEGER 型时也能按字符串值去重计数。
    final quoted = _quote(categoryCol);
    final rows = await db.rawQuery(
      'SELECT CAST($quoted AS TEXT) AS name, COUNT(*) AS c '
      'FROM ${_quote(mapping.table)} '
      'WHERE $quoted IS NOT NULL '
      'AND TRIM(CAST($quoted AS TEXT)) <> \'\' '
      'GROUP BY CAST($quoted AS TEXT) ORDER BY c DESC',
    );
    return [
      for (final row in rows)
        (row['name'].toString(), (row['c'] as num).toInt()),
    ];
  }

  /// 读一页作品（关键词搜 + 分类筛选；rowid 顺序翻页）。
  /// [category] 非空时只留该分类的作品，只筛当前这个库。
  /// 主表没存播放地址/封面时，自动从关联副表补（见 [GenericDbRelation]）。
  Future<List<GenericDbWork>> works({
    required int offset,
    required int limit,
    String query = '',
    Map<String, List<String>> filters = const {},
    String category = '',
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final q = query.trim().toLowerCase();
      final wanted = category.trim();
      var filtered = testWorks.where((w) {
        if (wanted.isNotEmpty && w.category != wanted) return false;
        if (q.isNotEmpty &&
            !w.title.toLowerCase().contains(q) &&
            !w.code.toLowerCase().contains(q) &&
            !w.actress.toLowerCase().contains(q) &&
            !w.category.toLowerCase().contains(q)) {
          return false;
        }
        return true;
      }).toList();
      if (filters.isNotEmpty) {
        filtered = filtered.where((w) => _testWorkMatches(w, filters)).toList();
      }
      return filtered.skip(offset).take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final (where, args) = _where(query, filters, category: category);
    final rows = await db.query(
      mapping.table,
      columns: _selectColumns(mapping),
      where: where,
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    final works = [for (final row in rows) _rowToWork(mapping, row)];
    return _attachRelated(works);
  }

  bool _testWorkMatches(GenericDbWork work, Map<String, List<String>> filters) {
    for (final entry in filters.entries) {
      if (entry.value.isEmpty) continue;
      if (!entry.value.contains(work.category)) return false;
    }
    return true;
  }

  /// 作品总数（与 [works] 同一过滤条件，含分类筛）。
  Future<int> countWorks({
    String query = '',
    Map<String, List<String>> filters = const {},
    String category = '',
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final list = await works(
        offset: 0,
        limit: testWorks.length + 1,
        query: query,
        filters: filters,
        category: category,
      );
      return list.length;
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return 0;
    final (where, args) = _where(query, filters, category: category);
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${_quote(mapping.table)}'
      '${where == null ? '' : ' WHERE $where'}',
      args.isEmpty ? null : args,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// 按人名取作品（名册对接库索引用）：SQL 侧先粗筛（女优列/标题
  /// 含这个名字），Dart 侧再按归一化名精确比对——库里的女优名可能
  /// 带空格/大小写差异，只靠 SQL = 会漏。
  Future<List<GenericDbWork>> worksForActress(
    String name, {
    int limit = 300,
  }) async {
    final normalized = name.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (normalized.isEmpty) return const [];
    final testWorks = _testWorks;
    if (testWorks != null) {
      return [
        for (final work in testWorks)
          if (work.actress
              .replaceAll(RegExp(r'\s+'), '')
              .toLowerCase()
              .contains(normalized))
            work,
      ].take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final actressCol = mapping.columnFor(GenericDbRole.actress);
    final titleCol = mapping.columnFor(GenericDbRole.title);
    final tokens = <String>[
      if (actressCol != null) 'CAST(${_quote(actressCol)} AS TEXT) LIKE ?',
      if (titleCol != null) 'CAST(${_quote(titleCol)} AS TEXT) LIKE ?',
    ];
    if (tokens.isEmpty) return const [];
    final like = '%${_escapeLike(name.trim())}%';
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        mapping.table,
        columns: _selectColumns(mapping),
        where: tokens.join(' OR '),
        whereArgs: [for (final _ in tokens) like],
        orderBy: 'rowid',
        limit: limit * 3,
      );
    } catch (_) {
      return const [];
    }
    final out = <GenericDbWork>[];
    for (final row in rows) {
      final work = _rowToWork(mapping, row);
      final candidate = work.actress
          .replaceAll(RegExp(r'\s+'), '')
          .toLowerCase();
      if (candidate.isEmpty) continue;
      if (!candidate.contains(normalized) && !normalized.contains(candidate)) {
        continue;
      }
      out.add(work);
      if (out.length >= limit) break;
    }
    return _attachRelated(out);
  }

  /// 按番号取作品（名册/搜索对接库索引用）：SQL 侧把番号列的
  /// 连字符、下划线、空格去掉再比（库里 "JUL-893"、查询 "jul893"
  /// 都能对上），Dart 侧再按归一化番号精确比对。
  Future<List<GenericDbWork>> worksForCode(
    String codeKey, {
    int limit = 200,
  }) async {
    final normalized = _normalizeCodeKey(codeKey);
    if (normalized.isEmpty) return const [];
    final testWorks = _testWorks;
    if (testWorks != null) {
      return [
        for (final work in testWorks)
          if (_normalizeCodeKey(work.code) == normalized) work,
      ].take(limit).toList();
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final codeCol = mapping.columnFor(GenericDbRole.code);
    final titleCol = mapping.columnFor(GenericDbRole.title);
    final columns = <String>[
      if (codeCol != null) codeCol,
      if (titleCol != null) titleCol,
    ];
    if (columns.isEmpty) return const [];
    // 2026-11-23 转圈根因之四：兜底池按番号查外来库时，LIKE '%番号%'
    // 全表扫（番号列还包了 REPLACE/UPPER，索引用不上），60 个番号 ×
    // 两个外来库 = 120 次全表扫，磁盘被打满几分钟，详情页的读也被拖
    // 慢。视频库的番号列就是 vod_id 主键：先按精确值查（走主键索引，
    // 毫秒级），命中就直接回；只有精确查不到才落回 LIKE 模糊查
    //（标题含番号、分隔符写法不同等情况）。
    if (codeCol == 'vod_id') {
      final exact = await _worksForCodeExact(codeKey, normalized, limit);
      if (exact.isNotEmpty) return exact;
    }
    final tokens = [for (final column in columns) _normalizedColumn(column)];
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        mapping.table,
        columns: _selectColumns(mapping),
        where: tokens.map((t) => "$t LIKE ?").join(' OR '),
        whereArgs: [for (final _ in tokens) '%$normalized%'],
        orderBy: 'rowid',
        limit: limit * 4,
      );
    } catch (_) {
      return const [];
    }
    final out = <GenericDbWork>[];
    for (final row in rows) {
      final work = _rowToWork(mapping, row);
      final codeMatch = _normalizeCodeKey(work.code) == normalized;
      final titleMatch = _normalizeCodeKey(work.title).contains(normalized);
      if (!codeMatch && !titleMatch) continue;
      out.add(work);
      if (out.length >= limit) break;
    }
    return _attachRelated(out);
  }

  /// 按番号精确查（走主键/索引）：调用方传来的番号可能是库里原样
  ///（ipzz-840）、也可能是归一化后（IPZZ840），几种写法都试一遍。
  /// 命中后仍按归一化番号在 Dart 侧精确比对，不合的不要。
  Future<List<GenericDbWork>> _worksForCodeExact(
    String codeKey,
    String normalized,
    int limit,
  ) async {
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    final codeCol = mapping.columnFor(GenericDbRole.code);
    if (codeCol == null) return const [];
    final variants = <String>{};
    for (final raw in [codeKey, normalized]) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      variants.add(t);
      variants.add(t.toLowerCase());
      variants.add(t.toUpperCase());
      // 归一化番号（IPZZ840）补回连字符写法（ipzz-840）。
      final m = RegExp(r'^([A-Za-z]+)0*(\d+)$').firstMatch(t);
      if (m != null) {
        variants.add('${m.group(1)}-${m.group(2)}'.toLowerCase());
        variants.add('${m.group(1)}-${m.group(2)}'.toUpperCase());
      }
    }
    if (variants.isEmpty) return const [];
    final placeholders = List.filled(variants.length, '?').join(',');
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.query(
        mapping.table,
        columns: _selectColumns(mapping),
        where: '${_quote(codeCol)} IN ($placeholders)',
        whereArgs: variants.toList(),
        orderBy: 'rowid',
        limit: limit,
      );
    } catch (_) {
      return const [];
    }
    final out = <GenericDbWork>[];
    for (final row in rows) {
      final work = _rowToWork(mapping, row);
      if (_normalizeCodeKey(work.code) != normalized) continue;
      out.add(work);
      if (out.length >= limit) break;
    }
    return _attachRelated(out);
  }

  /// 番号列去掉分隔符后的 SQL 表达式（归一化口径与 Dart 侧一致）。
  String _normalizedColumn(String column) {
    var expr = 'CAST(${_quote(column)} AS TEXT)';
    for (final sep in const ['-', '_', ' ', '.']) {
      expr = "REPLACE($expr, '$sep', '')";
    }
    return 'UPPER($expr)';
  }

  static String _escapeLike(String value) =>
      value.replaceAll('%', '').replaceAll('_', '').replaceAll("'", '');

  static String _normalizeCodeKey(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// 分类维度：作品表里像分类/分类名/标签/系列/地区的列，每列出
  /// 现过的值 + 每个值下的作品数（按作品数从多到少，[maxValues] 封顶）。
  /// 这就是「点进库以后按库内部的多级分类筛选」的数据来源。
  ///
  /// 2026-11-22 用户令「点进数据库读不到数据库里面的分类」：分类常常
  /// 不在作品表本身，而在副表（女优库的 videos 只有 type_name，真正的
  /// 有码/无码/4K 在 video_category(vod_id, main_category)）。副表维度
  /// 排在前面先出，主表列随后补上；每列单独查、单独容错，一列慢/坏
  /// 不影响其它列。
  Future<List<GenericDbFacet>> facets({int maxValues = 30}) async {
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null || _testWorks != null) return const [];
    final out = <GenericDbFacet>[];
    // 1) 副表分类维度（带表名做 key：`video_category.main_category`）
    for (final relation in schema.facetRelations) {
      final column = relation.columnFor(GenericDbRole.category);
      if (column == null) continue;
      final quoted = _quote(column);
      try {
        final rows = await db.rawQuery(
          'SELECT CAST($quoted AS TEXT) AS v, COUNT(*) AS c '
          'FROM ${_quote(relation.table)} '
          'WHERE $quoted IS NOT NULL AND TRIM(CAST($quoted AS TEXT)) <> \'\' '
          'GROUP BY CAST($quoted AS TEXT) '
          'ORDER BY c DESC, v ASC LIMIT ?',
          [maxValues],
        );
        final values = _facetValues(rows);
        if (values.isEmpty) continue;
        out.add(
          GenericDbFacet(
            column: '${relation.table}.$column',
            values: values,
          ),
        );
      } catch (_) {
        // 副表结构跟探测时不一致（视图/脏库）：跳过这一维，不影响其它。
      }
    }
    // 2) 作品表自己的分类列
    final coverColumn = mapping.columnFor(GenericDbRole.cover);
    for (final column in categoryFacetColumns(mapping).take(8)) {
      if (out.any((facet) => facet.column == column)) continue;
      final quoted = _quote(column);
      try {
        final rows = await db.rawQuery(
          'SELECT CAST($quoted AS TEXT) AS v, COUNT(*) AS c'
          '${coverColumn == null ? '' : ', MAX(${_quote(coverColumn)}) AS pic'} '
          'FROM ${_quote(mapping.table)} '
          'WHERE $quoted IS NOT NULL AND TRIM(CAST($quoted AS TEXT)) <> \'\' '
          'GROUP BY CAST($quoted AS TEXT) '
          'ORDER BY c DESC, v ASC LIMIT ?',
          [maxValues],
        );
        final values = _facetValues(rows);
        // 只有一种取值、还覆盖全库的列不是分类维度（女优库的
        // type_name 全是「成人影片」那种），摆出来只会误导。
        if (values.length <= 1) continue;
        out.add(GenericDbFacet(column: column, values: values));
      } catch (_) {
        // 这一列查不动（没索引的大表/脏数据）：跳过，接着查下一维。
      }
    }
    return out;
  }

  /// 标签维度（2026-11-24 标签筛选）：取 [facets] 里标签那一维。
  /// 优先 `video_tag.tag_name`（女优库 video_tag 表）；没有时退到
  /// 作品表里含 tag 的列（如 tags 列）；都没有回 key 空、values 空，
  /// 调用方如实显示“暂无标签”，不编。values 按作品数倒序；
  /// [maxValues] 默认 2000（全库 1,229 个标签一次取完，facets()
  /// 默认 30 只够分类用）。
  /// 返回的 key 就是筛选时传给 [works]/[countWorks] 的 filters 键
  /// （`video_tag.tag_name` 或作品表列名）。
  Future<({String key, List<(String, int)> values})> tagFacet({
    int maxValues = 2000,
  }) async {
    final all = await facets(maxValues: maxValues);
    GenericDbFacet? picked;
    for (final facet in all) {
      if (facet.column == 'video_tag.tag_name') {
        picked = facet;
        break;
      }
    }
    if (picked == null) {
      for (final facet in all) {
        if (facet.column.toLowerCase().contains('tag')) {
          picked = facet;
          break;
        }
      }
    }
    if (picked == null) {
      return (key: '', values: const <(String, int)>[]);
    }
    return (
      key: picked.column,
      values: [
        for (final v in picked.values) (v.value, v.count),
      ],
    );
  }

  /// 把 `SELECT ... AS v, COUNT(*) AS c` 的行转成取值列表。
  List<GenericDbFacetValue> _facetValues(List<Map<String, Object?>> rows) {
    final values = <GenericDbFacetValue>[];
    for (final row in rows) {
      final value = row['v']?.toString().trim() ?? '';
      if (value.isEmpty) continue;
      values.add(
        GenericDbFacetValue(
          value: value,
          count: (row['c'] as num?)?.toInt() ?? 0,
          coverUrl: resolveCoverUrl(row['pic'] ?? row['cover']),
        ),
      );
    }
    return values;
  }

  /// 类型文件夹维度（2026-11-24 文件夹视图）：作品表里字面
  /// `type_name` 列的取值分组计数（女优库 videos.type_name，如
  /// 成人影片/国产精品/无码专区…）。注意它与 video_category 主分类
  /// （有码/无码/国产…）是两套不同的维度，别混成一套：这里只认
  /// 作品表自己的 type_name 列，不认副表、不认映射后的分类列。
  /// 作品表没有 type_name 列时回空——调用方如实显示“暂无文件夹”，
  /// 不编。values 按作品数倒序；[maxValues] 默认 2000（女优库
  /// v3 实查 26 个类型，一次取完）。选了标签时 [tagKey]/[tag]
  /// 传进来（tagFacet 回的 key），文件夹计数只算带该标签的作品
  /// （与标签筛选 AND，见 [_where]）。
  /// 测试构造器按给定作品的 category 字段分组（与 categories()
  /// 的测试分支同一口径：测试作品没有独立的 typeName 字段）；
  /// 标签过滤按测试构造器给的 workTags（番号 → 标签集）算，
  /// 没给 workTags 时带标签的作品一条都筛不出来（不是“不过滤”，
  /// 是测试数据里没有标签信息）。真库的标签过滤以 Python 重放为准）。
  Future<List<(String, int)>> typeNameFacet({
    int maxValues = 2000,
    String tagKey = '',
    String tag = '',
  }) async {
    final testWorks = _testWorks;
    if (testWorks != null) {
      final counts = <String, int>{};
      for (final work in testWorks) {
        if (work.category.isEmpty) continue;
        if (tagKey.isNotEmpty &&
            tag.isNotEmpty &&
            !(_testWorkTags[work.code]?.contains(tag) ?? false)) {
          continue;
        }
        counts[work.category] = (counts[work.category] ?? 0) + 1;
      }
      final list = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      return [for (final e in list.take(maxValues)) (e.key, e.value)];
    }
    final mapping = schema.worksTable;
    final db = _db;
    if (mapping == null || db == null) return const [];
    if (!mapping.allColumns.contains('type_name')) return const [];
    final filters = <String, List<String>>{};
    if (tagKey.isNotEmpty && tag.isNotEmpty) {
      filters[tagKey] = [tag];
    }
    final (where, args) = _where('', filters);
    final clauses = <String>[
      if (where != null) '($where)',
      '"type_name" IS NOT NULL AND TRIM(CAST("type_name" AS TEXT)) <> \'\'',
    ];
    final rows = await db.rawQuery(
      'SELECT CAST("type_name" AS TEXT) AS name, COUNT(*) AS c '
      'FROM ${_quote(mapping.table)} '
      'WHERE ${clauses.join(' AND ')} '
      'GROUP BY CAST("type_name" AS TEXT) ORDER BY c DESC LIMIT ?',
      [...args, maxValues],
    );
    return [
      for (final row in rows)
        (row['name'].toString(), (row['c'] as num).toInt()),
    ];
  }

  /// 主表行缺地址/封面时，按关联副表一次性补上（每个主表 id 取副表
  /// 里第一条非空值）。
  Future<List<GenericDbWork>> _attachRelated(List<GenericDbWork> works) async {
    final db = _db;
    if (db == null || works.isEmpty || schema.relations.isEmpty) return works;
    var out = works;
    for (final relation in schema.relations) {
      final needsPlay = relation.columnFor(GenericDbRole.playUrl) != null;
      final needsCover = relation.columnFor(GenericDbRole.cover) != null;
      if (!needsPlay && !needsCover) continue;
      final keys = <Object?>{};
      for (final work in out) {
        final missing =
            (needsPlay && !work.playable) ||
            (needsCover && work.coverUrl.isEmpty);
        if (!missing) continue;
        final id = work.id;
        if (id != null) keys.add(id);
      }
      if (keys.isEmpty) continue;
      final values = await _relatedValues(relation, keys.toList());
      if (values.isEmpty) continue;
      out = [
        for (final work in out)
          if (values[work.id?.toString() ?? ''] == null)
            work
          else
            _withRelated(work, values[work.id?.toString() ?? '']!),
      ];
    }
    return out;
  }

  GenericDbWork _withRelated(
    GenericDbWork work,
    Map<GenericDbRole, String> related,
  ) {
    final play = work.playable
        ? work.playUrl
        : (related[GenericDbRole.playUrl] ?? '');
    final cover = work.coverUrl.isNotEmpty
        ? work.coverUrl
        : (related[GenericDbRole.cover] ?? '');
    if (play == work.playUrl && cover == work.coverUrl) return work;
    return work.copyWith(playUrl: play, coverUrl: cover);
  }

  Future<Map<String, Map<GenericDbRole, String>>> _relatedValues(
    GenericDbRelation relation,
    List<Object?> keys,
  ) async {
    final db = _db;
    final playCol = relation.columnFor(GenericDbRole.playUrl);
    final coverCol = relation.columnFor(GenericDbRole.cover);
    if (db == null || (playCol == null && coverCol == null)) return const {};
    final columns = <String>[relation.foreignKey, ?playCol, ?coverCol];
    final placeholders = List.filled(keys.length, '?').join(',');
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.rawQuery(
        'SELECT ${columns.map(_quote).join(',')} '
        'FROM ${_quote(relation.table)} '
        'WHERE ${_quote(relation.foreignKey)} IN ($placeholders)',
        keys,
      );
    } catch (_) {
      // 副表结构跟探测时不一致（脏库/视图）：补不上就不补，不让整页挂。
      return const {};
    }
    final out = <String, Map<GenericDbRole, String>>{};
    for (final row in rows) {
      final key = row[relation.foreignKey]?.toString() ?? '';
      if (key.isEmpty) continue;
      final slot = out.putIfAbsent(key, () => <GenericDbRole, String>{});
      if (playCol != null && (slot[GenericDbRole.playUrl] ?? '').isEmpty) {
        final url = extractPlayUrl(row[playCol]);
        if (url.isNotEmpty) slot[GenericDbRole.playUrl] = url;
      }
      if (coverCol != null && (slot[GenericDbRole.cover] ?? '').isEmpty) {
        final cover = resolveCoverUrl(row[coverCol]);
        if (cover.isNotEmpty) slot[GenericDbRole.cover] = cover;
      }
    }
    return out;
  }

  /// 读人物（有人物表时才有；没有返回空列表）。
  Future<List<GenericDbPerson>> persons({
    required int offset,
    required int limit,
  }) async {
    final mapping = schema.personsTable;
    if (mapping == null || _db == null) return const [];
    final rows = await _db.query(
      mapping.table,
      columns: _selectColumns(mapping),
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    return [
      for (final row in rows)
        GenericDbPerson(
          id: mapping.idColumn == null ? null : row[mapping.idColumn],
          name:
              row[mapping.columnFor(GenericDbRole.title)]?.toString().trim() ??
              '',
          avatarUrl: resolveCoverUrl(
            mapping.columnFor(GenericDbRole.cover) == null
                ? ''
                : row[mapping.columnFor(GenericDbRole.cover)],
          ),
        ),
    ];
  }

  /// 用户在“数据库字段”页手动指定映射：就地生效（下次读即用）
  /// 并按结构指纹存下来，下次换同结构的库直接用。
  Future<void> applyManualMapping({
    required String table,
    required Map<GenericDbRole, String> columns,
  }) async {
    final next = schema.withManualMapping(table: table, columns: columns);
    if (identical(next, schema)) return;
    schema = next;
    await mappingStore.saveMapping(schema.fingerprint, table, columns);
  }
}
