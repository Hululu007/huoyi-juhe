import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_sql_import.dart';

/// 假执行器：只记 SQL、不碰真 sqlite（flutter test 里 sqflite
/// 跑不起来，见 test/actress_film_library_test.dart 头注释）。
/// INSERT 按表计数，校验查询按记下来的行数回答；CREATE 建的表
/// 名记下来，供“缺表”校验分支用。
class _RecordingExecutor implements SqlImportExecutor {
  final batches = <List<String>>[];
  final singles = <String>[];
  final tables = <String>{};
  final counts = <String, int>{};
  var closed = false;

  /// 遇到往这张表 INSERT 就抛错（换库失败注入用）。
  String? failOnTable;

  /// 校验查询一律抛错。
  var failQuery = false;

  @override
  Future<void> execute(String sql) async {
    // 像真 sqlite 一样：没有活动事务时裸 COMMIT 抛错（2026-11-25
    // 复核发现的 _statementHead 漏网：'COMMIT;' 带分号、对不上
    // 'COMMIT' 就被当普通语句执行，真机导入会在最后一步失败；
    // 样本里末行就是裸 COMMIT;，这里抛错才能让全链路测试拦住它）。
    final upper = sql.trim().toUpperCase();
    if (upper == 'COMMIT;' || upper == 'BEGIN TRANSACTION;') {
      throw StateError('cannot commit - no transaction is active');
    }
    singles.add(sql);
    if (upper.startsWith('CREATE TABLE')) {
      final name = RegExp(
        r'CREATE TABLE\s+"?(\w+)',
        caseSensitive: false,
      ).firstMatch(sql)?.group(1)?.toLowerCase();
      if (name != null) tables.add(name);
    }
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    batches.add(List<String>.of(statements));
    for (final statement in statements) {
      final table = RegExp(
        r'INSERT INTO\s+"?(\w+)',
        caseSensitive: false,
      ).firstMatch(statement)?.group(1)?.toLowerCase();
      if (table == null) continue;
      if (failOnTable == table) throw StateError('fake fail on $table');
      counts[table] = (counts[table] ?? 0) + 1;
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (failQuery) throw StateError('fake query fail');
    if (sql.contains('sqlite_master')) {
      return [
        for (final t in tables) {'name': t},
      ];
    }
    final table =
        RegExp(r'FROM\s+(\w+)', caseSensitive: false)
            .firstMatch(sql)
            ?.group(1)
            ?.toLowerCase() ??
        '';
    // 样本夹具：300 部全有封面、30 人全有头像，过滤计数就是全表数。
    return [
      {'COUNT(*)': counts[table] ?? 0},
    ];
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  group('SqlStatementSplitter 切分', () {
    test('字符串里的分号不切', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('a;b','x');",
      );
      expect(out, hasLength(1));
      expect(out.first, "INSERT INTO videos VALUES('a;b','x');");
    });

    test("'' 转义不是串尾", () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('it''s; fine','x');",
      );
      expect(out, hasLength(1));
    });

    test('跨行字符串是一条语句', () {
      final splitter = SqlStatementSplitter();
      final first = splitter.addLine(
        "INSERT INTO videos VALUES('第一行",
      );
      expect(first, isEmpty);
      final second = splitter.addLine("第二行; 还有分号');");
      expect(second, hasLength(1));
      expect(
        second.first,
        "INSERT INTO videos VALUES('第一行\n第二行; 还有分号');",
      );
    });

    test('一行多条与 -- 注释', () {
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        'PRAGMA foreign_keys=OFF; -- 注释里的分号不算',
      );
      expect(out, ['PRAGMA foreign_keys=OFF;']);
      expect(splitter.addLine('-- 整行注释'), isEmpty);
    });

    test('字符串里的 -- 不是注释（真库标题就有）', () {
      // 2026-11-25 修仙版移植时发现：魔蚁版先整行 indexOf('--')
      // 再截断，v3 .sql 里 934 行标题带 '--'（如 'K1037 餌食牝 --
      // 北上尚子'），第 429 行就把字符串拦腰截掉、下一条错位，
      // 真库导入直接报语法错误。样本夹具里没有 '--'，12 个移植
      // 测试全过也拦不住；这里补测，修仙版 13 测。
      final splitter = SqlStatementSplitter();
      final out = splitter.addLine(
        "INSERT INTO videos VALUES('k1037','K1037 餌食牝 -- 北上尚子','x');",
      );
      expect(out, hasLength(1));
      expect(out.first, contains('餌食牝 -- 北上尚子'));
      final next = splitter.addLine(
        "INSERT INTO videos VALUES('pfes-081','PFES-081','y');",
      );
      expect(next, hasLength(1));
      expect(next.first, startsWith("INSERT INTO videos VALUES('pfes-081'"));
    });

    test('建表跨行', () {
      final splitter = SqlStatementSplitter();
      expect(splitter.addLine('CREATE TABLE videos('), isEmpty);
      expect(splitter.addLine('vod_id TEXT PRIMARY KEY,'), isEmpty);
      final done = splitter.addLine('title TEXT);');
      expect(done, hasLength(1));
      expect(done.first.startsWith('CREATE TABLE videos('), isTrue);
    });
  });

  group('ActressSqlImporter 真夹具导入（300 行样本）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sql_import_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// 假执行器工厂：同时在临时库路径上落一个标记文件，模拟
    /// sqflite 建出来的临时库文件（换库改名要这个文件存在）。
    Future<SqlImportExecutor> Function(String) factoryFor(
      _RecordingExecutor executor, {
      String marker = 'NEWDB',
    }) {
      return (tempPath) async {
        await File(tempPath).writeAsString(marker);
        return executor;
      };
    }

    test('.sql 全链路：行数/播放地址/封面/头像都对上', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final progress = <ActressSqlImportProgress>[];
      final importer = ActressSqlImporter(
        batchSize: 100,
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: progress.add,
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 300);
      expect(result.actresses, 30);
      expect(result.playUrls, 480);
      expect(result.covers, 300);
      expect(result.avatars, 30);
      expect(result.warnings, isEmpty);
      expect(result.needsReload, isTrue);
      expect(closeCalls, 1);
      // 换库：现库被标记文件顶替，原库进了 .bak，临时文件没了。
      expect(await File(livePath).readAsString(), 'NEWDB');
      expect(await File('$livePath.bak').readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      // 分批：每批不超 100 条，INSERT 总数与夹具一致。
      expect(
        executor.batches.every((b) => b.length <= 100),
        isTrue,
      );
      final inserted = executor.batches.fold<int>(
        0,
        (sum, b) => sum + b.length,
      );
      expect(inserted, 27556);
      // .dump 自带的 BEGIN/COMMIT 没进执行器（事务由导入器按批管）。
      // 断言按前缀判：裸 'COMMIT;' 带分号、精确相等对不上它，
      // 2026-11-25 复核前这里就是漏网的（见 _statementHead 注释）。
      expect(
        executor.singles.any(
          (s) {
            final t = s.trim().toUpperCase();
            return t.startsWith('BEGIN') || t.startsWith('COMMIT');
          },
        ),
        isFalse,
      );
      // 进度报过、语句数单调涨、最后一次是校验阶段。
      expect(progress, isNotEmpty);
      expect(progress.last.phase, '正在校验');
      for (var i = 1; i < progress.length; i++) {
        expect(
          progress[i].statements >= progress[i - 1].statements,
          isTrue,
        );
      }
    });

    test('.sql.gz 同样能导', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        batchSize: 1000,
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql.gz',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 300);
      expect(result.playUrls, 480);
      expect(await File(livePath).readAsString(), 'NEWDB');
    });

    test('校验不过：空库不换库，原库一字不动', () async {
      final executor = _RecordingExecutor();
      final emptySql = File('${tempDir.path}/empty.sql');
      await emptySql.writeAsString(
        'PRAGMA foreign_keys=OFF;\n'
        'BEGIN TRANSACTION;\n'
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT);\n'
        'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
        'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
        'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n'
        'COMMIT;\n',
      );
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: emptySql.path,
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('没有作品'));
      expect(closeCalls, 0);
      expect(result.needsReload, isFalse);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.bak').exists(), isFalse);
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('缺表：不是女优库不换库', () async {
      final executor = _RecordingExecutor();
      final badSql = File('${tempDir.path}/bad.sql');
      await badSql.writeAsString(
        'CREATE TABLE videos(vod_id TEXT PRIMARY KEY);\n'
        'INSERT INTO videos VALUES(\'x\');\n',
      );
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: badSql.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('缺表'));
      expect(await File(livePath).readAsString(), 'OLDDB');
    });

    test('取消：停在换库前，原库不动', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      var closeCalls = 0;
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {
          closeCalls++;
        },
        onProgress: (_) {},
        isCancelled: () => true,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('已取消'));
      expect(closeCalls, 0);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('执行中途出错：临时文件清掉，原库不动', () async {
      final executor = _RecordingExecutor()..failOnTable = 'video_tag';
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.bak').exists(), isFalse);
      expect(await File('$livePath.importing').exists(), isFalse);
    });

    test('取消后能立刻再导一次且导成功：临时库清干净', () async {
      // 2026-11-25 补充验收 1：导失败/取消/中断后原库一字不动，
      // 且临时库文件清干净、没有残留 .importing 挡住下一轮。
      // App 每次点导入都 new 一个 ActressSqlImporter（见
      // _startSqlImport），这里也用全新导入器 + 全新执行器重导。
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final cancelled = ActressSqlImporter(
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final first = await cancelled.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
        isCancelled: () => true,
      );
      expect(first.ok, isFalse);
      expect(first.error, contains('已取消'));
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      expect(await File('$livePath.bak').exists(), isFalse);

      final retry = ActressSqlImporter(
        batchSize: 100,
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final second = await retry.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(second.ok, isTrue, reason: second.error);
      expect(second.videos, 300);
      expect(await File(livePath).readAsString(), 'NEWDB');
    });

    test('执行中途出错后能立刻再导一次且导成功', () async {
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final failing = ActressSqlImporter(
        executorFactory: factoryFor(
          _RecordingExecutor()..failOnTable = 'video_tag',
        ),
      );
      final first = await failing.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(first.ok, isFalse);
      expect(await File(livePath).readAsString(), 'OLDDB');
      expect(await File('$livePath.importing').exists(), isFalse);
      expect(await File('$livePath.bak').exists(), isFalse);

      final retry = ActressSqlImporter(
        batchSize: 100,
        executorFactory: factoryFor(_RecordingExecutor()),
      );
      final second = await retry.importFile(
        sqlPath: 'test/fixtures/actress_sample.sql',
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(second.ok, isTrue, reason: second.error);
      expect(second.videos, 300);
      expect(second.playUrls, 480);
      expect(await File(livePath).readAsString(), 'NEWDB');
    });

    test('非 .sql 文件直接拒绝', () async {
      final executor = _RecordingExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final txt = File('${tempDir.path}/x.txt');
      await txt.writeAsString('hello');
      final importer = ActressSqlImporter(
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: txt.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('.sql'));
    });
  });
}
