// Big-file repro/regression for the bundle importer (2026-11-28
// bundle-import-crash): desktop real executor backed by system
// libsqlite3 via dart:ffi, driving the production
// SiteLibraryBundleImporter end to end on the real three-segment
// file. Materializer/landers are FFI test doubles that mirror the
// production SQL (ATTACH + INSERT SELECT) and count the landed
// segment databases, so staging / verify / materialize all run the
// real code paths. Fixtures are large local files not in the repo:
// when a fixture is missing the case skips itself.
// Asserts per-segment ground-truth counts and peak RSS < 500MB.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/site_library_bundle.dart';

// ---- libsqlite3 bindings (same set as sql_import_bigfile_test) ----
typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
typedef _ExecNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ExecDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _PrepareNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Int32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
typedef _PrepareDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Utf8>>,
    );
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
      prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>(
        'sqlite3_prepare_v2',
      ),
      step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step'),
      finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
        'sqlite3_finalize',
      ),
      columnCount = lib.lookupFunction<_ColCountNative, _ColCountDart>(
        'sqlite3_column_count',
      ),
      columnName = lib.lookupFunction<_ColNameNative, _ColNameDart>(
        'sqlite3_column_name',
      ),
      columnType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>(
        'sqlite3_column_type',
      ),
      columnInt = lib.lookupFunction<_ColIntNative, _ColIntDart>(
        'sqlite3_column_int64',
      ),
      columnDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>(
        'sqlite3_column_double',
      ),
      columnText = lib.lookupFunction<_ColTextNative, _ColTextDart>(
        'sqlite3_column_text',
      );

  static final _Sqlite instance = _Sqlite._(
    DynamicLibrary.open('/lib/x86_64-linux-gnu/libsqlite3.so.0'),
  );

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

class FfiSiteExecutor implements SiteLibrarySqlExecutor {
  FfiSiteExecutor._(this._db);

  final Pointer<Void> _db;
  bool _closed = false;

  static Future<FfiSiteExecutor> openDb(String path) async {
    final s = _Sqlite.instance;
    final pathPtr = path.toNativeUtf8();
    final dbPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.open(pathPtr, dbPtr);
      final db = dbPtr.value;
      if (rc != 0) {
        final msg = db == nullptr
            ? 'sqlite3_open failed rc=$rc'
            : s.errmsg(db).toDartString();
        if (db != nullptr) s.close(db);
        throw StateError(msg);
      }
      return FfiSiteExecutor._(db);
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
        throw StateError(
          '${_err()} [sql head: ${sql.length > 100 ? sql.substring(0, 100) : sql}]',
        );
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

  Future<int> count(String table) async {
    final rows = await query('SELECT COUNT(*) AS c FROM "$table"');
    return (rows.first['c'] as num).toInt();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _Sqlite.instance.close(_db);
  }
}

/// FFI materializer: same SQL shape as SqfliteSegmentMaterializer
/// (ATTACH staging, rewrite CREATE names, INSERT SELECT, rebuild
/// indexes), driven through the FFI executor instead of sqflite.
class FfiSegmentMaterializer implements SiteLibrarySegmentMaterializer {
  const FfiSegmentMaterializer();

  @override
  Future<void> materialize({
    required String stagingPath,
    required String segment,
    required String targetPath,
  }) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    await target.parent.create(recursive: true);
    final db = await FfiSiteExecutor.openDb(targetPath);
    try {
      final escaped = stagingPath.replaceAll("'", "''");
      await db.execute("ATTACH DATABASE '$escaped' AS stage");
      try {
        final prefix = 'seg_${segment}_';
        final tables = await db.query(
          "SELECT name, sql FROM stage.sqlite_master "
          "WHERE type='table' AND name LIKE '$prefix%' "
          "AND name <> '${prefix}manifest'",
        );
        for (final row in tables) {
          final prefixed = '${row['name']}';
          final bare = prefixed.substring(prefix.length);
          final ddl = '${row['sql']}'.replaceFirst(prefixed, '"$bare"');
          await db.execute(ddl);
          await db.execute(
            'INSERT INTO "$bare" SELECT * FROM stage."$prefixed"',
          );
        }
        final indexes = await db.query(
          "SELECT name, sql, tbl_name FROM stage.sqlite_master "
          "WHERE type='index' AND sql IS NOT NULL "
          "AND tbl_name LIKE '$prefix%'",
        );
        for (final row in indexes) {
          final tbl = '${row['tbl_name']}';
          if (tbl == '${prefix}manifest') continue;
          final bare = tbl.substring(prefix.length);
          try {
            await db.execute('${row['sql']}'.replaceFirst(tbl, '"$bare"'));
          } catch (_) {
            // Index rebuild failure does not block landing (same
            // stance as production materializer).
          }
        }
      } finally {
        await db.execute('DETACH DATABASE stage');
      }
    } finally {
      await db.close();
    }
  }
}

// ---- repro driver ---------------------------------------------------------

const _workDir =
    '/home/hatch/workspace/xiuxian_bundle_import_crash_20261128/work';
const _bundleSql =
    '/home/hatch/workspace/xiuxian_station_sql_build_20261127/out/凡人修仙站点.sql';
const _bundleSqlGz =
    '/home/hatch/workspace/xiuxian_bundle_import_crash_20261128/work/fanren_station.sql.gz';

Future<void> _runCase({
  required String label,
  required String sqlPath,
  required String caseDir,
}) async {
  final dir = Directory(caseDir);
  if (await dir.exists()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final siteDbPath = '$caseDir/site_library.db';

  var peakRss = 0;
  var lastPhase = '';
  var lastPrintAt = DateTime.fromMillisecondsSinceEpoch(0);
  final sw = Stopwatch()..start();
  final sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
  });
  void note(String what) {
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
    // ignore: avoid_print
    print(
      '[$label] t=${sw.elapsed.inSeconds}s $what '
      'rss=${(rss / 1048576).toStringAsFixed(1)}MB '
      'peak=${(peakRss / 1048576).toStringAsFixed(1)}MB',
    );
  }

  Future<({bool ok, String? error, String? detail})> actressLander(
    String segmentDbPath,
  ) async {
    final db = await FfiSiteExecutor.openDb(segmentDbPath);
    try {
      final videos = await db.count('videos');
      final actresses = await db.count('actresses');
      final playUrls = await db.count('video_play_urls');
      note(
        'actress lander counts videos=$videos actresses=$actresses '
        'playUrls=$playUrls',
      );
      expect(videos, 449339);
      expect(actresses, 32276);
      expect(playUrls, 520629);
      return (ok: true, error: null, detail: '作品 $videos 部');
    } finally {
      await db.close();
    }
  }

  Future<({bool ok, String? error, String? detail})> magnetLander(
    String segmentDbPath,
  ) async {
    final db = await FfiSiteExecutor.openDb(segmentDbPath);
    try {
      final videos = await db.count('videos');
      final playUrls = await db.count('video_play_urls');
      final actresses = await db.count('actresses');
      note(
        'magnet lander counts videos=$videos actresses=$actresses '
        'playUrls=$playUrls',
      );
      expect(videos, 96364);
      expect(actresses, 5611);
      expect(playUrls, 162889);
      return (ok: true, error: null, detail: '新增作品 $videos 部');
    } finally {
      await db.close();
    }
  }

  Future<void> postProcess(String segment, String segmentDbPath) async {
    if (segment != 'actress' && segment != 'magnet') return;
    final db = await FfiSiteExecutor.openDb(segmentDbPath);
    try {
      for (final ddl in actressSegmentIndexDdl) {
        try {
          await db.execute(ddl);
        } catch (_) {}
      }
    } finally {
      await db.close();
    }
  }

  try {
    final importer = SiteLibraryBundleImporter(
      executorFactory: (tempPath) => FfiSiteExecutor.openDb(tempPath),
      materializer: const FfiSegmentMaterializer(),
      actressLander: actressLander,
      magnetLander: magnetLander,
      segmentDbPostProcess: postProcess,
    );
    final outcome = await importer.importBundle(
      sqlPath: sqlPath,
      siteDbPath: siteDbPath,
      workDir: caseDir,
      onProgress: (p) {
        final now = DateTime.now();
        if (p.phase != lastPhase ||
            now.difference(lastPrintAt).inSeconds >= 10) {
          lastPhase = p.phase;
          lastPrintAt = now;
          note(
            'phase=${p.phase} statements=${p.statements} '
            'bytes=${p.bytesRead}/${p.totalBytes}',
          );
        }
      },
    );
    note('importBundle returned');
    // ignore: avoid_print
    print(
      '[$label] RESULT ok=${outcome?.ok} error=${outcome?.error} '
      'stationCount=${outcome?.stationCount} '
      'segments=${outcome?.segmentResults.map((r) => '${r.segment}:${r.ok}:${r.detail ?? r.error}').toList()} '
      'elapsed=${sw.elapsed.inSeconds}s '
      'peakRss=${(peakRss / 1048576).toStringAsFixed(1)}MB',
    );
    expect(outcome, isNotNull, reason: 'not recognised as bundle file');
    expect(outcome!.ok, isTrue, reason: 'import failed: ${outcome.error}');
    expect(outcome.stationCount, 639);
    for (final r in outcome.segmentResults) {
      expect(r.ok, isTrue, reason: 'segment ${r.segment} failed: ${r.error}');
    }
    expect(
      peakRss,
      lessThan(500 * 1024 * 1024),
      reason:
          'peak RSS ${(peakRss / 1048576).toStringAsFixed(1)}MB >= 500MB',
    );
  } finally {
    sampler.cancel();
    sw.stop();
  }
}

void main() {
  test('bigfile bundle sql (raw)', () async {
    if (!await File(_bundleSql).exists()) {
      markTestSkipped('fixture missing: $_bundleSql');
      return;
    }
    await _runCase(
      label: 'bundle-raw',
      sqlPath: _bundleSql,
      caseDir: '$_workDir/case_raw',
    );
  }, timeout: const Timeout(Duration(minutes: 120)));

  test('bigfile bundle sql.gz', () async {
    if (!await File(_bundleSqlGz).exists()) {
      markTestSkipped('fixture missing: $_bundleSqlGz');
      return;
    }
    await _runCase(
      label: 'bundle-gz',
      sqlPath: _bundleSqlGz,
      caseDir: '$_workDir/case_gz',
    );
  }, timeout: const Timeout(Duration(minutes: 120)));
}
