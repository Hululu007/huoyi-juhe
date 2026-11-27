// 磁力分类库数据层测试（修仙版）：验 ActressMagnetLibraryStore
// 的并存合并/删库/动态分类数据口径与 MagnetDriveStateResolver
// 的三态合成，全部对真 SQLite 文件跑（ATTACH/事务/临时表都
// 是真语义，不是内存假模型）。
//
// 真库假件说明：本机 pub 缓存里没有 sqflite_common_ffi、
// pub.dev 不可达，装不上官方 ffi 工厂；这里用 dart:ffi 直
// 接绑系统 libsqlite3 实现 sqflite 的 Database/Transaction
// 接口（仅测试用，生产代码走 sqflite 本体）。实现只覆盖数
// 据层用到的口：execute/rawQuery/rawUpdate/query/insert/
// update/delete/batch/transaction/close，其余成员走
// noSuchMethod 抛 UnimplementedError。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'package:fqapp/actress/actress_db_import.dart';
import 'package:fqapp/actress/actress_magnet_library.dart';
import 'package:fqapp/actress/actress_magnet_state.dart';
import 'package:fqapp/actress/actress_sql_import.dart';
import 'package:fqapp/cloud_drive/cloud_115_offline.dart';

// ---------------------------------------------------------------------------
// libsqlite3 FFI 绑定（最小集）
// ---------------------------------------------------------------------------

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _OpenDart = int Function(Pointer<Utf8>, Pointer<Pointer<Void>>);
typedef _CloseNative = Int32 Function(Pointer<Void>);
typedef _CloseDart = int Function(Pointer<Void>);
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
typedef _BindTextNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _BindTextDart =
    int Function(Pointer<Void>, int, Pointer<Utf8>, int, Pointer<Void>);
typedef _BindIntNative = Int32 Function(Pointer<Void>, Int32, Int64);
typedef _BindIntDart = int Function(Pointer<Void>, int, int);
typedef _BindDoubleNative = Int32 Function(Pointer<Void>, Int32, Double);
typedef _BindDoubleDart = int Function(Pointer<Void>, int, double);
typedef _BindNullNative = Int32 Function(Pointer<Void>, Int32);
typedef _BindNullDart = int Function(Pointer<Void>, int);
typedef _BindBlobNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Int32, Pointer<Void>);
typedef _BindBlobDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);
typedef _StepNative = Int32 Function(Pointer<Void>);
typedef _StepDart = int Function(Pointer<Void>);
typedef _FinalizeNative = Int32 Function(Pointer<Void>);
typedef _FinalizeDart = int Function(Pointer<Void>);
typedef _ParamCountNative = Int32 Function(Pointer<Void>);
typedef _ParamCountDart = int Function(Pointer<Void>);
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
typedef _ColTextNative = Pointer<Uint8> Function(Pointer<Void>, Int32);
typedef _ColTextDart = Pointer<Uint8> Function(Pointer<Void>, int);
typedef _ColBlobNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _ColBlobDart = Pointer<Void> Function(Pointer<Void>, int);
typedef _ColBytesNative = Int32 Function(Pointer<Void>, Int32);
typedef _ColBytesDart = int Function(Pointer<Void>, int);
typedef _ErrmsgNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _ErrmsgDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _ChangesNative = Int32 Function(Pointer<Void>);
typedef _ChangesDart = int Function(Pointer<Void>);
typedef _LastRowidNative = Int64 Function(Pointer<Void>);
typedef _LastRowidDart = int Function(Pointer<Void>);

class _Sqlite {
  _Sqlite._() {
    final lib = DynamicLibrary.open('libsqlite3.so.0');
    open = lib.lookupFunction<_OpenNative, _OpenDart>('sqlite3_open');
    close = lib.lookupFunction<_CloseNative, _CloseDart>('sqlite3_close');
    prepare = lib.lookupFunction<_PrepareNative, _PrepareDart>(
      'sqlite3_prepare_v2',
    );
    bindText = lib.lookupFunction<_BindTextNative, _BindTextDart>(
      'sqlite3_bind_text',
    );
    bindInt = lib.lookupFunction<_BindIntNative, _BindIntDart>(
      'sqlite3_bind_int64',
    );
    bindDouble = lib.lookupFunction<_BindDoubleNative, _BindDoubleDart>(
      'sqlite3_bind_double',
    );
    bindNull = lib.lookupFunction<_BindNullNative, _BindNullDart>(
      'sqlite3_bind_null',
    );
    bindBlob = lib.lookupFunction<_BindBlobNative, _BindBlobDart>(
      'sqlite3_bind_blob',
    );
    step = lib.lookupFunction<_StepNative, _StepDart>('sqlite3_step');
    finalize = lib.lookupFunction<_FinalizeNative, _FinalizeDart>(
      'sqlite3_finalize',
    );
    paramCount = lib.lookupFunction<_ParamCountNative, _ParamCountDart>(
      'sqlite3_bind_parameter_count',
    );
    colCount = lib.lookupFunction<_ColCountNative, _ColCountDart>(
      'sqlite3_column_count',
    );
    colName = lib.lookupFunction<_ColNameNative, _ColNameDart>(
      'sqlite3_column_name',
    );
    colType = lib.lookupFunction<_ColTypeNative, _ColTypeDart>(
      'sqlite3_column_type',
    );
    colInt = lib.lookupFunction<_ColIntNative, _ColIntDart>(
      'sqlite3_column_int64',
    );
    colDouble = lib.lookupFunction<_ColDoubleNative, _ColDoubleDart>(
      'sqlite3_column_double',
    );
    colText = lib.lookupFunction<_ColTextNative, _ColTextDart>(
      'sqlite3_column_text',
    );
    colBlob = lib.lookupFunction<_ColBlobNative, _ColBlobDart>(
      'sqlite3_column_blob',
    );
    colBytes = lib.lookupFunction<_ColBytesNative, _ColBytesDart>(
      'sqlite3_column_bytes',
    );
    errmsg = lib.lookupFunction<_ErrmsgNative, _ErrmsgDart>('sqlite3_errmsg');
    changes = lib.lookupFunction<_ChangesNative, _ChangesDart>(
      'sqlite3_changes',
    );
    lastRowid = lib.lookupFunction<_LastRowidNative, _LastRowidDart>(
      'sqlite3_last_insert_rowid',
    );
  }

  static final instance = _Sqlite._();

  late final _OpenDart open;
  late final _CloseDart close;
  late final _PrepareDart prepare;
  late final _BindTextDart bindText;
  late final _BindIntDart bindInt;
  late final _BindDoubleDart bindDouble;
  late final _BindNullDart bindNull;
  late final _BindBlobDart bindBlob;
  late final _StepDart step;
  late final _FinalizeDart finalize;
  late final _ParamCountDart paramCount;
  late final _ColCountDart colCount;
  late final _ColNameDart colName;
  late final _ColTypeDart colType;
  late final _ColIntDart colInt;
  late final _ColDoubleDart colDouble;
  late final _ColTextDart colText;
  late final _ColBlobDart colBlob;
  late final _ColBytesDart colBytes;
  late final _ErrmsgDart errmsg;
  late final _ChangesDart changes;
  late final _LastRowidDart lastRowid;
}

const _sqliteRow = 100;
const _sqliteDone = 101;

/// 真 SQLite 文件上的 sqflite Database 假件（测试专用）。
class FfiDatabase implements Database, Transaction {
  FfiDatabase._(this._handle, this.path);

  final Pointer<Void> _handle;

  @override
  final String path;

  var _open = true;
  var _txnDepth = 0;

  static Future<FfiDatabase> open(String path) async {
    final s = _Sqlite.instance;
    final namePtr = path.toNativeUtf8();
    final out = calloc<Pointer<Void>>();
    try {
      final rc = s.open(namePtr, out);
      if (rc != 0) {
        throw StateError('sqlite3_open($path) 失败 rc=$rc');
      }
      return FfiDatabase._(out.value, path);
    } finally {
      calloc.free(namePtr);
      calloc.free(out);
    }
  }

  @override
  bool get isOpen => _open;

  String get _errorMessage => _Sqlite.instance.errmsg(_handle).toDartString();

  Pointer<Void> _prepare(String sql, List<Object?>? arguments) {
    final s = _Sqlite.instance;
    final sqlPtr = sql.toNativeUtf8();
    final stmtOut = calloc<Pointer<Void>>();
    try {
      final rc = s.prepare(_handle, sqlPtr, -1, stmtOut, nullptr);
      if (rc != 0) {
        throw StateError('SQL 失败：$_errorMessage ← $sql');
      }
      final stmt = stmtOut.value;
      final count = s.paramCount(stmt);
      final args = arguments ?? const [];
      if (args.length > count) {
        s.finalize(stmt);
        throw StateError('参数个数多于占位符：$sql');
      }
      for (var i = 0; i < args.length; i++) {
        _bind(stmt, i + 1, args[i]);
      }
      return stmt;
    } finally {
      calloc.free(sqlPtr);
      calloc.free(stmtOut);
    }
  }

  void _bind(Pointer<Void> stmt, int index, Object? value) {
    final s = _Sqlite.instance;
    if (value == null) {
      s.bindNull(stmt, index);
    } else if (value is int) {
      s.bindInt(stmt, index, value);
    } else if (value is bool) {
      s.bindInt(stmt, index, value ? 1 : 0);
    } else if (value is double) {
      s.bindDouble(stmt, index, value);
    } else if (value is Uint8List) {
      final ptr = calloc<Uint8>(value.isEmpty ? 1 : value.length);
      try {
        ptr.asTypedList(value.length).setAll(0, value);
        // SQLITE_STATIC（nullptr 析构）：step 在 free 前已跑完。
        s.bindBlob(stmt, index, ptr.cast<Void>(), value.length, nullptr);
      } finally {
        // blob 字节在 step 前不能释放：本假件 step 紧随其后且
        // 同步执行完才返回，释放放在 _run 里做不到，改为泄漏
        // 这一小块（测试进程短命，可接受）。
      }
    } else {
      final ptr = value.toString().toNativeUtf8();
      s.bindText(stmt, index, ptr, -1, nullptr);
      // SQLITE_STATIC：step 同步跑完后才释放（见 _run 的同步性）。
      _pendingFree.add(ptr);
    }
  }

  final _pendingFree = <Pointer<Utf8>>[];

  void _flushPendingFree() {
    for (final ptr in _pendingFree) {
      calloc.free(ptr);
    }
    _pendingFree.clear();
  }

  /// 同步跑完一条语句：查询回全部行，非查询回受影响行数。
  ({List<Map<String, Object?>> rows, int changes, int rowId}) _run(
    String sql,
    List<Object?>? arguments,
  ) {
    final s = _Sqlite.instance;
    final stmt = _prepare(sql, arguments);
    try {
      final rows = <Map<String, Object?>>[];
      while (true) {
        final rc = s.step(stmt);
        if (rc == _sqliteRow) {
          final row = <String, Object?>{};
          final n = s.colCount(stmt);
          for (var i = 0; i < n; i++) {
            row[s.colName(stmt, i).toDartString()] = _column(stmt, i);
          }
          rows.add(row);
        } else if (rc == _sqliteDone) {
          break;
        } else {
          throw StateError('SQL 失败：$_errorMessage ← $sql');
        }
      }
      return (
        rows: rows,
        changes: s.changes(_handle),
        rowId: s.lastRowid(_handle),
      );
    } finally {
      s.finalize(stmt);
      _flushPendingFree();
    }
  }

  Object? _column(Pointer<Void> stmt, int i) {
    final s = _Sqlite.instance;
    switch (s.colType(stmt, i)) {
      case 1:
        return s.colInt(stmt, i);
      case 2:
        return s.colDouble(stmt, i);
      case 3:
        final ptr = s.colText(stmt, i);
        if (ptr == nullptr) return '';
        return ptr.cast<Utf8>().toDartString(length: s.colBytes(stmt, i));
      case 4:
        final bytes = s.colBytes(stmt, i);
        final ptr = s.colBlob(stmt, i);
        if (ptr == nullptr || bytes == 0) return Uint8List(0);
        return Uint8List.fromList(ptr.cast<Uint8>().asTypedList(bytes));
      default:
        return null;
    }
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    _run(sql, arguments);
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async => _run(sql, arguments).rows;

  @override
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).changes;

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).changes;

  @override
  Future<int> rawInsert(String sql, [List<Object?>? arguments]) async =>
      _run(sql, arguments).rowId;

  String _conflict(ConflictAlgorithm? algorithm) => switch (algorithm) {
    ConflictAlgorithm.ignore => ' OR IGNORE',
    ConflictAlgorithm.replace => ' OR REPLACE',
    ConflictAlgorithm.rollback => ' OR ROLLBACK',
    ConflictAlgorithm.abort => ' OR ABORT',
    ConflictAlgorithm.fail => ' OR FAIL',
    null => '',
  };

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final columns = values.keys.toList();
    final sql =
        'INSERT${_conflict(conflictAlgorithm)} INTO $table '
        '(${columns.join(', ')}) VALUES (${List.filled(columns.length, '?').join(', ')})';
    return _run(sql, values.values.toList()).rowId;
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final sets = [for (final key in values.keys) '$key = ?'].join(', ');
    final sql =
        'UPDATE${_conflict(conflictAlgorithm)} $table SET $sets'
        '${where == null ? '' : ' WHERE $where'}';
    return _run(sql, [...values.values, ...?whereArgs]).changes;
  }

  @override
  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final sql = 'DELETE FROM $table${where == null ? '' : ' WHERE $where'}';
    return _run(sql, whereArgs).changes;
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    final buffer = StringBuffer(
      'SELECT ${distinct == true ? 'DISTINCT ' : ''}'
      '${columns == null || columns.isEmpty ? '*' : columns.join(', ')} '
      'FROM $table',
    );
    if (where != null) buffer.write(' WHERE $where');
    if (groupBy != null) buffer.write(' GROUP BY $groupBy');
    if (having != null) buffer.write(' HAVING $having');
    if (orderBy != null) buffer.write(' ORDER BY $orderBy');
    if (limit != null) buffer.write(' LIMIT $limit');
    if (offset != null) buffer.write(' OFFSET $offset');
    return _run(buffer.toString(), whereArgs).rows;
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) async {
    if (_txnDepth > 0) return action(this);
    await execute(exclusive == false ? 'BEGIN' : 'BEGIN EXCLUSIVE');
    _txnDepth++;
    try {
      final result = await action(this);
      await execute('COMMIT');
      return result;
    } catch (e) {
      try {
        await execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    } finally {
      _txnDepth--;
    }
  }

  @override
  Batch batch() => _FfiBatch(this);

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _Sqlite.instance.close(_handle);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('FfiDatabase 未实现：${invocation.memberName}');
}

class _FfiBatch implements Batch {
  _FfiBatch(this._db);

  final FfiDatabase _db;
  final _ops = <(String, List<Object?>?)>[];

  @override
  void execute(String sql, [List<Object?>? arguments]) {
    _ops.add((sql, arguments));
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async {
    final ops = List.of(_ops);
    _ops.clear();
    await _db.transaction((txn) async {
      for (final (sql, args) in ops) {
        await txn.execute(sql, args);
      }
    });
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('_FfiBatch 未实现：${invocation.memberName}');
}

// ---------------------------------------------------------------------------
// 夹具：标准结构建库与播种
// ---------------------------------------------------------------------------

const _standardDdl = <String>[
  'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
  'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
  'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
  'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
  'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
  'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
];

const _magnet1 = 'magnet:?xt=urn:btih:AAAA1111&dn=one';
const _magnet2 = 'magnet:?xt=urn:btih:BBBB2222&dn=two';
const _magnet3 = 'magnet:?xt=urn:btih:CCCC3333&dn=three';

late Directory _dir;
var _seq = 0;

Future<FfiDatabase> _newDb(String label, {bool standard = true}) async {
  final file = File(path.join(_dir.path, '${label}_${_seq++}.db'));
  if (await file.exists()) await file.delete();
  final db = await FfiDatabase.open(file.path);
  if (standard) {
    for (final ddl in _standardDdl) {
      await db.execute(ddl);
    }
  }
  return db;
}

Future<void> _addVideo(
  Database db,
  String vodId, {
  String title = '标题',
  String pic = 'https://img/x.jpg',
  String playFrom = 'whos',
  String typeName = '有码',
}) async {
  await db.insert('videos', {
      'vod_id': vodId,
      'title': title,
      'pic_url': pic,
      'm3u8_url': '',
      'vod_remarks': '备注$vodId',
      'vod_pubdate': '2024-01-01',
      'vod_area': '日本',
      'vod_year': '2024',
      'vod_content': '简介$vodId',
      'vod_play_from': playFrom,
      'vod_play_url': '',
      'type_name': typeName,
      'created_at': '2024-01-01 00:00:00',
    });
}

Future<void> _addUrl(
  Database db,
  String vodId,
  String url, {
  String from = 'whos',
}) async {
  await db.insert('video_play_urls', {
    'vod_id': vodId,
    'play_url': url,
    'play_from': from,
  });
}

Future<void> _addActress(Database db, String cateId, String name) async {
  await db.insert('actresses', {
    'cate_id': cateId,
    'name': name,
    'avatar': '',
    'created_at': '2024-01-01',
    'sex': '女',
    'roster_id': '',
    'claimed': 0,
  });
}

Future<Set<String>> _videoIds(Database db) async => {
  for (final row in await db.rawQuery('SELECT vod_id FROM videos'))
    row['vod_id'].toString(),
};

Future<Set<String>> _urlsOf(Database db, String vodId) async => {
  for (final row in await db.rawQuery(
    'SELECT play_url FROM video_play_urls WHERE vod_id = ?',
    [vodId],
  ))
    row['play_url'].toString(),
};

Future<int> _count(Database db, String sql, [List<Object?>? args]) async {
  final rows = await db.rawQuery(sql, args);
  return (rows.first['c'] as num).toInt();
}

const _store = ActressMagnetLibraryStore();

void main() {
  setUpAll(() async {
    _dir = await Directory.systemTemp.createTemp('magnet_library_test_');
  });

  tearDownAll(() async {
    try {
      await _dir.delete(recursive: true);
    } catch (_) {}
  });

  group('磁力判定与库名', () {
    test('地址尺与标记尺任一命中都算磁力线路', () {
      expect(
        const ActressPlayLine(url: 'https://x', from: 'magnet').isMagnet,
        isTrue,
      );
      expect(
        const ActressPlayLine(url: _magnet1, from: 'whos').isMagnet,
        isTrue,
      );
      expect(
        const ActressPlayLine(url: 'https://x', from: 'whos').isMagnet,
        isFalse,
      );
      expect(actressIsMagnetPlayUrl(' MAGNET:?xt=1 '), isTrue);
      expect(magnetLibraryNameOfFile('/a/b/4K原版.sql'), '4K原版');
      expect(magnetLibraryNameOfFile('国产原创.sql.gz'), '国产原创');
      expect(magnetLibraryNameOfFile('VR视频区.sql'), 'VR视频区');
    });
  });

  group('并存合并（真 sqlite）', () {
    test('已有作品字段逐字不动、只加线路；新作品整行新增', () async {
      final target = await _newDb('target');
      await _addVideo(
        target,
        'ipz-999',
        title: '原标题',
        pic: 'https://img/orig.jpg',
      );
      await _addUrl(target, 'ipz-999', 'https://cdn/orig.m3u8');
      await target.insert('video_category', {
        'vod_id': 'ipz-999',
        'main_category': '有码',
      });
      await _addActress(target, 'a-old', '老演员');
      await target.insert('video_actress', {
        'vod_id': 'ipz-999',
        'cate_id': 'a-old',
      });
      final before = (await target.rawQuery(
        'SELECT * FROM videos WHERE vod_id = ?',
        ['ipz-999'],
      )).single;

      final staging = await _newDb('staging');
      await _addVideo(
        staging,
        'ipz-999',
        title: '被改过的标题',
        pic: 'https://img/new.jpg',
      );
      await _addUrl(staging, 'ipz-999', _magnet1, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'ipz-999',
        'main_category': '4K原版',
      });
      await _addActress(staging, 'a-new', '新演员');
      await staging.insert('video_actress', {
        'vod_id': 'ipz-999',
        'cate_id': 'a-new',
      });
      await _addVideo(staging, 'new-001', title: '全新作品');
      await _addUrl(staging, 'new-001', _magnet2, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'new-001',
        'main_category': '4K原版',
      });
      await staging.close();

      final outcome = await _store.mergeStaging(
        target,
        staging.path,
        sourceName: '磁力库.sql',
      );
      expect(outcome.ok, isTrue);
      expect(outcome.categories, ['4K原版']);
      expect(outcome.totalWorks, 2);
      expect(outcome.addedWorks, 1, reason: '只有 new-001 是新增');
      expect(outcome.addedPlayUrls, 2);
      expect(outcome.replaced, isFalse);

      final after = (await target.rawQuery(
        'SELECT * FROM videos WHERE vod_id = ?',
        ['ipz-999'],
      )).single;
      expect(after, before, reason: '已有作品整行逐字不动');
      expect(await _urlsOf(target, 'ipz-999'), {
        'https://cdn/orig.m3u8',
        _magnet1,
      });
      expect(await _videoIds(target), {'ipz-999', 'new-001'});
      // 演员只新增不覆盖。
      expect(
        await _count(target, 'SELECT COUNT(*) AS c FROM actresses'),
        2,
      );
      final libraries = await _store.listLibraries(target);
      expect(libraries, hasLength(1));
      expect(libraries.single.category, '4K原版');
      expect(libraries.single.works, 2);
      expect(libraries.single.workCount, 2);
      await target.close();
    });

    test('非磁力文件整单拒、目标库一字不动', () async {
      final target = await _newDb('target');
      await _addVideo(target, 'ipz-999');
      await _addUrl(target, 'ipz-999', 'https://cdn/orig.m3u8');

      final staging = await _newDb('staging');
      await _addVideo(staging, 'abc-001');
      await _addUrl(staging, 'abc-001', 'https://cdn/other.m3u8');
      await staging.close();

      expect(
        await ActressMagnetLibraryStore.stagingIsMagnetLibrary(
          staging.path,
          openReadOnly: (p) => FfiDatabase.open(p),
        ),
        isFalse,
      );
      final outcome = await _store.mergeStaging(
        target,
        staging.path,
        sourceName: '普通库.sql',
      );
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('没有磁力链接'));
      expect(await _videoIds(target), {'ipz-999'});
      expect(await _store.listLibraries(target), isEmpty);
      await target.close();
    });

    test('标记尺兜底：地址不是 magnet: 但 play_from=magnet 也认', () async {
      final staging = await _newDb('staging');
      await _addVideo(staging, 'abc-001');
      await _addUrl(
        staging,
        'abc-001',
        'https://cdn/weird',
        from: 'magnet',
      );
      await staging.close();
      expect(
        await ActressMagnetLibraryStore.stagingIsMagnetLibrary(
          staging.path,
          openReadOnly: (p) => FfiDatabase.open(p),
        ),
        isTrue,
      );
    });

    test('同名分类重导＝更新：不叠加、计数稳定', () async {
      final target = await _newDb('target');
      final staging1 = await _newDb('staging');
      await _addVideo(staging1, 'aaa-001');
      await _addUrl(staging1, 'aaa-001', _magnet1, from: 'magnet');
      await staging1.insert('video_category', {
        'vod_id': 'aaa-001',
        'main_category': '4K原版',
      });
      await staging1.close();
      final first = await _store.mergeStaging(
        target,
        staging1.path,
        sourceName: '合集.sql',
      );
      expect(first.ok, isTrue);
      expect(first.replaced, isFalse);

      final staging2 = await _newDb('staging');
      await _addVideo(staging2, 'aaa-001');
      await _addUrl(staging2, 'aaa-001', _magnet2, from: 'magnet');
      await _addVideo(staging2, 'bbb-002');
      await _addUrl(staging2, 'bbb-002', _magnet3, from: 'magnet');
      await staging2.insert('video_category', {
        'vod_id': 'aaa-001',
        'main_category': '4K原版',
      });
      await staging2.insert('video_category', {
        'vod_id': 'bbb-002',
        'main_category': '4K原版',
      });
      await staging2.close();
      final again = await _store.mergeStaging(
        target,
        staging2.path,
        sourceName: '合集.sql',
      );
      expect(again.ok, isTrue);
      expect(again.replaced, isTrue);
      expect(again.addedWorks, 2, reason: '旧片先摘再并，两部都算本轮新增');
      expect(await _videoIds(target), {'aaa-001', 'bbb-002'});
      expect(await _urlsOf(target, 'aaa-001'), {_magnet2});
      expect(await _store.listLibraries(target), hasLength(1));
      await target.close();
    });

    test('合集多分类逐片登记、磁力分类并集计数去重', () async {
      final target = await _newDb('target');
      // 主库已有作品，分类在主库是「有码」，磁力合集里归「国产原创」。
      await _addVideo(target, 'gana-111');
      await _addUrl(target, 'gana-111', 'https://cdn/g.m3u8');
      await target.insert('video_category', {
        'vod_id': 'gana-111',
        'main_category': '有码',
      });

      final staging = await _newDb('staging');
      await _addVideo(staging, 'ipz-999');
      await _addUrl(staging, 'ipz-999', _magnet1, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'ipz-999',
        'main_category': '4K原版',
      });
      await _addVideo(staging, 'gana-111');
      await _addUrl(staging, 'gana-111', _magnet2, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'gana-111',
        'main_category': '国产原创',
      });
      await staging.close();

      final outcome = await _store.mergeStaging(
        target,
        staging.path,
        sourceName: '合集.sql',
      );
      expect(outcome.ok, isTrue);
      expect(outcome.categories, containsAll(['4K原版', '国产原创']));
      expect(outcome.addedWorks, 1);
      expect(await _store.magnetCategories(target), ['4K原版', '国产原创']);

      // 并集口径（分类栏计数）：主分类 ∪ 来源登记，同番号只数一次。
      final unionCount = await _count(
        target,
        'SELECT COUNT(DISTINCT vod_id) AS c FROM ('
        'SELECT vod_id FROM video_category WHERE main_category = ? '
        'UNION SELECT mlw.vod_id FROM magnet_library_works mlw '
        'JOIN magnet_libraries ml ON ml.id = mlw.library_id '
        'WHERE ml.category = ?)',
        ['国产原创', '国产原创'],
      );
      expect(unionCount, 1, reason: 'gana-111 只在登记侧命中，并集计 1');

      // 分批查磁力地址：只回磁力行。
      final urls = await _store.magnetUrlsForWorks(target, [
        'ipz-999',
        'gana-111',
      ]);
      expect(urls['ipz-999'], [_magnet1]);
      expect(urls['gana-111'], [_magnet2]);

      // 逐片可删：删「4K原版」片，国产原创片与 gana-111 不动。
      final libraries = await _store.listLibraries(target);
      final fourK = libraries.singleWhere((r) => r.category == '4K原版');
      await _store.removeLibrary(target, fourK.id);
      expect(await _videoIds(target), {'gana-111'});
      expect(await _store.magnetCategories(target), ['国产原创']);
      await target.close();
    });

    test('空目标库合并：was_existing 全 0 起步，删库全清', () async {
      final target = await _newDb('target');
      final staging = await _newDb('staging');
      await _addVideo(staging, 'aaa-001');
      await _addUrl(staging, 'aaa-001', _magnet1, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'aaa-001',
        'main_category': '4K原版',
      });
      await staging.close();

      final outcome = await _store.mergeStaging(
        target,
        staging.path,
        sourceName: '合集.sql',
      );
      expect(outcome.ok, isTrue);
      expect(outcome.addedWorks, 1);
      expect(outcome.totalWorks, 1);
      final removed = await _store.removeLibrary(target, outcome.libraryId);
      expect(removed.removedWorks, 1);
      expect(await _videoIds(target), isEmpty);
      await target.close();
    });
  });

  group('删库语义（真 sqlite）', () {
    test('独有整删、共享只摘线路与分类行、演员按规矩', () async {
      final target = await _newDb('target');
      // S1：共享作品，有自己的分类行与演员。
      await _addVideo(target, 's1-001');
      await _addUrl(target, 's1-001', 'https://cdn/s1.m3u8');
      await target.insert('video_category', {
        'vod_id': 's1-001',
        'main_category': '有码',
      });
      // S2：共享作品，没有分类行。
      await _addVideo(target, 's2-002');
      await _addUrl(target, 's2-002', 'https://cdn/s2.m3u8');
      await _addActress(target, 'a-old', '老演员');
      await target.insert('video_actress', {
        'vod_id': 's1-001',
        'cate_id': 'a-old',
      });

      final staging = await _newDb('staging');
      await _addVideo(staging, 's1-001');
      await _addUrl(staging, 's1-001', _magnet1, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 's1-001',
        'main_category': '4K原版',
      });
      await _addVideo(staging, 's2-002');
      await _addUrl(staging, 's2-002', _magnet2, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 's2-002',
        'main_category': '4K原版',
      });
      await _addVideo(staging, 'n-003');
      await _addUrl(staging, 'n-003', _magnet3, from: 'magnet');
      await staging.insert('video_category', {
        'vod_id': 'n-003',
        'main_category': '4K原版',
      });
      await _addActress(staging, 'a-old', '老演员');
      await _addActress(staging, 'a-new', '新演员');
      await staging.insert('video_actress', {
        'vod_id': 'n-003',
        'cate_id': 'a-new',
      });
      await staging.close();

      final outcome = await _store.mergeStaging(
        target,
        staging.path,
        sourceName: '合集.sql',
      );
      expect(outcome.ok, isTrue);
      final removed = await _store.removeLibrary(target, outcome.libraryId);
      expect(removed.removedWorks, 1, reason: '只有 n-003 是独有作品');

      expect(await _videoIds(target), {'s1-001', 's2-002'});
      expect(await _urlsOf(target, 's1-001'), {'https://cdn/s1.m3u8'});
      expect(await _urlsOf(target, 's2-002'), {'https://cdn/s2.m3u8'});
      // S1 原有分类行留；S2 吃进的分类行被摘。
      final s1Category = await target.rawQuery(
        'SELECT main_category FROM video_category WHERE vod_id = ?',
        ['s1-001'],
      );
      expect(s1Category.single['main_category'], '有码');
      expect(
        await _count(
          target,
          'SELECT COUNT(*) AS c FROM video_category WHERE vod_id = ?',
          ['s2-002'],
        ),
        0,
      );
      // 演员：新演员随独有作品删，老演员留。
      final actresses = {
        for (final row in await target.rawQuery('SELECT cate_id FROM actresses'))
          row['cate_id'].toString(),
      };
      expect(actresses, {'a-old'});
      expect(await _store.listLibraries(target), isEmpty);
      expect(await _store.magnetCategories(target), isEmpty);
      await target.close();
    });

    test('两库共享同一作品：删一库作品不丢、只摘它贡献的线路', () async {
      final target = await _newDb('target');
      final staging1 = await _newDb('staging');
      await _addVideo(staging1, 'x-001');
      await _addUrl(staging1, 'x-001', _magnet1, from: 'magnet');
      await _addUrl(staging1, 'x-001', _magnet2, from: 'magnet');
      await staging1.insert('video_category', {
        'vod_id': 'x-001',
        'main_category': '甲类',
      });
      await staging1.close();
      final first = await _store.mergeStaging(
        target,
        staging1.path,
        sourceName: '甲.sql',
      );

      final staging2 = await _newDb('staging');
      await _addVideo(staging2, 'x-001');
      await _addUrl(staging2, 'x-001', _magnet2, from: 'magnet');
      await _addUrl(staging2, 'x-001', _magnet3, from: 'magnet');
      await staging2.insert('video_category', {
        'vod_id': 'x-001',
        'main_category': '乙类',
      });
      await staging2.close();
      await _store.mergeStaging(target, staging2.path, sourceName: '乙.sql');

      await _store.removeLibrary(target, first.libraryId);
      expect(await _videoIds(target), {'x-001'});
      expect(await _urlsOf(target, 'x-001'), {_magnet2, _magnet3});
      await target.close();
    });
  });

  group('buildMagnetStagingDb', () {
    test('.sql 走导入器落 staging、.db 走验法复制、后缀不对直接拒', () async {
      // .sql 路（注入用 FFI 假件执行器的导入器）。
      final sqlFile = File(path.join(_dir.path, '合集_${_seq++}.sql'));
      await sqlFile.writeAsString('''
CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT);
CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER);
CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id));
CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url));
CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT);
INSERT INTO videos VALUES ('aaa-001', '标题', 'https://img/a.jpg', '', '', '2024-01-01', '', '2024', '', 'magnet', '', '有码', '');
INSERT INTO video_play_urls VALUES ('aaa-001', '$_magnet1', 'magnet');
INSERT INTO video_category VALUES ('aaa-001', '4K原版');
''');
      // 组装接缝（20261127+3）：激活批给共享导入器缺省加了女优库
      // 版本门；本件测的是磁力 staging 落盘机制，磁力库不带女优库
      // 版本字段，注入导入器时把门放行（与生产 buildMagnetStagingDb
      // 缺省口径一致），断言不动。版本门本身由激活批套件专测。
      final importer = ActressSqlImporter(
        executorFactory: (tempPath) async =>
            SqfliteImportExecutor(await FfiDatabase.open(tempPath)),
        versionGate: (_) async => null,
      );
      final stagingPath = path.join(_dir.path, 'staging_${_seq++}.db');
      final outcome = await buildMagnetStagingDb(
        sqlFile.path,
        stagingPath: stagingPath,
        importer: importer,
      );
      expect(outcome.ok, isTrue, reason: outcome.error ?? '');
      expect(
        await ActressMagnetLibraryStore.stagingIsMagnetLibrary(
          stagingPath,
          openReadOnly: (p) => FfiDatabase.open(p),
        ),
        isTrue,
      );

      // .db 路：真库文件复制为 staging。
      final sourceDb = await _newDb('sourcedb');
      await _addVideo(sourceDb, 'bbb-002');
      await _addUrl(sourceDb, 'bbb-002', _magnet2, from: 'magnet');
      await sourceDb.close();
      final dbStagingPath = path.join(_dir.path, 'staging_${_seq++}.db');
      final dbOutcome = await buildMagnetStagingDb(
        sourceDb.path,
        stagingPath: dbStagingPath,
        // 注入与 validateActressDbFile 同口径的验法（文件头＋
        // videos 作品数>0），走本文件的 FFI 真库——缺省实现走
        // sqflite 工厂，测试环境没有。
        dbValidator: (dbPath) async {
          final file = File(dbPath);
          if (!await file.exists() || await file.length() == 0) {
            return const ActressDbValidation(
              ok: false,
              error: '选中的文件读不到',
            );
          }
          final head = await file.openRead(0, 16).first;
          if (!String.fromCharCodes(head).startsWith('SQLite format 3')) {
            return const ActressDbValidation(
              ok: false,
              error: '这个文件不是数据库文件',
            );
          }
          final probe = await FfiDatabase.open(dbPath);
          try {
            final works = await _count(
              probe,
              'SELECT COUNT(*) AS c FROM videos',
            );
            return ActressDbValidation(
              ok: works > 0,
              works: works,
              error: works > 0 ? null : '这个数据库里没有作品，已取消导入',
            );
          } finally {
            await probe.close();
          }
        },
      );
      expect(dbOutcome.ok, isTrue, reason: dbOutcome.error ?? '');
      expect(await File(dbStagingPath).exists(), isTrue);

      // 后缀不对。
      final bad = await buildMagnetStagingDb(
        path.join(_dir.path, 'x.txt'),
        stagingPath: path.join(_dir.path, 'staging_bad.db'),
      );
      expect(bad.ok, isFalse);
      expect(bad.error, contains('只认'));
    });
  });

  group('三态合成', () {
    Pan115OfflineTask task({
      String infoHash = '',
      String name = '',
      double percent = 0,
      bool done = false,
    }) => Pan115OfflineTask(
      infoHash: infoHash,
      name: name,
      percent: percent,
      done: done,
    );

    test('任务命中番号：完成算网盘可播、在跑算离线中', () {
      final resolver = MagnetDriveStateResolver(
        listTasks: () async => const [],
        submittedHashes: () async => const {},
        confirmInDrive: (_) async => false,
      );
      final doneTask = task(name: 'IPZ-999.mp4', percent: 1, done: true);
      expect(
        resolver.stateFromSnapshot(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
          submitted: const {},
          tasks: [doneTask],
        ),
        MagnetDriveState.drivePlayable,
      );
      final runningTask = task(name: 'IPZ-999.mp4', percent: 0.4);
      expect(
        resolver.stateFromSnapshot(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
          submitted: const {},
          tasks: [runningTask],
        ),
        MagnetDriveState.offlineRunning,
      );
    });

    test('没任务但哈希在已提交记录里算离线中，其余未下载', () {
      final resolver = MagnetDriveStateResolver(
        listTasks: () async => const [],
        submittedHashes: () async => const {},
        confirmInDrive: (_) async => false,
      );
      expect(
        resolver.stateFromSnapshot(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
          submitted: const {'aaaa1111'},
          tasks: const [],
        ),
        MagnetDriveState.offlineRunning,
      );
      expect(
        resolver.stateFromSnapshot(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
          submitted: const {},
          tasks: const [],
        ),
        MagnetDriveState.notDownloaded,
      );
    });

    test('无番号作品靠 infohash 认任务（任务名里没番号）', () {
      final noCodeTask = task(
        infoHash: 'AAAA1111',
        name: '某主播 2024 直播回放.mp4',
        percent: 0.7,
      );
      expect(pan115TaskMatchesMagnets(noCodeTask, const [_magnet1]), isTrue);
      expect(pan115TaskMatchesMagnets(noCodeTask, const [_magnet2]), isFalse);
      final resolver = MagnetDriveStateResolver(
        listTasks: () async => [noCodeTask],
        submittedHashes: () async => const {},
        confirmInDrive: (_) async => false,
      );
      expect(
        resolver.stateFromSnapshot(
          code: 'magnet-aaaa1111',
          magnetUrls: const [_magnet1],
          submitted: const {},
          tasks: [noCodeTask],
        ),
        MagnetDriveState.offlineRunning,
      );
    });

    test('快照合成四分支（注入三口）', () async {
      final resolver = MagnetDriveStateResolver(
        listTasks: () async => [
          task(name: 'IPZ-999.mp4', percent: 1, done: true),
          task(name: 'ABC-001.mp4', percent: 0.5),
        ],
        submittedHashes: () async => {'cccc3333'},
        confirmInDrive: (_) async => false,
      );
      final states = await resolver.snapshotForWorks(const [
        MagnetWorkRef(vodId: 'ipz-999', code: 'IPZ-999', magnetUrls: [_magnet1]),
        MagnetWorkRef(vodId: 'abc-001', code: 'ABC-001', magnetUrls: [_magnet2]),
        MagnetWorkRef(vodId: 'zzz-003', code: 'ZZZ-003', magnetUrls: [_magnet3]),
        MagnetWorkRef(
          vodId: 'none-004',
          code: 'NONE-004',
          magnetUrls: ['magnet:?xt=urn:btih:DDDD4444'],
        ),
      ]);
      expect(states['ipz-999'], MagnetDriveState.drivePlayable);
      expect(states['abc-001'], MagnetDriveState.offlineRunning);
      expect(
        states['zzz-003'],
        MagnetDriveState.offlineRunning,
        reason: '哈希在已提交记录里',
      );
      expect(states['none-004'], MagnetDriveState.notDownloaded);
    });

    test('resolveForWork：网盘里真有文件才升到网盘可播', () async {
      final inDrive = MagnetDriveStateResolver(
        listTasks: () async => const [],
        submittedHashes: () async => const {},
        confirmInDrive: (_) async => true,
      );
      expect(
        await inDrive.resolveForWork(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
        ),
        MagnetDriveState.drivePlayable,
      );
      final notInDrive = MagnetDriveStateResolver(
        listTasks: () async => const [],
        submittedHashes: () async => const {},
        confirmInDrive: (_) async => false,
      );
      expect(
        await notInDrive.resolveForWork(
          code: 'IPZ-999',
          magnetUrls: const [_magnet1],
        ),
        MagnetDriveState.notDownloaded,
      );
      expect(MagnetDriveState.drivePlayable.label, '网盘可播');
      expect(MagnetDriveState.offlineRunning.label, '离线中');
      expect(MagnetDriveState.notDownloaded.label, '未下载');
    });
  });
}
