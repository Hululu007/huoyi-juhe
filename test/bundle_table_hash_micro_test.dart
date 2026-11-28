// Micro repro (2026-11-28 bundle-import-crash): drives the
// production computeSegmentTableSha256 over the real actress
// library's biggest tables (videos 449,339 rows / video_play_urls
// 520,629 rows) through the desktop FFI executor and samples RSS.
// This is the exact function the bundle verifier uses per segment
// table. Fixture missing -> skip.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/site_library_bundle.dart';

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

class _FfiExecutor implements SiteLibrarySqlExecutor {
  _FfiExecutor._(this._db);

  final Pointer<Void> _db;
  bool _closed = false;

  static Future<_FfiExecutor> openDb(String path) async {
    final s = _Sqlite.instance;
    final pathPtr = path.toNativeUtf8();
    final dbPtr = calloc<Pointer<Void>>();
    try {
      final rc = s.open(pathPtr, dbPtr);
      final db = dbPtr.value;
      if (rc != 0) {
        if (db != nullptr) s.close(db);
        throw StateError('sqlite3_open failed rc=$rc');
      }
      return _FfiExecutor._(db);
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

  @override
  Future<void> execute(String sql) async {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    try {
      final rc = s.exec(_db, sqlPtr, nullptr, nullptr, nullptr);
      if (rc != 0) throw StateError(_err());
    } finally {
      calloc.free(sqlPtr);
    }
  }

  @override
  Future<void> executeBatch(List<String> statements) async {
    await execute('BEGIN');
    try {
      for (final st in statements) {
        await execute(st);
      }
    } catch (e) {
      try {
        await execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
    await execute('COMMIT');
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
          if (stepRc == 101) break;
          if (stepRc != 100) throw StateError(_err());
          final row = <String, Object?>{};
          for (var i = 0; i < n; i++) {
            final type = s.columnType(stmt, i);
            Object? value;
            switch (type) {
              case 1:
                value = s.columnInt(stmt, i);
              case 2:
                value = s.columnDouble(stmt, i);
              case 3:
                final p = s.columnText(stmt, i);
                value = p == nullptr ? null : p.toDartString();
              case 5:
                value = null;
              default:
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

const _dbPath =
    '/home/hatch/workspace/xiuxian_db_v4_20261127/out/女优库.db';

Future<void> _hashTable(String table, String goldenHash) async {
  final executor = await _FfiExecutor.openDb(_dbPath);
  var peak = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
  });
  final sw = Stopwatch()..start();
  try {
    final hash = await computeSegmentTableSha256(executor, table);
    final rss = ProcessInfo.currentRss;
    if (rss > peak) peak = rss;
    // ignore: avoid_print
    print(
      '[hash $table] hash=$hash elapsed=${sw.elapsed.inSeconds}s '
      'peakRss=${(peak / 1048576).toStringAsFixed(1)}MB',
    );
    // Golden hashes were produced by the OLD whole-table
    // implementation (2026-11-28, pre-fix run): the streaming
    // rewrite must reproduce them byte-for-byte, and its peak
    // RSS must stay in phone territory (old peaks: videos
    // 1,889.9MB, video_play_urls 514.5MB).
    expect(hash, goldenHash);
    expect(
      peak,
      lessThan(500 * 1024 * 1024),
      reason: 'peak RSS ${(peak / 1048576).toStringAsFixed(1)}MB >= 500MB',
    );
  } finally {
    sampler.cancel();
    await executor.close();
  }
}

void main() {
  test('table hash videos (449,339 rows)', () async {
    if (!await File(_dbPath).exists()) {
      markTestSkipped('fixture missing: $_dbPath');
      return;
    }
    await _hashTable(
      'videos',
      'eff151b0585de783a7d8bb03fb8462aa2330425bd12c7c95df718a5622ad77c5',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('table hash video_play_urls (520,629 rows)', () async {
    if (!await File(_dbPath).exists()) {
      markTestSkipped('fixture missing: $_dbPath');
      return;
    }
    await _hashTable(
      'video_play_urls',
      '5220c9a8f461180b81a0d91e21ab60123c8db7147995ba0de61eee0f42ddea7b',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}
