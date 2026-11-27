import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart' show applyActressDbReadPragmas;
import 'actress_db_source.dart';
import 'actress_generic_db.dart';
import 'actress_sql_import.dart';

/// 双库导入服务（2026-11-27 双库批）：统一入口收 .db / .sql /
/// .sql.gz，落点一律是 imported 槽（App 私有目录固定落点，见
/// [ActressDbSource]），外置库一个字都不写，选中文件也绝不原地
/// 当库用。
///
/// - .sql / .sql.gz：复用 [ActressSqlImporter]（流式执行→归一化
///   →校验→备份 .bak→换库，失败原 imported 不动）。iOS 现有 tile
///   本来就是往同一落点导（iosDbPath 与 imported 槽同路径），
///   语义一致、iOS 流程未改。
/// - .db：先验后换——选中文件先以只读方式打开做结构探测
///   （[validateActressDbFile]：严格结构认 videos 表、通用结构认
///   探测到的作品表，两者都要作品数 > 0），校验过才拷进
///   imported 槽：先拷到同目录中转文件，旧 imported 留 .bak，
///   中转改名就位；校验不过给中文报错、imported 槽原样不动。
///
/// 报错全中文且分开说：文件读不到 / 格式不对 / 作品数为 0 /
/// 复制失败（空间不足等）各是各的文案。

/// .db 校验结果：认得出作品表且作品数 > 0 才 [ok]。
class ActressDbValidation {
  const ActressDbValidation({
    required this.ok,
    this.works = 0,
    this.error,
  });

  final bool ok;

  /// 探测到的作品数（严格库 = videos 行数，通用库 = 作品表行数）。
  final int works;

  /// 中文失败原因（ok 时为空）。
  final String? error;
}

/// .db 校验器（可注入：测试用假件，不硬依赖真机 sqflite）。
typedef ActressDbValidator = Future<ActressDbValidation> Function(
  String dbPath,
);

/// 默认 .db 校验：只读打开选中文件探结构（见
/// [validateActressDbFile]）。
Future<ActressDbValidation> validateActressDbFile(String dbPath) async {
  final file = File(dbPath);
  if (!file.existsSync()) {
    return const ActressDbValidation(ok: false, error: '选中的文件读不到');
  }
  if (file.lengthSync() == 0) {
    return const ActressDbValidation(ok: false, error: '选中的文件是空的');
  }
  // SQLite 文件头：不是这个头就不是数据库文件，先挡掉改了
  // 后缀的文本/压缩包，报错也说得清。
  try {
    final raf = await file.open();
    final head = await raf.read(16);
    await raf.close();
    const magic = 'SQLite format 3';
    final headText = String.fromCharCodes(
      head.takeWhile((b) => b != 0),
    );
    if (!headText.startsWith(magic)) {
      return const ActressDbValidation(
        ok: false,
        error: '这个文件不是数据库文件（.db 请选择 SQLite 数据库）',
      );
    }
  } catch (_) {
    return const ActressDbValidation(ok: false, error: '选中的文件读不到');
  }
  Database? db;
  try {
    db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
      onOpen: applyActressDbReadPragmas,
    );
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = {for (final row in tables) row['name'].toString()};
    if (names.contains('videos')) {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM videos');
      final works = (rows.first['c'] as num?)?.toInt() ?? 0;
      if (works <= 0) {
        return const ActressDbValidation(
          ok: false,
          error: '这个数据库里没有作品，已取消导入',
        );
      }
      return ActressDbValidation(ok: true, works: works);
    }
    final schema = await probeGenericDbSchema(db);
    final worksTable = schema.worksTable;
    if (worksTable == null) {
      return const ActressDbValidation(
        ok: false,
        error: '认不出这个数据库的结构：没有同时带标题与播放地址的作品表',
      );
    }
    final escaped = worksTable.table.replaceAll('"', '""');
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM "$escaped"');
    final works = (rows.first['c'] as num?)?.toInt() ?? 0;
    if (works <= 0) {
      return const ActressDbValidation(
        ok: false,
        error: '这个数据库里没有作品，已取消导入',
      );
    }
    return ActressDbValidation(ok: true, works: works);
  } catch (e) {
    return ActressDbValidation(
      ok: false,
      error: '这个数据库打不开：${e.toString().split('\n').first}',
    );
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}

/// 一次导入的结果（.db 与 .sql 两路统一形状）。
class ActressDbImportOutcome {
  const ActressDbImportOutcome({
    required this.ok,
    this.error,
    this.videos = 0,
    this.actresses = 0,
    this.playUrls = 0,
    this.warnings = const [],
    this.needsReload = false,
  });

  final bool ok;
  final String? error;

  /// 作品数（.db 路 = 校验时数到的作品数；.sql 路 = 导入器结果）。
  final int videos;
  final int actresses;
  final int playUrls;
  final List<String> warnings;

  /// true = imported 槽文件已被换动，调用方应重读数据库。
  final bool needsReload;
}

/// 双库导入服务：文件已落到本地路径后调 [importLocalFile]。
/// 选文件（file_selector）与收件拷贝在管理页做，与 iOS tile 同款。
class ActressDbImportService {
  ActressDbImportService({
    ActressDbSource? source,
    ActressDbValidator? dbValidator,
    ActressSqlImporter? sqlImporter,
  }) : _source = source ?? ActressDbSource.instance,
       _dbValidator = dbValidator ?? validateActressDbFile,
       _sqlImporter = sqlImporter ?? ActressSqlImporter();

  final ActressDbSource _source;
  final ActressDbValidator _dbValidator;
  final ActressSqlImporter _sqlImporter;

  /// 导入一个本地文件（按后缀分路）到 imported 槽。
  ///
  /// [closeDatabase] 只在真正换库前调（关当前主库连接，好让读库
  /// 层重开新文件）；校验不过时不调、任何现有库都不动。
  Future<ActressDbImportOutcome> importLocalFile({
    required String localPath,
    required Future<void> Function() closeDatabase,
    void Function(ActressSqlImportProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final lower = localPath.toLowerCase();
    final isSql = lower.endsWith('.sql') || lower.endsWith('.sql.gz');
    final isDb = lower.endsWith('.db');
    if (!isSql && !isDb) {
      return const ActressDbImportOutcome(
        ok: false,
        error: '只认 .db、.sql 或 .sql.gz 文件',
      );
    }
    final file = File(localPath);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return const ActressDbImportOutcome(
        ok: false,
        error: '选中的文件读不到或为空',
      );
    }
    final importedPath = await _source.importedDbPath();
    if (importedPath.isEmpty) {
      return const ActressDbImportOutcome(
        ok: false,
        error: '导入落点不可用，请稍后再试',
      );
    }
    if (isSql) return _importSql(
      sqlPath: localPath,
      importedPath: importedPath,
      closeDatabase: closeDatabase,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    return _importDb(
      pickedPath: localPath,
      importedPath: importedPath,
      closeDatabase: closeDatabase,
    );
  }

  Future<ActressDbImportOutcome> _importSql({
    required String sqlPath,
    required String importedPath,
    required Future<void> Function() closeDatabase,
    void Function(ActressSqlImportProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final result = await _sqlImporter.importFile(
      sqlPath: sqlPath,
      dbPath: importedPath,
      closeDatabase: closeDatabase,
      onProgress: onProgress ?? (_) {},
      isCancelled: isCancelled,
    );
    if (result.ok) {
      _source.notifyChanged();
    }
    return ActressDbImportOutcome(
      ok: result.ok,
      error: result.error,
      videos: result.videos,
      actresses: result.actresses,
      playUrls: result.playUrls,
      warnings: result.warnings,
      needsReload: result.needsReload,
    );
  }

  /// .db 先验后换：校验（只读开选中文件）→ 拷中转 → 旧 imported
  /// 留 .bak → 中转改名就位。任一步失败 imported 原样不动
  /// （改名失败且原文件已挪走时从 .bak 恢复）。
  Future<ActressDbImportOutcome> _importDb({
    required String pickedPath,
    required String importedPath,
    required Future<void> Function() closeDatabase,
  }) async {
    final validation = await _dbValidator(pickedPath);
    if (!validation.ok) {
      return ActressDbImportOutcome(
        ok: false,
        error: validation.error ?? '这个数据库不能用，已取消导入',
      );
    }
    final stagingPath = '$importedPath.importing-db';
    final staging = File(stagingPath);
    final live = File(importedPath);
    final bak = File('$importedPath.bak');
    try {
      await live.parent.create(recursive: true);
      if (staging.existsSync()) await staging.delete();
      await File(pickedPath).copy(stagingPath);
      if (!staging.existsSync() || staging.lengthSync() == 0) {
        return const ActressDbImportOutcome(
          ok: false,
          error: '复制数据库失败，请确认存储空间充足后重试',
        );
      }
    } catch (e) {
      try {
        if (staging.existsSync()) await staging.delete();
      } catch (_) {}
      return ActressDbImportOutcome(
        ok: false,
        error: '复制数据库失败（可能是存储空间不足）：${e.toString().split('\n').first}',
      );
    }
    // 换库：先关主库连接（读库层随后按新文件重开），旧 imported
    // 拷成 .bak 再让中转改名就位；.bak 与 .sql 导入同口径保留，
    // 出问题时管理页可凭它人工恢复。
    try {
      await closeDatabase();
    } catch (_) {}
    final hadLive = live.existsSync();
    try {
      if (hadLive) await live.copy(bak.path);
      if (live.existsSync()) await live.delete();
      await staging.rename(importedPath);
    } catch (e) {
      // 改名失败：原文件还在就不动；已被删就从 .bak 恢复。
      if (!live.existsSync() && hadLive && bak.existsSync()) {
        try {
          await bak.copy(importedPath);
        } catch (_) {}
      }
      try {
        if (staging.existsSync()) await staging.delete();
      } catch (_) {}
      return ActressDbImportOutcome(
        ok: false,
        error: '换库失败：${e.toString().split('\n').first}（已恢复原导入库）',
        needsReload: true,
      );
    }
    _source.notifyChanged();
    return ActressDbImportOutcome(
      ok: true,
      videos: validation.works,
      needsReload: true,
    );
  }

  /// 收件文件落点（管理页选完文件先拷到这，再走导入）：与
  /// imported 槽同目录（私有目录内），导入完由调用方删。
  Future<File> inboxFileFor(String pickedName) async {
    final importedPath = await _source.importedDbPath();
    final dir = Directory(path.dirname(importedPath));
    await dir.create(recursive: true);
    return File(
      path.join(
        dir.path,
        'inbox_${DateTime.now().microsecondsSinceEpoch}_$pickedName',
      ),
    );
  }
}
