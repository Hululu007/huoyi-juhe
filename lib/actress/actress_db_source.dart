import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart' show applyActressDbReadPragmas;
import 'actress_generic_db.dart';
import 'actress_mytv_bind.dart';

/// 双数据库来源层（2026-11-27 双库批）：演员库同时认两个库槽，
/// 二选一作为「当前库」，读库层只问本层要生效路径，不再各自直读
/// MYTV 绑定路径。
///
/// 两个槽：
/// - external（外置库）：[ActressMytvBind] 解析出的路径
///   （安卓 MYTV/db/女优库.db 直读或 SAF 镜像落点）。**只读红线
///   不变**：本层只报路径与状态，导入/切换/删除一律不写它。
/// - imported（导入库）：App 私有目录固定落点——应用 documents
///   下 `actress/` 子目录里的 `女优库.db`，与 iOS 导入库落点是
///   同一条路径（[ActressMytvBind.iosDbPath]），.db 收编与 .sql
///   导入都只往这里写，两平台语义一致。
///
/// 当前选择存 SharedPreferences 键 [actressDbSlotPrefsKey]
/// （值 `external` / `imported`）：
/// - 安卓默认 external（没存过 = 外置库，与改前行为一致）；
/// - iOS 维持现状：imported 是唯一来源，选择恒为 imported，
///   存了别的值也不认（iOS 没有外置直读这条路，不许回退）。
///
/// 生效路径解析：选 imported 但导入库文件不存在/为空 → 回落
/// external，并在状态里标明（[ActressDbSourceStatus.fellBack]），
/// 界面据此如实显示「已回落外置库」，不假装在用导入库。
///
/// 变更通知：[revision] 每次切换/导入/删除后 +1。读库层的失效
/// 主要靠既有的「路径 + 文件戳」机制（切换必然换路径、换路径
/// 必然触发重开；同路径换文件靠戳变化）；[revision] 供界面与
/// 后续监听方订阅，本层不直接关任何连接。

/// 当前库槽的 SharedPreferences 键。
const actressDbSlotPrefsKey = 'actress_db_current_slot_v1';

/// 两个库槽。
enum ActressDbSlot { external, imported }

extension ActressDbSlotWire on ActressDbSlot {
  String get wire => this == ActressDbSlot.imported ? 'imported' : 'external';

  static ActressDbSlot fromWire(String? value) =>
      value == 'imported' ? ActressDbSlot.imported : ActressDbSlot.external;
}

/// 一个库槽的状态快照（路径/是否存在/大小/修改时间）。
class ActressDbSlotInfo {
  const ActressDbSlotInfo({
    required this.slot,
    required this.dbPath,
    required this.exists,
    this.sizeBytes = 0,
    this.modified,
  });

  final ActressDbSlot slot;

  /// 槽的库文件路径（外置槽未绑定时为空字符串）。
  final String dbPath;

  /// 文件存在且非空。
  final bool exists;

  final int sizeBytes;
  final DateTime? modified;

  /// 界面用一句话状态：未绑定或不存在 / 已就绪。
  String get statusText {
    if (slot == ActressDbSlot.external && dbPath.isEmpty) return '未绑定';
    return exists ? '已就绪' : '不存在';
  }
}

/// 来源层一次解析的完整状态。
class ActressDbSourceStatus {
  const ActressDbSourceStatus({
    required this.selection,
    required this.effectiveSlot,
    required this.effectivePath,
    required this.fellBack,
    required this.external,
    required this.imported,
  });

  /// 用户存的选择（iOS 恒为 imported）。
  final ActressDbSlot selection;

  /// 实际生效的槽（回落时与 [selection] 不同）。
  final ActressDbSlot effectiveSlot;

  /// 实际生效的库文件路径；两个槽都不可用时为空字符串。
  final String effectivePath;

  /// true = 选了 imported 但导入库不在，已回落 external。
  final bool fellBack;

  final ActressDbSlotInfo external;
  final ActressDbSlotInfo imported;

  ActressDbSlotInfo infoOf(ActressDbSlot slot) =>
      slot == ActressDbSlot.imported ? imported : external;

  bool isEffective(ActressDbSlot slot) =>
      effectivePath.isNotEmpty && effectiveSlot == slot;
}

/// 外置槽路径解析（默认走 MYTV 绑定，测试可注入）。
typedef ActressExternalPathResolver = Future<String> Function();

/// 导入槽路径解析（默认与 iOS 落点共用 [ActressMytvBind.iosDbPath]）。
typedef ActressImportedPathResolver = Future<String> Function();

/// 作品数统计（默认只读开库数行，数不出来回 null；测试可注入）。
typedef ActressDbWorksCounter = Future<int?> Function(String dbPath);

/// 双库来源层：槽状态、选择存取、生效路径解析、变更通知。
class ActressDbSource {
  ActressDbSource({
    ActressExternalPathResolver? externalPath,
    ActressImportedPathResolver? importedPath,
    ActressDbWorksCounter? worksCounter,
    Future<SharedPreferences> Function()? preferences,
    bool Function()? isIOS,
  }) : _externalPath = externalPath ?? _defaultExternalPath,
       _importedPath = importedPath ?? _defaultImportedPath,
       _worksCounter = worksCounter ?? _defaultWorksCounter,
       _preferences = preferences ?? SharedPreferences.getInstance,
       _isIOS = isIOS ?? (() => Platform.isIOS);

  ActressDbSource._()
    : _externalPath = _defaultExternalPath,
      _importedPath = _defaultImportedPath,
      _worksCounter = _defaultWorksCounter,
      _preferences = SharedPreferences.getInstance,
      _isIOS = (() => Platform.isIOS);

  static final ActressDbSource instance = ActressDbSource._();

  final ActressExternalPathResolver _externalPath;
  final ActressImportedPathResolver _importedPath;
  final ActressDbWorksCounter _worksCounter;
  final Future<SharedPreferences> Function() _preferences;
  final bool Function() _isIOS;

  /// 变更代次：切换选择、导入落库、删除导入库后 +1（见类注释）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知变更（导入服务/管理页在动了槽文件后调）。
  void notifyChanged() => revision.value = revision.value + 1;

  static Future<String> _defaultExternalPath() async {
    try {
      final bind = await ActressMytvBind.instance.ensureBound();
      return bind.dbPath;
    } catch (_) {
      return '';
    }
  }

  static Future<String> _defaultImportedPath() =>
      ActressMytvBind.instance.iosDbPath();

  /// 导入库固定落点（导入服务写它、管理页删它，都走这一处）。
  Future<String> importedDbPath() => _importedPath();

  /// 外置库当前解析路径（只报路径，绝不写）。
  Future<String> externalDbPath() => _externalPath();

  /// 读选择：iOS 恒 imported；安卓读存值，没存过默认 external。
  Future<ActressDbSlot> loadSelection() async {
    if (_isIOS()) return ActressDbSlot.imported;
    try {
      final prefs = await _preferences();
      return ActressDbSlotWire.fromWire(
        prefs.getString(actressDbSlotPrefsKey),
      );
    } catch (_) {
      return ActressDbSlot.external;
    }
  }

  /// 写选择并通知变更。iOS 恒 imported（写什么都按 imported 存，
  /// 保持「iOS 只有导入库」这一条不被存值带偏）。
  Future<void> setSelection(ActressDbSlot slot) async {
    final effective = _isIOS() ? ActressDbSlot.imported : slot;
    try {
      final prefs = await _preferences();
      await prefs.setString(actressDbSlotPrefsKey, effective.wire);
    } catch (_) {
      // 存不下不崩：本次进程内仍按通知走，重启后回默认。
    }
    notifyChanged();
  }

  ActressDbSlotInfo _infoOf(ActressDbSlot slot, String dbPath) {
    if (dbPath.isEmpty) {
      return ActressDbSlotInfo(slot: slot, dbPath: '', exists: false);
    }
    try {
      final file = File(dbPath);
      if (!file.existsSync()) {
        return ActressDbSlotInfo(slot: slot, dbPath: dbPath, exists: false);
      }
      final stat = file.statSync();
      return ActressDbSlotInfo(
        slot: slot,
        dbPath: dbPath,
        exists: stat.size > 0,
        sizeBytes: stat.size,
        modified: stat.modified,
      );
    } catch (_) {
      return ActressDbSlotInfo(slot: slot, dbPath: dbPath, exists: false);
    }
  }

  /// 完整状态：两槽快照 + 生效解析（含 imported 缺失回落）。
  Future<ActressDbSourceStatus> status() async {
    final selection = await loadSelection();
    final externalInfo = _infoOf(
      ActressDbSlot.external,
      await _externalPath(),
    );
    final importedInfo = _infoOf(
      ActressDbSlot.imported,
      await _importedPath(),
    );
    if (selection == ActressDbSlot.imported) {
      if (importedInfo.exists) {
        return ActressDbSourceStatus(
          selection: selection,
          effectiveSlot: ActressDbSlot.imported,
          effectivePath: importedInfo.dbPath,
          fellBack: false,
          external: externalInfo,
          imported: importedInfo,
        );
      }
      // 选了导入库但它不在：回落外置库并标明（iOS 没有外置路，
      // 回落结果就是空路径，界面显示未导入，与改前一致）。
      return ActressDbSourceStatus(
        selection: selection,
        effectiveSlot: ActressDbSlot.external,
        effectivePath: externalInfo.exists ? externalInfo.dbPath : '',
        fellBack: !_isIOS(),
        external: externalInfo,
        imported: importedInfo,
      );
    }
    return ActressDbSourceStatus(
      selection: selection,
      effectiveSlot: ActressDbSlot.external,
      effectivePath: externalInfo.exists ? externalInfo.dbPath : '',
      fellBack: false,
      external: externalInfo,
      imported: importedInfo,
    );
  }

  /// 当前生效路径（读库层唯一入口）：没有可用库回空字符串。
  Future<String> effectiveDbPath() async => (await status()).effectivePath;

  /// 某槽的作品数：只读开库数——严格库数 videos 表，通用库数
  /// 探测到的作品表；数不出来（打不开/认不出）回 null，界面显
  /// 「—」，不报错、不写库。
  Future<int?> countWorks(ActressDbSlotInfo info) {
    if (!info.exists || info.dbPath.isEmpty) return Future.value(null);
    return _worksCounter(info.dbPath);
  }

  static Future<int?> _defaultWorksCounter(String dbPath) async {
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
        return (rows.first['c'] as num?)?.toInt();
      }
      final schema = await probeGenericDbSchema(db);
      final works = schema.worksTable;
      if (works == null) return null;
      final escaped = works.table.replaceAll('"', '""');
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM "$escaped"',
      );
      return (rows.first['c'] as num?)?.toInt();
    } catch (_) {
      return null;
    } finally {
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  /// 删除导入库（仅 imported 槽；外置库永不经本层删除）。
  /// 连同 .bak 与导入临时文件一起清；删完通知变更。当前选择
  /// 仍是 imported 时，生效解析自动回落 external（见 [status]）。
  Future<bool> deleteImported() async {
    final importedPath = await _importedPath();
    if (importedPath.isEmpty) return false;
    var removed = false;
    for (final candidate in [
      importedPath,
      '$importedPath.bak',
      '$importedPath.importing',
    ]) {
      try {
        final file = File(candidate);
        if (file.existsSync()) {
          await file.delete();
          removed = true;
        }
      } catch (_) {}
    }
    // 临时收编文件（.db 导入的中转）一并清。
    try {
      final dir = Directory(path.dirname(importedPath));
      if (dir.existsSync()) {
        for (final entity in dir.listSync()) {
          if (entity is File &&
              path.basename(entity.path).contains('.importing-db')) {
            try {
              await entity.delete();
              removed = true;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    if (removed) notifyChanged();
    return removed;
  }
}
