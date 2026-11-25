import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 女优库绑定手机根目录下的 MYTV 文件夹（2026-11-20 用户令）。
///
/// 落点（2026-11-22 用户令最终口径：只读外置数据库，不内置任何
/// 数据库与 JSON 种子）：
/// - `MYTV/db/女优库.db`：唯一数据库。用户发来的视频结构库
///   （videos / video_actress / actresses 表），有就用它；
///   没有就是空库，界面如实提示放入、点“重新加载数据库”再读，
///   不回落任何内置库、不悄悄造数据。
/// - 应用库 `女优库应用.db` 已删除：包里不再带它，加载链里也不再
///   回落到它；老库 `documents/actress.db` 也不再是回退落点。
///   旧版迁移（老库拷进应用库）随之作废。
/// - `MYTV/db/mjv011.json`：本地 json 影子文件（现爬写盘入口，
///   与原来 documents/actress_json/mjv011.json 同一口径）。
/// - `MYTV/m3u/`：用户自己放 m3u 文件的地方（女优合集1.m3u～
///   9.m3u 这种），m3u 兜底先读这里。
///
/// 权限与降级（targetSdk 36）：直接写根目录要“所有文件访问权限”
/// （MANAGE_EXTERNAL_STORAGE）。没拿到权限时不硬写、不崩——
/// 绑定失败，女优库显示空态、给去设置的入口；用户授权后点
/// “重新绑定”再试一次。
///
/// 鸿蒙 NEXT（卓易通容器）：外部存储实际路径可能与原生安卓不同，
/// 根目录解析不到、或建目录失败时一律优雅降级，不在本机上假装
/// 验过——手机待验清单见 REPORT.md。
///
/// 本模块只算路径、建目录，不碰界面、不直接开库：
/// 真正开库的是 [SqfliteActressDatabase._openNow]，它第一次开库
/// 前调 [ensureBound] 拿路径；列表页在 bootstrap 里先调一次，
/// 为的是提前拿到结果显示绑定行、给 json/m3u 指目录。

/// MYTV 文件夹名（手机根目录下）。
const mytvFolderName = 'MYTV';

/// MYTV 下的两个子文件夹。
const mytvDbFolderName = 'db';
const mytvM3uFolderName = 'm3u';

/// 涩库引擎（py 的 SikuEngine.DB_DIRS）同款补充扫描目录：手机根
/// 目录下这 4 个目录里的 .db 都当女优库源读（递归扫，与 py 的
/// os.walk 一致）。MYTV/db 仍是主目录（绑定落点），这 4 个是
/// 补充——2026-11-21 用户令按 py 逻辑读库、改路径。
const sikuDbScanDirs = ['纯福利/db', '女优库', '私藏视频', 'lz/db'];

/// MYTV/db 里的唯一数据库文件名（2026-11-22 用户令最终口径）：
/// `女优库.db` 是用户发来的视频结构库（videos / video_actress /
/// actresses 表），女优库只读它。应用自己的 persons / works 表
/// 库 `女优库应用.db` 已删除，不再是落点、不再回落。
const mytvVideoDbFileName = '女优库.db';

/// 老 json 影子文件目录名（documents 下）。
const legacyJsonDirName = 'actress_json';

/// MYTV 根目录下的合并 JSON 导出落点（不碰 MYTV/db 里正在用的
/// 影子文件，导出只写这一份，用户拷走即用）。
const mytvMergedJsonFileName = 'mjv011.json';

/// 外部存储根目录解析：默认先走平台通道拿真根目录，拿不到再从
/// getExternalStorageDirectory 的应用专属目录往上推（去
/// `/Android/data/<包名>/files` 后缀）；两条路都走不通回 null，
/// 调用方按未绑定处理。
typedef MytvExternalRootResolver = Future<Directory?> Function();

/// “所有文件访问权限”是否已授予。
typedef MytvAllFilesAccessChecker = Future<bool> Function();

/// 打开系统“所有文件访问权限”设置页。
typedef MytvAllFilesSettingsOpener = Future<void> Function();

/// documents 目录解析。
typedef MytvDocumentsResolver = Future<Directory> Function();

/// 一次绑定解析的结果：列表页显示绑定行、给 json/m3u 指目录、
/// 导出合并 JSON 落点都用它。
class MytvBindResult {
  const MytvBindResult({
    required this.bound,
    required this.needsPermission,
    required this.root,
    this.externalRoot,
    required this.dbDir,
    required this.m3uDir,
    required this.jsonDir,
    required this.dbPath,
    required this.hasVideoDb,
    required this.displayPath,
    required this.mergedJsonExportPath,
    this.note,
  });

  /// true = MYTV 可用，json 与 m3u 都走 MYTV；false = 未绑定
  /// （原因见 [note]），女优库显示空态。
  final bool bound;

  /// true = 没拿到所有文件访问权限，用户去设置授权后点
  /// “重新绑定”可再试一次。
  final bool needsPermission;

  /// MYTV 根目录（未绑定时是 documents 目录，仅作展示与
  /// 导出路径拼接用）。
  final Directory root;

  /// 外部存储根目录（/storage/emulated/0，绑定成功时才有）：
  /// 补充扫描目录（[sikuDbScanDirs]）从这里拼。未绑定时为 null，
  /// 镜像只扫主目录。
  final Directory? externalRoot;

  /// 库目录：MYTV/db 或 documents。
  final Directory dbDir;

  /// m3u 目录：MYTV/m3u 或 documents。
  final Directory m3uDir;

  /// json 影子文件目录：MYTV/db 或 documents/actress_json。
  final Directory jsonDir;

  /// 实际开库路径：MYTV/db/女优库.db；未找到外置库时为空字符串，
  /// 开库方按“没有外置数据库”处理（不回落任何内置库）。
  final String dbPath;

  /// true = MYTV/db/女优库.db 存在且非空，女优库读它；
  /// false = 没有外置库，界面显示空态提示。
  final bool hasVideoDb;

  /// 界面显示的库落点：'MYTV/db/女优库.db'，或未找到时
  /// '未找到外置数据库'。
  final String displayPath;

  /// 合并 JSON 导出落点：MYTV/mjv011.json（只在 bound 时用）。
  final String mergedJsonExportPath;

  /// 未绑定 / 未找到外置库的原因（给界面提示用）；正常时为空。
  final String? note;
}

/// MYTV 绑定解析：路径、建目录。
///
/// 平台调用全部包在 try/catch 里：测试环境没有平台通道、
/// 鸿蒙容器路径与原生不同，任何一步拿不到都按未绑定处理，
/// 绝不抛错。
class ActressMytvBind {
  ActressMytvBind({
    MytvExternalRootResolver? externalRoot,
    MytvAllFilesAccessChecker? hasAllFilesAccess,
    MytvAllFilesSettingsOpener? requestAllFilesAccess,
    MytvDocumentsResolver? documentsDir,
  }) : _externalRoot = externalRoot ?? _defaultExternalRoot,
       _hasAllFilesAccess = hasAllFilesAccess ?? _defaultHasAllFilesAccess,
       _requestAllFilesAccess =
           requestAllFilesAccess ?? _defaultRequestAllFilesAccess,
       _documentsDir = documentsDir ?? _defaultDocumentsDir;

  static final instance = ActressMytvBind._();

  ActressMytvBind._()
    : _externalRoot = _defaultExternalRoot,
      _hasAllFilesAccess = _defaultHasAllFilesAccess,
      _requestAllFilesAccess = _defaultRequestAllFilesAccess,
      _documentsDir = _defaultDocumentsDir;

  static const _deviceChannel = MethodChannel('moyi/device');

  final MytvExternalRootResolver _externalRoot;
  final MytvAllFilesAccessChecker _hasAllFilesAccess;
  final MytvAllFilesSettingsOpener _requestAllFilesAccess;
  final MytvDocumentsResolver _documentsDir;

  MytvBindResult? _cached;
  Future<MytvBindResult>? _pending;

  /// 上次解析结果（首次解析前为空）。
  MytvBindResult? get current => _cached;

  /// 解析一次绑定（结果缓存，并发调用共用同一份）。
  /// [refresh] 为 true 时重新解析（授权后重新绑定、手动“重新加载
  /// 数据库”时用：新放进 MYTV/db 的女优库.db 只有重解析才看得到）。
  Future<MytvBindResult> ensureBound({bool refresh = false}) {
    if (!refresh && _cached != null) return Future.value(_cached);
    var pending = _pending;
    if (!refresh && pending != null) return pending;
    pending = _resolve();
    _pending = pending;
    return pending.then((result) {
      _cached = result;
      _pending = null;
      return result;
    });
  }

  /// 启动时自动生成 MYTV/db 与 MYTV/m3u（2026-11-24 用户令）：
  /// 以前只在进演员库时才调 ensureBound 顺带建目录，不进演员库
  /// 文件夹就一直没有；现在启动先建一次。任何失败自己吞掉，
  /// 不阻塞启动、不抛错（没权限时等用户授权后点“重新绑定”再建）。
  /// [bind] 仅供测试注入，正常调用传空、用单例。
  static Future<void> ensureFoldersAtStartup([
    ActressMytvBind? bind,
  ]) async {
    try {
      await (bind ?? instance).ensureBound();
    } catch (_) {}
  }

  /// 打开系统“所有文件访问权限”设置页（走平台通道；打不开
  /// 也不抛错，列表页只弹提示）。
  Future<void> requestPermission() async {
    try {
      await _requestAllFilesAccess();
    } catch (_) {
      // 打不开设置页也不崩：用户手动去设置里找也行。
    }
  }

  static Future<Directory> _defaultDocumentsDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      // 测试环境没有平台通道：用系统临时目录兜底，路径只作
      // 展示与拼接，不会在这里真开库（测试都注入内存库）。
      return Directory.systemTemp;
    }
  }

  static Future<Directory?> _defaultExternalRoot() async {
    // 1）平台通道拿真根目录（MainActivity 的 moyi/device 通道）。
    // 平台通道调用一律 5 秒超时：鸿蒙卓易通容器里通道迟迟不回时，
    // 开库链（直播首屏、女优库）不能跟着无限等，超时走下面的推导。
    try {
      final root = await _deviceChannel
          .invokeMethod<String>('externalStorageRoot')
          .timeout(const Duration(seconds: 5));
      if (root != null && root.isNotEmpty) {
        final dir = Directory(root);
        if (dir.existsSync()) return dir;
      }
    } catch (_) {
      // 通道没有/旧包没实现：走下面的推导。
    }
    // 2）从应用专属目录往上推：/storage/emulated/0/Android/data/
    // <包名>/files → /storage/emulated/0。鸿蒙卓易通容器里这条
    // 路径可能没有 /Android/data/ 标记，推导失败回 null 降级。
    try {
      final ext = await getExternalStorageDirectory().timeout(
        const Duration(seconds: 5),
      );
      if (ext == null) return null;
      const marker = '/Android/data/';
      final idx = ext.path.indexOf(marker);
      if (idx <= 0) return null;
      final dir = Directory(ext.path.substring(0, idx));
      if (dir.existsSync()) return dir;
    } catch (_) {
      return null;
    }
    return null;
  }

  static Future<bool> _defaultHasAllFilesAccess() async {
    try {
      return await _deviceChannel.invokeMethod<bool>('hasAllFilesAccess') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _defaultRequestAllFilesAccess() async {
    await _deviceChannel.invokeMethod<void>('openAllFilesSettings');
  }

  Future<MytvBindResult> _resolve() async {
    final docs = await _documentsDir();
    Directory? externalRoot;
    try {
      externalRoot = await _externalRoot();
    } catch (_) {
      externalRoot = null;
    }
    if (externalRoot == null) {
      return _fallbackResult(docs, '外部存储不可用：未找到外置数据库');
    }
    final mytvRoot = Directory(path.join(externalRoot.path, mytvFolderName));
    final dbDir = Directory(path.join(mytvRoot.path, mytvDbFolderName));
    final m3uDir = Directory(path.join(mytvRoot.path, mytvM3uFolderName));
    // 建目录：没权限时这里就抛 EACCES（Android 11+ 根目录写要
    // 所有文件访问权限），进下面的权限分支。
    try {
      dbDir.createSync(recursive: true);
      m3uDir.createSync(recursive: true);
      // 写探针：目录建得出来不等于写得进去，实写一次才算数。
      final probe = File(path.join(dbDir.path, '.mytv_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
    } catch (_) {
      var granted = false;
      try {
        granted = await _hasAllFilesAccess();
      } catch (_) {
        granted = false;
      }
      if (!granted) {
        return _fallbackResult(
          docs,
          '没有所有文件访问权限：未找到外置数据库',
          needsPermission: true,
        );
      }
      return _fallbackResult(docs, 'MYTV 文件夹写不进去：未找到外置数据库');
    }
    // 老 json 影子文件拷进 MYTV/db（只补没有的，不覆盖已有的；
    // 拷失败不影响绑定；用户自己的现爬文件，不是内置数据）。
    try {
      final legacyJsonDir = Directory(
        path.join(docs.path, legacyJsonDirName),
      );
      if (legacyJsonDir.existsSync()) {
        for (final entity in legacyJsonDir.listSync()) {
          if (entity is! File) continue;
          if (!path.basename(entity.path).endsWith('.json')) continue;
          final target = File(path.join(dbDir.path, path.basename(entity.path)));
          if (!target.existsSync()) {
            await entity.copy(target.path);
          }
        }
      }
    } catch (_) {
      // json 拷失败不影响绑定。
    }
    // 唯一数据库：MYTV/db/女优库.db。存在且非空就用它；
    // 没有就是空库（note 写清去哪里放、怎么重读），不回落任何
    // 内置库、不建新库、不悄悄造数据。
    final videoDb = File(path.join(dbDir.path, mytvVideoDbFileName));
    final hasVideoDb = videoDb.existsSync() && videoDb.lengthSync() > 0;
    return MytvBindResult(
      bound: true,
      needsPermission: false,
      root: mytvRoot,
      externalRoot: externalRoot,
      dbDir: dbDir,
      m3uDir: m3uDir,
      jsonDir: dbDir,
      dbPath: hasVideoDb ? videoDb.path : '',
      hasVideoDb: hasVideoDb,
      displayPath: hasVideoDb
          ? '$mytvFolderName/$mytvDbFolderName/$mytvVideoDbFileName'
          : '未找到外置数据库',
      mergedJsonExportPath: path.join(
        mytvRoot.path,
        mytvMergedJsonFileName,
      ),
      note: hasVideoDb
          ? null
          : '未找到外置数据库：请把 女优库.db 放进 MYTV/db/ 文件夹，'
              '再点“重新加载数据库”',
    );
  }

  /// 未绑定结果：没有外置数据库可读（dbPath 为空），女优库显示空态。
  MytvBindResult _fallbackResult(
    Directory docs,
    String? note, {
    bool needsPermission = false,
  }) {
    return MytvBindResult(
      bound: false,
      needsPermission: needsPermission,
      root: docs,
      dbDir: docs,
      m3uDir: Directory(path.join(docs.path, legacyJsonDirName)),
      jsonDir: Directory(path.join(docs.path, legacyJsonDirName)),
      dbPath: '',
      hasVideoDb: false,
      displayPath: '未找到外置数据库',
      mergedJsonExportPath: path.join(docs.path, mytvMergedJsonFileName),
      note: note,
    );
  }
}

/// 共用站点库文件名（MYTV/db/站点库.db）：只记播过的片，是播放
/// 记录库，不当女优库源扫（见 [collectDbMirrorTargets] 的排除），
/// 多库勾选里单独补回、默认不勾。原定义在已删的 actress_site_db
///（写库死代码，2026-11-26 删），常量随读侧扫描一起搬来这里。
const siteDbFileName = '站点库.db';

/// 收集可合并/可勾选的外来 .db 文件（只读扫描，不写任何文件）：
/// 主目录 MYTV/db 只扫一层 + 补充目录递归扫；排除主库本身、
/// 应用库与站点库（播放记录库绝不当女优库源）。原定义在已删的
/// actress_db_mirror（镜像写库，2026-11-26 删），扫描逻辑是读侧
/// 的，多库合并与多库勾选共用，搬来绑定层。
List<File> collectDbMirrorTargets({
  required Directory dbDir,
  required String libraryPath,
  List<Directory> extraDirs = const [],
}) {
  final seen = <String>{};
  final targets = <File>[];
  void add(File file) {
    final normalized = path.normalize(file.path);
    if (!file.path.toLowerCase().endsWith('.db')) return;
    if (path.equals(normalized, path.normalize(libraryPath))) return;
    final baseName = path.basename(file.path);
    if (baseName == '女优库应用.db' || baseName == 'actress.db') return;
    // 共用站点库（MYTV/db/站点库.db）只记播过的片，绝不当女优库
    // 源扫进来——勾选页单独把它补回（默认不勾）。
    if (baseName == siteDbFileName) return;
    if (!seen.add(normalized)) return;
    targets.add(file);
  }

  try {
    for (final entity in dbDir.listSync()) {
      if (entity is File) add(entity);
    }
  } catch (_) {
    // 主目录扫失败：返回已收集到的（可能为空），不抛错。
  }
  for (final dir in extraDirs) {
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) add(entity);
      }
    } catch (_) {
      // 该目录不存在/扫失败：跳过，不影响其他目录。
    }
  }
  return targets;
}
