import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_sql_import.dart';

/// 模拟老版本 SQLite 的假执行器：ANALYZE 不认 sqlite_schema、
/// sqlite_stat1 表不存在——碰到统计语句就抛错（魔蚁
/// sql-analyze-fix 批的真机故障形态）。导入器若把统计语句整类
/// 过滤掉，本执行器永远收不到它们、导入照常成功。
class _OldSqliteExecutor implements SqlImportExecutor {
  final batches = <List<String>>[];
  final singles = <String>[];
  final tables = <String>{};
  final counts = <String, int>{};
  var closed = false;

  bool _isStatistics(String sql) {
    final upper = sql.trim().toUpperCase();
    return upper.startsWith('ANALYZE') ||
        RegExp(r'INSERT INTO\s+"?SQLITE_STAT1\b').hasMatch(upper);
  }

  @override
  Future<void> execute(String sql) async {
    if (_isStatistics(sql)) {
      throw StateError('old sqlite: no such table: sqlite_schema');
    }
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
      if (_isStatistics(statement)) {
        throw StateError('old sqlite: no such table: sqlite_stat1');
      }
      final table = RegExp(
        r'INSERT INTO\s+"?(\w+)',
        caseSensitive: false,
      ).firstMatch(statement)?.group(1)?.toLowerCase();
      if (table == null) continue;
      counts[table] = (counts[table] ?? 0) + 1;
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    if (sql.contains('sqlite_master')) {
      return [
        for (final t in tables) {'name': t},
      ];
    }
    final table =
        RegExp(
              r'FROM\s+(\w+)',
              caseSensitive: false,
            ).firstMatch(sql)?.group(1)?.toLowerCase() ??
        '';
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
  group('ANALYZE / sqlite_stat1 统计语句整类过滤（老 SQLite 兼容）', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sql_import_analyze_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<SqlImportExecutor> Function(String) factoryFor(
      _OldSqliteExecutor executor,
    ) {
      return (tempPath) async {
        await File(tempPath).writeAsString('NEWDB');
        return executor;
      };
    }

    test('带 ANALYZE 与 stat1 INSERT 的样本在老 SQLite 口径下导入成功', () async {
      // 标准四表小样本（标题里带 -- 顺带验切分器）+ .dump 尾部
      // 同款统计语句：中部一条 ANALYZE sqlite_schema、尾部
      // ANALYZE sqlite_master + 16 条 stat1 INSERT + 无目标
      // ANALYZE + 无分号残段 ANALYZE。
      const ddl = [
        'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT);',
        'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER);',
        'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id));',
        'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url));',
      ];
      const rows = [
        "INSERT INTO videos VALUES('v1','标题一','http://x/c1.jpg','http://x/1.m3u8','','','','','','','http://x/1.m3u8','有码','');",
        "INSERT INTO videos VALUES('v2','标题 -- 二','http://x/c2.jpg','http://x/2.m3u8','','','','','','','http://x/2.m3u8','无码','');",
        "INSERT INTO actresses VALUES('a1','甲','http://x/a1.jpg','','女','',0);",
        "INSERT INTO video_actress VALUES('v1','a1');",
        "INSERT INTO video_actress VALUES('v2','a1');",
        "INSERT INTO video_play_urls VALUES('v1','http://x/1.m3u8','');",
        "INSERT INTO video_play_urls VALUES('v2','http://x/2.m3u8','');",
      ];
      final poisoned = <String>[
        ...ddl,
        ...rows.sublist(0, 3),
        'ANALYZE sqlite_schema;',
        ...rows.sublist(3),
        'ANALYZE sqlite_master;',
        for (var i = 0; i < 16; i++)
          "INSERT INTO sqlite_stat1 VALUES('videos','idx',1.0);",
        'ANALYZE;',
        'ANALYZE sqlite_schema',
      ].join('\n');
      final sqlFile = File('${tempDir.path}/poisoned.sql');
      await sqlFile.writeAsString(poisoned);

      final executor = _OldSqliteExecutor();
      final livePath = '${tempDir.path}/女优库.db';
      await File(livePath).writeAsString('OLDDB');
      final importer = ActressSqlImporter(
        batchSize: 100,
        executorFactory: factoryFor(executor),
      );
      final result = await importer.importFile(
        sqlPath: sqlFile.path,
        dbPath: livePath,
        closeDatabase: () async {},
        onProgress: (_) {},
      );
      // 统计语句被整类过滤：导入成功、计数与干净样本一致。
      expect(result.ok, isTrue, reason: result.error);
      expect(result.videos, 2);
      expect(result.actresses, 1);
      expect(result.playUrls, 2);
      expect(await File(livePath).readAsString(), 'NEWDB');
      // 执行器从未收到任何统计语句。
      final received = <String>[
        ...executor.singles,
        for (final b in executor.batches) ...b,
      ];
      expect(
        received.any((s) {
          final upper = s.trim().toUpperCase();
          return upper.startsWith('ANALYZE') ||
              upper.contains('SQLITE_STAT1');
        }),
        isFalse,
      );
    });
  });
}
