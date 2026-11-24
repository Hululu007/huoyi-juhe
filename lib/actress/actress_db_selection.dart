import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_db_mirror.dart';
import 'actress_film_library.dart';
import 'actress_generic_db.dart';
import 'actress_mytv_bind.dart';
import 'actress_site_db.dart';

/// 女优库多库勾选：一个库选项（设置齿轮弹窗“数据库”区里一行）。
typedef ActressDbChoice = ({
  String name,
  String path,
  bool isMain,
  bool isSiteDb,
});

/// 勾选的数据库集合：存在 SharedPreferences，默认只勾主库
/// （MYTV/db/女优库.db）。存的是完整路径；主库路径变了（换绑）
/// 以后旧路径对不上就按默认只勾主库处理。
class ActressDbSelection {
  static const String keySelectedDbs = 'moyi_actress_selected_dbs';

  /// 已勾的库路径（默认只勾主库）。调用方传当前主库路径。
  static Future<Set<String>> loadSelectedPaths(String mainPath) async {
    final store = await SharedPreferences.getInstance();
    final saved = store.getStringList(keySelectedDbs);
    if (saved == null || saved.isEmpty) {
      return mainPath.isEmpty ? <String>{} : {mainPath};
    }
    final paths = saved.where((p) => p.isNotEmpty).toSet();
    if (mainPath.isNotEmpty) paths.add(mainPath);
    return paths;
  }

  static Future<void> saveSelectedPaths(Set<String> paths) async {
    final store = await SharedPreferences.getInstance();
    await store.setStringList(keySelectedDbs, paths.toList());
  }

  /// 可勾的库：主库 + MYTV/db 与补充目录里其它 .db（与镜像收集
  /// 同一套扫描，站点库.db 已在排除名单里所以扫不到，这里单独补
  /// 回来——默认不勾）。主库永远在第一位。
  static List<ActressDbChoice> availableChoices({
    required MytvBindResult bind,
  }) {
    final choices = <ActressDbChoice>[];
    final seen = <String>{};
    void addChoice(String filePath, {required bool isMain}) {
      final normalized = path.normalize(filePath);
      if (!seen.add(normalized)) return;
      final baseName = path.basename(filePath);
      choices.add((
        name: path.basenameWithoutExtension(filePath),
        path: filePath,
        isMain: isMain,
        isSiteDb: baseName == siteDbFileName,
      ));
    }

    if (bind.dbPath.isNotEmpty) {
      addChoice(bind.dbPath, isMain: true);
    }
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
      targets = const [];
    }
    for (final file in targets) {
      addChoice(file.path, isMain: false);
    }
    // 站点库.db 不在镜像扫描里（已排除），单独补回来，默认不勾。
    final siteDbPath = path.join(bind.dbDir.path, siteDbFileName);
    if (File(siteDbPath).existsSync()) {
      addChoice(siteDbPath, isMain: false);
    }
    return choices;
  }

  /// 这个文件是不是女优库严格结构（videos/video_actress/
  /// video_category 三张表）：只读探一下，不写、不建索引。
  /// 不是的库不进列表合并（仍可当播放兜底，那是另一条路）。
  static Future<bool> isStrictVideoLibraryDbFile(String filePath) async {
    Database? db;
    try {
      final file = File(filePath);
      if (!file.existsSync() || file.lengthSync() == 0) return false;
      // 2026-11-24 掉线修复：探库必须 singleInstance: false——
      // 默认单例下同路径 open 返回的是主库正在用的同一个连接，
      // 这里 close() 会把主库的共享连接一起关掉，主库此后全掉线。
      // 独立连接探完关自己的，不动主库。
      db = await openDatabase(
        filePath,
        readOnly: true,
        singleInstance: false,
      );
      final schema = await probeGenericDbSchema(db);
      return filmIsStrictVideosSchema(schema);
    } catch (_) {
      return false;
    } finally {
      await db?.close();
    }
  }

  /// 该库的可播视频数（2026-11-23 用户令：数据库全部支持勾选）。
  /// 严格结构时数 videos 表（有行就回行数，老口径）；videos 表
  /// 是空的、或不是严格结构时，按通用读法数：每张同时有标题列
  /// 与播放地址列的表各数一次可播地址行（地址含 http，磁力不算），
  /// 取最大的那张——AV 总库就是这样：videos/video_actress/
  /// video_category 三张表都在但全是空的，361681 条在 results
  /// 表（fanhao + video_url），只数 videos 会把它报成 0 部。
  /// 返回 -1 = 文件打不开/不是数据库；返回 0 = 确实一条可播
  /// 视频都没有（界面如实写“0 部可播视频”，不勾）。
  static Future<int> countPlayableVideos(String filePath) async {
    Database? db;
    try {
      final file = File(filePath);
      if (!file.existsSync() || file.lengthSync() == 0) return -1;
      // 2026-11-24 掉线修复：同上，探库独立连接，关完不拖主库掉线。
      db = await openDatabase(
        filePath,
        readOnly: true,
        singleInstance: false,
      );
      final schema = await probeGenericDbSchema(db);
      if (filmIsStrictVideosSchema(schema)) {
        final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM videos');
        final strictCount = (rows.first['c'] as num?)?.toInt() ?? -1;
        if (strictCount > 0) return strictCount;
      }
      var best = 0;
      for (final mapping in schema.tables) {
        final titleCol = mapping.columnFor(GenericDbRole.title);
        final urlCol = mapping.columnFor(GenericDbRole.playUrl);
        if (titleCol == null || urlCol == null) continue;
        final rows = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM ${_quote(mapping.table)} '
          "WHERE CAST(${_quote(urlCol)} AS TEXT) LIKE '%http%'",
        );
        final n = (rows.first['c'] as num?)?.toInt() ?? 0;
        if (n > best) best = n;
      }
      // 作品表经关联副表取地址时，上面的循环数不到：按 worksTable
      // + 关联补一次（地址在副表、标题在主表的库）。
      final works = schema.worksTable;
      if (works != null && works.columnFor(GenericDbRole.playUrl) == null) {
        final relation = schema.relationFor(GenericDbRole.playUrl);
        final relUrlCol = relation?.columnFor(GenericDbRole.playUrl);
        if (relation != null && relUrlCol != null) {
          final rows = await db.rawQuery(
            'SELECT COUNT(*) AS c FROM ${_quote(works.table)} w '
            'WHERE EXISTS (SELECT 1 FROM ${_quote(relation.table)} r '
            'WHERE CAST(r.${_quote(relation.foreignKey)} AS TEXT) = '
            'CAST(w.${_quote(relation.primaryKey)} AS TEXT) '
            "AND CAST(r.${_quote(relUrlCol)} AS TEXT) LIKE '%http%')",
          );
          final n = (rows.first['c'] as num?)?.toInt() ?? 0;
          if (n > best) best = n;
        }
      }
      return best;
    } catch (_) {
      return -1;
    } finally {
      await db?.close();
    }
  }

  static String _quote(String identifier) =>
      '"${identifier.replaceAll('"', '""')}"';
}
