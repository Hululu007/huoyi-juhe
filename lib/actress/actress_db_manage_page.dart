import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../services/site_library.dart';
import '../services/source_registry.dart';
import '../services/unified_import.dart';
import 'actress_database.dart';
import 'actress_db_import.dart';
import 'actress_db_source.dart';
import 'actress_magnet_library.dart';
import 'actress_mytv_bind.dart';
import 'actress_neon.dart';
import 'actress_sql_import.dart';
import 'unified_import_page.dart';

/// 统一数据库管理页（2026-11-27 双库批，全树唯一一份）：两个
/// 入口共用——「我的」页的「数据库导入」行、演员库顶栏数据库
/// 管理弹层里的「数据库管理页（导入/激活）」项。
///
/// 激活制（2026-11-27 演员库激活批）：演员库必须经导入激活
/// 才出数据。页内：导入按钮（.db / .sql / .sql.gz，导入成功
/// 即激活，流程见 [ActressDbImportService]）+ 两张库卡：
/// - 外置库卡 = **导入来源**：MYTV/db/女优库.db 放着不生效，
///   卡上能看状态、能授权，点「导入激活」才走校验＋版本门
///   拷进导入库；外置库永不给删、本页不写它一字。
/// - 导入库卡 = 已激活的库：显激活状态与库自报版本、作品数、
///   大小、修改时间；可删除（删完演员库回到未激活）。
/// 没激活时页顶有引导文案；版本字段缺失/对不上的导入失败
/// 原因在本页红字区原样呈现（服务层给的中文原因）。
///
/// 红线：本页不写外置库；导入失败不毁任何现有可用库（服务层
/// 保证）；读库层靠路径+文件戳机制失效旧连接（见
/// actress_db_source.dart 类注释）。
class ActressDbManagePage extends StatefulWidget {
  const ActressDbManagePage({
    super.key,
    this.source,
    this.importService,
    this.siteLibraryService,
    this.onLibraryChanged,
    this.magnetLibrariesLoader,
  });

  /// 来源层（测试注入假件；默认单例）。
  final ActressDbSource? source;

  /// 导入服务（测试注入假件；默认真服务，校验走真探测）。
  final ActressDbImportService? importService;

  /// 磁力分类库列表加载（测试/预览注入假件；默认只读开导入
  /// 库走数据层 listLibraries——flutter test 里 sqflite 跑不
  /// 起来，列表类断言靠这个缝注入）。
  final Future<List<MagnetLibraryRecord>> Function()? magnetLibrariesLoader;

  /// 站点库服务（测试注入假件；默认单例）。与女优库完全独立：
  /// 本页只是共用一个入口，校验器、落点、删除动作都不相干。
  final SiteLibraryService? siteLibraryService;

  /// 库发生变化（导入成功/切换/删除）后调：默认关主库连接并
  /// 强制重读一次，让演员库各读库入口立刻换到新库。测试可注入
  /// 空实现。
  final Future<void> Function()? onLibraryChanged;

  @override
  State<ActressDbManagePage> createState() => _ActressDbManagePageState();
}

class _ActressDbManagePageState extends State<ActressDbManagePage> {
  ActressDbSource get _source => widget.source ?? ActressDbSource.instance;

  late final ActressDbImportService _importService =
      widget.importService ?? ActressDbImportService(source: _source);

  SiteLibraryService get _siteLibrary =>
      widget.siteLibraryService ?? SiteLibraryService.instance;

  ActressDbSourceStatus? _status;
  final _works = <ActressDbSlot, int?>{};
  var _loading = true;
  var _importing = false;
  var _cancelled = false;
  ActressSqlImportProgress? _progress;
  String? _message;
  String? _error;

  /// 已并存导入的磁力分类库（登记在导入库里，删库入口在本页
  /// 磁力区，见 _magnetSection）。
  var _magnetLibraries = const <MagnetLibraryRecord>[];
  var _magnetImporting = false;
  var _magnetDeleting = false;
  ActressSqlImportProgress? _magnetProgress;

  // 统一导入口状态（2026-11-28 统一导入口批）：认库中标记与
  // 统一口自己的汇总结果行；各库的进度/结果状态仍各自保留。
  var _unifiedSniffing = false;
  String? _unifiedMessage;
  String? _unifiedError;

  bool get _anyImporting =>
      _importing || _magnetImporting || _siteImporting || _unifiedSniffing;

  // 站点库区独立状态（与女优库导入互不干扰，可各自跑）。
  var _siteImporting = false;
  var _siteCancelled = false;
  SiteLibraryProgress? _siteProgress;
  String? _siteMessage;
  String? _siteError;
  var _siteLoaded = false;

  @override
  void initState() {
    super.initState();
    _source.revision.addListener(_onRevision);
    _refresh();
    _refreshSite();
  }

  @override
  void dispose() {
    _source.revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) _refresh();
  }

  Future<void> _refresh() async {
    final status = await _source.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
    for (final slot in ActressDbSlot.values) {
      final count = await _source.countWorks(status.infoOf(slot));
      if (!mounted) return;
      setState(() => _works[slot] = count);
    }
    final libraries = await _loadMagnetLibraries();
    if (!mounted) return;
    setState(() => _magnetLibraries = libraries);
  }

  /// 磁力登记列表：只读开导入库取登记；导入库文件不存在就不
  /// 开（开库会把空文件建出来）、读失败按没有处理，不挡管理页。
  Future<List<MagnetLibraryRecord>> _loadMagnetLibraries() async {
    final loader = widget.magnetLibrariesLoader;
    if (loader != null) {
      try {
        return await loader();
      } catch (_) {
        return const [];
      }
    }
    try {
      final importedPath = await _source.importedDbPath();
      if (importedPath.isEmpty) return const [];
      final file = File(importedPath);
      if (!file.existsSync() || file.lengthSync() == 0) return const [];
      final db = await openDatabase(
        importedPath,
        readOnly: true,
        singleInstance: false,
      );
      try {
        return await ActressMagnetLibraryStore().listLibraries(db);
      } finally {
        await db.close();
      }
    } catch (_) {
      return const [];
    }
  }

  Future<void> _notifyLibraryChanged() async {
    final hook = widget.onLibraryChanged;
    if (hook != null) {
      await hook();
      return;
    }
    try {
      await SqfliteActressDatabase.instance.reloadIfChanged(force: true);
    } catch (_) {
      // 重读失败不挡管理页：读库层下次打开会按生效路径再试。
    }
  }

  /// 外置文件导入激活：走导入服务的 .db 同一条链（校验＋版本
  /// 门＋拷入导入库＋落激活记录），外置文件只读不写。
  Future<void> _importExternal() async {
    if (_importing) return;
    setState(() {
      _importing = true;
      _message = null;
      _error = null;
      _progress = null;
    });
    try {
      final outcome = await _importService.importExternalFile(
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
      );
      if (!mounted) return;
      setState(() {
        _importing = false;
        if (outcome.ok) {
          _message = outcome.videos > 0
              ? '外置库导入成功，已激活：${outcome.videos} 部作品'
              : '外置库导入成功，已激活';
          _error = null;
        } else {
          _error = outcome.error ?? '导入失败';
        }
      });
      if (outcome.needsReload) await _notifyLibraryChanged();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _error = '导入失败：${e.toString().split('\n').first}';
      });
    }
  }

  Future<void> _deleteImported() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.surface,
        title: const Text('删除导入库', style: TextStyle(color: Neon.text)),
        content: const Text(
          '删除后演员库回到未激活状态，要重新导入才能用。外置库不受影响（它只是导入来源）。',
          style: TextStyle(color: Neon.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('dual-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: Neon.pink)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _source.deleteImported();
    await _notifyLibraryChanged();
    if (!mounted) return;
    setState(() {
      _message = '导入库已删除，演员库已回到未激活状态';
      _error = null;
    });
    await _refresh();
  }

  /// 统一导入口（2026-11-28 统一导入口批）：全页唯一的导入
  /// 入口。点开选文件页（MYTV/db 全部可导文件＋页尾「选择其他
  /// 文件」），选定后由 [UnifiedImportSniffer] 按内容认库，再
  /// 分发到各自原有的导入尾段（站点/女优/磁力，校验、版本门、
  /// 落位语义一字不改）。原先散在三个区的六个导入按钮已全撤。
  Future<void> _startUnifiedImport() async {
    if (_anyImporting) return;
    final files = await _importService.listMytvDbImportFiles();
    if (!mounted) return;
    final result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute<Object?>(
        builder: (_) => UnifiedImportListPage(files: files),
      ),
    );
    if (!mounted || result == null) return;
    if (result == UnifiedImportListPage.pickOtherFile) {
      await _pickOtherFileForUnifiedImport();
      return;
    }
    final file = result as ({String name, String path, int sizeBytes});
    await _runUnifiedImport(
      path: file.path,
      sourceName: file.name,
      deleteAfter: false,
    );
  }

  /// 统一口里的次要方式：系统选择器选其他位置的文件（只适合
  /// 小文件；大文件走 MYTV/db 直读）。选中先拷进收件文件再认
  /// 库分发，导完删收件副本。
  Future<void> _pickOtherFileForUnifiedImport() async {
    if (_anyImporting) return;
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '数据库文件', extensions: ['db', 'sql', 'gz']),
      ],
    );
    if (picked == null || !mounted) return;
    File inbox;
    try {
      inbox = await _importService.inboxFileFor(picked.name);
      final sink = inbox.openWrite();
      try {
        await sink.addStream(picked.openRead());
      } finally {
        await sink.close();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _unifiedError = '导入失败：${e.toString().split('\n').first}';
        _unifiedMessage = null;
      });
      return;
    }
    await _runUnifiedImport(
      path: inbox.path,
      sourceName: picked.name,
      deleteAfter: true,
    );
  }

  /// 认库＋分发：认出哪种库就调哪种库原有的导入尾段；认不出
  /// 给中文提示、不瞎导。分发结果汇总到统一口一行（带库名），
  /// 各区自己的结果文案照旧显示。
  Future<void> _runUnifiedImport({
    required String path,
    required String sourceName,
    required bool deleteAfter,
  }) async {
    if (_importing || _magnetImporting || _siteImporting) return;
    setState(() {
      _unifiedSniffing = true;
      _unifiedMessage = null;
      _unifiedError = null;
    });
    final kind = await UnifiedImportSniffer.sniff(path);
    if (!mounted) return;
    setState(() => _unifiedSniffing = false);
    switch (kind) {
      case UnifiedImportKind.bundle:
      case UnifiedImportKind.siteLibrary:
        setState(() => _unifiedMessage = '已认出是${kind.labelZh}，正在导入…');
        await _runSiteImport(File(path), deleteAfter: deleteAfter);
        _mirrorUnifiedResult(kind);
      case UnifiedImportKind.actressDb:
      case UnifiedImportKind.actressSql:
        setState(() => _unifiedMessage = '已认出是${kind.labelZh}，正在导入…');
        await _runActressImport(path, deleteAfter: deleteAfter);
        _mirrorUnifiedResult(kind);
      case UnifiedImportKind.magnetSql:
        setState(() => _unifiedMessage = '已认出是${kind.labelZh}，正在导入…');
        await _runMagnetImport(
          path,
          sourceName: sourceName,
          deleteAfter: deleteAfter,
        );
        _mirrorUnifiedResult(kind);
      case UnifiedImportKind.unknown:
        if (deleteAfter) {
          try {
            final file = File(path);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
        setState(() {
          _unifiedMessage = null;
          _unifiedError =
              '这份文件认不出是什么库（不是站点库、女优库、'
              '磁力库，也不是三库合并文件），没有导入。'
              '请确认文件没下错、没下坏。';
        });
    }
  }

  /// 把各库尾段的结果汇总到统一口一行（成功/失败都带库名）。
  void _mirrorUnifiedResult(UnifiedImportKind kind) {
    if (!mounted) return;
    final isSite =
        kind == UnifiedImportKind.bundle ||
        kind == UnifiedImportKind.siteLibrary;
    final message = isSite ? _siteMessage : _message;
    final error = isSite ? _siteError : _error;
    setState(() {
      if (error != null) {
        _unifiedMessage = null;
        _unifiedError = '${kind.labelZh}：$error';
      } else if (message != null) {
        _unifiedMessage = '${kind.labelZh}：$message';
        _unifiedError = null;
      }
    });
  }

  /// 女优库导入共用尾段：进度、结果回报、成功后重读。
  /// [deleteAfter] 只对收件副本为真；MYTV/db 源文件一字不动。
  Future<void> _runActressImport(
    String localPath, {
    required bool deleteAfter,
  }) async {
    setState(() {
      _importing = true;
      _cancelled = false;
      _message = null;
      _error = null;
      _progress = null;
    });
    try {
      final outcome = await _importService.importLocalFile(
        localPath: localPath,
        closeDatabase: () => SqfliteActressDatabase.instance.close(),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      setState(() {
        _importing = false;
        _progress = null;
        if (outcome.ok) {
          _message = outcome.videos > 0
              ? '导入成功，已激活：${outcome.videos} 部作品'
                    '${outcome.warnings.isEmpty ? '' : '\n${outcome.warnings.join('\n')}'}'
              : '导入成功，已激活';
          _error = null;
        } else {
          _error = outcome.error ?? '导入失败';
        }
      });
      if (outcome.needsReload) await _notifyLibraryChanged();
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _progress = null;
        _error = '导入失败：${e.toString().split('\n').first}';
      });
    } finally {
      if (deleteAfter) {
        try {
          final inbox = File(localPath);
          if (await inbox.exists()) await inbox.delete();
        } catch (_) {}
      }
    }
  }

  /// 空目标库的标准表 DDL（与 actress_sql_import.dart 的
  /// _standardTableDdl 逐字一致）：导入槽为空时先建一本只有
  /// 标准空表的目标库再合并，was_existing 全 0 起步（施工图
  /// §1 口径）。数据层未提供建空库动作，这里在管理页侧凑齐。
  static const _emptyTargetDdl = <String>[
    'CREATE TABLE videos (vod_id TEXT PRIMARY KEY, title TEXT, pic_url TEXT, m3u8_url TEXT, vod_remarks TEXT, vod_pubdate TEXT, vod_area TEXT, vod_year TEXT, vod_content TEXT, vod_play_from TEXT, vod_play_url TEXT, type_name TEXT, created_at TEXT)',
    'CREATE TABLE actresses (cate_id TEXT PRIMARY KEY, name TEXT, avatar TEXT, created_at TEXT, sex TEXT, roster_id TEXT, claimed INTEGER)',
    'CREATE TABLE video_actress (vod_id TEXT, cate_id TEXT, PRIMARY KEY (vod_id, cate_id))',
    'CREATE TABLE video_play_urls (vod_id TEXT, play_url TEXT, play_from TEXT, PRIMARY KEY (vod_id, play_url))',
    'CREATE TABLE video_category (vod_id TEXT PRIMARY KEY, main_category TEXT)',
    'CREATE TABLE video_tag (vod_id TEXT, tag_name TEXT, PRIMARY KEY (vod_id, tag_name))',
  ];

  /// 打开导入库作磁力合并/删库的目标连接：文件不存在时先建
  /// 空目标库（标准空表 + 磁力登记表）。合并会改文件，先关主
  /// 库连接，免得两条连接同写一本库。
  Future<Database> _openMagnetTarget() async {
    final importedPath = await _source.importedDbPath();
    final file = File(importedPath);
    final existed = file.existsSync() && file.lengthSync() > 0;
    if (!existed) {
      await file.parent.create(recursive: true);
    }
    try {
      await SqfliteActressDatabase.instance.close();
    } catch (_) {
      // 主库连接没开着：关失败不挡合并。
    }
    final db = await openDatabase(importedPath, singleInstance: false);
    if (!existed) {
      for (final ddl in _emptyTargetDdl) {
        await db.execute(ddl);
      }
    }
    await ActressMagnetLibraryStore.ensureSchema(db);
    return db;
  }

  /// 磁力分类库的导入入口已并入页面上方统一导入口（2026-11-28
  /// 统一导入口批）：选文件后软件按内容认出磁力库、调下面这条
  /// 共用尾段；本区只留已导入列表与删除。

  /// 磁力分类库导入共用尾段：落归一化临时库 → 非磁力整单拒 →
  /// 合并进导入库。[deleteAfter] 只对收件副本为真；MYTV/db 源
  /// 文件一字不动。调用方负责先把 _magnetImporting 置真（MYTV/db
  /// 路在弹窗选完后置真）。
  Future<void> _runMagnetImport(
    String localPath, {
    required String sourceName,
    required bool deleteAfter,
  }) async {
    setState(() {
      _magnetImporting = true;
      _magnetProgress = null;
      _message = null;
      _error = null;
    });
    String? stagingPath;
    try {
      // 临时库与目标库同目录（数据层缺省口径）；目录先建好，
      // 免得导入器往不存在的目录落临时文件。
      final importedPath = await _source.importedDbPath();
      if (importedPath.isEmpty) {
        throw StateError('导入库路径不可用，没法导入磁力分类库');
      }
      await File(importedPath).parent.create(recursive: true);
      stagingPath = magnetStagingPathFor(importedPath);
      final staging = await buildMagnetStagingDb(
        localPath,
        stagingPath: stagingPath,
        onProgress: (progress) {
          if (mounted) setState(() => _magnetProgress = progress);
        },
      );
      if (!staging.ok) {
        throw StateError(staging.error ?? '文件校验没通过');
      }
      // 非磁力整单拒（先验在开目标库之前：被拒时不建空目标
      // 库、目标库一字不动）；合并内部还有同一道尺兜底。
      if (!await ActressMagnetLibraryStore.stagingIsMagnetLibrary(
        stagingPath,
      )) {
        throw StateError('这个文件里没有磁力链接，不是磁力分类库；整库数据库请用上面的「导入数据库」');
      }
      final db = await _openMagnetTarget();
      MagnetImportOutcome outcome;
      try {
        outcome = await ActressMagnetLibraryStore().mergeStaging(
          db,
          stagingPath,
          sourceName: sourceName,
        );
      } finally {
        await db.close();
      }
      if (!outcome.ok) {
        throw StateError(outcome.error ?? '导入失败');
      }
      _source.notifyChanged();
      await _notifyLibraryChanged();
      if (!mounted) return;
      setState(() {
        _magnetImporting = false;
        _magnetProgress = null;
        _message = _magnetImportResultText(outcome);
        _error = null;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _magnetImporting = false;
        _magnetProgress = null;
        _error = '磁力分类库导入失败：${e.toString().split('\n').first}';
      });
    } finally {
      if (deleteAfter) {
        try {
          final inbox = File(localPath);
          if (await inbox.exists()) await inbox.delete();
        } catch (_) {}
      }
      // 临时库四件残件一并清（与数据层导入器的清理口径一致）。
      if (stagingPath != null) {
        for (final suffix in ['', '.bak', '-wal', '-journal']) {
          try {
            final staging = File('$stagingPath$suffix');
            if (await staging.exists()) await staging.delete();
          } catch (_) {}
        }
      }
    }
  }

  String _magnetImportResultText(MagnetImportOutcome outcome) {
    final String text;
    if (outcome.categories.length > 1) {
      text =
          '已导入 ${outcome.categories.length} 个分类'
          '（${outcome.categories.join('、')}）：'
          '新增 ${outcome.addedWorks} 部作品'
          '（共收录 ${outcome.totalWorks} 部）';
    } else if (outcome.category.isNotEmpty) {
      text =
          '已导入分类「${outcome.category}」：'
          '新增 ${outcome.addedWorks} 部作品'
          '（这个分类共 ${outcome.totalWorks} 部）';
    } else {
      text = '已导入磁力分类库：新增 ${outcome.addedWorks} 部作品';
    }
    return outcome.replaced ? '$text；同名分类已更新为这一版' : text;
  }

  /// 删一个磁力分类库：确认弹窗 → removeLibrary → 按现行管理
  /// 页口径刷新（notifyChanged + 重读 + _refresh）。
  Future<void> _deleteMagnetLibrary(MagnetLibraryRecord record) async {
    if (_importing || _magnetImporting || _magnetDeleting) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.surface,
        title: Text(
          '删除分类库「${record.category}」？',
          style: const TextStyle(color: Neon.text),
        ),
        content: const Text(
          '删完演员库分类栏里就没有这个分类了，它独有的作品也会消失；'
          '女优库原有的作品一条都不动。',
          style: TextStyle(color: Neon.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('magnet-library-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: Neon.pink)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _magnetDeleting = true);
    try {
      final importedPath = await _source.importedDbPath();
      if (importedPath.isEmpty || !File(importedPath).existsSync()) {
        throw StateError('导入库不存在');
      }
      try {
        await SqfliteActressDatabase.instance.close();
      } catch (_) {}
      final db = await openDatabase(importedPath, singleInstance: false);
      MagnetRemoveResult result;
      try {
        result = await ActressMagnetLibraryStore().removeLibrary(db, record.id);
      } finally {
        await db.close();
      }
      _source.notifyChanged();
      await _notifyLibraryChanged();
      if (!mounted) return;
      setState(() {
        _magnetDeleting = false;
        _message =
            '已删除分类库「${record.category}」：'
            '带走了 ${result.removedWorks} 部它独有的作品';
        _error = null;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _magnetDeleting = false;
        _error = '删除失败：${e.toString().split('\n').first}';
      });
    }
  }

  Future<void> _refreshSite() async {
    try {
      await _siteLibrary.load();
    } catch (_) {
      // 读不到就按未导入显示，不挡女优库那半页。
    }
    if (!mounted) return;
    setState(() => _siteLoaded = true);
  }

  /// 导入成功/删除后通知注册链对账 SQL 站。syncSqlSites 由注册链
  /// 批提供；本页先落时该方法可能还不存在，用 dynamic 调用、
  /// 缺失/失败都静默（注册链启动时也会自己对账一次）。
  Future<void> _syncSqlSites() async {
    try {
      await (SourceRegistry.instance as dynamic).syncSqlSites();
    } catch (_) {}
  }

  /// 站点库的导入入口已并入页面上方统一导入口（2026-11-28
  /// 统一导入口批）：选文件后软件按内容认出站点库/合并文件、
  /// 调下面这条共用尾段；本区只留状态与删除。

  /// 站点库导入共用尾段：进度、逐段回报、成功后注册链对账。
  /// [deleteAfter] 只对收件副本为真；MYTV/db 源文件一字不动。
  Future<void> _runSiteImport(File file, {required bool deleteAfter}) async {
    setState(() {
      _siteImporting = true;
      _siteCancelled = false;
      _siteMessage = null;
      _siteError = null;
      _siteProgress = null;
    });
    try {
      final outcome = await _siteLibrary.importLocalFile(
        localPath: file.path,
        onProgress: (progress) {
          if (mounted) setState(() => _siteProgress = progress);
        },
        isCancelled: () => _siteCancelled,
      );
      if (!mounted) return;
      setState(() {
        _siteImporting = false;
        _siteProgress = null;
        if (outcome.segmentResults.isNotEmpty) {
          // 合并文件：逐段回报（成功段计数、拒收段中文原因）。
          final lines = [
            for (final r in outcome.segmentResults)
              r.ok
                  ? '${r.segmentLabel}导入成功：${r.detail ?? ''}'
                  : '${r.segmentLabel}未导入：${r.error ?? '未知原因'}',
          ];
          if (outcome.ok) {
            _siteMessage = lines.join('\n');
            _siteError = null;
          } else {
            _siteError = lines.join('\n');
          }
        } else if (outcome.ok) {
          _siteMessage =
              '站点库导入成功：${outcome.stationCount} 个站'
              '${outcome.libraryVersion == null ? '' : '（版本 ${outcome.libraryVersion}）'}';
          _siteError = null;
        } else {
          _siteError = outcome.error ?? '导入失败';
        }
      });
      if (outcome.ok) await _syncSqlSites();
      await _refreshSite();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _siteImporting = false;
        _siteProgress = null;
        _siteError = '导入失败：${e.toString().split('\n').first}';
      });
    } finally {
      if (deleteAfter) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteSiteLibrary() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Neon.surface,
        title: const Text('删除站点库', style: TextStyle(color: Neon.text)),
        content: const Text(
          '删除后站点回到只有名单、点不开的状态（名单态），'
          '要再用得重新导入站点库。女优库不受任何影响。',
          style: TextStyle(color: Neon.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            key: const ValueKey('site-delete-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除', style: TextStyle(color: Neon.pink)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _siteLibrary.deleteLibrary();
    await _syncSqlSites();
    if (!mounted) return;
    setState(() {
      _siteMessage = '站点库已删除，已回到名单态';
      _siteError = null;
    });
    await _refreshSite();
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      backgroundColor: Neon.bg,
      appBar: AppBar(
        backgroundColor: Neon.bg,
        foregroundColor: Neon.text,
        title: const Text('数据库管理', style: TextStyle(fontSize: 17)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            _importSection(),
            const SizedBox(height: 12),
            _siteLibrarySection(),
            if (_message != null) ...[
              const SizedBox(height: 10),
              Text(
                _message!,
                key: const ValueKey('dual-message'),
                style: const TextStyle(color: Neon.cyan, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('dual-error'),
                style: const TextStyle(color: Neon.pink, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            if (_loading || status == null)
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Center(
                  child: Text(
                    '正在读取数据库状态…',
                    style: TextStyle(color: Neon.textDim),
                  ),
                ),
              )
            else ...[
              if (!status.activated) ...[
                Container(
                  key: const ValueKey('activation-guide'),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Neon.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Neon.pink.withValues(alpha: .55)),
                  ),
                  child: const Text(
                    '演员库还没激活：导入一个带版本字段的女优库（.db / .sql）'
                    '完成激活后才能用；外置库里的文件放着不生效，'
                    '可以在下面外置库卡上点「导入激活」。',
                    style: TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              _slotCard(
                slot: ActressDbSlot.external,
                title: '外置库（导入来源）',
                subtitle: 'MYTV/db/女优库.db（放着不生效，点导入激活才用；只读，不会被改动）',
                status: status,
              ),
              const SizedBox(height: 12),
              _slotCard(
                slot: ActressDbSlot.imported,
                title: '导入库（已激活）',
                subtitle: '通过本页导入激活的 .db / .sql 落成的库',
                status: status,
              ),
            ],
            const SizedBox(height: 12),
            _magnetSection(),
          ],
        ),
      ),
    );
  }

  /// 磁力分类库区：并存导入入口 + 已导入列表（分类 + 部数 ·
  /// 来源）+ 逐个删除。登记落在导入库里，导入库不存在时列表
  /// 为空、导入会先建空目标库（见 _openMagnetTarget）。
  Widget _magnetSection() {
    return Container(
      key: const ValueKey('magnet-library-section'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.violet.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '磁力分类库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '磁力 .db / .sql 并存导入到导入库：只往里加、不覆盖，已有'
            '作品一条不动；分类按文件里的分类字段逐个登记。导入后演'
            '员库分类栏会多出这些分类，磁力作品走 115 网盘离线播放。'
            '导入用页面上方唯一的「导入数据库」入口，选文件后软件会'
            '自动认出磁力库；导入进度也在上方入口里看。',
            style: TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          const SizedBox(height: 6),
          if (_magnetLibraries.isEmpty)
            const Text(
              '还没有导入过磁力分类库。',
              key: ValueKey('magnet-library-empty'),
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            )
          else
            for (final record in _magnetLibraries)
              ListTile(
                key: ValueKey('magnet-library-${record.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.cloud_outlined,
                  color: Neon.textDim,
                  size: 20,
                ),
                title: Text(
                  record.category,
                  style: const TextStyle(color: Neon.text, fontSize: 13.5),
                ),
                subtitle: Text(
                  '${record.workCount} 部 · 来源 ${record.sourceName}',
                  style: const TextStyle(color: Neon.textFaint, fontSize: 11.5),
                ),
                trailing: IconButton(
                  key: ValueKey('magnet-library-delete-${record.id}'),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Neon.textDim,
                  tooltip: '删除这个分类库',
                  onPressed: _magnetDeleting || _magnetImporting
                      ? null
                      : () => _deleteMagnetLibrary(record),
                ),
              ),
        ],
      ),
    );
  }

  /// 统一导入区（2026-11-28 统一导入口批）：全页唯一的导入
  /// 入口区块。一个按钮点开选文件页，认库分发在软件里完成；
  /// 三个库的导入进度与汇总结果都显示在这一个口里。
  Widget _importSection() {
    return Container(
      key: const ValueKey('unified-import-section'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.violet.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导入数据库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '所有库都从这一个口导入：把文件放进 MYTV/db，点下面按钮选文件，'
            '软件会按文件内容自动认出是站点库、女优库、磁力库还是三库合并文件，'
            '分别走各自的导入（校验和版本门照旧，导入失败时现有库原样不动）。'
            '文件不在 MYTV/db 里的小文件，在选文件页里点「选择其他文件」。',
            style: TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (_unifiedMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _unifiedMessage!,
              key: const ValueKey('unified-import-result'),
              style: const TextStyle(color: Neon.cyan, fontSize: 13),
            ),
          ],
          if (_unifiedError != null) ...[
            const SizedBox(height: 8),
            Text(
              _unifiedError!,
              key: const ValueKey('unified-import-error'),
              style: const TextStyle(color: Neon.pink, fontSize: 13),
            ),
          ],
          if (_unifiedSniffing) ...[
            const SizedBox(height: 10),
            const LinearProgressIndicator(
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            const Text(
              '正在认这份文件是什么库…',
              key: ValueKey('unified-import-sniffing'),
              style: TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ] else if (_importing) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: (_progress?.fraction ?? 0).clamp(0, 1),
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _progress == null
                        ? '正在导入女优库…'
                        : '${_progress!.phase}…已处理 ${_progress!.statements} 条',
                    style: const TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ),
                TextButton(
                  key: const ValueKey('dual-import-cancel'),
                  onPressed: () => _cancelled = true,
                  child: const Text('取消'),
                ),
              ],
            ),
          ] else if (_siteImporting) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: (_siteProgress?.fraction ?? 0).clamp(0, 1),
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _siteProgress == null
                        ? '正在导入站点库…'
                        : '${_siteProgress!.phase}…已处理 ${_siteProgress!.statements} 条',
                    style: const TextStyle(color: Neon.textDim, fontSize: 12),
                  ),
                ),
                TextButton(
                  key: const ValueKey('site-import-cancel'),
                  onPressed: () => _siteCancelled = true,
                  child: const Text('取消'),
                ),
              ],
            ),
          ] else if (_magnetImporting) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: _magnetProgress == null
                  ? null
                  : (_magnetProgress!.fraction).clamp(0, 1),
              color: Neon.cyan,
              backgroundColor: Neon.surfaceHigh,
            ),
            const SizedBox(height: 6),
            Text(
              _magnetProgress == null
                  ? '正在导入磁力库…'
                  : '正在导入磁力库…已处理 '
                        '${_magnetProgress!.statements} 条'
                        '（${(_magnetProgress!.fraction * 100).toStringAsFixed(0)}%）',
              key: const ValueKey('magnet-import-progress'),
              style: const TextStyle(color: Neon.textDim, fontSize: 12),
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('dual-import-button'),
                onPressed: _startUnifiedImport,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('从 MYTV/db 导入'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _siteLibrarySection() {
    final service = _siteLibrary;
    final imported = _siteLoaded && service.imported;
    final rejection = _siteLoaded ? service.loadRejectionReason : null;
    final statusText = !_siteLoaded
        ? '正在读取站点库状态…'
        : rejection != null
        ? '版本不符，未激活：$rejection'
        : imported
        ? '已导入 · 版本 ${service.libraryVersion ?? '未知'}'
              ' · ${service.stations.length} 个站'
              ' · 大小 ${_formatSize(service.libraryFileSizeBytes)}'
        : '未导入（名单态：站点只有名字，点不开）';
    return Container(
      key: const ValueKey('site-library-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Neon.violet.withValues(alpha: .45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '站点库',
            style: TextStyle(
              color: Neon.text,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '站点的代码装在独立的「站点库」里，导入后才能用；'
            '没导入时站点列表只有名单。与女优库互不影响。'
            '导入用页面上方唯一的「导入数据库」入口，选文件后软件会'
            '自动认出站点库；导入进度也在上方入口里看。',
            style: TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            '状态：$statusText',
            key: const ValueKey('site-library-status'),
            style: TextStyle(
              color: rejection != null ? Neon.pink : Neon.textDim,
              fontSize: 12,
            ),
          ),
          if (_siteMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _siteMessage!,
              key: const ValueKey('site-message'),
              style: const TextStyle(color: Neon.cyan, fontSize: 13),
            ),
          ],
          if (_siteError != null) ...[
            const SizedBox(height: 8),
            Text(
              _siteError!,
              key: const ValueKey('site-error'),
              style: const TextStyle(color: Neon.pink, fontSize: 13),
            ),
          ],
          if (imported && !_siteImporting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                key: const ValueKey('site-delete'),
                onPressed: _deleteSiteLibrary,
                child: const Text('删除站点库', style: TextStyle(color: Neon.pink)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _slotCard({
    required ActressDbSlot slot,
    required String title,
    required String subtitle,
    required ActressDbSourceStatus status,
  }) {
    final info = status.infoOf(slot);
    final isCurrent = status.isEffective(slot);
    final works = _works[slot];
    return Container(
      key: ValueKey('dual-card-${slot.wire}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Neon.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? Neon.cyan.withValues(alpha: .7)
              : Neon.violet.withValues(alpha: .45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.storage_rounded, color: Neon.textDim, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Neon.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (isCurrent)
                Container(
                  key: ValueKey('dual-current-${slot.wire}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Neon.cyan.withValues(alpha: .18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '当前使用中',
                    style: TextStyle(color: Neon.cyan, fontSize: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(color: Neon.textFaint, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(
            '状态：${info.statusText}'
            ' · 作品数：${works ?? '—'}'
            ' · 大小：${info.exists ? _formatSize(info.sizeBytes) : '—'}'
            ' · 修改时间：${info.modified == null ? '—' : _formatTime(info.modified!)}',
            style: const TextStyle(color: Neon.textDim, fontSize: 12),
          ),
          if (slot == ActressDbSlot.imported) ...[
            const SizedBox(height: 4),
            Text(
              status.activated
                  ? '激活：已激活 · ${status.activation!.describe}'
                  : '激活：未激活（导入成功后自动激活）',
              key: const ValueKey('dual-activation-line'),
              style: TextStyle(
                color: status.activated ? Neon.cyan : Neon.textDim,
                fontSize: 12,
              ),
            ),
          ],
          if (slot == ActressDbSlot.external && info.exists) ...[
            const SizedBox(height: 4),
            const Text(
              '这个文件只是导入来源：放着不会生效，点下面「导入激活」才会校验版本并拷进导入库。',
              style: TextStyle(color: Neon.textFaint, fontSize: 11),
            ),
          ],
          if (info.dbPath.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              info.dbPath,
              style: const TextStyle(color: Neon.textFaint, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              if (slot == ActressDbSlot.external && info.exists)
                OutlinedButton(
                  key: const ValueKey('dual-import-external'),
                  onPressed: _importing ? null : _importExternal,
                  child: const Text('导入激活'),
                ),
              if (slot == ActressDbSlot.imported && info.exists)
                OutlinedButton(
                  key: const ValueKey('dual-delete-imported'),
                  onPressed: _deleteImported,
                  child: const Text(
                    '删除导入库',
                    style: TextStyle(color: Neon.pink),
                  ),
                ),
              if (slot == ActressDbSlot.external && Platform.isAndroid) ...[
                OutlinedButton(
                  key: const ValueKey('dual-grant-folder'),
                  onPressed: () async {
                    final granted = await ActressMytvBind.instance
                        .grantFolderAccess();
                    if (!mounted) return;
                    setState(() {
                      _message = granted
                          ? '已取得文件夹授权，正在重新读取'
                          : '没有选择文件夹，或系统选择器打不开';
                      _error = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(refresh: true);
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权文件夹读取'),
                ),
                OutlinedButton(
                  key: const ValueKey('dual-grant-file'),
                  onPressed: () async {
                    final granted = await ActressMytvBind.instance
                        .grantFileAccess();
                    if (!mounted) return;
                    setState(() {
                      _message = granted
                          ? '已取得文件授权，正在重新读取'
                          : '没有选择文件，或系统选择器打不开';
                      _error = null;
                    });
                    if (granted) {
                      await ActressMytvBind.instance.ensureBound(refresh: true);
                      await _notifyLibraryChanged();
                    }
                    await _refresh();
                  },
                  child: const Text('授权单个数据库文件'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}
