import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'actress_database.dart' show applyActressDbReadPragmas;

/// 女优库版本门（2026-11-27 演员库激活批）：女优库不再是文件放对
/// 位置就生效，必须走导入激活；导入先查库里的版本字段，对不上
/// 不激活。字段规格与站点库（lib/services/site_library.dart）钉死
/// 同款，不发明第二套：
///
/// - 版本字段住在库内 `schema_meta` 表（key/value）：
///   `format`（女优库恒为 `actress_library`）、`format_version`
///   （库格式版本）、`core_version`（本库要求的核心版本）、
///   `library_version`（库自身版本，仅展示/留痕，不参与比对）；
/// - 比对口径与站点库一致：**精确相等**——format_version 必须
///   等于 [actressLibrarySupportedFormatVersion]，core_version
///   必须等于 [actressLibraryDefaultCoreVersion]（均可注入覆盖，
///   测试/将来升版用）；
/// - 缺表/缺字段、对不上，一律拒收并给中文原因（写明库要求什么、
///   当前软件是什么），已激活的旧库一字不动（调用方保证）。
///
/// 存量口径（同批定版）：版本门只管**新导入**。升级前导入槽里
/// 已经在用的库（没有版本字段）视为存量继续可用，激活记录记
/// origin=legacy，见 actress_db_source.dart。

/// 本软件支持的女优库格式版本（schema_meta.format_version 必须
/// 等于它）。
const actressLibrarySupportedFormatVersion = '1';

/// 本软件的核心版本（schema_meta.core_version 必须等于它）。
const actressLibraryDefaultCoreVersion = '2026.11.27';

/// 女优库 schema_meta 的 format 标识值。
const actressLibraryMetaFormat = 'actress_library';

/// 从一个库里读到的版本信息（读不到的字段为空字符串）。
class ActressLibraryVersionInfo {
  const ActressLibraryVersionInfo({
    this.format = '',
    this.formatVersion = '',
    this.coreVersion = '',
    this.libraryVersion = '',
  });

  final String format;
  final String formatVersion;
  final String coreVersion;
  final String libraryVersion;

  /// schema_meta 表不存在或 format 不是女优库：视为没有版本字段。
  bool get hasVersionFields =>
      format == actressLibraryMetaFormat &&
      formatVersion.isNotEmpty &&
      coreVersion.isNotEmpty;

  /// 展示用一句话（管理页激活信息）。
  String get describe {
    if (!hasVersionFields) return '无版本字段（存量库）';
    return '库版本 ${libraryVersion.isEmpty ? '未知' : libraryVersion}'
        ' · 格式 $formatVersion · 要求核心 $coreVersion';
  }
}

/// 查询函数形态：给一句 SQL 回行（与 SqlImportExecutor.query /
/// sqflite rawQuery 同形状，两条导入链共用本门的读取逻辑）。
typedef ActressMetaQuery = Future<List<Map<String, Object?>>> Function(
  String sql,
);

/// 从任意查询通道读 schema_meta（表不存在/查不动回全空信息，
/// 不抛错——拒收原因由 [actressLibraryVersionError] 统一生成）。
Future<ActressLibraryVersionInfo> readActressLibraryVersion(
  ActressMetaQuery query,
) async {
  try {
    final tables = await query(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='schema_meta'",
    );
    if (tables.isEmpty) return const ActressLibraryVersionInfo();
    final rows = await query('SELECT key, value FROM schema_meta');
    final map = <String, String>{
      for (final row in rows)
        '${row['key'] ?? ''}': '${row['value'] ?? ''}',
    };
    return ActressLibraryVersionInfo(
      format: map['format'] ?? '',
      formatVersion: map['format_version'] ?? '',
      coreVersion: map['core_version'] ?? '',
      libraryVersion: map['library_version'] ?? '',
    );
  } catch (_) {
    return const ActressLibraryVersionInfo();
  }
}

/// 版本门判定：通过回 null，不通过回中文拒收原因（写明要求与
/// 现状）。[supportedFormatVersion] / [currentCoreVersion] 可注入。
String? actressLibraryVersionError(
  ActressLibraryVersionInfo info, {
  String supportedFormatVersion = actressLibrarySupportedFormatVersion,
  String currentCoreVersion = actressLibraryDefaultCoreVersion,
}) {
  if (!info.hasVersionFields) {
    return '这个库没有版本字段，无法激活（多半是旧版库）：'
        '当前软件只认带版本字段的女优库'
        '（格式版本 $supportedFormatVersion、核心版本 $currentCoreVersion），'
        '请换用新版库文件再导入';
  }
  if (info.formatVersion != supportedFormatVersion) {
    return '女优库格式版本 ${info.formatVersion} 与当前软件支持的 '
        '格式版本 $supportedFormatVersion 不一致，无法激活';
  }
  if (info.coreVersion != currentCoreVersion) {
    return '女优库要求核心版本 ${info.coreVersion}，'
        '当前软件核心版本是 $currentCoreVersion，版本对不上，无法激活';
  }
  return null;
}

/// 对一个 .db 文件做版本门检查（只读打开读 schema_meta 即关，
/// 绝不写文件）。文件打不开回「打不开」类原因，由调用方与结构
/// 校验的报错合并呈现。
Future<({ActressLibraryVersionInfo info, String? error})>
checkActressDbFileVersion(
  String dbPath, {
  String supportedFormatVersion = actressLibrarySupportedFormatVersion,
  String currentCoreVersion = actressLibraryDefaultCoreVersion,
}) async {
  final file = File(dbPath);
  if (!file.existsSync() || file.lengthSync() == 0) {
    return (
      info: const ActressLibraryVersionInfo(),
      error: '选中的文件读不到或为空',
    );
  }
  Database? db;
  try {
    db = await openDatabase(
      dbPath,
      readOnly: true,
      singleInstance: false,
      onOpen: applyActressDbReadPragmas,
    );
    final info = await readActressLibraryVersion(
      (sql) => db!.rawQuery(sql),
    );
    return (
      info: info,
      error: actressLibraryVersionError(
        info,
        supportedFormatVersion: supportedFormatVersion,
        currentCoreVersion: currentCoreVersion,
      ),
    );
  } catch (e) {
    return (
      info: const ActressLibraryVersionInfo(),
      error: '这个数据库打不开：${e.toString().split('\n').first}',
    );
  } finally {
    try {
      await db?.close();
    } catch (_) {}
  }
}
