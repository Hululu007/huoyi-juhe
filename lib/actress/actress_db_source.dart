import 'dart:convert';
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
/// （值 `external` / `imported`）：2026-11-27 激活批起，这个
/// 选择只剩存量兼容意义（旧测试与旧存值可读），**不再决定生效
/// 路径**——生效与否只看激活状态（见下）。iOS 恒 imported 的
/// 旧口径同样只剩兼容意义。
///
/// 【激活语义（2026-11-27 演员库激活批，用户令「演员库也要
/// 通过数据库激活」）】
/// - 女优库只有 imported 槽里的库能被激活，且必须经导入链
///   （.db 收编 / .sql 导入 / 外置文件点「导入激活」）走完
///   结构校验＋版本门（见 actress_library_version.dart）后，
///   由导入服务调 [markActivated] 落一条激活记录才生效。
/// - 外置槽**不再直通**：MYTV/db/女优库.db 放着不生效，它只是
///   管理页里看得见的「导入来源」，不点导入永远不激活。
/// - 没激活（或已激活但导入库文件没了）→ 生效路径为空，演员
///   库只有未激活空态＋导入引导，全局搜索的演员库段同样不出
///   （读库层拿不到路径即静默，与「没库静默」同口径）。
/// - 存量过渡：升级后首次解析状态时，若导入槽里已有库文件
///   且没有激活记录，视为 +2 时代已在用的存量库，自动补一条
///   origin=legacy 的激活记录继续可用——版本门只管新导入，
///   不把人锁死。外置槽不享受这条：它从来没经导入槽「激活」
///   过，按新规矩走导入。
///
/// 变更通知：[revision] 每次激活/导入/删除后 +1。读库层的失效
/// 主要靠既有的「路径 + 文件戳」机制（激活必然给出路径、删库
/// 必然收回路径）；[revision] 供界面与后续监听方订阅，本层不
/// 直接关任何连接。

/// 当前库槽的 SharedPreferences 键（存量兼容，见类注释）。
const actressDbSlotPrefsKey = 'actress_db_current_slot_v1';

/// 激活记录的 SharedPreferences 键（JSON 一条，见
/// [ActressDbActivation]）。
const actressDbActivationPrefsKey = 'actress_db_activation_v1';

/// 一条激活记录：哪个来源激活的、库自报的版本字段、激活时间。
/// 只记 imported 槽（唯一能激活的槽），槽文件不在了记录自动
/// 失效（status 解析时以文件存在为准）。
class ActressDbActivation {
  const ActressDbActivation({
    required this.origin,
    this.libraryVersion = '',
    this.formatVersion = '',
    this.coreVersion = '',
    this.activatedAtMs = 0,
  });

  /// 'import' = 经导入链过版本门激活；'legacy' = 存量过渡
  /// （+2 时代导入槽里已在用的库，无版本字段也继续可用）。
  final String origin;
  final String libraryVersion;
  final String formatVersion;
  final String coreVersion;
  final int activatedAtMs;

  bool get isLegacy => origin == 'legacy';

  /// 管理页展示用一句话。
  String get describe {
    if (isLegacy) return '存量库（升级前已在用，无版本字段，继续可用）';
    return '库版本 ${libraryVersion.isEmpty ? '未知' : libraryVersion}'
        ' · 格式 $formatVersion · 要求核心 $coreVersion';
  }

  Map<String, Object?> toJson() => {
    'origin': origin,
    'libraryVersion': libraryVersion,
    'formatVersion': formatVersion,
    'coreVersion': coreVersion,
    'activatedAtMs': activatedAtMs,
  };

  static ActressDbActivation? fromJson(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final origin = '${decoded['origin'] ?? ''}';
      if (origin != 'import' && origin != 'legacy') return null;
      return ActressDbActivation(
        origin: origin,
        libraryVersion: '${decoded['libraryVersion'] ?? ''}',
        formatVersion: '${decoded['formatVersion'] ?? ''}',
        coreVersion: '${decoded['coreVersion'] ?? ''}',
        activatedAtMs: (decoded['activatedAtMs'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

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
    this.activation,
  });

  /// 用户存的选择（存量兼容字段，不再决定生效，见类注释）。
  final ActressDbSlot selection;

  /// 实际生效的槽：已激活时恒为 imported；未激活时为 external
  /// 但 [effectivePath] 为空（[isEffective] 两槽都 false）。
  final ActressDbSlot effectiveSlot;

  /// 实际生效的库文件路径；未激活时为空字符串。
  final String effectivePath;

  /// 存量兼容字段：激活制下没有回落，恒为 false。
  final bool fellBack;

  final ActressDbSlotInfo external;
  final ActressDbSlotInfo imported;

  /// 当前激活记录（未激活为 null；含存量过渡的 legacy 记录）。
  final ActressDbActivation? activation;

  /// 演员库是否已激活（有记录且导入库文件在）。
  bool get activated => activation != null && imported.exists;

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

  /// 读激活记录（不含存量补记；补记在 [status] 里做）。
  Future<ActressDbActivation?> loadActivation() async {
    try {
      final prefs = await _preferences();
      return ActressDbActivation.fromJson(
        prefs.getString(actressDbActivationPrefsKey),
      );
    } catch (_) {
      return null;
    }
  }

  /// 落一条激活记录并通知变更（导入服务在导入成功换库后调；
  /// origin 只认 'import' / 'legacy'）。
  Future<void> markActivated({
    required String origin,
    String libraryVersion = '',
    String formatVersion = '',
    String coreVersion = '',
  }) async {
    final record = ActressDbActivation(
      origin: origin == 'legacy' ? 'legacy' : 'import',
      libraryVersion: libraryVersion,
      formatVersion: formatVersion,
      coreVersion: coreVersion,
      activatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      final prefs = await _preferences();
      await prefs.setString(
        actressDbActivationPrefsKey,
        jsonEncode(record.toJson()),
      );
    } catch (_) {
      // 存不下不崩：本次进程内仍靠文件与记录的内存态走不通，
      // 如实让 status 按无记录处理（下次导入会再落）。
    }
    notifyChanged();
  }

  /// 清激活记录（删导入库时调）。
  Future<void> clearActivation() async {
    try {
      final prefs = await _preferences();
      await prefs.remove(actressDbActivationPrefsKey);
    } catch (_) {}
  }

  /// 完整状态：两槽快照 + 激活解析（激活制，见类注释）。
  ///
  /// 存量过渡在本方法内补记：没有激活记录但 imported 槽已有
  /// 库文件 → 视为 +2 时代已在用的存量库，补 origin=legacy
  /// 记录并继续生效（只补一次，落盘后走正常记录路径）。
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
    var activation = await loadActivation();
    if (activation == null && importedInfo.exists) {
      activation = ActressDbActivation(
        origin: 'legacy',
        activatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        final prefs = await _preferences();
        await prefs.setString(
          actressDbActivationPrefsKey,
          jsonEncode(activation.toJson()),
        );
      } catch (_) {
        // 补记落盘失败不挡本次生效：内存里的记录先用着。
      }
    }
    final activated = activation != null && importedInfo.exists;
    return ActressDbSourceStatus(
      selection: selection,
      effectiveSlot: activated
          ? ActressDbSlot.imported
          : ActressDbSlot.external,
      effectivePath: activated ? importedInfo.dbPath : '',
      fellBack: false,
      external: externalInfo,
      imported: importedInfo,
      activation: activated ? activation : null,
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
  /// 连同 .bak 与导入临时文件一起清，并清激活记录——删完演员
  /// 库回到未激活态（不回落外置库，外置只是导入来源）。
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
    if (removed) {
      await clearActivation();
      notifyChanged();
    }
    return removed;
  }
}
