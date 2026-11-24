import 'dart:async';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_adapter_models.dart' show AppFailure;
import 'actress_adapter_http.dart';
import 'actress_generic_db.dart'
    show
        GenericDbRole,
        GenericDbSchema,
        extractPlayUrl,
        GenericDbRelation,
        normalizeDbFieldName,
        roleForColumn;

/// 一次体检用到的字段映射。
///
/// 2026-11-22 用户报「其他数据库无法全面扫描修复」：修复脚本把列名
/// 写死成 `videos.m3u8_url`，可他那个「全球丽影库」的播放地址列叫
/// `vod_play_url`，一开修就
/// `DatabaseException(no such column: m3u8_url)`。
///
/// 所以开修前先把库的真实结构探清楚：作品表叫什么、主键列是哪一列、
/// 播放地址列是哪一列（还可能根本不在作品表，而在副表里）。探不到就
/// 明确告诉用户去哪指定，绝不拿写死的列名去撞库。
class VideoDbRepairColumns {
  const VideoDbRepairColumns({
    required this.table,
    required this.idColumn,
    required this.playColumn,
    this.playTable = '',
    this.playForeignKey = '',
    this.titleColumn = '',
    this.playSample = 0,
  });

  /// 作品表名。
  final String table;

  /// 作品表主键列；空串 = 用 rowid。
  final String idColumn;

  /// 播放地址列（[playTable] 为空时它在作品表里，否则在副表里）。
  final String playColumn;

  /// 地址所在的副表（空 = 地址就在作品表）。
  final String playTable;

  /// 副表指回作品表的列。
  final String playForeignKey;

  /// 标题列（报错提示用）。
  final String titleColumn;

  /// 采样时这列有多少比例是真 http 地址（0-100），用来给用户看探测
  /// 依据、也用来判断这列到底像不像播放地址。
  final int playSample;

  bool get valid => playColumn.isNotEmpty;

  String get describe {
    final where = playTable.isEmpty
        ? '$table.$playColumn'
        : '$playTable.$playColumn → $table.$playForeignKey';
    final id = idColumn.isEmpty ? 'rowid' : '$table.$idColumn';
    final conf = playSample > 0 ? '（该列 $playSample% 是非空 http 地址）' : '';
    return '识别到：$where · 主键 $id$conf';
  }
}

/// 一次视频库体检的结果。
class VideoDbRepairReport {
  const VideoDbRepairReport({
    required this.total,
    required this.alive,
    required this.dead,
    required this.unknown,
    required this.removed,
    required this.elapsed,
    required this.cancelled,
    this.columns,
    this.rollupSkipped = false,
  });

  final int total;
  final int alive;

  /// 明确打不开的（404/410/连不上/地址非法）。
  final int dead;

  /// 403/超时之类测不准的：一律保留，不拿它当死链删。
  final int unknown;
  final int removed;
  final Duration elapsed;
  final bool cancelled;

  /// 这次实际用的字段映射（空 = 没探到就失败了）。
  final VideoDbRepairColumns? columns;

  /// 大库跳过了演员汇总重建：几 G 的库 join 一遍全表要很久，别让修完
  /// 卡在最后一步；下次进女优库会自己重算。
  final bool rollupSkipped;

  String get summary =>
      '共 $total 部：可播 $alive'
      '${unknown > 0 ? '，待确认 $unknown' : ''}'
      '，删除 $removed';
}

enum _Verdict { alive, dead, unknown }

/// 本地视频库自愈：逐条按库里存的地址验活，确认打不开的删掉。
///
/// - 字段全程按库的真实结构来（见 [VideoDbRepairColumns]），不写死列名；
/// - 404/410/域名解析失败/连接被拒/地址非法 → 判死链，删掉
///   （作品表 + 关联副表一起清）；
/// - 401/403/超时/TLS 失败 → 测不准，一律保留，不误删能播的源；
/// - 删完重建 actress_rollup 汇总（演员作品数）与分类计数（库里有才做）。
class VideoDbRepair {
  VideoDbRepair._();

  static const defaultConcurrency = 12;
  static const defaultTimeout = Duration(seconds: 8);

  /// 探过的地址缓存上限：大库里同一个地址重复几千次，缓存能把请求量
  /// 压掉几个数量级（800 万条的表硬测一遍不现实）。
  static const _urlCacheLimit = 60000;

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';

  static Future<_Verdict> _probe(String url, Duration timeout) async {
    final target = url.trim();
    if (target.isEmpty) return _Verdict.dead;
    final uri = Uri.tryParse(target);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      return _Verdict.dead;
    }
    try {
      final response = await probeStreamHead(target, const {}, timeout);
      final code = response.statusCode;
      if (code >= 200 && code < 300) {
        // m3u8 要以 #EXTM3U 开头；返回别的（错误页）算测不准，不删。
        final text = String.fromCharCodes(
          response.headBytes.take(16).toList(growable: false),
        );
        if (target.toLowerCase().contains('.m3u8')) {
          return text.contains('#EXTM3U')
              ? _Verdict.alive
              : _Verdict.unknown;
        }
        return _Verdict.alive;
      }
      if (code == 404 || code == 410) return _Verdict.dead;
      return _Verdict.unknown;
    } catch (error) {
      final text = error.toString().toLowerCase();
      if (text.contains('not found') ||
          text.contains('failed host lookup') ||
          text.contains('connection refused') ||
          text.contains('network is unreachable') ||
          text.contains('no address associated')) {
        return _Verdict.dead;
      }
      if (error is AppFailure && text.contains('验播地址无效')) {
        return _Verdict.dead;
      }
      return _Verdict.unknown;
    }
  }

  static Future<List<String>> _columnsOf(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info(${_quote(table)})');
    return [
      for (final row in rows)
        if ((row['name']?.toString() ?? '').isNotEmpty)
          row['name'].toString(),
    ];
  }

  /// 列名里带这些词的**不是**播放地址（封面/标题/简介之类）。
  static const _nonPlayKeywords = [
    'pic',
    'cover',
    'img',
    'image',
    'poster',
    'thumb',
    'name',
    'title',
    'content',
    'intro',
    'remark',
    'from',
    'actor',
    'actress',
    'time',
    'date',
    'year',
    'area',
    'note',
    'desc',
    'tag',
    'cate',
    'type',
    'class',
    'score',
    'count',
  ];

  static const _videoExts = [
    '.m3u8',
    '.mp4',
    '.flv',
    '.mpd',
    '.mkv',
    '.webm',
    '.mov',
    '.ts',
  ];

  /// 采样一批值，算这列有多少比例是真 http 地址（[http]）、多少比例
  /// 直接指向视频流（[video]）。
  ///
  /// 两个数都要：像 yellow 那个库，`id` 列存的是网页播放页地址
  /// （http 占比 100%），真视频地址在 `play_url` 列。只看 http 就会
  /// 认错列，一修就全乱。
  static Future<({int http, int video})> _sampleAddress(
    Database db,
    String table,
    String column,
  ) async {
    const zero = (http: 0, video: 0);
    final List<Map<String, Object?>> rows;
    try {
      rows = await db.rawQuery(
        'SELECT ${_quote(column)} AS v FROM ${_quote(table)} '
        "WHERE ${_quote(column)} IS NOT NULL "
        "AND TRIM(CAST(${_quote(column)} AS TEXT)) <> '' "
        'ORDER BY rowid LIMIT 40',
      );
    } catch (_) {
      return zero;
    }
    if (rows.isEmpty) return zero;
    var http = 0;
    var video = 0;
    for (final row in rows) {
      final url = extractPlayUrl(row['v']);
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        continue;
      }
      http++;
      final lower = url.toLowerCase().split('?').first;
      if (_videoExts.any(lower.endsWith)) video++;
    }
    return (
      http: ((http * 100) / rows.length).round(),
      video: ((video * 100) / rows.length).round(),
    );
  }

  /// 打分：视频直链权重高，纯 http 页（播放页/图片页）低。
  static int _addressScore(({int http, int video}) sample) =>
      sample.video * 3 + sample.http;

  /// 探字段：作品表、主键列、播放地址列。
  ///
  /// [schema] 是浏览页已经探好的库结构（用户手动指定过字段时以它为准，
  /// 这时候绝不该再自己猜一遍）。
  static Future<VideoDbRepairColumns> detect(
    Database db, {
    GenericDbSchema? schema,
  }) async {
    final tableRows = await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    final tables = <String>{
      for (final row in tableRows) row['name']?.toString() ?? '',
    }..remove('');

    // 作品表：优先浏览页认出来的那张，其次 videos，再次带标题列的表。
    var table = schema?.worksTable?.table ?? '';
    if (table.isEmpty) {
      table = tables.contains('videos') ? 'videos' : '';
    }
    if (table.isEmpty) {
      for (final candidate in tables) {
        final columns = await _columnsOf(db, candidate);
        final hasTitle = columns.any(
          (c) => roleForColumn(c)?.$1 == GenericDbRole.title,
        );
        if (hasTitle) {
          table = candidate;
          break;
        }
      }
    }
    if (table.isEmpty || !tables.contains(table)) {
      throw AppFailure(
        '这个文件里没找到作品表（没有 videos 表）。\n'
        '点右上角「数据库字段」手动指定一下是哪个表，再来修。',
      );
    }

    final columns = await _columnsOf(db, table);
    if (columns.isEmpty) {
      throw AppFailure('表 $table 读不出字段');
    }

    final mapping = schema?.worksTable?.table == table
        ? schema!.worksTable
        : null;

    // 主键列：映射里认出来的优先，其次常见 id 名，最后拿 SQLite 主键。
    var idColumn = mapping?.idColumn ?? '';
    if (idColumn.isEmpty || !columns.contains(idColumn)) {
      idColumn = '';
      for (final wanted in const [
        'vodid',
        'videoid',
        'vid',
        'movieid',
        'workid',
        'id',
      ]) {
        for (final column in columns) {
          if (normalizeDbFieldName(column) == wanted) {
            idColumn = column;
            break;
          }
        }
        if (idColumn.isNotEmpty) break;
      }
    }
    if (idColumn.isEmpty) {
      try {
        final info = await db.rawQuery('PRAGMA table_info(${_quote(table)})');
        for (final row in info) {
          if (((row['pk'] as num?)?.toInt() ?? 0) > 0) {
            idColumn = row['name']?.toString() ?? '';
            if (idColumn.isNotEmpty) break;
          }
        }
      } catch (_) {}
    }

    var titleColumn = mapping?.columnFor(GenericDbRole.title) ?? '';
    if (titleColumn.isEmpty) {
      for (final column in columns) {
        if (roleForColumn(column)?.$1 == GenericDbRole.title) {
          titleColumn = column;
          break;
        }
      }
    }

    // 1) 作品表里有没有播放地址列：映射给的优先，其次按名字打分，
    //    最后按「这列里真有多少 http 地址」实测定夺。
    final playCandidates = <String>[];
    final mappedPlay = mapping?.columnFor(GenericDbRole.playUrl);
    if (mappedPlay != null && columns.contains(mappedPlay)) {
      playCandidates.add(mappedPlay);
    }
    for (final column in columns) {
      if (playCandidates.contains(column)) continue;
      final normalized = normalizeDbFieldName(column);
      if (normalized.isEmpty) continue;
      if (_nonPlayKeywords.any(normalized.contains)) continue;
      final scored = roleForColumn(column);
      final isPlay = scored?.$1 == GenericDbRole.playUrl;
      final looksUrl = normalized.contains('url') ||
          normalized.contains('m3u8') ||
          normalized.contains('play') ||
          normalized.contains('link') ||
          normalized.contains('stream') ||
          normalized.contains('地址') ||
          normalized.contains('播放');
      if (isPlay || looksUrl) playCandidates.add(column);
    }

    var playColumn = '';
    var playSample = 0;
    var best = (http: 0, video: 0);
    String? pendingColumn;

    Future<void> consider(String column) async {
      // 主键列绝不当播放地址：yellow 库里 id 存的就是网页播放页地址。
      if (column == idColumn) return;
      final sample = await _sampleAddress(db, table, column);
      if (sample.http < 40) return;
      if (pendingColumn == null || _addressScore(sample) > _addressScore(best)) {
        pendingColumn = column;
        best = sample;
      }
    }

    for (final candidate in playCandidates) {
      await consider(candidate);
      // 已经测到一列大半是视频直链，够确定了，不用再往下试。
      if (best.video >= 70) break;
    }
    // 命名候选都不像：整表扫一遍列，挑真地址最多、最像视频的那一列
    // （外来库的列名可能是 link / playaddr / 地址 这类咱没列举到的）。
    if (_addressScore(best) < 120) {
      for (final column in columns) {
        if (playCandidates.contains(column)) continue;
        final normalized = normalizeDbFieldName(column);
        if (normalized.isEmpty) continue;
        if (_nonPlayKeywords.any(normalized.contains)) continue;
        await consider(column);
      }
    }
    if (pendingColumn != null) {
      playColumn = pendingColumn!;
      playSample = best.video > 0 ? best.video : best.http;
    }

    if (playColumn.isNotEmpty && best.http >= 40) {
      return VideoDbRepairColumns(
        table: table,
        idColumn: idColumn,
        playColumn: playColumn,
        titleColumn: titleColumn,
        playSample: playSample,
      );
    }

    // 2) 作品表里没有能用的地址列：地址可能在副表（files / play / url 表）。
    GenericDbRelation? relation;
    if (schema != null) {
      for (final item in schema.relations) {
        if (item.columnFor(GenericDbRole.playUrl) != null) {
          relation = item;
          break;
        }
      }
    }
    if (relation != null) {
      final playColumnInRelated = relation.columnFor(GenericDbRole.playUrl)!;
      final sample =
          await _sampleAddress(db, relation.table, playColumnInRelated);
      if (sample.http >= 40) {
        return VideoDbRepairColumns(
          table: table,
          idColumn: relation.primaryKey,
          playColumn: playColumnInRelated,
          playTable: relation.table,
          playForeignKey: relation.foreignKey,
          titleColumn: titleColumn,
          playSample: sample.video > 0 ? sample.video : sample.http,
        );
      }
    }
    // 结构没给出关联时，自己找：哪张表有一列指回作品表、又有一列像地址。
    for (final candidate in tables) {
      if (candidate == table) continue;
      final relatedColumns = await _columnsOf(db, candidate);
      String? fk;
      for (final column in relatedColumns) {
        final normalized = normalizeDbFieldName(column);
        if (normalized.isEmpty) continue;
        if (normalized == normalizeDbFieldName(idColumn) ||
            _foreignKeyNames.contains(normalized)) {
          fk = column;
          break;
        }
      }
      if (fk == null) continue;
      for (final column in relatedColumns) {
        final normalized = normalizeDbFieldName(column);
        if (normalized.isEmpty) continue;
        if (_nonPlayKeywords.any(normalized.contains)) continue;
        final looksUrl = normalized.contains('url') ||
            normalized.contains('m3u8') ||
            normalized.contains('play') ||
            normalized.contains('link') ||
            normalized.contains('stream') ||
            normalized.contains('地址');
        if (!looksUrl) continue;
        final sample = await _sampleAddress(db, candidate, column);
        if (sample.http >= 40) {
          return VideoDbRepairColumns(
            table: table,
            idColumn: idColumn,
            playColumn: column,
            playTable: candidate,
            playForeignKey: fk,
            titleColumn: titleColumn,
            playSample: sample.video > 0 ? sample.video : sample.http,
          );
        }
      }
    }

    throw AppFailure(
      '这个库的作品表 $table 里没认到播放地址列。\n'
      '表里的字段有：${columns.take(14).join('、')}'
      '${columns.length > 14 ? ' …' : ''}\n\n'
      '点右上角「数据库字段」，把「播放地址」指定到正确的列'
      '（如果地址在另一张表，先在那个页面指定作品表），再来修。',
    );
  }

  /// 常见的「指回作品表」外键列名（归一化后）。
  static const _foreignKeyNames = ['vodid', 'videoid', 'movieid', 'workid'];

  /// 找出哪些副表存着指回作品表的 id（删死链时一起清）。
  ///
  /// 纯函数版在 [linkTablesFor]：删死链时只有外键味的名字才算关联。
  static Future<List<({String table, String column})>> _linkTables(
    Database db,
    Set<String> tables,
    String worksTable,
    String idColumn,
  ) async {
    if (idColumn.isEmpty) return const [];
    final tableColumns = <String, List<String>>{};
    for (final table in tables) {
      if (table == worksTable) continue;
      tableColumns[table] = await _columnsOf(db, table);
    }
    return linkTablesFor(tableColumns, worksTable, idColumn);
  }

  /// 删死链时要连带清哪些副表（纯函数，不碰数据库，测试直接验）。
  ///
  /// 只有外键味的名字才算关联：`vod_id` / `videoid` / `movieid` /
  /// `workid` 这类，或与作品表主键同名、但主键本身不是裸 `id` 的列。
  ///
  /// 裸 `id` 绝不当外键——每张表都有自己的 `id` 主键。旧代码按名字
  /// 一刀切：作品表主键是 plain `id` 的外来库，`categories.id` 也被
  /// 当成关联列，删死链 `DELETE FROM categories WHERE id IN (死链的
  /// 视频 id)`，分类表里同号的行全被连带删掉（2026-11-22 用户报
  /// 「修复把数据库删坏了」的根因之一；读库层 `_foreignKeyFor` 早就
  /// 写明「单列 `id` 不算外键」，这里是反的，现改成一致）。
  static List<({String table, String column})> linkTablesFor(
    Map<String, List<String>> tableColumns,
    String worksTable,
    String idColumn,
  ) {
    if (idColumn.isEmpty) return const [];
    final normalizedId = normalizeDbFieldName(idColumn);
    final out = <({String table, String column})>[];
    for (final entry in tableColumns.entries) {
      final table = entry.key;
      if (table == worksTable) continue;
      for (final column in entry.value) {
        final normalized = normalizeDbFieldName(column);
        if (normalized.isEmpty || normalized == 'id') continue;
        if (normalized == normalizedId ||
            _foreignKeyNames.contains(normalized)) {
          out.add((table: table, column: column));
          break;
        }
      }
    }
    return out;
  }

  /// 跑一次体检。 [path] 是库文件绝对路径（就地修改，调用方负责先备份）。
  static Future<VideoDbRepairReport> run(
    String path, {
    int concurrency = defaultConcurrency,
    Duration timeout = defaultTimeout,
    int scanLimit = 100000000,
    GenericDbSchema? schema,
    VideoDbRepairColumns? columns,
    void Function(int done, int total)? onProgress,
    void Function(String stage)? onStage,
    bool Function()? cancelled,
    Future<void> Function()? onBeforeWrite,
  }) async {
    final stopwatch = Stopwatch()..start();
    final db = await openDatabase(path);
    try {
      onStage?.call('正在识别这个库的字段…');
      final target = columns ?? await detect(db, schema: schema);
      onStage?.call(target.describe);

      final tables = <String>{
        for (final row in await db.rawQuery(
          "select name from sqlite_master where type='table'",
        ))
          (row['name'] as String? ?? ''),
      }..remove('');

      // 表名/列名一律引号包起来：外来库真有叫 order、group 的列。
      final scanTable =
          target.playTable.isEmpty ? target.table : target.playTable;
      final scanIdColumn =
          target.playTable.isEmpty ? target.idColumn : target.playForeignKey;
      final idExpr =
          scanIdColumn.isEmpty ? 'rowid' : _quote(scanIdColumn);
      final playExpr = _quote(target.playColumn);

      // 数总数：小库照数（进度能给百分比）；几 G 的大库不数——count(*)
      // 得把整表扫一遍，手机上能扫几分钟，一开修就卡在那儿像坏了一样。
      // 大库只探一下“有没有可测地址”，进度只报已测条数。
      var bigFile = false;
      try {
        bigFile = await File(path).length() > 900 * 1024 * 1024;
      } catch (_) {}
      var total = 0;
      var hasTestable = false;
      if (bigFile) {
        final probeRow = await db.rawQuery(
          'select rowid from ${_quote(scanTable)} where $playExpr is not null '
          "and trim(cast($playExpr as text)) <> '' limit 1",
        );
        hasTestable = probeRow.isNotEmpty;
      } else {
        total = Sqflite.firstIntValue(
              await db.rawQuery(
                'select count(*) from ${_quote(scanTable)} '
                "where $playExpr is not null "
                "and trim(cast($playExpr as text)) <> ''",
              ),
            ) ??
            0;
        hasTestable = total > 0;
      }
      if (!hasTestable) {
        throw AppFailure(
          '${target.playColumn} 这一列里没有可测的地址（全空）。\n'
          '${target.describe}',
        );
      }
      onStage?.call(
        total > 0 ? '待测 $total 条' : '开始体检（大库，边测边报进度）',
      );

      // 一边扫一边测一边删：每批 2000 行验完就把死链删掉，再读下一批。
      //
      // 3.5G 那种大库绝不能先把所有地址读进内存（几十万条 URL 就能把
      // 手机内存撑爆，用户看到的就是“修到一半没了”），也不能攒到最后
      // 一次性删（WAL 涨满磁盘）。这样内存只占一批，进度随时可见。
      final cache = <String, _Verdict>{};
      final links = target.playTable.isEmpty
          ? await _linkTables(db, tables, target.table, target.idColumn)
          : const <({String table, String column})>[];

      Future<_Verdict> verdictOf(String url) async {
        final key = url.trim();
        final cached = cache[key];
        if (cached != null) return cached;
        final verdict = await _probe(key, timeout);
        if (cache.length < _urlCacheLimit) cache[key] = verdict;
        return verdict;
      }

      /// 删一批死链（作品表那一行 + 关联副表），返回实际删掉的行数。
      Future<int> removeDead(List<Object?> slice, List<int> rids) async {
        const chunk = 500;
        var removedRows = 0;
        for (var i = 0; i < slice.length; i += chunk) {
          final end = i + chunk > slice.length ? slice.length : i + chunk;
          final idsPart = slice.sublist(i, end);
          final ridPart = rids.sublist(i, end);
          final marks = List.filled(idsPart.length, '?').join(',');
          // 地址在副表时删副表那一行（同一个作品别的地址保留）。
          if (target.playTable.isNotEmpty) {
            await db.transaction((txn) async {
              await txn.rawDelete(
                'delete from ${_quote(target.playTable)} '
                'where rowid in ($marks)',
                ridPart,
              );
            });
            removedRows += ridPart.length;
            continue;
          }
          await db.transaction((txn) async {
            final keyExpr =
                target.idColumn.isEmpty ? 'rowid' : _quote(target.idColumn);
            await txn.rawDelete(
              'delete from ${_quote(target.table)} where $keyExpr in ($marks)',
              idsPart,
            );
            for (final link in links) {
              await txn.rawDelete(
                'delete from ${_quote(link.table)} '
                'where ${_quote(link.column)} in ($marks)',
                idsPart,
              );
            }
          });
          removedRows += idsPart.length;
        }
        return removedRows;
      }

      const batchSize = 2000;
      final workers = concurrency.clamp(1, 32);
      var scanned = 0;
      var alive = 0;
      var unknown = 0;
      var deadCount = 0;
      var removed = 0;
      var cursor = 0;
      var batches = 0;
      var aborted = false;

      while (scanned < scanLimit) {
        if (cancelled?.call() ?? false) {
          aborted = true;
          break;
        }
        final batch = await db.rawQuery(
          'select rowid as rid, $idExpr as vid, $playExpr as addr '
          'from ${_quote(scanTable)} '
          'where rowid > ? and $playExpr is not null '
          "and trim(cast($playExpr as text)) <> '' "
          'order by rowid limit $batchSize',
          [cursor],
        );
        if (batch.isEmpty) break;

        final ids = <Object?>[];
        final rowIds = <int>[];
        final urls = <String>[];
        for (final row in batch) {
          cursor = (row['rid'] as num).toInt();
          rowIds.add(cursor);
          ids.add(scanIdColumn.isEmpty ? cursor : row['vid']);
          urls.add(extractPlayUrl(row['addr']));
        }

        final verdicts = List<_Verdict?>.filled(urls.length, null);
        var index = 0;
        Future<void> worker() async {
          while (true) {
            if (cancelled?.call() ?? false) {
              aborted = true;
              return;
            }
            final i = index;
            if (i >= urls.length) return;
            index = i + 1;
            verdicts[i] = await verdictOf(urls[i]);
          }
        }

        await Future.wait([for (var i = 0; i < workers; i++) worker()]);

        final deadIds = <Object?>[];
        final deadRowIds = <int>[];
        for (var i = 0; i < urls.length; i++) {
          switch (verdicts[i]) {
            case _Verdict.dead:
              deadIds.add(ids[i]);
              deadRowIds.add(rowIds[i]);
            case _Verdict.alive:
              alive++;
            case _Verdict.unknown:
            case null:
              unknown++;
          }
        }
        scanned += urls.length;
        deadCount += deadIds.length;
        onProgress?.call(scanned, total);
        if (deadIds.isNotEmpty) {
          await onBeforeWrite?.call();
          onStage?.call('正在删除 ${deadCount} 条死链…');
          removed += await removeDead(deadIds, deadRowIds);
        }
        // 大库写多了 WAL 会一直涨，定期截断一次，别把手机磁盘写满。
        batches++;
        if (batches % 10 == 0) {
          try {
            await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
          } catch (_) {}
        }
        if (aborted) break;
      }
      onProgress?.call(scanned, total);

      var rollupSkipped = false;
      if (removed > 0) {
        if (bigFile) {
          // 几 G 的库重建汇总要 join 全表，等于再扫一遍，别把修好的库
          // 卡在最后一步；女优库打开时会自己重算。
          rollupSkipped = true;
        } else {
          try {
            await _rebuildRollup(db, tables);
          } catch (_) {
            // 汇总重建是锦上添花：库结构不认识就跳过，别让整个修复失败。
          }
        }
      }

      return VideoDbRepairReport(
        total: scanned,
        alive: alive,
        dead: deadCount,
        unknown: unknown,
        removed: removed,
        elapsed: stopwatch.elapsed,
        cancelled: aborted,
        columns: target,
        rollupSkipped: rollupSkipped,
      );
    } finally {
      await db.close();
    }
  }

  static Future<void> _rebuildRollup(
    Database db,
    Set<String> tables,
  ) async {
    if (!tables.contains('actress_rollup') ||
        !tables.contains('actresses') ||
        !tables.contains('video_actress')) {
      return;
    }
    await db.transaction((txn) async {
      await txn.rawDelete('delete from actress_rollup');
      await txn.rawInsert('''
        insert into actress_rollup (name, first_rowid, avatar, works, sex, last_date)
        select a.name, a.rowid, coalesce(a.avatar,''), count(distinct va.vod_id),
               coalesce(a.sex,'female'), ''
          from actresses a
          join video_actress va on va.cate_id = a.cate_id
          join videos v on v.vod_id = va.vod_id
         group by a.cate_id
      ''');
      if (tables.contains('actress_rollup_meta')) {
        final people = Sqflite.firstIntValue(
              await txn.rawQuery('select count(*) from actress_rollup'),
            ) ??
            0;
        final links = Sqflite.firstIntValue(
              await txn.rawQuery('select count(*) from video_actress'),
            ) ??
            0;
        await txn.rawInsert(
          "insert or replace into actress_rollup_meta(key, value) values('signature', ?)",
          ['$people/$links'],
        );
      }
      if (tables.contains('index_categories')) {
        await txn.rawUpdate('''
          update index_categories set video_count = coalesce((
              select count(*) from video_category vc
                join videos v on v.vod_id = vc.vod_id
               where vc.main_category = index_categories.category_name), 0)
        ''');
      }
    });
  }
}
