// Big-file test (2026-11-27 sql-import-crash): desktop real executor
// backed by system libsqlite3 via dart:ffi, driving the production
// ActressSqlImporter end to end on the real .sql / .sql.gz files.
// Fixtures are large local files not in the repo: when a fixture is
// missing the case skips itself (CI / other machines must stay green).
// Verifies counts against ground truth and asserts peak RSS < 500MB.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_sql_import.dart';

// ---- libsqlite3 bindings -------------------------------------------------
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _ExecNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ExecDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _PrepareNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _PrepareDart = int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ColCountNative = Int32 Function(Pointer<Void>);
typedef _ColCountDart = int Function(Pointer<Void>);
typedef _ColNameNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColNameDart = Pointer<Utf8> Function(Pointer<Void>, int);
typedef _ColTypeNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColTypeDart = int Function(Pointer<Void>, int);
typedef _ColIntNative = Int64 Function(Pointer<Void>, Int32);
typedef _ColIntDart = int Function(Pointer<Void>, int);
typedef _ColDoubleNative = Double Function(Pointer<Void>, Int32);
typedef _ColDoubleDart = double Function(Pointer<Void>, int);
typedef _ColTextNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Utf8> Function(Pointer<Void>, int);

class _Sqlite {
  _Sqlite._(DynamicLibrary lib)
      : open = lib.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open'),
        close = lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close'),
        exec = lib.lookupFunction<_ExecNative, _ExecDart>('sqlite3_exec'),
        errmsg = lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg'),
        prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>('sqlite3_prepare_v2'),
        step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step'),
        finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>('sqlite3_finalize'),
        columnCount = lib.lookupFunction<_ColCountNative, _ColCountDart>('sqlite3_column_count'),
        columnName = lib.lookupFunction<_ColNameNative, _ColNameDart>('sqlite3_column_name'),
        columnType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>('sqlite3_column_type'),
        columnInt = lib.lookupFunction<_ColIntNative, _ColIntDart>('sqlite3_column_int64'),
        columnDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>('sqlite3_column_double'),
        columnText = lib.lookupFunction<_ColTextNative, _ColTextDart>('sqlite3_column_text');

  static final _Sqlite instance =
      _Sqlite._(DynamicLibrary.open('/lib/x86_64-linux-gnu/libsqlite3.so.0'));

  final _OpenDart open;
  final _CloseDart close;
  final _ExecDart exec;
  final _ErrmsgDart errmsg;
  final _PrepareDart prepare;
  final _StepDart step;
  final _FinalizeDart finalize;
  final _ColCountDart columnCount;
  final _ColNameDart columnName;
  final _ColTypeDart columnType;
  final _ColIntDart columnInt;
  final _ColDoubleDart columnDouble;
  final _ColTextDart columnText;
}

class FfiImportExecutor implements SqlImportExecutor {
  FfiImportExecutor._(this._db);

  final Pointer<Void> _db;
  bool _closed = false;

  static Future<FfiImportExecutor> openDb(String path) async {
    final s = _Sqlite.instance;
    final pathPtr = path.toNativeUtf8();
    final dbPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.open(pathPtr, dbPtr);
      final db = dbPtr.value;
      if (rc != 0) {
        final msg = db == nullptr ? 'sqlite3_open failed rc=$rc' : s.errmsg(db).toDartString();
        if (db != nullptr) s.close(db);
        throw StateError(msg);
      }
      return FfiImportExecutor._(db);
    } finally {
      calloc.free(pathPtr);
      calloc.free(dbPtr);
    }
  }

  String _err() {
    try {
      return _Sqlite.instance.errmsg(_db).toDartString();
    } catch (_) {
      return 'unknown sqlite error';
    }
  }

  void _execRaw(String sql) {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    try {
      final rc = s.exec(_db, sqlPtr, nullptr, nullptr, nullptr);
      if (rc != 0) {
        throw StateError('${_err()} [sql head: ${sql.length > 100 ? sql.substring(0, 100) : sql}]');
      }
    } finally {
      calloc.free(sqlPtr);
    }
  }

  @override
  Future<void> execute(String sql) async => _execRaw(sql);

  @override
  Future<void> executeBatch(List<String> statements) async {
    // sqflite Batch semantics: whole batch in one transaction,
    // any failure rolls the whole batch back and throws.
    _execRaw('BEGIN');
    try {
      for (final st in statements) {
        _execRaw(st);
      }
    } catch (e) {
      try {
        _execRaw('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
    _execRaw('COMMIT');
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql) async {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    final stmtPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.prepare(_db, sqlPtr, -1, stmtPtr, nullptr);
      if (rc != 0) throw StateError(_err());
      final stmt = stmtPtr.value;
      final rows = <Map<String, Object?>>[];
      try {
        final n = s.columnCount(stmt);
        final names = <String>[
          for (var i = 0; i < n; i++) s.columnName(stmt, i).toDartString(),
        ];
        while (true) {
          final stepRc = s.step(stmt);
          if (stepRc == 101) break; // SQLITE_DONE
          if (stepRc != 100) throw StateError(_err()); // not ROW
          final row = <String, Object?>{};
          for (var i = 0; i < n; i++) {
            final type = s.columnType(stmt, i);
            Object? value;
            switch (type) {
              case 1: // INTEGER
                value = s.columnInt(stmt, i);
              case 2: // FLOAT
                value = s.columnDouble(stmt, i);
              case 3: // TEXT
                final p = s.columnText(stmt, i);
                value = p == nullptr ? null : p.toDartString();
              case 5: // NULL
                value = null;
              default: // BLOB etc: expose as text form
                final p = s.columnText(stmt, i);
                value = p == nullptr ? null : p.toDartString();
            }
            row[names[i]] = value;
          }
          rows.add(row);
        }
      } finally {
        s.finalize(stmt);
      }
      return rows;
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtPtr);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _Sqlite.instance.close(_db);
  }
}

// ---- repro driver ---------------------------------------------------------

Future<void> _runCase({
  required String label,
  required String sqlPath,
  required String dbPath,
  required int expectVideos,
  required int expectActresses,
  required int expectPlayUrls,
}) async {
  for (final p in [dbPath, '$dbPath.bak', '$dbPath.importing']) {
    final f = File(p);
    if (await f.exists()) await f.delete();
  }
  var peakRss = 0;
  var lastPrintStatements = -200000;
  final sw = Stopwatch()..start();
  void sample(ActressSqlImportProgress progress) {
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
    if (progress.statements - lastPrintStatements >= 200000) {
      lastPrintStatements = progress.statements;
      // ignore: avoid_print
      print('[$label] phase=${progress.phase} statements=${progress.statements} '
          'elapsed=${sw.elapsed.inSeconds}s rss=${(rss / 1048576).toStringAsFixed(1)}MB '
          'peak=${(peakRss / 1048576).toStringAsFixed(1)}MB');
    }
  }

  final importer = ActressSqlImporter(
    versionGate: (_) async => null,
    executorFactory: (tempPath) => FfiImportExecutor.openDb(tempPath),
  );
  final result = await importer.importFile(
    sqlPath: sqlPath,
    dbPath: dbPath,
    closeDatabase: () async {},
    onProgress: sample,
  );
  sw.stop();
  final rss = ProcessInfo.currentRss;
  if (rss > peakRss) peakRss = rss;
  final dbFile = File(dbPath);
  final dbSize = await dbFile.exists() ? await dbFile.length() : -1;
  // ignore: avoid_print
  print('[$label] RESULT ok=${result.ok} error=${result.error} '
      'videos=${result.videos} actresses=${result.actresses} playUrls=${result.playUrls} '
      'covers=${result.covers} avatars=${result.avatars} skipped=${result.skipped} '
      'warnings=${result.warnings} elapsed=${sw.elapsed.inSeconds}s '
      'peakRss=${(peakRss / 1048576).toStringAsFixed(1)}MB dbSize=$dbSize');
  expect(result.ok, isTrue, reason: 'import failed: ${result.error}');
  expect(result.videos, expectVideos);
  expect(result.actresses, expectActresses);
  expect(result.playUrls, expectPlayUrls);
  expect(
    peakRss,
    lessThan(500 * 1024 * 1024),
    reason: 'peak RSS ${(peakRss / 1048576).toStringAsFixed(1)}MB >= 500MB',
  );
}

void main() {
  const workDir = '/home/hatch/workspace/xiuxian_sql_import_crash_20261127/work';
  const magnetSql =
      '/home/hatch/workspace/magnet_sql_convert_20261127/out/磁力库.sql';
  const actressSqlGz =
      '/home/hatch/workspace/xiuxian_db_v4_20261127/out/actress-db-20261125-v3.sql.gz';

  test('bigfile magnet sql', () async {
    if (!await File(magnetSql).exists()) {
      markTestSkipped('fixture missing: $magnetSql');
      return;
    }
    await _runCase(
      label: 'magnet',
      sqlPath: magnetSql,
      dbPath: '$workDir/magnet_repro.db',
      expectVideos: 96364,
      expectActresses: 5611,
      expectPlayUrls: 162889,
    );
  }, timeout: const Timeout(Duration(minutes: 60)));

  test('bigfile actress sql.gz', () async {
    if (!await File(actressSqlGz).exists()) {
      markTestSkipped('fixture missing: $actressSqlGz');
      return;
    }
    // This machine's VM storage layer randomly raises SQLITE_IOERR
    // on the 675MB file (system sqlite3 CLI hits it too, random
    // offsets; not a code/data fault). Retry the whole run up to
    // 3 attempts when the failure is an I/O error; any other
    // failure is a real failure and is not retried away.
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await _runCase(
          label: 'actress attempt $attempt',
          sqlPath: actressSqlGz,
          dbPath: '$workDir/actress_repro.db',
          expectVideos: 449339,
          expectActresses: 32276,
          expectPlayUrls: 520629,
        );
        // ignore: avoid_print
        print('[actress] succeeded on attempt $attempt');
        break;
      } on TestFailure catch (e) {
        final isIoErr =
            e.message?.contains('disk I/O error') == true ||
            e.toString().contains('disk I/O error');
        // ignore: avoid_print
        print('[actress] attempt $attempt failed ioErr=$isIoErr');
        if (!isIoErr || attempt >= 3) rethrow;
      }
    }
  }, timeout: const Timeout(Duration(minutes: 180)));
}
