import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_sql_import.dart';

/// Fake executor for the 2026-11-27 crash-fix cases: batch retry and
/// byte-limit flushing. Records batches, counts INSERTs per table,
/// answers validation queries from those counts (same approach as
/// actress_sql_import_test.dart's recording executor).
class _FakeExecutor implements SqlImportExecutor {
  final batches = <List<String>>[];
  final singles = <String>[];
  final tables = <String>{};
  final counts = <String, int>{};
  var batchCalls = 0;
  var closed = false;

  /// First executeBatch call throws, later calls succeed.
  var failFirstBatch = false;

  /// Every executeBatch call throws.
  var failAllBatches = false;

  @override
  Future<void> execute(String sql) async {
    singles.add(sql);
    if (sql.trim().toUpperCase().startsWith('CREATE TABLE')) {
      final name = RegExp(
        r'CREATE TABLE\s+"?(\w+)',
        caseSensitive: false,
      ).firstMatch(sql)?.group(1)?.toLowerCase();
      if (name != null) tables.add(name);
    }
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    batchCalls++;
    if (failAllBatches) throw StateError('fake batch fail (all)');
    if (failFirstBatch && batchCalls == 1) {
      throw StateError('fake batch fail (first)');
    }
    batches.add(List<String>.of(statements));
    for (final statement in statements) {
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
        RegExp(r'FROM\s+(\w+)', caseSensitive: false)
            .firstMatch(sql)
            ?.group(1)
            ?.toLowerCase() ??
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

String _schemaSql() {
  return 'CREATE TABLE videos(vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT);\n'
      'CREATE TABLE actresses(cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT);\n'
      'CREATE TABLE video_actress(vod_id TEXT, cate_id TEXT);\n'
      'CREATE TABLE video_play_urls(vod_id TEXT, play_url TEXT);\n';
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sql_import_retry_');
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<SqlImportExecutor> Function(String) factoryFor(
    _FakeExecutor executor,
  ) {
    return (tempPath) async {
      await File(tempPath).writeAsString('NEWDB');
      return executor;
    };
  }

  Future<File> writeSql(String name, String body) async {
    final f = File('${tempDir.path}/$name');
    await f.writeAsString(body);
    return f;
  }

  test('retry: first batch fails, retry succeeds, import succeeds', () async {
    final executor = _FakeExecutor()..failFirstBatch = true;
    final sql = await writeSql(
      'ok.sql',
      '${_schemaSql()}'
          "INSERT INTO videos VALUES('v1','t','p');\n"
              "INSERT INTO actresses VALUES('a1','n','av');\n"
              "INSERT INTO video_actress VALUES('v1','a1');\n"
              "INSERT INTO video_play_urls VALUES('v1','http://x/1.m3u8');\n",
    );
    final livePath = '${tempDir.path}/live.db';
    await File(livePath).writeAsString('OLDDB');
    final importer = ActressSqlImporter(
      versionGate: (_) async => null,
      executorFactory: factoryFor(executor),
    );
    final result = await importer.importFile(
      sqlPath: sql.path,
      dbPath: livePath,
      closeDatabase: () async {},
      onProgress: (_) {},
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(result.videos, 1);
    expect(result.playUrls, 1);
    // First call failed + its retry + remaining batches => at least 2 calls
    // for the first batch's worth of data, and data counted exactly once
    // (retry re-executes the same batch, fake counts only on success).
    expect(executor.batchCalls, greaterThan(executor.batches.length));
    expect(await File(livePath).readAsString(), 'NEWDB');
    // synchronous OFF was set on the import connection.
    expect(
      executor.singles.any(
        (s) => s.toUpperCase().contains('PRAGMA SYNCHRONOUS=OFF'),
      ),
      isTrue,
    );
  });

  test('retry exhausted: every batch fails, Chinese error, temp cleaned, live untouched', () async {
    final executor = _FakeExecutor()..failAllBatches = true;
    final sql = await writeSql(
      'fail.sql',
      '${_schemaSql()}'
          "INSERT INTO videos VALUES('v1','t','p');\n"
              "INSERT INTO video_play_urls VALUES('v1','http://x/1.m3u8');\n",
    );
    final livePath = '${tempDir.path}/live.db';
    await File(livePath).writeAsString('OLDDB');
    final importer = ActressSqlImporter(
      versionGate: (_) async => null,
      executorFactory: factoryFor(executor),
    );
    final result = await importer.importFile(
      sqlPath: sql.path,
      dbPath: livePath,
      closeDatabase: () async {},
      onProgress: (_) {},
    );
    expect(result.ok, isFalse);
    expect(result.error, isNotNull);
    expect(result.error, contains('导入失败'));
    expect(result.needsReload, isFalse);
    expect(await File(livePath).readAsString(), 'OLDDB');
    expect(await File('$livePath.bak').exists(), isFalse);
    expect(await File('$livePath.importing').exists(), isFalse);
    // The failing batch was attempted exactly twice (original + one retry).
    expect(executor.batchCalls, 2);
  });

  test('byte limit: flush triggered by bytes, not by count', () async {
    final executor = _FakeExecutor();
    // Each statement is ~200 bytes of padding; with a 512-byte limit
    // and a huge count limit, flushing must happen roughly every
    // 3 statements purely on bytes.
    final pad = 'x' * 160;
    final body = StringBuffer(_schemaSql());
    for (var i = 0; i < 10; i++) {
      body.writeln("INSERT INTO videos VALUES('v$i','$pad','p');");
    }
    body.writeln("INSERT INTO video_play_urls VALUES('v0','http://x/1.m3u8');");
    final sql = await writeSql('big-stmt.sql', body.toString());
    final livePath = '${tempDir.path}/live.db';
    await File(livePath).writeAsString('OLDDB');
    final importer = ActressSqlImporter(
      versionGate: (_) async => null,
      batchSize: 1000,
      batchByteLimit: 512,
      executorFactory: factoryFor(executor),
    );
    final result = await importer.importFile(
      sqlPath: sql.path,
      dbPath: livePath,
      closeDatabase: () async {},
      onProgress: (_) {},
    );
    expect(result.ok, isTrue, reason: result.error);
    // 11 INSERTs total. Count-only flushing would be a single batch;
    // byte flushing must split into at least 3 batches, none of them
    // holding all 10 padded video rows at once.
    expect(executor.batches.length, greaterThanOrEqualTo(3));
    final videoBatches = executor.batches
        .where((b) => b.any((s) => s.contains('INTO videos')))
        .toList();
    expect(videoBatches.length, greaterThanOrEqualTo(3));
    expect(
      videoBatches.every((b) => b.length < 10),
      isTrue,
    );
  });
}
