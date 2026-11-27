import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_generic_db.dart';
import 'actress_library_version.dart';

/// 女优库 .sql 导入（2026-11-25 用户令）：把女优库.db 改成 .sql 后，
/// 从演员库设置里选 .sql / .sql.gz 文件导回手机，导完直接当主库用。
///
/// 流程：流式读 SQL（整文件不进内存）→ 临时库分批执行
/// （每批 INSERT 一个事务：条数上限 2000、字节上限 512KB，
/// 先到先 flush）→ 字段归一化（标准库直接过；
/// 字段不一样的库按字段名宽容映射建成标准表，见 _normalizeImport）
/// → 校验三项（作品数/播放地址大于 0；人数可为 0 只警告）
/// → 版本门（2026-11-27 激活批：临时库 schema_meta 的版本字段
/// 必须与当前软件对得上，见 actress_library_version.dart；
/// 缺字段/对不上整单拒、原库一字不动）
/// → 关主库连接 → 备份现库为 .bak → 临时库改名顶替主库。
/// 校验不过、取消、执行出错都在换库之前停下：原库一字不动，
/// 临时文件删掉。
///
/// 红线：临时库只在导入时存在，导完即改名成主库；journal_mode /
/// synchronous 一个字不改（读写库不抄参考文件的 OFF/WAL 写法）。
/// 导入失败绝不把半成品库留在主库路径上。

/// 导入进度：阶段 + 已执行语句数 + 已读字节 + 文件总字节。
class ActressSqlImportProgress {
  const ActressSqlImportProgress({
    required this.phase,
    required this.statements,
    required this.bytesRead,
    required this.totalBytes,
  });

  /// 阶段：正在导入 / 正在校验。
  final String phase;

  /// 已执行完的 SQL 语句数。
  final int statements;

  /// 已从 .sql 文件读入的字节数（.gz 按压缩后字节算）。
  final int bytesRead;

  /// .sql 文件总字节数（.gz 按压缩后大小算）。
  final int totalBytes;

  /// 0..1：按已读字节算的进度。
  double get fraction =>
      totalBytes <= 0 ? 0 : (bytesRead / totalBytes).clamp(0, 1);
}

/// 导入结果：成功时带四项验收数；失败时 [error] 非空、原库不动。
class ActressSqlImportResult {
  const ActressSqlImportResult({
    required this.ok,
    this.error,
    this.videos = 0,
    this.actresses = 0,
    this.playUrls = 0,
    this.covers = 0,
    this.avatars = 0,
    this.skipped = 0,
    this.warnings = const [],
    this.needsReload = false,
  });

  final bool ok;

  /// 失败原因（成功时为空）。取消也走这里。
  final String? error;

  /// 作品数（videos 表行数）。
  final int videos;

  /// 人数（actresses 表行数）。
  final int actresses;

  /// 播放地址行数（video_play_urls 表行数）。
  final int playUrls;

  /// 有封面的作品数（pic_url 非空）。
  final int covers;

  /// 有头像的人数（avatar 非空）。
  final int avatars;

  /// 归一化时跳过的行数（没有播放地址的行，不进库）。
  final int skipped;

  /// 非致命提醒（例如封面/头像数为 0 时写在这里，不拦导入）。
  final List<String> warnings;

  /// true = 导入走到过关主库连接那步（换库成功或换库失败），
  /// 调用方须重读数据库恢复连接；false = 还没动主库，不用重读。
  final bool needsReload;
}

/// SQL 语句切分器：流式喂行，按分号切语句。
///
/// 只认单引号字符串里的分号（`'a;b'` 不切、`''` 是转义不是串尾），
/// 跨行字符串也认（vod_content 里有换行时一条 INSERT 占多行）。
/// `--` 行注释（不在字符串里时）整行跳过。sqlite3 .dump 的输出
/// 就是这个格式：每条 INSERT 一行、建表跨行、字符串里可能有分号
/// 与换行。
class SqlStatementSplitter {
  final _buffer = StringBuffer();
  var _inString = false;

  /// 喂一行（不带换行符），返回这一行里切完的语句（0 条或多条）。
  ///
  /// `--` 只在字符串外面才是行注释：标题里就有 `--`（如
  /// 'K1037 餌食牝 -- 北上尚子'，v3 .sql 里 934 行），先整行
  /// indexOf('--') 再截断会把字符串拦腰截掉、下一条语句错位，
  /// 真库导入到第 429 行就报语法错误。所以注释判定必须逐字
  /// 扫描：只有不在字符串里时遇到 `--` 才丢掉行尾。
  List<String> addLine(String line) {
    final out = <String>[];
    var i = 0;
    while (i < line.length) {
      final c = line[i];
      if (_inString) {
        if (c == "'") {
          if (i + 1 < line.length && line[i + 1] == "'") {
            _buffer.write("''");
            i += 2;
            continue;
          }
          _inString = false;
        }
        _buffer.write(c);
        i++;
        continue;
      }
      // 行注释：不在字符串里时 `--` 后面整行不要。
      if (c == '-' && i + 1 < line.length && line[i + 1] == '-') {
        break;
      }
      if (c == "'") {
        _inString = true;
        _buffer.write(c);
        i++;
        continue;
      }
      if (c == ';') {
        _buffer.write(c);
        final statement = _buffer.toString().trim();
        _buffer.clear();
        if (statement.isNotEmpty) out.add(statement);
        i++;
        continue;
      }
      _buffer.write(c);
      i++;
    }
    // 行尾：字符串没闭合就是跨行字符串，补个换行留着。
    if (_inString) _buffer.write('\n');
    return out;
  }

  /// 流结束时收尾：残留的未闭合内容（正常 .dump 不应有）原样吐出。
  String? flush() {
    final rest = _buffer.toString().trim();
    _buffer.clear();
    _inString = false;
    return rest.isEmpty ? null : rest;
  }
}

/// 导入执行器：真正往库里写 SQL 的那一层。生产用 sqflite，
/// 测试用假实现（不碰真 sqlite，flutter test 里 sqflite 跑不起来）。
abstract class SqlImportExecutor {
  /// 执行一条非 INSERT 语句（建表、建索引、PRAGMA）。
  Future<void> execute(String sql);

  /// 一批 INSERT（一个事务内执行完）。
  Future<void> executeBatch(List<String> statements);

  /// 查一行（校验用）。
  Future<List<Map<String, Object?>>> query(String sql);

  Future<void> close();
}

/// sqflite 实现：批处理走 Batch，一次通道调用交一整批。
class SqfliteImportExecutor implements SqlImportExecutor {
  SqfliteImportExecutor(this._db);

  final Database _db;

  @override
  Future<void> execute(String sql) => _db.execute(sql);

  @override
  Future<void> executeBatch(List<String> statements) async {
    final batch = _db.batch();
    for (final statement in statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) => _db.rawQuery(sql);

  @override
  Future<void> close() => _db.close();
}

/// 取消导入：执行器之间检查 [isCancelled] 时抛这个，调用方按
/// “已取消，数据库未改动”收尾。
class ActressSqlImportCancelled implements Exception {}

/// 版本门拒收：message 是可直接上屏的中文原因（不套「导入
/// 失败：」前缀，与其它执行错误分开呈现）。
class ActressSqlImportRejected implements Exception {
  const ActressSqlImportRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 版本门判定：给临时库执行器，回中文拒收原因（null = 通过）。
/// 测试可注入假件；默认走 [actressLibraryVersionError] 真判定。
typedef ActressSqlVersionGate = Future<String?> Function(
  SqlImportExecutor executor,
);

/// 默认版本门：读临时库 schema_meta 按女优库版本规格判定。
Future<String?> defaultActressSqlVersionGate(
  SqlImportExecutor executor,
) async {
  final info = await readActressLibraryVersion(
    (sql) => executor.query(sql),
  );
  return actressLibraryVersionError(info);
}

/// 女优库 .sql 导入器。
class ActressSqlImporter {
  ActressSqlImporter({
    this.batchSize = 2000,
    this.batchByteLimit = 512 * 1024,
    Future<SqlImportExecutor> Function(String tempPath)? executorFactory,
    ActressSqlVersionGate? versionGate,
  }) : _executorFactory =
           executorFactory ??
           ((tempPath) async {
             final db = await openDatabase(
               tempPath,
               singleInstance: false,
             );
             return SqfliteImportExecutor(db);
           }),
       _versionGate = versionGate ?? defaultActressSqlVersionGate;

  /// 每批 INSERT 条数上限：2000 条一个事务，失败只丢一批、进度可续报。
  final int batchSize;

  /// 每批 INSERT 的 SQL 文本字节上限（默认 512KB）：累计字节数
  /// 达到上限就提前 flush，哪怕条数还没到 [batchSize]。单批载荷
  /// 封顶，避免少数超大语句把单次平台通道调用撑到近 MB 量级。
  final int batchByteLimit;

  final Future<SqlImportExecutor> Function(String tempPath) _executorFactory;

  /// 版本门（校验后、换库前执行；拒收时原库不动、临时库删）。
  final ActressSqlVersionGate _versionGate;

  static const _requiredTables = {
    'videos',
    'actresses',
    'video_actress',
    'video_play_urls',
  };

  /// 导入一个 .sql / .sql.gz 文件，成功就顶替 [dbPath] 的主库。
  ///
  /// [closeDatabase] 只在校验通过、准备换库时才调（关主库连接，
  /// 好让文件改名）。校验不过/取消/执行出错时不调，主库连接还
  /// 在、文件也不动。
  Future<ActressSqlImportResult> importFile({
    required String sqlPath,
    required String dbPath,
    required Future<void> Function() closeDatabase,
    required void Function(ActressSqlImportProgress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final sqlFile = File(sqlPath);
    if (dbPath.isEmpty) {
      return const ActressSqlImportResult(
        ok: false,
        error: '没有可替换的数据库路径',
      );
    }
    if (!await sqlFile.exists() || await sqlFile.length() == 0) {
      return const ActressSqlImportResult(
        ok: false,
        error: '选中的文件不存在或为空',
      );
    }
    final lower = sqlPath.toLowerCase();
    final isGz = lower.endsWith('.gz');
    if (!lower.endsWith('.sql') && !isGz) {
      return const ActressSqlImportResult(
        ok: false,
        error: '只认 .sql 或 .sql.gz 文件',
      );
    }
    final totalBytes = await sqlFile.length();
    final tempPath = '$dbPath.importing';
    final tempFile = File(tempPath);
    try {
      if (await tempFile.exists()) await tempFile.delete();
    } catch (_) {
      return const ActressSqlImportResult(
        ok: false,
        error: '临时库文件删不掉，请先确认没有别的导入在跑',
      );
    }

    SqlImportExecutor? executor;
    var closedDb = false;
    try {
      executor = await _executorFactory(tempPath);
      // .dump 开头自带 PRAGMA foreign_keys=OFF；这里再关一次，
      // 导入中途外键不拦批量写。
      await executor.execute('PRAGMA foreign_keys=OFF');
      // 导入期关掉落盘同步：每批提交不再等一次物理落盘同步，
      // 导入时长大幅缩短。注意这是连接级设置、不写进库文件、
      // 只作用于临时库的导入连接；最终库文件仍是标准设置，
      // 不触碰文件头红线的本意（红线管的是成品库文件属性，
      // 不让成品库带着 OFF/WAL 跑）；journal_mode 本次不动。
      await executor.execute('PRAGMA synchronous=OFF');
      var statements = 0;
      var bytesRead = 0;
      var lastReportedBytes = 0;
      final splitter = SqlStatementSplitter();
      final pendingInserts = <String>[];
      var pendingBytes = 0;

      Future<void> flushInserts() async {
        if (pendingInserts.isEmpty) return;
        final batch = List<String>.of(pendingInserts);
        pendingInserts.clear();
        pendingBytes = 0;
        try {
          await executor!.executeBatch(batch);
        } catch (_) {
          // 批是单事务、失败整批回滚，重执行同一批是安全的：
          // 等 300ms 用同一批重试一次，瞬时 I/O 抖动不该让
          // 几十分钟的导入整单作废；再失败才按原路报错收尾。
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await executor!.executeBatch(batch);
        }
        statements += batch.length;
        onProgress(
          ActressSqlImportProgress(
            phase: '正在导入',
            statements: statements,
            bytesRead: bytesRead,
            totalBytes: totalBytes,
          ),
        );
      }

      void checkCancelled() {
        if (isCancelled != null && isCancelled()) {
          throw ActressSqlImportCancelled();
        }
      }

      Stream<List<int>> byteStream = sqlFile.openRead();
      if (isGz) byteStream = byteStream.transform(gzip.decoder);
      final lines = byteStream
          .map((chunk) {
            bytesRead += chunk.length;
            return chunk;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        checkCancelled();
        for (final statement in splitter.addLine(line)) {
          final head = _statementHead(statement);
          if (head == 'BEGIN' || head == 'COMMIT') {
            // .dump 自带的事务起止：事务由这里按批管，跳过它自己的。
            continue;
          }
          if (_isStatisticsStatement(statement, head)) {
            // 查询优化器统计语句整类过滤（魔蚁 sql-analyze-fix 口径）：
            // ANALYZE 在老版本 SQLite 上不认 sqlite_schema 必炸、
            // sqlite_stat1 表又只能由它建，17 条连环失败曾把整份
            // 导入拖死；统计数据不是用户数据，不执行、不计数。
            continue;
          }
          if (head == 'INSERT') {
            pendingInserts.add(statement);
            pendingBytes += utf8.encode(statement).length;
            if (pendingInserts.length >= batchSize ||
                pendingBytes >= batchByteLimit) {
              await flushInserts();
              checkCancelled();
            }
          } else {
            await flushInserts();
            await executor.execute(statement);
            statements++;
          }
        }
        // 每读 1MB 报一次进度（读得比写快时进度条也走）。
        if (bytesRead - lastReportedBytes >= 1024 * 1024) {
          lastReportedBytes = bytesRead;
          onProgress(
            ActressSqlImportProgress(
              phase: '正在导入',
              statements: statements,
              bytesRead: bytesRead,
              totalBytes: totalBytes,
            ),
          );
        }
      }
      final tail = splitter.flush();
      if (tail != null) {
        final head = _statementHead(tail);
        if (head != 'BEGIN' &&
            head != 'COMMIT' &&
            !_isStatisticsStatement(tail, head)) {
          if (head == 'INSERT') {
            pendingInserts.add(tail);
          } else {
            await executor.execute(tail);
            statements++;
          }
        }
      }
      await flushInserts();
      checkCancelled();

      // 字段归一化：标准库直接过；字段不一样的库按字段名宽容映射
      // 建成标准表（缺播放地址的行跳过并计数）。
      var normalizedRows = 0;
      final skipped = await _normalizeImport(
        executor,
        onNormalized: (rows) {
          normalizedRows = rows;
          onProgress(
            ActressSqlImportProgress(
              phase: '正在归一化',
              statements: statements + rows,
              bytesRead: bytesRead,
              totalBytes: totalBytes,
            ),
          );
        },
      );
      checkCancelled();

      // 校验（还在临时库上，不合格不换库）。
      onProgress(
        ActressSqlImportProgress(
          phase: '正在校验',
          statements: statements + normalizedRows,
          bytesRead: bytesRead,
          totalBytes: totalBytes,
        ),
      );
      final counts = await _validate(executor);
      // 版本门（2026-11-27 激活批）：临时库的版本字段必须与当前
      // 软件对得上，缺字段/对不上整单拒——还在临时库上，原库
      // 一字不动、临时文件由 finally 清掉。
      final versionError = await _versionGate(executor);
      if (versionError != null) {
        throw ActressSqlImportRejected(versionError);
      }
      final warnings = <String>[];
      if (counts.covers == 0) warnings.add('导入的库里没有封面');
      if (counts.avatars == 0) warnings.add('导入的库里没有头像');
      if (counts.actresses == 0) warnings.add('导入的库里没有演员信息');
      if (skipped > 0) warnings.add('跳过 $skipped 行（没有播放地址）');
      await executor.close();
      executor = null;

      // 换库：关主库连接 → 备份现库 → 临时库改名顶替。
      try {
        await closeDatabase();
      } catch (_) {
        // 关连接失败不拦换库（文件改名才是关键一步）。
      }
      closedDb = true;
      final liveFile = File(dbPath);
      final bakPath = '$dbPath.bak';
      final liveExists = await liveFile.exists();
      if (liveExists) {
        await liveFile.copy(bakPath);
      }
      try {
        await tempFile.rename(dbPath);
      } catch (e) {
        // 改名失败：现库还在就不用动；现库没了就从备份恢复。
        if (!await liveFile.exists() && liveExists) {
          try {
            await File(bakPath).copy(dbPath);
          } catch (_) {}
        }
        return ActressSqlImportResult(
          ok: false,
          error: '换库失败：$e（已恢复原库）',
          needsReload: true,
        );
      }
      return ActressSqlImportResult(
        ok: true,
        videos: counts.videos,
        actresses: counts.actresses,
        playUrls: counts.playUrls,
        covers: counts.covers,
        avatars: counts.avatars,
        skipped: skipped,
        warnings: warnings,
        needsReload: true,
      );
    } on ActressSqlImportRejected catch (e) {
      return ActressSqlImportResult(
        ok: false,
        error: e.message,
        needsReload: closedDb,
      );
    } on ActressSqlImportCancelled {
      return ActressSqlImportResult(
        ok: false,
        error: '已取消，数据库未改动',
        needsReload: closedDb,
      );
    } catch (e) {
      return ActressSqlImportResult(
        ok: false,
        error: '导入失败：${e.toString().split('\n').first}',
        needsReload: closedDb,
      );
    } finally {
      try {
        await executor?.close();
      } catch (_) {}
      // 失败/取消后临时文件必须清掉，不留半成品库。
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
    }
  }

  /// 查询优化器统计语句判定（整类过滤、不执行、不计数）：
  /// `ANALYZE` 全部形态（带 sqlite_schema / sqlite_master 目标、
  /// 无目标）与往 `sqlite_stat1` 的 INSERT。依据见魔蚁
  /// sql-analyze-fix 批：.dump 尾部的 ANALYZE + 16 条 stat1 INSERT
  /// 在老版本 SQLite 上连环失败、零用户数据，不该拖死整份导入。
  static bool _isStatisticsStatement(String statement, String head) {
    if (head == 'ANALYZE') return true;
    if (head != 'INSERT') return false;
    return RegExp(
      r'''^\s*INSERT\s+INTO\s+["'\[\`]?\s*sqlite_stat1\b''',
      caseSensitive: false,
    ).hasMatch(statement);
  }

  /// 语句头一个词（INSERT / CREATE / PRAGMA / BEGIN / COMMIT …）。
  ///
  /// 注意：语句自带尾部分号，'COMMIT;' 按空白/括号切会得到
  /// 'COMMIT;'（没有空白可切），与 'COMMIT' 对不上、会被当成
  /// 普通语句执行——真 sqlite 里没有活动事务时 COMMIT 直接抛
  /// 错，整个导入在最后一步失败（v3 .sql 末行就是裸 COMMIT;，
  /// 2026-11-25 移植后复核发现，魔蚁版同款问题）。先去掉尾部
  /// 分号再取头词。
  static String _statementHead(String statement) {
    final text = statement
        .trimLeft()
        .replaceFirst(RegExp(r';\s*$'), '');
    final end = text.indexOf(RegExp(r'\s|\('));
    final head = (end < 0 ? text : text.substring(0, end)).toUpperCase();
    // CREATE TABLE / CREATE INDEX / CREATE UNIQUE INDEX：头词都是 CREATE。
    return head;
  }

  /// 校验临时库：四张必备表都在、作品与播放地址都大于 0。
  /// 人数可为 0（只警告、不拦：没演员信息的库作品仍可通过分类/
  /// 影视库看）。失败抛错（调用方按“原库不动”收尾）。
  Future<
    ({
      int videos,
      int actresses,
      int playUrls,
      int covers,
      int avatars,
    })
  > _validate(SqlImportExecutor executor) async {
    final tableRows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = {
      for (final row in tableRows) '${row['name']}',
    };
    final missing = _requiredTables.difference(tables);
    if (missing.isNotEmpty) {
      throw StateError('缺表：${missing.join('、')}，不是女优库');
    }
    Future<int> count(String sql) async {
      final rows = await executor.query(sql);
      if (rows.isEmpty) return 0;
      return (rows.first.values.first as num?)?.toInt() ?? 0;
    }

    final videos = await count('SELECT COUNT(*) FROM videos');
    final actresses = await count('SELECT COUNT(*) FROM actresses');
    final playUrls = await count('SELECT COUNT(*) FROM video_play_urls');
    final covers = await count(
      "SELECT COUNT(*) FROM videos WHERE pic_url IS NOT NULL AND pic_url <> ''",
    );
    final avatars = await count(
      "SELECT COUNT(*) FROM actresses WHERE avatar IS NOT NULL AND avatar <> ''",
    );
    if (videos == 0) throw StateError('导入的库里没有作品');
    if (playUrls == 0) throw StateError('导入的库里没有播放地址');
    return (
      videos: videos,
      actresses: actresses,
      playUrls: playUrls,
      covers: covers,
      avatars: avatars,
    );
  }

  /// 标准库关键列：四表齐且这些列都在，才算标准库、走快捷通道。
  static const _standardKeyColumns = <String, List<String>>{
    'videos': [
      'vod_id',
      'title',
      'pic_url',
      'm3u8_url',
      'vod_play_url',
      'type_name',
    ],
    'actresses': ['cate_id', 'name', 'avatar'],
    'video_actress': ['vod_id', 'cate_id'],
    'video_play_urls': ['vod_id', 'play_url'],
  };

  /// 标准表 DDL（与真库一致，见 REPORT §九）：归一化建表用；
  /// actresses 带 roster_id/claimed/sex 列，免得同步写时缺列失败。
  static const _standardTableDdl = <String, String>{
    'videos':
        'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
    'actresses':
        'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
    'video_actress':
        'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
    'video_play_urls':
        'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
    'video_category':
        'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
    'video_tag':
        'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
  };

  /// 头像列名（归一化后）：人物表与作品表独立头像列都认这些。
  static const _avatarColumnNames = {
    'avatar',
    'avatarurl',
    'head',
    'headimg',
    'headpic',
    'photo',
    'portrait',
    'face',
    '头像',
    'pic',
    'image',
  };

  static bool _isAvatarColumnName(String column) =>
      _avatarColumnNames.contains(normalizeDbFieldName(column));

  /// 字段不一样的 .sql 归一化（2026-11-25 用户令：不管什么字段的
  /// .sql 导入，都要能显示列表/封面/头像/播放链接、能播）：
  /// 先判标准库（四表齐且关键列在）→ 快捷通道，返回 0；
  /// 否则按字段名宽容映射，把作品表读行建成标准表。
  /// 缺播放地址的行跳过并计数（返回值）；缺失的可选字段按空处理。
  /// [onNormalized] 每读完一批作品行回调一次（累计已归一化行数），
  /// 调用方用它报“正在归一化”进度。
  Future<int> _normalizeImport(
    SqlImportExecutor executor, {
    required void Function(int rows) onNormalized,
  }) async {
    final tableRows = await executor.query(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = <String>{
      for (final row in tableRows) '${row['name']}',
    }..removeWhere((t) => t.startsWith('sqlite_'));
    // 探每张表的列：答不出列信息（测试假执行器）时按老口径——
    // 四表齐当标准库，不齐报缺表。
    final tableColumns = <String, List<String>>{};
    final pkColumns = <String, String>{};
    var canInspect = true;
    for (final table in tables) {
      final cols = await executor.query(
        'PRAGMA table_info(${_ident(table)})',
      );
      final names = <String>[];
      for (final col in cols) {
        final name = col['name'];
        if (name == null) continue;
        names.add('$name');
        if (col['pk'] == 1) pkColumns[table] = '$name';
      }
      if (names.isEmpty) {
        canInspect = false;
        break;
      }
      tableColumns[table] = names;
    }
    if (!canInspect) {
      final missing = _requiredTables.difference(tables);
      if (missing.isNotEmpty) {
        throw StateError('缺表：${missing.join('、')}，不是女优库');
      }
      return 0;
    }
    if (_isStandardLibrary(tableColumns)) {
      // 标准库：可选表缺了就补建空表（首页分类/标签读它们）。
      for (final optional in ['video_category', 'video_tag']) {
        if (!tables.contains(optional)) {
          await executor.execute(_standardTableDdl[optional]!);
        }
      }
      return 0;
    }
    return _normalizeToStandard(
      executor,
      tables,
      tableColumns,
      pkColumns,
      onNormalized: onNormalized,
    );
  }

  bool _isStandardLibrary(Map<String, List<String>> tableColumns) {
    for (final entry in _standardKeyColumns.entries) {
      final columns = tableColumns[entry.key];
      if (columns == null) return false;
      final lower = columns.map((c) => c.toLowerCase()).toSet();
      for (final required in entry.value) {
        if (!lower.contains(required)) return false;
      }
    }
    return true;
  }

  /// 归一化本体：作品表读行 → 建标准表。已存在但结构不对的标准表
  /// 先改名成 <名>_source（数据不动），再建标准表。
  Future<int> _normalizeToStandard(
    SqlImportExecutor executor,
    Set<String> tables,
    Map<String, List<String>> tableColumns,
    Map<String, String> pkColumns, {
    required void Function(int rows) onNormalized,
  }) async {
    final schema = classifyGenericTables(tableColumns, pkColumns: pkColumns);
    var works = schema.worksTable;
    if (works != null) {
      final playCol = works.columnFor(GenericDbRole.playUrl);
      if (playCol != null && _isAvatarColumnName(playCol)) {
        // 唯一的“地址列”其实是头像列：这张表没有真播放地址。
        works = null;
      }
    }
    if (works == null) {
      throw StateError('认不出作品表：没有同时带标题与播放地址的表');
    }
    final titleCol = works.columnFor(GenericDbRole.title)!;
    final playCol = works.columnFor(GenericDbRole.playUrl)!;
    final persons =
        schema.personsTable ?? _personsTableFallback(schema, works);

    // 标准表名已存在但结构不对：先改名（数据不动），再建标准表。
    final renamed = <String, String>{};
    for (final name in _standardTableDdl.keys) {
      if (!tables.contains(name)) continue;
      var source = '${name}_source';
      if (tables.contains(source)) source = '${name}_source2';
      if (tables.contains(source)) {
        throw StateError('表名冲突：$name 与 $source 都已存在');
      }
      await executor.execute(
        'ALTER TABLE ${_ident(name)} RENAME TO ${_ident(source)}',
      );
      renamed[name] = source;
    }
    String sourceName(String original) => renamed[original] ?? original;
    for (final ddl in _standardTableDdl.values) {
      await executor.execute(ddl);
    }

    // 人物表：名 → cate_id 映射（作品行挂人用），头像一起进库。
    final nameToCateId = <String, String>{};
    if (persons != null) {
      final personsTable = sourceName(persons.table);
      final personsNameCol =
          persons.columnFor(GenericDbRole.title) ??
          persons.columnFor(GenericDbRole.actress);
      final personsAvatarCol =
          persons.columnFor(GenericDbRole.cover) ??
          _avatarColumn(persons.allColumns);
      final personsIdCol =
          persons.columnFor(GenericDbRole.code) ?? persons.idColumn;
      if (personsNameCol != null) {
        await _forEachRow(
          executor,
          personsTable,
          columns: [
            if (personsIdCol != null) personsIdCol,
            personsNameCol,
            if (personsAvatarCol != null) personsAvatarCol,
          ],
          onBatch: (rows) async {
            final inserts = <String>[];
            for (final row in rows) {
              final name = _cellText(row[personsNameCol]);
              if (name.isEmpty) continue;
              final id = personsIdCol == null
                  ? name
                  : _cellText(row[personsIdCol]);
              final cateId = id.isEmpty ? name : id;
              nameToCateId[name] = cateId;
              final avatar = personsAvatarCol == null
                  ? ''
                  : resolveCoverUrl(row[personsAvatarCol]);
              inserts.add(
                'INSERT OR IGNORE INTO actresses (cate_id, name, avatar, sex, roster_id, claimed) '
                "VALUES (${_q(cateId)}, ${_q(name)}, ${_q(avatar)}, '', '', 0)",
              );
            }
            if (inserts.isNotEmpty) await executor.executeBatch(inserts);
          },
        );
      }
    }

    // 作品表各角色列。
    final coverCol = works.columnFor(GenericDbRole.cover);
    final codeCol = works.columnFor(GenericDbRole.code);
    final categoryCol = works.columnFor(GenericDbRole.category);
    final actressCol = works.columnFor(GenericDbRole.actress);
    final dateCol = works.columnFor(GenericDbRole.date);
    // 作品表独立头像列：只认 avatar/avatarurl/头像，且不是封面列那一列。
    final worksAvatarCol = _avatarColumn(
      works.allColumns,
      exclude: coverCol,
    );
    final worksTable = sourceName(works.table);
    final playFrom = works.table;
    final readColumns = <String>{
      titleCol,
      playCol,
      if (codeCol != null) codeCol,
      if (coverCol != null) coverCol,
      if (categoryCol != null) categoryCol,
      if (actressCol != null) actressCol,
      if (dateCol != null) dateCol,
      if (worksAvatarCol != null) worksAvatarCol,
    }.toList();
    var skipped = 0;
    var normalized = 0;
    await _forEachRow(
      executor,
      worksTable,
      columns: readColumns,
      onBatch: (rows) async {
        final videoInserts = <String>[];
        final urlInserts = <String>[];
        final categoryInserts = <String>[];
        final actressInserts = <String>[];
        final linkInserts = <String>[];
        for (final row in rows) {
          final playUrl = extractPlayUrl(row[playCol]);
          if (playUrl.isEmpty) {
            skipped++;
            continue;
          }
          final rowId = row['rowid'];
          final code = codeCol == null ? '' : _cellText(row[codeCol]);
          final vodId = code.isEmpty ? 'row-${rowId ?? ''}' : code;
          var title = _cellText(row[titleCol]);
          if (title.isEmpty) title = vodId;
          final cover = coverCol == null
              ? ''
              : resolveCoverUrl(row[coverCol]);
          final category = categoryCol == null
              ? ''
              : _cellText(row[categoryCol]);
          final date = dateCol == null ? '' : _cellText(row[dateCol]);
          videoInserts.add(
            'INSERT OR IGNORE INTO videos (vod_id, title, pic_url, m3u8_url, vod_remarks, vod_pubdate, vod_area, vod_year, vod_content, vod_play_from, vod_play_url, type_name) '
            "VALUES (${_q(vodId)}, ${_q(title)}, ${_q(cover)}, ${_q(playUrl)}, '', ${_q(date)}, '', '', '', ${_q(playFrom)}, ${_q(playUrl)}, ${_q(category)})",
          );
          urlInserts.add(
            'INSERT OR IGNORE INTO video_play_urls (vod_id, play_url, play_from) '
            "VALUES (${_q(vodId)}, ${_q(playUrl)}, ${_q(playFrom)})",
          );
          if (category.isNotEmpty) {
            categoryInserts.add(
              'INSERT OR IGNORE INTO video_category (vod_id, main_category) '
              "VALUES (${_q(vodId)}, ${_q(category)})",
            );
          }
          // 女优：作品行里的名字先挂进 actresses（头像只认作品表
          // 的独立头像列），再挂 video_actress 关联。
          final names = actressCol == null
              ? const <String>[]
              : _splitActressNames(_cellText(row[actressCol]));
          for (final name in names) {
            final cateId = nameToCateId[name] ?? name;
            final avatar = worksAvatarCol == null
                ? ''
                : resolveCoverUrl(row[worksAvatarCol]);
            actressInserts.add(
              'INSERT OR IGNORE INTO actresses (cate_id, name, avatar, sex, roster_id, claimed) '
              "VALUES (${_q(cateId)}, ${_q(name)}, ${_q(avatar)}, '', '', 0)",
            );
            linkInserts.add(
              'INSERT OR IGNORE INTO video_actress (vod_id, cate_id) '
              "VALUES (${_q(vodId)}, ${_q(cateId)})",
            );
          }
        }
        for (final batch in [
          videoInserts,
          urlInserts,
          categoryInserts,
          actressInserts,
          linkInserts,
        ]) {
          if (batch.isNotEmpty) await executor.executeBatch(batch);
        }
        normalized += rows.length;
        onNormalized(normalized);
      },
    );
    return skipped;
  }

  /// 人物表兜底：classify 没认出来时（比如头像列叫 avatar_url 被算
  /// 成播放地址列，或人名列只认出 actress 角色没认出 title 角色），
  /// 再按“有名列、且播放地址列全是头像列”扫一遍。分类字典表排除。
  GenericDbTableMapping? _personsTableFallback(
    GenericDbSchema schema,
    GenericDbTableMapping works,
  ) {
    for (final mapping in schema.tables) {
      if (mapping.table == works.table) continue;
      final normalizedTable = normalizeDbFieldName(mapping.table);
      if (normalizedTable == 'categories' ||
          normalizedTable == 'category') {
        continue;
      }
      final nameCol =
          mapping.columnFor(GenericDbRole.actress) ??
          mapping.columnFor(GenericDbRole.title);
      if (nameCol == null) continue;
      final playCol = mapping.columnFor(GenericDbRole.playUrl);
      if (playCol != null && !_isAvatarColumnName(playCol)) continue;
      return mapping;
    }
    return null;
  }

  /// 作品表/人物表里找头像列：第一个头像名、且不是封面列那一列。
  static String? _avatarColumn(
    List<String> columns, {
    String? exclude,
  }) {
    for (final column in columns) {
      if (column == exclude) continue;
      if (_isAvatarColumnName(column)) return column;
    }
    return null;
  }

  /// 分页读一张表（ORDER BY rowid，每页 [batchSize] 行），
  /// 读完一批调一次 [onBatch]。行里带 rowid 键。
  Future<void> _forEachRow(
    SqlImportExecutor executor,
    String table, {
    required List<String> columns,
    required Future<void> Function(List<Map<String, Object?>> rows) onBatch,
  }) async {
    final selectList = [
      'rowid',
      for (final c in columns) _ident(c),
    ].join(', ');
    var offset = 0;
    while (true) {
      final rows = await executor.query(
        'SELECT $selectList FROM ${_ident(table)} '
        'ORDER BY rowid LIMIT $batchSize OFFSET $offset',
      );
      if (rows.isEmpty) return;
      await onBatch(rows);
      offset += rows.length;
      if (rows.length < batchSize) return;
    }
  }

  /// SQL 字符串字面量：单引号加倍转义。
  static String _q(String value) => "'${value.replaceAll("'", "''")}'";

  /// SQL 标识符（表名/列名）：双引号包起来，双引号加倍转义。
  static String _ident(String name) => '"${name.replaceAll('"', '""')}"';

  /// 单元格取值：null → ''，其余转字符串去首尾空白。
  static String _cellText(Object? value) =>
      value == null ? '' : value.toString().trim();

  /// 女优名拆分：`A、B、C` / `A, B` / `A/B` / `A|B` 都拆，去重保序。
  static List<String> _splitActressNames(String text) {
    if (text.isEmpty) return const [];
    final names = <String>[];
    for (final part in text.split(RegExp(r'[、，,;；/｜|]+'))) {
      final name = part.trim();
      if (name.isNotEmpty && !names.contains(name)) names.add(name);
    }
    return names;
  }
}
