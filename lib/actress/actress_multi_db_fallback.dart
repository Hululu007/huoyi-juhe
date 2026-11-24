import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart';
import 'actress_db_mirror.dart';
import 'actress_film_library.dart';
import 'actress_generic_db.dart';
import 'actress_json_fallback.dart';
import 'actress_mytv_bind.dart';
import 'actress_models.dart';
import 'video_db_normalize.dart';

/// 三库合并内置兜底（2026-11-21 用户令「这三个合并内置兜底」）：
/// 主库（MYTV/db 里绑定的女优库，严格结构）+ MYTV/db 与补充目录里
/// 其它所有 .db（lsp_videos、yellow 大 … 通用结构）合成**一个**兜底
/// 来源，对外还是 [FilmDbFallbackProvider] 那一个接口：
///
/// - 名册（在线女优名册 / 主库 persons）里点一个人 → 先查主库，
///   再把每个外来库按人名查出来的作品并进来（去重），作品列表里
///   就有封面和播放地址了；
/// - 按番号搜/播 → 同样先主库、再各外来库按番号查（连字符/下划线
///   差异都能对上）。
///
/// 库文件一律只读打开、只读不写；单个库打不开/结构认不出就跳过，
/// 不影响其它库和原有 json/m3u 兜底。连接按「路径+修改时间+大小」
/// 缓存，最多同时留 [_maxOpen] 个，避免大库一起开着把手机拖死。
class MultiDbFilmFallback implements FilmDbFallbackProvider {
  MultiDbFilmFallback({
    required this.database,
    FilmLibraryService? primary,
    this.maxExtraDbs = 6,
  }) : primary = primary ?? FilmLibraryService(database: database);

  final ActressDatabase database;

  /// 主库（严格结构 / 绑定的女优库）：原有逻辑照旧先走它。
  final FilmLibraryService primary;

  /// 最多合并几个外来库（太大的机器上可以调小）。
  final int maxExtraDbs;

  static const _maxOpen = 3;

  final _open = <String, _OpenGenericDb>{};
  final _lru = <String>[];

  String? _scanKey;
  List<String> _extraPaths = const [];

  /// 从主库读到的作品 + 各外来库读到的作品，按播放地址/番号去重。
  List<ActressJsonEntry> _merge(List<ActressJsonEntry> rows) {
    final out = <ActressJsonEntry>[];
    final seen = <String>{};
    for (final row in rows) {
      if (!row.playable) continue;
      final key = row.playable && row.playUrl.isNotEmpty
          ? row.playUrl
          : '${row.site}:${row.codeKey}:${row.vodId}';
      if (!seen.add(key)) continue;
      // 同一个番号同一站只留一条（地址不同取先到的）。
      final codeKey = '${row.site}:${row.codeKey}';
      if (row.codeKey.isNotEmpty && !seen.add(codeKey)) continue;
      out.add(row);
    }
    return out;
  }

  @override
  Future<List<ActressJsonEntry>> entriesForActress(
    String name, {
    String? site,
  }) async {
    final rows = <ActressJsonEntry>[];
    try {
      rows.addAll(await primary.entriesForActress(name, site: site));
    } catch (_) {
      // 主库读不到（没绑定/换库中）：外来库照查。
    }
    for (final db in await _extraDatabases()) {
      try {
        final works = await db.reader.worksForActress(name);
        rows.addAll([for (final work in works) work.toJsonEntry()]);
      } catch (_) {
        // 单个库查失败跳过。
      }
    }
    return _filterSite(_merge(rows), site);
  }

  @override
  Future<List<ActressJsonEntry>> entriesForCode(
    String codeKey, {
    String? site,
  }) async {
    final key = normalizeAvCode(codeKey);
    if (key.isEmpty) return const [];
    final rows = <ActressJsonEntry>[];
    try {
      rows.addAll(await primary.entriesForCode(codeKey, site: site));
    } catch (_) {}
    for (final db in await _extraDatabases()) {
      try {
        final works = await db.reader.worksForCode(key);
        rows.addAll([for (final work in works) work.toJsonEntry()]);
      } catch (_) {}
    }
    return _filterSite(_merge(rows), site);
  }

  /// 批量按番号取作品（2026-11-22 女优库加载优化）：
  /// 主库一次批量取（见 [FilmLibraryService.entriesForCodes]），
  /// 外来小库仍逐番号查；外来库清单只扫一次，不逐番号重扫。
  /// 本方法不在 [FilmDbFallbackProvider] 接口上（见
  /// actress_json_fallback.dart 顶部说明），只挂真实实现。
  Future<List<ActressJsonEntry>> entriesForCodes(
    List<String> codeKeys, {
    String? site,
  }) async {
    final rows = <ActressJsonEntry>[];
    try {
      rows.addAll(await primary.entriesForCodes(codeKeys, site: site));
    } catch (_) {}
    final extras = await _extraDatabases();
    for (final codeKey in codeKeys) {
      final key = normalizeAvCode(codeKey);
      if (key.isEmpty) continue;
      for (final db in extras) {
        try {
          final works = await db.reader.worksForCode(key);
          rows.addAll([for (final work in works) work.toJsonEntry()]);
        } catch (_) {}
      }
    }
    return _filterSite(_merge(rows), site);
  }

  /// 直接按库浏览用：把合并后的外来库清单给页面（瓦片以外的入口）。
  Future<List<({String name, String path, GenericDbReader reader})>>
  extraDatabases() async => [
    for (final db in await _extraDatabases())
      (name: db.name, path: db.path, reader: db.reader),
  ];

  List<ActressJsonEntry> _filterSite(
    List<ActressJsonEntry> rows,
    String? site,
  ) {
    if (site == null || site.isEmpty) return rows;
    return [for (final row in rows) if (row.site == site) row];
  }

  Future<void> close() async {
    for (final db in _open.values) {
      await db.close();
    }
    _open.clear();
    _lru.clear();
    await primary.close();
  }

  /// 扫出外来库清单（只扫 .db 文件，排除主库本身），按修改时间从
  /// 新到旧取前 [maxExtraDbs] 个——用户新放进去的库优先。
  Future<List<String>> _scanExtraPaths() async {
    final bind = ActressMytvBind.instance.current ??
        await ActressMytvBind.instance.ensureBound();
    if (!bind.bound) return const [];
    final extraDirs = bind.externalRoot == null
        ? const <Directory>[]
        : [
            for (final rel in sikuDbScanDirs)
              Directory(path.join(bind.externalRoot!.path, rel)),
          ];
    List<File> targets;
    try {
      targets = collectDbMirrorTargets(
        dbDir: bind.dbDir,
        libraryPath: bind.dbPath,
        extraDirs: extraDirs,
      );
    } catch (_) {
      return const [];
    }
    targets.sort((a, b) {
      final at = a.statSync().modified;
      final bt = b.statSync().modified;
      return bt.compareTo(at);
    });
    return [for (final file in targets.take(maxExtraDbs)) file.path];
  }

  Future<List<_OpenGenericDb>> _extraDatabases() async {
    final paths = await _scanExtraPaths();
    final key = paths.join('|');
    if (key != _scanKey) {
      _scanKey = key;
      _extraPaths = paths;
    }
    final out = <_OpenGenericDb>[];
    for (final filePath in _extraPaths) {
      final db = await _openDb(filePath);
      if (db != null) out.add(db);
    }
    return out;
  }

  Future<_OpenGenericDb?> _openDb(String filePath) async {
    var stamp = '';
    try {
      final stat = File(filePath).statSync();
      stamp = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    } catch (_) {
      return null;
    }
    final cached = _open[filePath];
    if (cached != null && cached.stamp == stamp) {
      _touch(filePath);
      return cached;
    }
    if (cached != null) {
      await cached.close();
      _open.remove(filePath);
      _lru.remove(filePath);
    }
    Database? db;
    try {
      // 2026-11-23：外来库也补索引（只加索引，不动行；后台跑不堵读）。
      // 主库开库时已补（_ensureVideoIndexes），但 MYTV/db/ 下别的 .db
      // 走这里只读打开，从来没人给它们补过——大库上 LIKE 扫表就是
      // 详情页地址池建不起来的原因之一。建过一次后直接跳过。
      unawaited(ensureVideoDbIndexes(filePath));
      db = await openDatabase(
        filePath,
        readOnly: true,
        singleInstance: false,
      ).timeout(const Duration(seconds: 12));
      final schema = await probeGenericDbSchema(db).timeout(
        const Duration(seconds: 20),
      );
      if (schema.worksTable == null) {
        await db.close();
        return null;
      }
      final reader = GenericDbReader(
        db: db,
        schema: schema,
        mappingStore: GenericDbMappingStore(
          file: File(path.join(path.dirname(filePath), '字段映射.json')),
        ),
      );
      final opened = _OpenGenericDb(
        name: path.basenameWithoutExtension(filePath),
        path: filePath,
        stamp: stamp,
        readOnlyDb: db,
        reader: reader,
      );
      _open[filePath] = opened;
      _touch(filePath);
      await _trim();
      return opened;
    } catch (_) {
      await db?.close();
      return null;
    }
  }

  void _touch(String filePath) {
    _lru.remove(filePath);
    _lru.add(filePath);
  }

  Future<void> _trim() async {
    while (_lru.length > _maxOpen) {
      final oldest = _lru.removeAt(0);
      final db = _open.remove(oldest);
      await db?.close();
    }
  }
}

class _OpenGenericDb {
  _OpenGenericDb({
    required this.name,
    required this.path,
    required this.stamp,
    required this.readOnlyDb,
    required this.reader,
  });

  final String name;
  final String path;
  final String stamp;
  final Database readOnlyDb;
  final GenericDbReader reader;

  Future<void> close() => readOnlyDb.close();
}
